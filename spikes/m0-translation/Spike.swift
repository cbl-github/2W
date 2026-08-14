// M0 spike: 验证 Apple Translation 框架在 Intel + macOS 15.7 上可用。
// 结果追加写入 /tmp/bifeed-m0-result.txt，完成后自动退出。
import SwiftUI
import Translation

let resultPath = "/tmp/bifeed-m0-result.txt"

func log(_ line: String) {
    let data = (line + "\n").data(using: .utf8)!
    if let h = FileHandle(forWritingAtPath: resultPath) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: resultPath))
    }
    print(line)
}

func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(info.resident_size) / 1024 / 1024
}

func finish(_ verdict: String) {
    log(verdict)
    log("DONE")
    exit(0)
}

@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup { SpikeView() }
    }
}

struct SpikeView: View {
    @State private var config: TranslationSession.Configuration?
    @State private var status = "checking availability…"

    var body: some View {
        Text(status)
            .padding()
            .frame(width: 420, height: 80)
            .task { await start() }
            .translationTask(config) { session in await run(session) }
    }

    func start() async {
        log("arch=\(ProcessInfo.processInfo.machineHardwareName) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("RSS_START_MB=\(String(format: "%.1f", rssMB()))")
        let en = Locale.Language(identifier: "en")
        let zh = Locale.Language(identifier: "zh-Hans")
        let st = await LanguageAvailability().status(from: en, to: zh)
        log("AVAILABILITY en->zh-Hans: \(st)")
        switch st {
        case .installed, .supported:
            status = "translating…"
            config = .init(source: en, target: zh)
        case .unsupported:
            finish("VERDICT: UNSUPPORTED — 系统翻译在本机不支持 en->zh-Hans")
        @unknown default:
            finish("VERDICT: UNKNOWN_STATUS \(st)")
        }
    }

    func run(_ session: TranslationSession) async {
        do {
            let tPrep = Date()
            try await session.prepareTranslation()
            log("prepareTranslation ok in \(String(format: "%.2f", -tPrep.timeIntervalSinceNow))s")

            let texts = [
                "SQLite is a C-language library that implements a small, fast, self-contained, high-reliability SQL database engine.",
                "The design of an RSS reader should keep memory usage low by never loading article bodies into list queries.",
                "Translation results are cached locally, so reopening an article costs nothing.",
            ]
            let reqs = texts.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            let t0 = Date()
            let first = try await session.translations(from: reqs)
            let cold = -t0.timeIntervalSinceNow
            let t1 = Date()
            _ = try await session.translations(from: reqs)
            let warm = -t1.timeIntervalSinceNow

            log("BATCH_COLD_S=\(String(format: "%.2f", cold)) BATCH_WARM_S=\(String(format: "%.2f", warm))")
            for r in first.sorted(by: { ($0.clientIdentifier ?? "") < ($1.clientIdentifier ?? "") }) {
                log("[\(r.clientIdentifier ?? "?")] \(r.targetText)")
            }
            log("RSS_AFTER_MB=\(String(format: "%.1f", rssMB()))")
            finish("VERDICT: OK")
        } catch {
            finish("VERDICT: ERROR — \(error)")
        }
    }
}

extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &chars, &size, nil, 0)
        return String(cString: chars)
    }
}
