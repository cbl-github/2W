import Foundation

/// 「多久没更新」的筛选档位。
enum StaleWindow: Int, CaseIterable, Identifiable {
    case any = 0
    case d3 = 3
    case d7 = 7
    case d15 = 15
    case d30 = 30

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .any: "全部"
        case .d3: "3 天"
        case .d7: "7 天"
        case .d15: "15 天"
        case .d30: "30 天及以上"
        }
    }
}

/// 批量退订的筛选条件。三个条件之间是「同时满足」。
struct FeedCleanupFilter: Equatable {
    var stale: StaleWindow = .any
    /// 近 30 天到过新文章，但一篇都没读——订了不看的典型信号。
    var onlyIgnored = false
    /// 硬错误或抓取失败的源。
    var onlyFailing = false

    /// 从未有过文章的源，任何停更档位都算命中：它比"停更 30 天"更糟。
    func matches(_ row: FeedHealthRow, now: Date = Date()) -> Bool {
        if stale != .any {
            let days = row.staleDays(now: now)
            guard days == nil || days! >= stale.rawValue else { return false }
        }
        if onlyIgnored, !(row.recentCount > 0 && row.recentReadCount == 0) { return false }
        if onlyFailing, row.feed.isHardErrored == false, row.feed.fetchError == nil { return false }
        return true
    }

    /// 越"该退订"的排越前：从未更新 > 停更久 > 停更短。
    static func sorted(_ rows: [FeedHealthRow], now: Date = Date()) -> [FeedHealthRow] {
        rows.sorted { a, b in
            let x = a.staleDays(now: now) ?? .max
            let y = b.staleDays(now: now) ?? .max
            if x != y { return x > y }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}
