import Foundation
import GRDB

/// 备份文件的体检结果。恢复前必须看这份结果，不合格不落盘。
struct BackupInfo {
    var migrations: Set<String>
    var feedCount: Int
    var articleCount: Int
    /// 备份里有、本版本不认识的迁移 = 备份来自更新版本的 2W。
    var unknownMigrations: [String]

    var summary: String {
        L("data.backup.summary", feedCount, articleCount)
    }
}

enum BackupError: LocalizedError {
    case notBiFeedDatabase
    case newerVersion([String])

    var errorDescription: String? {
        switch self {
        case .notBiFeedDatabase:
            L("error.backup.notBiFeedDatabase")
        case .newerVersion(let ids):
            L("error.backup.newerVersion", ids.joined(separator: "、"))
        }
    }
}

/// 数据可信（M11）：一致性快照、自动 OPML 备份、带校验的恢复。
/// 恢复不在运行中替换数据库文件——连接池正开着它。改成落一份待恢复文件，
/// 下次启动打开连接池之前换过去（applyPendingRestore）。
enum Backup {
    /// 自动备份目录：`~/Library/Application Support/BiFeed/Backups`
    static var directory: URL {
        URL(fileURLWithPath: AppDatabase.defaultPath())
            .deletingLastPathComponent()
            .appendingPathComponent("Backups")
    }

    static func pendingRestorePath(dbPath: String) -> String {
        (dbPath as NSString).deletingLastPathComponent + "/pending-restore.sqlite"
    }

    static func suggestedFilename(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "2W-\(f.string(from: now)).sqlite"
    }

    // MARK: - 快照

    /// `VACUUM INTO` 是 SQLite 自带的一致性快照：单条语句拿到完整、已整理的副本，
    /// 不需要停写，也不会抄到写前日志里的半个事务。
    /// 目标文件已存在时 VACUUM INTO 直接报错，所以先删。
    static func snapshot(_ db: AppDatabase, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        // VACUUM 不能在事务里跑，走 writeWithoutTransaction
        try await db.pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
    }

    // MARK: - 自动 OPML 备份

    /// 每天一份订阅列表，保留最近 keep 份。文件名带日期，当天已有就不重复写。
    /// 订阅列表是丢了最难重建的东西，体积又极小，所以自动备份只做它。
    static func autoOPML(_ db: AppDatabase, into root: URL = Backup.directory,
                         keep: Int = 7, now: Date = Date()) async throws {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("opml")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let target = dir.appendingPathComponent("2W-\(f.string(from: now)).opml")
        guard !fm.fileExists(atPath: target.path) else { return }

        let (folders, feeds) = try await db.pool.read { db in
            (try Folder.fetchAll(db), try Feed.fetchAll(db))
        }
        guard !feeds.isEmpty else { return } // 空库不写空备份，免得挤掉有内容的旧份
        try OPML.export(folders: folders, feeds: feeds)
            .write(to: target, atomically: true, encoding: .utf8)

        let existing = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "opml" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        for old in existing.dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    // MARK: - 恢复

    /// 只读打开候选文件做体检：确认是 BiFeed 库，且迁移版本不比本版本新。
    /// 更旧的备份可以恢复——迁移器会在下次启动时把它升上来。
    static func inspect(_ url: URL) throws -> BackupInfo {
        var config = Configuration()
        config.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw BackupError.notBiFeedDatabase
        }
        let info: BackupInfo = try queue.read { db in
            guard try db.tableExists("article"), try db.tableExists("feed"),
                  try db.tableExists("grdb_migrations") else {
                throw BackupError.notBiFeedDatabase
            }
            let migrations = try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
            let known = Set(AppDatabase.migrator.migrations)
            return BackupInfo(
                migrations: migrations,
                feedCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed") ?? 0,
                articleCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article") ?? 0,
                unknownMigrations: migrations.subtracting(known).sorted())
        }
        guard info.unknownMigrations.isEmpty else {
            throw BackupError.newerVersion(info.unknownMigrations)
        }
        return info
    }

    /// 体检通过后把备份拷到待恢复位置。真正的替换在下次启动。
    @discardableResult
    static func stageRestore(from url: URL, dbPath: String = AppDatabase.defaultPath()) throws -> BackupInfo {
        let info = try inspect(url)
        let pending = pendingRestorePath(dbPath: dbPath)
        try? FileManager.default.removeItem(atPath: pending)
        try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: pending))
        return info
    }

    /// 打开连接池之前调用（AppDatabase.init 的第一步）。
    /// 有待恢复文件就换上去，当前库留一份 `.bak`。任何一步失败都放弃本次恢复并清掉待恢复文件——
    /// 启动路径上宁可保持原样，也不能反复崩在同一个坏文件上。
    static func applyPendingRestore(dbPath: String) {
        let fm = FileManager.default
        let pending = pendingRestorePath(dbPath: dbPath)
        guard fm.fileExists(atPath: pending) else { return }
        defer {
            try? fm.removeItem(atPath: pending)
            try? fm.removeItem(atPath: pending + "-wal")
            try? fm.removeItem(atPath: pending + "-shm")
        }
        do {
            if fm.fileExists(atPath: dbPath) {
                try? fm.removeItem(atPath: dbPath + ".bak")
                try fm.moveItem(atPath: dbPath, toPath: dbPath + ".bak")
            }
            // 旧库的 WAL/SHM 属于被换掉的那个文件，留着会污染新库
            try? fm.removeItem(atPath: dbPath + "-wal")
            try? fm.removeItem(atPath: dbPath + "-shm")
            try fm.copyItem(atPath: pending, toPath: dbPath)
        } catch {
            FileHandle.standardError.write(Data("[2W] 恢复失败，保持原库: \(error)\n".utf8))
            // 原库已被移走但新库没落位 = 会开出空库，把 .bak 挪回来
            if !fm.fileExists(atPath: dbPath), fm.fileExists(atPath: dbPath + ".bak") {
                try? fm.moveItem(atPath: dbPath + ".bak", toPath: dbPath)
            }
        }
    }
}
