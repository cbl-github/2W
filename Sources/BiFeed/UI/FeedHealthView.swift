import SwiftUI

/// 源健康面板（需求 20）：每源一行的统计表，默认最不看的排最上面，支持多选批量退订。
struct FeedHealthView: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model: DBObserved<[FeedHealthRow]>

    @State private var selection: Set<Int64> = []
    /// 默认按近 30 天已读数升序：这一列就是「我到底看不看这个源」
    @State private var sortOrder = [KeyPathComparator(\FeedHealthRow.recentReadCount, order: .forward)]
    @State private var confirmingUnsubscribe = false

    init() {
        // 与 SidebarView 同一条路径：观察对象要在 init 里建，此处拿不到 EnvironmentObject
        // 闭包而非函数引用：默认参数 since 要在每次观察重算时取当时的「近 30 天」
        _model = StateObject(wrappedValue: DBObserved(
            db: AppEnvironment.sharedDB, initial: []) { try FeedHealthRow.fetchAll($0) })
    }

    private var rows: [FeedHealthRow] { model.value.sorted(using: sortOrder) }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("订阅", value: \.title) { Text($0.title).lineLimit(1) }
                .width(min: 140, ideal: 200)
            TableColumn("近 30 天", value: \.recentCount) {
                Text($0.recentCount.formatted()).monospacedDigit()
            }
            .width(70)
            TableColumn("已读", value: \.recentReadCount) {
                Text($0.recentReadCount.formatted()).monospacedDigit()
            }
            .width(60)
            TableColumn("静音命中", value: \.mutedCount) {
                Text($0.mutedCount.formatted()).monospacedDigit()
            }
            .width(70)
            TableColumn("最后一篇", value: \.lastPublishedSort) { row in
                Text(row.lastPublishedAt?.formatted(date: .numeric, time: .omitted) ?? "—")
            }
            .width(100)
            TableColumn("状态", value: \.status) { Text($0.status).lineLimit(1) }
                .width(min: 80, ideal: 120)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button("退订所选") { confirmingUnsubscribe = true }
                    .disabled(selection.isEmpty)
            }
            .padding(DesignTokens.Spacing.lg)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .alert("退订所选的 \(selection.count) 个订阅？", isPresented: $confirmingUnsubscribe) {
            Button("取消", role: .cancel) {}
            Button("退订", role: .destructive) { unsubscribeSelected() }
        } message: {
            Text("这些订阅和它们的文章都会被删除，不能撤销。")
        }
    }

    private func unsubscribeSelected() {
        let ids = Array(selection)
        selection = []
        env.dbWrite { [db = env.db] in
            for id in ids { try await db.deleteFeed(id: id) }
        }
    }
}
