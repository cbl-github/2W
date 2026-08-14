import Foundation

/// 天数档位。批量退订的两个时长条件共用同一组档位。
enum StaleWindow: Int, CaseIterable, Identifiable {
    case any = 0
    case d3 = 3
    case d7 = 7
    case d15 = 15
    case d30 = 30

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .any: "不限"
        case .d3: "3 天"
        case .d7: "7 天"
        case .d15: "15 天"
        case .d30: "30 天及以上"
        }
    }
}

/// 批量退订的筛选条件。各条件之间取交集。
struct FeedCleanupFilter: Equatable {
    /// 未更新时长：距最后一篇文章的天数。
    var notUpdated: StaleWindow = .any
    /// 近期未读：距最后一篇已读文章的天数。
    var notRead: StaleWindow = .any
    /// 硬错误或抓取失败的订阅。
    var failing = false

    /// 从未收到文章、从未读过的订阅在任何档位下均命中：它们比任何天数都糟。
    func matches(_ row: FeedHealthRow, now: Date = Date()) -> Bool {
        if notUpdated != .any {
            let days = row.staleDays(now: now)
            guard days == nil || days! >= notUpdated.rawValue else { return false }
        }
        if notRead != .any {
            let days = row.readIdleDays(now: now)
            guard days == nil || days! >= notRead.rawValue else { return false }
        }
        if failing, !row.feed.isHardErrored, row.feed.fetchError == nil { return false }
        return true
    }

    /// 未更新越久排越前；同档按名称。
    static func sorted(_ rows: [FeedHealthRow], now: Date = Date()) -> [FeedHealthRow] {
        rows.sorted { a, b in
            let x = a.staleDays(now: now) ?? .max
            let y = b.staleDays(now: now) ?? .max
            if x != y { return x > y }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}
