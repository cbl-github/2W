import Foundation
import GRDB

/// 搜索的时间范围限定。since 为 nil = 不限。
enum SearchWindow: String, Codable, CaseIterable, Sendable {
    case any, week, month, year

    var label: String {
        switch self {
        case .any: "不限时间"
        case .week: "最近 7 天"
        case .month: "最近 30 天"
        case .year: "最近一年"
        }
    }

    func since(now: Date = Date()) -> Date? {
        switch self {
        case .any: nil
        case .week: now.addingTimeInterval(-7 * 86400)
        case .month: now.addingTimeInterval(-30 * 86400)
        case .year: now.addingTimeInterval(-365 * 86400)
        }
    }
}

/// 保存的搜索：词 + 范围 + 时间窗 + 保存时的未读/星标过滤，作为侧栏的智能源常驻。
struct SavedSearch: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "savedSearch"
    var id: Int64?
    var name: String
    var query: String
    /// "all" | "folder" | "feed"
    var scopeKind: String
    var scopeId: Int64?
    var window: String
    var createdAt: Date
    /// 保存时的列表过滤（SettingsKey.readFilter 取值）；点开这条搜索时恢复它。
    var filter: String = "all"

    var searchWindow: SearchWindow { SearchWindow(rawValue: window) ?? .any }

    /// 分组或订阅被删后 scopeId 成为死引用，回落到「全部文章」而不是给出空列表。
    func scopeSelection(feedIds: Set<Int64>, folderIds: Set<Int64>) -> SidebarSelection {
        switch (scopeKind, scopeId) {
        case ("feed", .some(let id)) where feedIds.contains(id): .feed(id)
        case ("folder", .some(let id)) where folderIds.contains(id): .folder(id)
        default: .all
        }
    }
}

enum SavedSearches {
    static func fetchAll(_ db: Database) throws -> [SavedSearch] {
        try SavedSearch.fetchAll(db, sql: "SELECT * FROM savedSearch ORDER BY id")
    }

    static func scopeFields(_ scope: SidebarSelection) -> (kind: String, id: Int64?) {
        switch scope {
        case .feed(let id): ("feed", id)
        case .folder(let id): ("folder", id)
        default: ("all", nil)
        }
    }

    @discardableResult
    static func add(_ db: AppDatabase, name: String, query: String,
                    scope: SidebarSelection, window: SearchWindow,
                    filter: String) async throws -> SavedSearch {
        let fields = scopeFields(scope)
        let saved = SavedSearch(
            id: nil, name: name, query: query, scopeKind: fields.kind, scopeId: fields.id,
            window: window.rawValue, createdAt: Date(), filter: filter)
        let id = try await db.pool.write { db -> Int64 in
            try saved.insert(db)
            return db.lastInsertedRowID
        }
        var stored = saved
        stored.id = id
        return stored
    }

    static func rename(_ db: AppDatabase, id: Int64, to name: String) async throws {
        try await db.pool.write { db in
            try db.execute(sql: "UPDATE savedSearch SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    static func delete(_ db: AppDatabase, id: Int64) async throws {
        try await db.pool.write { db in
            try db.execute(sql: "DELETE FROM savedSearch WHERE id = ?", arguments: [id])
        }
    }

    /// 侧栏点选后要立刻拿到词与范围，比等异步观察更简单；单行查询，同步读可接受。
    static func resolve(_ db: AppDatabase, id: Int64) -> (saved: SavedSearch, scope: SidebarSelection)? {
        try? db.pool.read { db in
            guard let saved = try SavedSearch.fetchOne(db, key: id) else { return nil }
            let feedIds = try Int64.fetchSet(db, sql: "SELECT id FROM feed")
            let folderIds = try Int64.fetchSet(db, sql: "SELECT id FROM folder")
            return (saved, saved.scopeSelection(feedIds: feedIds, folderIds: folderIds))
        } ?? nil
    }
}
