import Foundation

struct UsageResponse: Codable {
    let fiveHour: UsageBucket
    let sevenDay: UsageBucket
    let sevenDayOpus: UsageBucket?
    let limits: [UsageLimit]?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case limits
        case extraUsage = "extra_usage"
    }

    /// Per-model weekly limits (e.g. Fable) surfaced in the `limits` array as
    /// `weekly_scoped` entries with a model scope.
    var scopedModelLimits: [UsageLimit] {
        (limits ?? []).filter { $0.kind == "weekly_scoped" && $0.scope?.model?.displayName != nil }
    }
}

/// Extra-usage ("usage credits" / overage) spend for the billing period, present
/// when the plan has it. Amounts are in minor units of `currency` (cents for USD).
struct ExtraUsage: Codable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?
    /// Why extra usage is currently disabled (e.g. out of credits), when it is.
    let disabledReason: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case disabledReason = "disabled_reason"
        case utilization, currency
    }

    /// Spend as a percentage of the monthly limit, or nil when there is no limit.
    var percentOfLimit: Double? {
        guard let usedCredits, let monthlyLimit, monthlyLimit > 0 else { return nil }
        return usedCredits / monthlyLimit * 100
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
