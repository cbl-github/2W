import Foundation
import GRDB

/// 把一条 GRDB ValueObservation 包装成 ObservableObject。
/// UI 数据源统一走这里（设计文档 §4 机制 3）：按查询粒度订阅，不手动刷新。
@MainActor
final class DBObserved<Value>: ObservableObject {
    @Published private(set) var value: Value
    private var cancellable: AnyDatabaseCancellable?

    init(db: AppDatabase, initial: Value, fetch: @escaping @Sendable (Database) throws -> Value) {
        value = initial
        let observation = ValueObservation.tracking(fetch)
        cancellable = observation.start(
            in: db.pool,
            scheduling: .async(onQueue: .main),
            onError: { error in fatalError("数据库观察失败: \(error)") },
            onChange: { [weak self] newValue in self?.value = newValue })
    }
}
