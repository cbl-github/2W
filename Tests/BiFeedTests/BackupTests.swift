import GRDB
import XCTest
@testable import BiFeed

/// M11：一致性快照、迁移校验、启动时替换数据库。
final class BackupTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bifeed-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seed(_ db: AppDatabase) async throws {
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: ParsedItem(
                guid: "g1", url: nil, title: "文章", author: nil, publishedAt: Date(),
                contentHTML: "<p>正文</p>", summaryText: "正文"), action: nil)])
    }

    func testSnapshotIsReadableAndPassesInspection() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase(path: dir.appendingPathComponent("bifeed.sqlite").path)
        try await seed(db)

        let target = dir.appendingPathComponent("snapshot.sqlite")
        try await Backup.snapshot(db, to: target)

        let info = try Backup.inspect(target)
        XCTAssertEqual(info.feedCount, 1)
        XCTAssertEqual(info.articleCount, 1)
        XCTAssertTrue(info.unknownMigrations.isEmpty)

        // 同名文件已存在时也要能覆盖（VACUUM INTO 本身拒绝写已存在的文件）
        try await Backup.snapshot(db, to: target)
        XCTAssertEqual(try Backup.inspect(target).articleCount, 1)
    }

    func testInspectRejectsNonBiFeedAndNewerBackups() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let junk = dir.appendingPathComponent("junk.sqlite")
        try Data("not a database".utf8).write(to: junk)
        XCTAssertThrowsError(try Backup.inspect(junk))

        let newer = dir.appendingPathComponent("newer.sqlite")
        let db = try AppDatabase(path: newer.path)
        try await db.pool.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-the-future')")
        }
        XCTAssertThrowsError(try Backup.inspect(newer)) { error in
            guard case BackupError.newerVersion(let ids) = error else {
                return XCTFail("应报告未知迁移，实际是 \(error)")
            }
            XCTAssertEqual(ids, ["v99-from-the-future"])
        }
    }

    func testPendingRestoreSwapsDatabaseOnNextOpen() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let livePath = dir.appendingPathComponent("bifeed.sqlite").path

        // 当前库：一个订阅
        let live = try AppDatabase(path: livePath)
        try await seed(live)
        // 备份来自"另一台机器"：两个订阅
        let otherPath = dir.appendingPathComponent("other.sqlite").path
        let other = try AppDatabase(path: otherPath)
        try await seed(other)
        _ = try await other.addFeed(url: "https://b.example/rss", title: "B", siteURL: nil, folderId: nil)
        let backup = dir.appendingPathComponent("backup.sqlite")
        try await Backup.snapshot(other, to: backup)

        let info = try Backup.stageRestore(from: backup, dbPath: livePath)
        XCTAssertEqual(info.feedCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Backup.pendingRestorePath(dbPath: livePath)))

        // 重开连接池 = 应用重启：替换在打开之前发生
        let restored = try AppDatabase(path: livePath)
        let count = try await restored.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM feed") }
        XCTAssertEqual(count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: livePath + ".bak"), "原库留一份 .bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Backup.pendingRestorePath(dbPath: livePath)),
                       "待恢复文件用完即删，不会每次启动都恢复一遍")
    }

    func testAutoOPMLWritesOncePerDayAndPrunes() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase(path: dir.appendingPathComponent("bifeed.sqlite").path)
        try await seed(db)

        let root = dir.appendingPathComponent("Backups")
        let opmlDir = root.appendingPathComponent("opml")
        try await Backup.autoOPML(db, into: root)
        try await Backup.autoOPML(db, into: root) // 当天第二次调用不应再写
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: opmlDir.path).count, 1)

        // 攒够 9 天只留最近 7 份，且留下的是最新的
        for day in 1...8 {
            try await Backup.autoOPML(db, into: root, keep: 7,
                                      now: Date(timeIntervalSinceNow: Double(day) * 86400))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: opmlDir.path).sorted()
        XCTAssertEqual(files.count, 7)
        XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".opml") })
    }
}
