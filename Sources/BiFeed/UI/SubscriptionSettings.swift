import GRDB
import SwiftUI

/// 设置 → 订阅：按未更新时长等条件筛选订阅，勾选后批量退订。
/// 侧栏右键的单个退订保留，两条路径并存。
struct SubscriptionSettings: View {
    @StateObject private var rows: DBObserved<[FeedHealthRow]>
    @State private var filter = FeedCleanupFilter()
    @State private var selected: Set<Int64> = []
    @State private var keepStarred = true
    @State private var confirming = false

    init() {
        _rows = StateObject(wrappedValue: DBObserved(db: AppEnvironment.sharedDB, initial: []) { db in
            try FeedHealthRow.fetchAll(db)
        })
    }

    private var visible: [FeedHealthRow] {
        FeedCleanupFilter.sorted(rows.value.filter { filter.matches($0) })
    }

    /// 勾选之后条件可能又变了，退订只处理当前仍在列表中的订阅。
    private var picked: [FeedHealthRow] {
        visible.filter { selected.contains($0.id) }
    }

    var body: some View {
        Form {
            Section("筛选") {
                Picker("未更新时长", selection: $filter.notUpdated) {
                    ForEach(StaleWindow.allCases) { Text($0.label).tag($0) }
                }
                Picker("近期未读", selection: $filter.notRead) {
                    ForEach(StaleWindow.allCases) { Text($0.label).tag($0) }
                }
                Toggle("仅显示抓取失败的订阅", isOn: $filter.failing)
                Text("未更新时长按最后一篇文章计算，近期未读按最后一篇已读文章计算。"
                     + "从未收到文章或从未读过的订阅在任何档位下均会列出。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }

            Section {
                if visible.isEmpty {
                    Text("无符合条件的订阅。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visible) { row in
                        Toggle(isOn: binding(row)) {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                Text(row.title).lineLimit(1)
                                Text(detail(row))
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

            Section("退订") {
                Toggle("保留星标文章", isOn: $keepStarred)
                Text(keepStarred
                     ? "星标文章移入「\(AppDatabase.starredArchiveTitle)」，其余文章随订阅删除。"
                     : "订阅及其全部文章一并删除，星标不保留。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Button("退订所选（\(picked.count)）", role: .destructive) { confirming = true }
                    .disabled(picked.isEmpty)
                Text("退订不可撤销。")
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
                 + (picked.count > 8 ? "\n…… 共 \(picked.count) 个" : ""))
        }
    }

    private func binding(_ row: FeedHealthRow) -> Binding<Bool> {
        Binding(
            get: { selected.contains(row.id) },
            set: { on in
                if on { selected.insert(row.id) } else { selected.remove(row.id) }
            })
    }

    private func detail(_ row: FeedHealthRow) -> String {
        let updated = row.staleDays().map { "未更新 \($0) 天" } ?? "从未收到文章"
        let read = row.readIdleDays().map { "未读 \($0) 天" } ?? "从未读过"
        let volume = row.recentCount == 0
            ? "近 30 天无新文章"
            : "近 30 天 \(row.recentCount) 篇 / 已读 \(row.recentReadCount) 篇"
        let status = row.status == "正常" ? "" : " · \(row.status)"
        return "\(updated) · \(read) · \(volume)\(status)"
    }

    private func unsubscribe() {
        let ids = picked.map(\.id)
        let keep = keepStarred
        selected.removeAll()
        Task {
            for id in ids {
                try? await AppEnvironment.sharedDB.deleteFeed(id: id, keepStarred: keep)
            }
        }
    }
}
