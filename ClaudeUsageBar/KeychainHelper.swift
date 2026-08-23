import CryptoKit
import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case unexpectedData
    case noTokenField
    case securityError(Int32, String)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Claude Code credentials not found in Keychain"
        case .unexpectedData:
            return "Could not read Keychain data"
        case .noTokenField:
            return "No OAuth token found in stored credentials"
        case .securityError(let code, let message):
            return message.isEmpty ? "Keychain error: \(code)" : "Keychain error: \(message)"
        }
    }
}

struct ClaudeCredentials {
    var accessToken: String
    var refreshToken: String
    /// Absolute expiration time. The keychain stores this as milliseconds since epoch.
    var expiresAt: Date
}

struct KeychainHelper {
    /// The service name of the default (non-profile) Claude CLI credential item.
    static let defaultService = "Claude Code-credentials"

    /// Lists all keychain generic-password services that look like Claude CLI
    /// credential items ("Claude Code-credentials" plus the hash-suffixed
    /// variants created per CLAUDE_CONFIG_DIR profile). Attribute-only query,
    /// so no decryption and no ACL prompt.
    static func discoverServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return [defaultService]
        }
        let services = Set(items.compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix(defaultService) })
        // Default item first, then suffixed profiles alphabetically.
        return services.sorted { a, b in
            if a == defaultService { return true }
            if b == defaultService { return false }
            return a < b
        }
    }

    /// Maps credential service names to friendly profile names. The CLI derives
    /// each profile's keychain suffix from sha256(CLAUDE_CONFIG_DIR)[0..<8], so
    /// hashing the ~/.claude-* directories recovers the dir behind each item.
    static func profileNames() -> [String: String] {
        var map = [defaultService: "default"]
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let entries = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        for entry in entries where entry.hasPrefix(".claude-") {
            let path = home + "/" + entry
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            let digest = SHA256.hash(data: Data(path.utf8))
            let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
            map["\(defaultService)-\(suffix)"] = String(entry.dropFirst(".claude-".count))
        }
        return map
    }

    /// Reads the full Claude Code credential blob. Falls back to searching any
    /// string that looks like an access token if the JSON shape is unexpected,
    /// in which case refreshToken/expiresAt are empty/distant-past and callers
    /// must treat the token as non-refreshable.
    static func readCredentials(service: String) throws -> ClaudeCredentials {
        let data = try readKeychainData(service: service)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let raw = String(data: data, encoding: .utf8),
               let token = extractAccessToken(from: raw) {
                return ClaudeCredentials(accessToken: token, refreshToken: "", expiresAt: .distantPast)
            }
            throw KeychainError.unexpectedData
        }

        // Claude Code wraps the user credential under "claudeAiOauth"; sibling keys
        // like "mcpOAuth" hold other entries and must be preserved on write-back.
        let creds = (root["claudeAiOauth"] as? [String: Any]) ?? root

        if let access = creds["accessToken"] as? String, !access.isEmpty {
            let refresh = (creds["refreshToken"] as? String) ?? ""
            let expiresAt: Date
            if let ms = creds["expiresAt"] as? Double {
                expiresAt = Date(timeIntervalSince1970: ms / 1000.0)
            } else if let ms = creds["expiresAt"] as? Int {
                expiresAt = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
            } else {
                expiresAt = .distantPast
            }
            return ClaudeCredentials(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
        }

        if let token = findAccessToken(in: root) {
            return ClaudeCredentials(accessToken: token, refreshToken: "", expiresAt: .distantPast)
        }

        throw KeychainError.noTokenField
    }

    /// Writes updated tokens back to the keychain, preserving the rest of the
    /// stored JSON (e.g. mcpOAuth, subscriptionType, scopes) so Claude CLI is
    /// not disrupted.
    static func writeBackCredentials(service: String, accessToken: String, refreshToken: String, expiresAt: Date) throws {
        let existing = try readKeychainData(service: service)

        guard var root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw KeychainError.unexpectedData
        }

        let expiresMs = Int(expiresAt.timeIntervalSince1970 * 1000)

        if var wrapper = root["claudeAiOauth"] as? [String: Any] {
            wrapper["accessToken"] = accessToken
            wrapper["refreshToken"] = refreshToken
            wrapper["expiresAt"] = expiresMs
            root["claudeAiOauth"] = wrapper
        } else {
            root["accessToken"] = accessToken
            root["refreshToken"] = refreshToken
            root["expiresAt"] = expiresMs
        }

        let updated = try JSONSerialization.data(withJSONObject: root, options: [])
        guard let updatedString = String(data: updated, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }

        // Claude Code CLI writes/reads via /usr/bin/security, which leaves the item's
        // ACL allowing only `security` to decrypt. Updating via Security.framework
        // from this app fails with errSecAuthFailed because the bundle isn't in the
        // ACL — and re-granting requires the user's password (apple-tool partition).
        // Shell out instead: `security` is in the ACL and the "encrypt" entry is
        // unrestricted, so updates go through without prompting.
        let result = runSecurity([
            "add-generic-password",
            "-s", service,
            "-a", NSUserName(),
            "-w", updatedString,
            "-U"
        ])
        if result.exitCode != 0 {
            throw KeychainError.securityError(result.exitCode, result.stderr)
        }
    }

    private static func readKeychainData(service: String) throws -> Data {
        let result = runSecurity(["find-generic-password", "-s", service, "-w"])

        // `security` exits 44 (SEC_E_ITEM_NOT_FOUND) when no matching item exists.
        if result.exitCode == 44 {
            throw KeychainError.itemNotFound
        }
        guard result.exitCode == 0 else {
            throw KeychainError.securityError(result.exitCode, result.stderr)
        }

        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return data
    }

    private struct ProcessResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private static func runSecurity(_ arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private static func findAccessToken(in json: [String: Any]) -> String? {
        let tokenKeys = ["oauth_token", "token", "access_token", "oauthToken", "accessToken"]
        for key in tokenKeys {
            if let token = json[key] as? String, token.hasPrefix("sk-ant-oat01-") {
                return token
            }
        }
        for (_, value) in json {
            if let str = value as? String, str.hasPrefix("sk-ant-oat01-") {
                return str
            }
            if let nested = value as? [String: Any], let token = findAccessToken(in: nested) {
                return token
            }
        }
        return nil
    }

    private static func extractAccessToken(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-oat01-") ? trimmed : nil
    }
}
