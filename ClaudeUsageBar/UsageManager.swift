import Foundation
import Combine

enum APIError: LocalizedError {
    case rateLimited
    case httpError(statusCode: Int, body: String)
    case oauthRefreshFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "Rate limited (429)"
        case .httpError(let statusCode, let body):
            let truncated = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "HTTP \(statusCode): \(truncated)"
        case .oauthRefreshFailed(let statusCode, let body):
            let truncated = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "OAuth refresh failed (\(statusCode)): \(truncated)"
        }
    }
}

@MainActor
final class UsageManager: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var isStale: Bool = false

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300 // 5 minutes
    private var cachedCreds: ClaudeCredentials?
    private var claudeVersion: String = "2.0.31"
    private var consecutiveFailures: Int = 0
    private let maxFailuresBeforeStale: Int = 3 // ~15 min at 5-min intervals

    // Claude Code's public OAuth client. Same ID used by the CLI.
    private let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let oauthTokenURL = "https://claude.ai/v1/oauth/token"
    /// Refresh proactively if the access token expires within this window.
    private let refreshSkew: TimeInterval = 60

    init() {
        Task { [weak self] in
            await self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() async {
        claudeVersion = detectClaudeCodeVersion() ?? "2.0.31"
        do {
            let creds = try await ensureFreshCredentials()
            let data = try await fetchUsage(token: creds.accessToken)
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            self.usage = decoded
            self.errorMessage = nil
            self.lastUpdated = Date()
            self.consecutiveFailures = 0
            self.isStale = false
        } catch let error as URLError where error.code == .userAuthenticationRequired {
            // Access token was rejected despite passing the expiry check — force
            // a refresh and retry once. If that fails too, surface the error.
            do {
                let refreshed = try await forceRefreshCredentials()
                let data = try await fetchUsage(token: refreshed.accessToken)
                let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
                self.usage = decoded
                self.errorMessage = nil
                self.lastUpdated = Date()
                self.consecutiveFailures = 0
                self.isStale = false
            } catch {
                handleRefreshFailure(error: error)
            }
        } catch {
            handleRefreshFailure(error: error)
        }
    }

    private func ensureFreshCredentials() async throws -> ClaudeCredentials {
        if cachedCreds == nil {
            cachedCreds = try KeychainHelper.readCredentials()
        }
        guard var creds = cachedCreds else { throw KeychainError.itemNotFound }

        if creds.expiresAt.timeIntervalSinceNow > refreshSkew {
            return creds
        }

        // Re-read keychain first in case another Claude Code instance just refreshed.
        creds = try KeychainHelper.readCredentials()
        cachedCreds = creds
        if creds.expiresAt.timeIntervalSinceNow > refreshSkew {
            return creds
        }

        return try await forceRefreshCredentials()
    }

    private func forceRefreshCredentials() async throws -> ClaudeCredentials {
        let current: ClaudeCredentials
        if let cached = cachedCreds {
            current = cached
        } else {
            current = try KeychainHelper.readCredentials()
        }
        guard !current.refreshToken.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }

        let refreshed = try await performOAuthRefresh(refreshToken: current.refreshToken)
        try KeychainHelper.writeBackCredentials(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken,
            expiresAt: refreshed.expiresAt
        )
        cachedCreds = refreshed
        return refreshed
    }

    private func performOAuthRefresh(refreshToken: String) async throws -> ClaudeCredentials {
        guard let url = URL(string: oauthTokenURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/\(claudeVersion)", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: oauthClientId),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.oauthRefreshFailed(statusCode: http.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw APIError.oauthRefreshFailed(statusCode: http.statusCode, body: "no access_token in response")
        }
        let newRefresh = (json["refresh_token"] as? String) ?? refreshToken
        let expiresIn = (json["expires_in"] as? Double) ?? 36_000
        return ClaudeCredentials(
            accessToken: access,
            refreshToken: newRefresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private func handleRefreshFailure(error: Error) {
        consecutiveFailures += 1

        // 429 is rate limiting — keep showing last-known data as stale.
        // Don't clear the cached token: rate limiting doesn't mean the token is
        // invalid, and clearing it forces a Keychain read that can trigger a
        // macOS password prompt (blocking all refreshes if the user is away).
        if let apiError = error as? APIError, case .rateLimited = apiError {
            if usage != nil {
                self.isStale = true
                self.errorMessage = nil // cached data IS the display, not an error
            }
            return
        }

        self.errorMessage = error.localizedDescription

        // After repeated failures, clear stale usage data so menu bar shows ⚪ --
        if consecutiveFailures >= maxFailuresBeforeStale {
            self.usage = nil
            self.isStale = false
        }

        // Force re-read from keychain on persistent errors
        if consecutiveFailures >= 2 {
            cachedCreds = nil
        }
    }

    private func fetchUsage(token: String) async throws -> Data {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/\(claudeVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw URLError(.userAuthenticationRequired)
            }
            if httpResponse.statusCode == 429 {
                throw APIError.rateLimited
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        return data
    }

    // MARK: - Display helpers

    var menuBarText: String {
        guard let usage else {
            if errorMessage != nil {
                return "\u{26AA} --"
            }
            return "\u{26AA} --"
        }
        let h5 = Int(usage.fiveHour.utilization.rounded())
        let d7 = Int(usage.sevenDay.utilization.rounded())
        let dot = colorDot(for: max(usage.fiveHour.utilization, usage.sevenDay.utilization))
        let staleIndicator = isStale ? " \u{29D6}" : ""
        return "\(dot) 5h: \(h5)% | 7d: \(d7)%\(staleIndicator)"
    }

    func colorDot(for utilization: Double) -> String {
        switch utilization {
        case ..<50: return "\u{1F7E2}"   // green circle
        case 50..<80: return "\u{1F7E1}" // yellow circle
        default: return "\u{1F534}"      // red circle
        }
    }

    var lastUpdatedText: String {
        guard let lastUpdated else { return "Never" }
        let elapsed = Date().timeIntervalSince(lastUpdated)
        if elapsed < 60 { return "Just now" }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m ago"
    }

    func relativeReset(from isoString: String?) -> String {
        guard let isoString, let date = parseISO8601(isoString) else {
            return "unknown"
        }
        let now = Date()
        if date <= now { return "resetting soon" }

        let diff = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: date)
        var parts: [String] = []
        if let d = diff.day, d > 0 { parts.append("\(d)d") }
        if let h = diff.hour, h > 0 { parts.append("\(h)h") }
        if let m = diff.minute, m > 0 { parts.append("\(m)m") }
        return parts.isEmpty ? "soon" : "resets in \(parts.joined(separator: " "))"
    }

    private nonisolated func detectClaudeCodeVersion() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return nil
    }

    private func parseISO8601(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: str) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }
}
