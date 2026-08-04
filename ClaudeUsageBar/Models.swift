import Foundation

struct UsageResponse: Codable {
    let fiveHour: UsageBucket
    let sevenDay: UsageBucket
    let sevenDayOpus: UsageBucket?
    let limits: [UsageLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case limits
    }

    /// Per-model weekly limits (e.g. Fable) surfaced in the `limits` array as
    /// `weekly_scoped` entries with a model scope.
    var scopedModelLimits: [UsageLimit] {
        (limits ?? []).filter { $0.kind == "weekly_scoped" && $0.scope?.model?.displayName != nil }
    }
}

struct UsageLimit: Codable {
    let kind: String
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let scope: LimitScope?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, scope
        case resetsAt = "resets_at"
    }
}

struct LimitScope: Codable {
    let model: LimitScopeModel?
}

struct LimitScopeModel: Codable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct UsageBucket: Codable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
