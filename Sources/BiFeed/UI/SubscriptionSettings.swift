import GRDB
import SwiftUI

/// 设置 → 订阅：按停更时间等条件筛出不值得留的源，勾选后一次退订。
/// 单个退订仍在侧栏右键菜单，两条路并存。
struct SubscriptionSettings: View {
    @StateObject private var rows: DBObserved<[FeedHealthRow]>
    @State private var filter = FeedCleanupFilter()
    @State private var selected: Set<Int64> = []
    @State private var confirming = false

    init() {
        _rows = StateObject(wrappedValue: DBObserved(db: AppEnvironment.sharedDB, initial: []) { db in
            try FeedHealthRow.fetchAll(db)
        })
    }

    private var visible: [FeedHealthRow] {
        FeedCleanupFilter.sorted(rows.value.filter { filter.matches($0) })
    }

    /// 勾选过之后条件可能又变了，退订只认当前还看得见的那些。
    private var picked: [FeedHealthRow] {
        visible.filter { selected.contains($0.id) }
    }

    var body: some View {
        Form {
            Section("筛选") {
                Picker("多久没更新", selection: $filter.stale) {
                    ForEach(StaleWindow.allCases) { Text($0.label).tag($0) }
                }
                Toggle("近 30 天有更新但一篇没读", isOn: $filter.onlyIgnored)
                Toggle("抓取失败", isOn: $filter.onlyFailing)
                Text("从未有过文章的源，任何档位都会列出。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }

            Section {
                if visible.isEmpty {
                    Text("没有符合条件的订阅。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visible) { row in
                        Toggle(isOn: binding(row)) {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                Text(row.title).lineLimit(1)
                                Text(subtitle(row))
                                    .font(.system(size: DesignTokens.Typography.caption))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("符合条件的订阅（\(visible.count)）")
                    Spacer()
                    Button(selected.isEmpty ? "全选" : "取消选择") {
                        selected = selected.isEmpty ? Set(visible.map(\.id)) : []
                    }
                    .font(.system(size: 11))
                    .disabled(visible.isEmpty)
                }
            }

            Section {
                Button("退订所选（\(picked.count)）", role: .destructive) { confirming = true }
                    .disabled(picked.isEmpty)
                Text("退订会删除该源及其全部文章，星标也不保留。此操作不可撤销。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("退订 \(picked.count) 个订阅？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("退订", role: .destructive) { unsubscribe() }
        } message: {
            Text(picked.prefix(8).map(\.title).joined(separator: "\n")
                 + (picked.count > 8 ? "\n……共 \(picked.count) 个" : ""))
        }
    }

    private func binding(_ row: FeedHealthRow) -> Binding<Bool> {
        Binding(
            get: { selected.contains(row.id) },
            set: { on in
                if on { selected.insert(row.id) } else { selected.remove(row.id) }
            })
    }

    private func subtitle(_ row: FeedHealthRow) -> String {
        let stale = row.staleDays().map { "\($0) 天没更新" } ?? "从未更新"
        let read = row.recentCount == 0
            ? "近 30 天无新文章"
            : "近 30 天 \(row.recentCount) 篇，读过 \(row.recentReadCount) 篇"
        let status = row.status == "正常" ? "" : " · \(row.status)"
        return "\(stale) · \(read)\(status)"
    }

    private func unsubscribe() {
        let ids = picked.map(\.id)
        selected.removeAll()
        Task {
            for id in ids {
                try? await AppEnvironment.sharedDB.deleteFeed(id: id)
            }
        }
    }
}
