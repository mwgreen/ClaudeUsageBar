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

struct KeychainHelper {
    static func readOAuthToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }
        guard status == errSecSuccess else {
            throw KeychainError.securityError(status)
        }
        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }

        // The stored value is JSON — parse it to find the OAuth token
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Maybe it's stored as a plain string
            if let raw = String(data: data, encoding: .utf8) {
                if let token = extractToken(from: raw) {
                    return token
                }
            }
            throw KeychainError.unexpectedData
        }

        if let token = findToken(in: json) {
            return token
        }

        throw KeychainError.noTokenField
    }

    private static func findToken(in json: [String: Any]) -> String? {
        // Check common field names for the OAuth token
        let tokenKeys = ["oauth_token", "token", "access_token", "oauthToken", "accessToken"]
        for key in tokenKeys {
            if let token = json[key] as? String, token.hasPrefix("sk-ant-oat01-") {
                return token
            }
        }

        // Walk all string values looking for the token pattern
        for (_, value) in json {
            if let str = value as? String, str.hasPrefix("sk-ant-oat01-") {
                return str
            }
            if let nested = value as? [String: Any], let token = findToken(in: nested) {
                return token
            }
        }

        return nil
    }

    private static func extractToken(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("sk-ant-oat01-") {
            return trimmed
        }
        return nil
    }
}
