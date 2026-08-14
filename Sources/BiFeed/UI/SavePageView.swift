import SwiftUI

/// 需求 26：手动保存单篇网页。形态对齐 AddFeedView（地址框 + 保存按钮 + 错误行）。
struct SavePageView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("feed.savePage.title"))
                .font(.headline)
            TextField(L("feed.savePage.placeholder"), text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
                .disabled(working)
            Text(L("feed.savePage.note"))
                .font(.callout)
                .foregroundStyle(.secondary)
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
                    save()
                } label: {
                    if working {
                        ProgressView().controlSize(.small).frame(width: 28)
                    } else {
                        Text(L("common.save"))
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

    private func save() {
        guard !working else { return }
        // 与订阅输入同一套补全：不带 scheme 的按 https 处理
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host() != nil else {
            errorText = FetchError.badURL(input).localizedDescription
            return
        }
        working = true
        errorText = nil
        Task {
            do {
                try await SavedPages.save(url: url, into: env.db)
                dismiss()
            } catch {
                errorText = error.localizedDescription
                working = false
            }
        }
    }
}
