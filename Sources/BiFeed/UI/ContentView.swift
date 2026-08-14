import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var sidebarSelection: SidebarSelection? = .all
    @State private var selectedArticleId: Int64?
    // 沉浸模式（⌘↩）：隐藏侧栏和列表，单篇占满。Esc 或再按 ⌘↩ 退出
    @State private var immersive = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $sidebarSelection, columnVisibility: $columnVisibility)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        } content: {
            ArticleListView(db: env.db, scope: sidebarSelection ?? .all, selectedArticleId: $selectedArticleId)
                .id(sidebarSelection) // 切范围 = 重建观察
                .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 460)
        } detail: {
            ReaderView(articleId: selectedArticleId)
                .onExitCommand {
                    guard immersive else { return }
                    setImmersive(false)
                }
        }
        // 翻译宿主：.translationTask 必须挂在可见视图层级里，用 1×1 隐藏视图承接
        .background(TranslationHost(engine: AppEnvironment.sharedTranslationEngine))
        .frame(minWidth: 920, minHeight: 560)
        .onChange(of: sidebarSelection) {
            selectedArticleId = nil
            env.clearUndo() // 撤销名单属于上一个范围，换了源就别再提供
        }
        .onReceive(NotificationCenter.default.publisher(for: .bifeedToggleImmersive)) { _ in
            setImmersive(!immersive)
        }
        .alert(L("update.available.title", env.availableUpdate?.version ?? ""),
               isPresented: .constant(env.availableUpdate != nil)) {
            Button(L("update.available.download")) {
                if let info = env.availableUpdate {
                    NSWorkspace.shared.open(info.downloadURL ?? info.pageURL)
                }
                env.availableUpdate = nil
            }
            Button(L("update.available.skip")) {
                if let info = env.availableUpdate { env.skipUpdate(info) }
            }
            Button(L("update.available.later"), role: .cancel) { env.availableUpdate = nil }
        } message: {
            Text(updateMessage)
        }
        .alert(L("update.check.title"), isPresented: .constant(env.updateStatus != nil)) {
            Button(L("common.ok")) { env.updateStatus = nil }
        } message: {
            Text(env.updateStatus ?? "")
        }
        .sheet(isPresented: $env.showAddFeed) {
            AddFeedView()
                .environmentObject(env)
        }
        .sheet(isPresented: $env.showSavePage) {
            SavePageView()
                .environmentObject(env)
        }
    }

    /// release 说明可能很长，弹窗里只给前几行；完整内容在下载页。
    private var updateMessage: String {
        guard let info = env.availableUpdate else { return "" }
        let head = info.notes.split(separator: "\n").prefix(8).joined(separator: "\n")
        let current = L("update.available.current", UpdateChecker.currentVersion)
        return head.isEmpty ? current : current + "\n\n" + head
    }

    private func setImmersive(_ on: Bool) {
        immersive = on
        // 不加动画：分栏动画期间 WKWebView 逐帧重排在 Intel 上必卡（用户实测"卡卡的"），
        // 瞬时切换零卡顿。侧栏收起同理，见 SidebarView 的自定义切换按钮。
        columnVisibility = on ? .detailOnly : .all
    }
}
