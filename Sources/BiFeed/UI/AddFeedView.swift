import GRDB
import SwiftUI

struct AddFeedView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var folders: DBObserved<[Folder]>

    @State private var input = ""
    @State private var folderId: Int64? = nil
    @State private var working = false
    @State private var errorText: String?
    @State private var candidates: [FeedCandidate] = []
    @State private var picked: Set<URL> = []

    init() {
        _folders = StateObject(wrappedValue: DBObserved(db: AppEnvironment.sharedDB, initial: []) { db in
            try Folder.order(Column("name")).fetchAll(db)
        })
    }

    var body: some View {
        if candidates.isEmpty { inputForm } else { candidateList }
    }

    private var inputForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("feed.add.title"))
                .font(.headline)
            TextField(L("feed.add.placeholder"), text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add() }
                .disabled(working)
            Picker(L("common.folder"), selection: $folderId) {
                Text(L("common.noFolder")).tag(Int64?.none)
                ForEach(folders.value) { folder in
                    Text(folder.name).tag(Optional(folder.id!))
                }
            }
            .disabled(working)
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    add()
                } label: {
                    if working {
                        ProgressView().controlSize(.small).frame(width: 28)
                    } else {
                        Text(L("feed.add.submit"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text(L("feed.add.candidates.title", candidates.count))
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ForEach(candidates) { candidate in
                        Toggle(isOn: pickBinding(candidate)) {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                Text(candidate.title)
                                    .font(.system(size: DesignTokens.Typography.body))
                                Text(candidate.url.absoluteString)
                                    .font(.system(size: DesignTokens.Typography.caption))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .disabled(working)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    subscribePicked()
                } label: {
                    if working {
                        ProgressView().controlSize(.small).frame(width: 28)
                    } else {
                        Text(L("feed.add.candidates.submit"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working || picked.isEmpty)
            }
        }
        .padding(DesignTokens.Spacing.xxl)
        .frame(width: 440)
    }

    private func pickBinding(_ candidate: FeedCandidate) -> Binding<Bool> {
        Binding(
            get: { picked.contains(candidate.url) },
            set: { on in
                if on { picked.insert(candidate.url) } else { picked.remove(candidate.url) }
            })
    }

    private func add() {
        guard !working else { return }
        working = true
        errorText = nil
        let text = input
        let targetFolder = folderId
        Task {
            do {
                switch try await SubscribeResolver.resolve(text, fetcher: env.fetcher) {
                case .feed(let feedURL, let parsed):
                    try await store(feedURL: feedURL, parsed: parsed, folderId: targetFolder)
                    dismiss()
                case .candidates(let found):
                    candidates = found
                    working = false
                }
            } catch {
                errorText = friendly(error)
                working = false
            }
        }
    }

    /// 逐个订阅勾选的候选；中途失败就停在清单上报错，已入库的保留。
    private func subscribePicked() {
        guard !working else { return }
        working = true
        errorText = nil
        let chosen = candidates.filter { picked.contains($0.url) }
        let targetFolder = folderId
        Task {
            do {
                for candidate in chosen {
                    let hit = try await SubscribeResolver.fetchFeed(
                        url: candidate.url, fetcher: env.fetcher)
                    try await store(feedURL: hit.url, parsed: hit.parsed, folderId: targetFolder)
                }
                dismiss()
            } catch {
                errorText = friendly(error)
                working = false
            }
        }
    }

    private func store(feedURL: URL, parsed: ParsedFeed, folderId: Int64?) async throws {
        let feed = try await env.db.addFeed(
            url: feedURL.absoluteString,
            title: parsed.title,
            siteURL: parsed.siteURL,
            folderId: folderId)
        // 订阅时已抓到内容，直接入库，不再发第二次请求。
        // 这就是「新增订阅的首批文章」，首批已读策略在这里生效（调度器路径按 lastSuccessAt 判定）。
        let rules = try await MuteRules.all(env.db)
        let result = try await env.db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: MuteRules.evaluate(
                parsed.items, feedId: feed.id!, folderId: feed.folderId, rules: rules),
            initialPolicy: InitialReadPolicy.current())
        // 首批被策略标掉的文章挂到列表工具栏的撤销按钮上，与「全部标为已读」同一个入口
        env.offerUndo(result.initialReadIds)
    }

    private func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("UNIQUE constraint") { return L("error.feed.duplicate") }
        return text
    }
}
