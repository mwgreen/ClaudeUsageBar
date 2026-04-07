import Foundation
import Combine

@MainActor
final class UsageManager: ObservableObject {
    @Published var usage: UsageResponse?
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300 // 5 minutes

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
        do {
            let token = try KeychainHelper.readOAuthToken()
            let data = try await fetchUsage(token: token)
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
            self.usage = decoded
            self.errorMessage = nil
            self.lastUpdated = Date()
        } catch {
            self.errorMessage = error.localizedDescription
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
        request.setValue("claude-code/2.0.31", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
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
        return "\(dot) 5h: \(h5)% | 7d: \(d7)%"
    }

    func colorDot(for utilization: Double) -> String {
        switch utilization {
        case ..<50: return "\u{1F7E2}"   // green circle
        case 50..<80: return "\u{1F7E1}" // yellow circle
        default: return "\u{1F534}"      // red circle
        }
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

    private func parseISO8601(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: str) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }
}
