import Foundation
import Combine
import os

enum APIError: LocalizedError {
    case rateLimited
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "Rate limited (429)"
        case .httpError(let statusCode, let body):
            let truncated = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "HTTP \(statusCode): \(truncated)"
        }
    }
}

/// The Keychain holds a login, but its access token is past its expiry.
enum CredentialError: LocalizedError {
    case expired

    var errorDescription: String? {
        switch self {
        case .expired: return "stored access token is past its expiry"
        }
    }
}

@MainActor
final class UsageManager: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var isStale: Bool = false
    /// Non-nil when this profile has no usable login, which hides the account
    /// from the menu bar: the Keychain item is gone (`claude logout` deletes
    /// it) or its access token has expired. The app never refreshes tokens
    /// itself (see `usableCredentials`), so an expired token stays unusable
    /// until the CLI refreshes it, which any `claude` command under that
    /// profile does; the row returns on the next poll after that.
    @Published var loggedOutReason: String?

    var isLoggedOut: Bool { loggedOutReason != nil }

    static let notLoggedInReason = "Not logged in"
    static let tokenExpiredReason = "Token expired \u{2014} run any claude command under this profile to refresh it"

    /// Keychain service name of the credential item this instance tracks.
    let service: String

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300 // 5 minutes
    private var cachedCreds: ClaudeCredentials?
    private var claudeVersion: String = "2.0.31"
    private var consecutiveFailures: Int = 0
    private let maxFailuresBeforeStale: Int = 3 // ~15 min at 5-min intervals

    /// Poll outcomes go to the unified log as public messages (NSLog text is
    /// redacted to <private> there):
    ///   /usr/bin/log show --predicate 'subsystem == "com.mwgreen.ClaudeUsageBar"' --last 1h
    private let log = Logger(subsystem: "com.mwgreen.ClaudeUsageBar", category: "usage")

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
            let creds = try usableCredentials()
            let data = try await fetchUsage(token: creds.accessToken)
            try applySuccessfulFetch(data)
        } catch let error as URLError where error.code == .userAuthenticationRequired {
            // The API rejected a token that looked unexpired. Re-read the
            // Keychain once in case the CLI rotated it since we cached it; if
            // the stored token is still refused, treat it as expired.
            cachedCreds = nil
            do {
                let creds = try usableCredentials()
                let data = try await fetchUsage(token: creds.accessToken)
                try applySuccessfulFetch(data)
            } catch {
                handleFailure(error: error)
            }
        } catch {
            handleFailure(error: error)
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

    /// The token the CLI stored, provided it is still valid.
    ///
    /// The app deliberately never calls the OAuth token endpoint. It refused
    /// this app's refreshes outright (429 on the first attempt) while the CLI
    /// refreshed the very same token without trouble, and a refresh that did
    /// succeed would rotate the refresh token underneath a running CLI session.
    /// So the app is a read-only consumer of the CLI's tokens: it re-reads the
    /// Keychain whenever the cached token is expired, and a token the CLI has
    /// refreshed in the meantime is used on the next poll.
    private func usableCredentials() throws -> ClaudeCredentials {
        // Attributes-only existence check (no decrypt, so no ACL prompt) so that
        // `claude logout`, which deletes the item, is noticed on the next poll
        // even while a cached access token would still be accepted by the API.
        guard KeychainHelper.itemExists(service: service) else {
            cachedCreds = nil
            throw KeychainError.itemNotFound
        }
        if let creds = cachedCreds, creds.isUsable {
            return creds
        }
        let creds = try KeychainHelper.readCredentials(service: service)
        cachedCreds = creds
        guard creds.isUsable else { throw CredentialError.expired }
        return creds
    }

    private func handleFailure(error: Error) {
        // A missing or expired login isn't an error to flag — the row is hidden
        // until a usable token shows up in the Keychain. Clearing the cache
        // makes the next poll re-read it.
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

        log.error("[\(self.service, privacy: .public)] fetch failed: \(error.localizedDescription, privacy: .public)")
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

    /// Classifies errors that mean "no usable login" rather than a transient
    /// failure: no credential item (or one without a token), an access token
    /// past its stored expiry, or one the API refuses even after re-reading the
    /// Keychain. Network errors, 5xx and 429 are not included.
    private func loggedOutReason(for error: Error) -> String? {
        if let keychainError = error as? KeychainError {
            switch keychainError {
            case .itemNotFound, .noTokenField: return Self.notLoggedInReason
            default: return nil
            }
        }
        if error is CredentialError {
            return Self.tokenExpiredReason
        }
        if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
            return Self.tokenExpiredReason
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
