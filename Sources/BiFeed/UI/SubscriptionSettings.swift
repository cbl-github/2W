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
            Section(L("settings.subscriptions.filter")) {
                Picker(L("settings.subscriptions.notUpdated"), selection: $filter.notUpdated) {
                    ForEach(StaleWindow.allCases) { Text($0.label).tag($0) }
                }
                Picker(L("settings.subscriptions.notRead"), selection: $filter.notRead) {
                    ForEach(StaleWindow.allCases) { Text($0.label).tag($0) }
                }
                Toggle(L("settings.subscriptions.failingOnly"), isOn: $filter.failing)
                Text(L("settings.subscriptions.filter.note"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }

            Section {
                if visible.isEmpty {
                    Text(L("settings.subscriptions.empty"))
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
                    Text(L("settings.subscriptions.matched", visible.count))
                    Spacer()
                    Button(
                        selected.isEmpty
                            ? L("settings.subscriptions.selectAll")
                            : L("settings.subscriptions.deselectAll")
                    ) {
                        selected = selected.isEmpty ? Set(visible.map(\.id)) : []
                    }
                    .font(.system(size: 11))
                    .disabled(visible.isEmpty)
                }
            }

            Section(L("common.unsubscribe")) {
                Toggle(L("settings.subscriptions.keepStarred"), isOn: $keepStarred)
                Text(keepStarred
                     ? L("settings.subscriptions.keepStarred.on")
                     : L("settings.subscriptions.keepStarred.off"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Button(
                    L("settings.subscriptions.unsubscribeSelected", picked.count),
                    role: .destructive
                ) { confirming = true }
                    .disabled(picked.isEmpty)
                Text(L("settings.subscriptions.irreversible"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert(L("settings.subscriptions.unsubscribe.confirm", picked.count), isPresented: $confirming) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("common.unsubscribe"), role: .destructive) { unsubscribe() }
        } message: {
            Text(picked.prefix(8).map(\.title).joined(separator: "\n")
                 + (picked.count > 8 ? "\n" + L("settings.subscriptions.andMore", picked.count) : ""))
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
        let updated = row.staleDays().map { L("settings.subscriptions.detail.staleDays", $0) }
            ?? L("settings.subscriptions.detail.neverUpdated")
        let read = row.readIdleDays().map { L("settings.subscriptions.detail.unreadDays", $0) }
            ?? L("settings.subscriptions.detail.neverRead")
        let volume = row.recentCount == 0
            ? L("settings.subscriptions.detail.noRecent")
            : L("settings.subscriptions.detail.recent", row.recentCount, row.recentReadCount)
        let status = row.status == L("feed.health.status.ok") ? "" : " · \(row.status)"
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
