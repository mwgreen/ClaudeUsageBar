import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case unexpectedData
    case noTokenField
    case securityError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Claude Code credentials not found in Keychain"
        case .unexpectedData:
            return "Could not read Keychain data"
        case .noTokenField:
            return "No OAuth token found in stored credentials"
        case .securityError(let status):
            return "Keychain error: \(status)"
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
    private static let service = "Claude Code-credentials"

    /// Reads the full Claude Code credential blob. Falls back to searching any
    /// string that looks like an access token if the JSON shape is unexpected,
    /// in which case refreshToken/expiresAt are empty/distant-past and callers
    /// must treat the token as non-refreshable.
    static func readCredentials() throws -> ClaudeCredentials {
        let data = try readKeychainData()

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

    /// Backward-compatible helper that returns just the access token.
    static func readOAuthToken() throws -> String {
        return try readCredentials().accessToken
    }

    /// Writes updated tokens back to the keychain, preserving the rest of the
    /// stored JSON (e.g. mcpOAuth, subscriptionType, scopes) so Claude CLI is
    /// not disrupted.
    static func writeBackCredentials(accessToken: String, refreshToken: String, expiresAt: Date) throws {
        let existing = try readKeychainData()

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

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let attrs: [String: Any] = [kSecValueData as String: updated]

        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        guard status == errSecSuccess else {
            throw KeychainError.securityError(status)
        }
    }

    private static func readKeychainData() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else { throw KeychainError.itemNotFound }
        guard status == errSecSuccess else { throw KeychainError.securityError(status) }
        guard let data = result as? Data else { throw KeychainError.unexpectedData }
        return data
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
