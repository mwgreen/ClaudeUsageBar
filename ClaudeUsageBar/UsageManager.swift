import Foundation
import Combine
import os

enum APIError: LocalizedError {
    case rateLimited
    case httpError(statusCode: Int, body: String)
    case oauthRefreshFailed(statusCode: Int, body: String)
    /// The token endpoint rate-limited a refresh recently; no request was made.
    case refreshBackingOff(until: Date)

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
        case .refreshBackingOff(let until):
            let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
            return "Token refresh rate-limited; retrying in \(minutes) min"
        }
    }
}

@MainActor
final class UsageManager: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var isStale: Bool = false
    /// Non-nil when this profile has no usable login: the Keychain item is gone
    /// (`claude logout` deletes it) or the token expired and could not be
    /// refreshed. The account is hidden from the menu bar until a login reappears.
    @Published var loggedOutReason: String?

    var isLoggedOut: Bool { loggedOutReason != nil }

    /// Keychain service name of the credential item this instance tracks.
    let service: String

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300 // 5 minutes
    private var cachedCreds: ClaudeCredentials?
    private var claudeVersion: String = "2.0.31"
    private var consecutiveFailures: Int = 0
    private let maxFailuresBeforeStale: Int = 3 // ~15 min at 5-min intervals

    /// Exponential backoff for the OAuth token endpoint. Retrying a 429'd
    /// refresh on every 5-minute poll kept one account throttled for a week;
    /// after a 429 the next attempt waits 10, 20, 40 … minutes, capped at an
    /// hour. Every poll still re-reads the Keychain, so a token the CLI refreshed
    /// in the meantime is used at once and clears the backoff.
    private var refreshBackoffUntil: Date?
    private var refreshBackoffStep: Int = 0
    private let refreshBackoffBase: TimeInterval = 600 // 10 minutes
    private let refreshBackoffMax: TimeInterval = 3600 // 1 hour

    /// Poll outcomes go to the unified log as public messages (NSLog text is
    /// redacted to <private> there):
    ///   /usr/bin/log show --predicate 'subsystem == "com.mwgreen.ClaudeUsageBar"' --last 1h
    private let log = Logger(subsystem: "com.mwgreen.ClaudeUsageBar", category: "usage")

    // Claude Code's public OAuth client. Same ID used by the CLI.
    private let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Token endpoint and request shape mirror Claude Code 2.1.x: JSON body
    /// with the CLI's default scopes on platform.claude.com. The old
    /// form-encoded POST to claude.ai/v1/oauth/token answered every refresh
    /// with 429 even though the CLI refreshed the same token fine.
    private let oauthTokenURL = "https://platform.claude.com/v1/oauth/token"
    private let oauthScopes = [
        "user:profile", "user:inference", "user:sessions:claude_code",
        "user:mcp_servers", "user:file_upload"
    ]
    /// Refresh proactively if the access token expires within this window.
    private let refreshSkew: TimeInterval = 60

    init(service: String) {
        self.service = service
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
            try applySuccessfulFetch(data)
        } catch let error as URLError where error.code == .userAuthenticationRequired {
            // Access token was rejected despite passing the expiry check — force
            // a refresh and retry once. If that fails too, surface the error.
            do {
                let refreshed = try await forceRefreshCredentials()
                let data = try await fetchUsage(token: refreshed.accessToken)
                try applySuccessfulFetch(data)
            } catch {
                handleRefreshFailure(error: error)
            }
        } catch {
            handleRefreshFailure(error: error)
        }
    }

    private func applySuccessfulFetch(_ data: Data) throws {
        let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
        logFetch(data, decoded)
        usage = decoded
        errorMessage = nil
        loggedOutReason = nil
        lastUpdated = Date()
        consecutiveFailures = 0
        isStale = false
    }

    private func ensureFreshCredentials() async throws -> ClaudeCredentials {
        // Attributes-only existence check (no decrypt, so no ACL prompt) so that
        // `claude logout`, which deletes the item, is noticed on the next poll
        // even while a cached access token would still be accepted by the API.
        guard KeychainHelper.itemExists(service: service) else {
            cachedCreds = nil
            throw KeychainError.itemNotFound
        }
        if cachedCreds == nil {
            cachedCreds = try KeychainHelper.readCredentials(service: service)
        }
        guard var creds = cachedCreds else { throw KeychainError.itemNotFound }

        if creds.expiresAt.timeIntervalSinceNow > refreshSkew {
            return creds
        }

        // Re-read keychain first in case another Claude Code instance just refreshed.
        creds = try KeychainHelper.readCredentials(service: service)
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
            current = try KeychainHelper.readCredentials(service: service)
        }
        guard !current.refreshToken.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        if let until = refreshBackoffUntil, until > Date() {
            throw APIError.refreshBackingOff(until: until)
        }

        let refreshed = try await performOAuthRefresh(refreshToken: current.refreshToken)
        refreshBackoffUntil = nil
        refreshBackoffStep = 0
        try KeychainHelper.writeBackCredentials(
            service: service,
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
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/\(claudeVersion)", forHTTPHeaderField: "User-Agent")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientId,
            "scope": oauthScopes.joined(separator: " ")
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
        // A missing or unusable login isn't an error to flag — the profile is
        // logged out (or its login expired). Hide it until a fresh login shows
        // up in the Keychain; clearing the cache makes the next poll re-read it.
        if let reason = loggedOutReason(for: error) {
            log.notice("[\(self.service, privacy: .public)] \(reason, privacy: .public): \(error.localizedDescription, privacy: .public)")
            loggedOutReason = reason
            usage = nil
            isStale = false
            errorMessage = nil
            cachedCreds = nil
            consecutiveFailures = 0
            return
        }

        log.error("[\(self.service, privacy: .public)] refresh failed: \(error.localizedDescription, privacy: .public)")
        consecutiveFailures += 1

        // 429 is rate limiting — keep showing last-known data as stale.
        // Don't clear the cached token: rate limiting doesn't mean the token is
        // invalid, and clearing it forces a Keychain read that can trigger a
        // macOS password prompt (blocking all refreshes if the user is away).
        if let apiError = error as? APIError {
            switch apiError {
            case .rateLimited:
                if usage != nil {
                    self.isStale = true
                    self.errorMessage = nil // cached data IS the display, not an error
                }
                return
            case .oauthRefreshFailed(let status, _) where status == 429:
                // Arm (or lengthen) the backoff so the next polls skip the token
                // endpoint instead of hammering it while it is throttling us.
                let delay = min(refreshBackoffBase * pow(2, Double(refreshBackoffStep)), refreshBackoffMax)
                refreshBackoffStep += 1
                refreshBackoffUntil = Date().addingTimeInterval(delay)
                log.notice("[\(self.service, privacy: .public)] token refresh backing off for \(Int(delay / 60)) min")
                fallthrough
            case .refreshBackingOff:
                if usage != nil {
                    self.isStale = true
                    self.errorMessage = nil
                } else {
                    self.errorMessage = APIError.refreshBackingOff(until: refreshBackoffUntil ?? Date()).localizedDescription
                }
                return
            default:
                break
            }
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

    /// Classifies errors that mean "no usable login" rather than a transient
    /// failure: no credential item (or one without a token), an OAuth refresh the
    /// server rejected as invalid, or an access token the API still refuses
    /// after a forced refresh. Network errors, 5xx and 429 are not included.
    private func loggedOutReason(for error: Error) -> String? {
        if let keychainError = error as? KeychainError {
            switch keychainError {
            case .itemNotFound, .noTokenField: return "Not logged in"
            default: return nil
            }
        }
        if let apiError = error as? APIError,
           case .oauthRefreshFailed(let status, _) = apiError,
           [400, 401, 403].contains(status) {
            return "Login expired"
        }
        if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
            return "Login expired"
        }
        return nil
    }

    /// One line per successful poll in the unified log, including the raw
    /// extra_usage value so a vanished amount can be traced to what the server
    /// actually sent.
    private func logFetch(_ data: Data, _ decoded: UsageResponse) {
        var extraDescription = "absent"
        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let value = root["extra_usage"] {
            extraDescription = value is NSNull
                ? "null"
                : String(describing: value).replacingOccurrences(of: "\n", with: " ")
        }
        let fiveHour = Int(decoded.fiveHour.utilization.rounded())
        let sevenDay = Int(decoded.sevenDay.utilization.rounded())
        log.notice("[\(self.service, privacy: .public)] usage ok: 5h=\(fiveHour)% 7d=\(sevenDay)% extra_usage=\(extraDescription, privacy: .public)")
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

    struct Metric {
        let name: String
        let percent: Double
        let resetsAt: String?
    }

    /// Buckets in display order for the compact menu bar line: 5h, 7d, then any
    /// per-model weekly limits (e.g. Fable).
    var metrics: [Metric] {
        guard let usage else { return [] }
        var out = [
            Metric(name: "5h", percent: usage.fiveHour.utilization, resetsAt: usage.fiveHour.resetsAt),
            Metric(name: "7d", percent: usage.sevenDay.utilization, resetsAt: usage.sevenDay.resetsAt)
        ]
        for limit in usage.scopedModelLimits {
            guard let name = limit.scope?.model?.displayName, let percent = limit.percent else { continue }
            out.append(Metric(name: name, percent: percent, resetsAt: limit.resetsAt))
        }
        return out
    }

    /// Extra-usage ("usage credits") spend for the billing period, when the
    /// plan has it enabled. Money strings are formatted in the response currency.
    struct ExtraUsageSummary {
        /// Formatted spend, when the server reports one. While extra usage is
        /// disabled (e.g. out_of_credits) the server sends used_credits as null.
        let used: String?
        let limit: String?
        /// Spend as a percentage of the monthly limit; nil when there is no limit.
        let percent: Double?
        let hasSpend: Bool
        /// False while the server says extra usage can't cover sends.
        let isEnabled: Bool
        /// Server's reason when disabled, e.g. "out_of_credits".
        let disabledReason: String?
    }

    /// Non-nil when there is something to say: a reported spend amount, or
    /// extra usage disabled for a stated reason. An account that simply has
    /// extra usage switched off yields nil.
    var extraUsage: ExtraUsageSummary? {
        guard let extra = usage?.extraUsage else { return nil }
        let enabled = extra.isEnabled ?? true
        guard extra.usedCredits != nil || (!enabled && extra.disabledReason != nil) else { return nil }
        let currency = extra.currency ?? "USD"
        return ExtraUsageSummary(
            used: extra.usedCredits.map { formatMoney(minorUnits: $0, currency: currency) },
            limit: extra.monthlyLimit.map { formatMoney(minorUnits: $0, currency: currency) },
            percent: extra.percentOfLimit,
            hasSpend: (extra.usedCredits ?? 0) > 0,
            isEnabled: enabled,
            disabledReason: extra.disabledReason
        )
    }

    private func formatMoney(minorUnits: Double, currency: String) -> String {
        let amount = minorUnits / 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, currency)
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
