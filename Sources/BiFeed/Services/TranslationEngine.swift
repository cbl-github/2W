import SwiftUI
import Translation

enum EngineAvailability {
    case installed, downloadable, unsupported
}

/// 引擎边界：Apple Translation 是最大不可控依赖，藏在协议后（DESIGN.md §6）。
@MainActor
protocol TranslationEngine: AnyObject {
    func availability(source: String, target: String) async -> EngineAvailability
    /// 返回值与输入等长同序。
    func translate(_ texts: [String], source: String, target: String) async throws -> [String]
    func requestDownload(source: String, target: String) async
}

/// TranslationSession 只经 `.translationTask` 修饰符发放，不能直接构造（DESIGN.md §8 坑 1）。
/// 所以引擎只操纵 config，请求排进内部队列；宿主视图挂 translationTask，
/// session 到手后由 drain 消费队列。
@MainActor
final class AppleTranslationEngine: ObservableObject, TranslationEngine {
    /// 非 nil = 宿主视图持有活跃 session；置 nil = 卸掉 session，模型内存还给系统（DESIGN.md §4 机制 6）。
    @Published private(set) var config: TranslationSession.Configuration?

    private enum Job {
        case translate(texts: [String], cont: CheckedContinuation<[String], Error>)
        case prepare(cont: CheckedContinuation<Void, Never>)
    }

    private var queue: [Job] = []
    private var isDraining = false

    func availability(source: String, target: String) async -> EngineAvailability {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target))
        switch status {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported // 未来新增状态无从翻译，按不可用处理
        }
    }

    func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { cont in
            queue.append(.translate(texts: texts, cont: cont))
            kick(source: source, target: target)
        }
    }

    /// 触发系统的语言模型下载 UI。M0 实测：prepareTranslation 返回 ≠ 模型就绪，
    /// 调用方要自己轮询 availability 直到 .installed（DESIGN.md §8 坑 3）。
    func requestDownload(source: String, target: String) async {
        await withCheckedContinuation { cont in
            queue.append(.prepare(cont: cont))
            kick(source: source, target: target)
        }
    }

    /// 保证宿主的 translationTask 会为当前语言对跑一次 drain。
    private func kick(source: String, target: String) {
        let src = Locale.Language(identifier: source)
        let tgt = Locale.Language(identifier: target)
        if let current = config, current.source == src, current.target == tgt {
            // 语言对相同但没有活跃 drain（宿主已释放 session）：invalidate 让 translationTask 重跑。
            // 有活跃 drain 时不动 config——drain 的循环会消费刚入队的 Job。
            if !isDraining { config?.invalidate() }
        } else {
            config = TranslationSession.Configuration(source: src, target: tgt) // 换语言对触发 translationTask 重跑
        }
    }

    /// 宿主视图在 translationTask 里调用。语言对切换会让 SwiftUI 取消本任务并携新 session 重跑，
    /// 所以取消时留下队列给下一次 drain，也不碰已被新值接管的 config。
    func drain(_ session: TranslationSession) async {
        isDraining = true
        defer {
            isDraining = false
            if !Task.isCancelled, queue.isEmpty { config = nil } // 空闲释放（§4 机制 6）
        }
        while !Task.isCancelled, !queue.isEmpty {
            switch queue.removeFirst() {
            case .translate(let texts, let cont):
                do {
                    let requests = texts.enumerated().map {
                        TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                    }
                    // 响应顺序不保证，按 clientIdentifier（我们写入的下标）数值排序还原输入顺序。
                    // 标识符缺失或非数字 = 不变量破坏，直接崩。
                    let responses = try await session.translations(from: requests)
                        .sorted { Int($0.clientIdentifier!)! < Int($1.clientIdentifier!)! }
                    cont.resume(returning: responses.map(\.targetText))
                } catch {
                    cont.resume(throwing: error) // 单个 Job 失败不拖累后续
                }
            case .prepare(let cont):
                // 用户点掉下载弹窗即抛错/返回，均视为"已触发下载"，就绪与否由调用方轮询。
                try? await session.prepareTranslation()
                cont.resume()
            }
        }
    }
}

/// 隐藏宿主视图，持有 session 的唯一途径。挂在常驻 UI 里（1×1 透明，不参与布局观感）。
struct TranslationHost: View {
    @ObservedObject var engine: AppleTranslationEngine

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(engine.config) { session in
                await engine.drain(session)
            }
    }
}
