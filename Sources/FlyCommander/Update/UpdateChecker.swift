import Foundation
import Darwin
import TCCore

/// latest.json 取数抽象（测试注入 canned Data，真实现走 URLSession）。
protocol UpdateFetching {
    func fetch(_ url: URL) throws -> Data
}

/// 真实现：同步 GET（只在后台队列调，勿主线程）。
/// 同步包装用 URLSession 的 data(for:) + 信号量（C API，无泛型元数据——守缩减 SDK 纪律）。
final class URLSessionUpdateFetcher: UpdateFetching {
    func fetch(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("FlyCommander-Update", forHTTPHeaderField: "User-Agent")
        let lock = NSLock()
        var result: Result<(Data, URLResponse), Error>?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, resp, err in
            lock.lock()
            result = if let err { .failure(err) }
                     else if let data, let resp { .success((data, resp)) }
                     else { .failure(URLError(.zeroByteResource)) }
            lock.unlock()
            sem.signal()
        }.resume()
        guard sem.wait(timeout: .now() + 20) == .success else { throw URLError(.timedOut) }
        lock.lock(); let r = result; lock.unlock()
        guard let r else { throw URLError(.unknown) }
        let (data, resp) = try r.get()
        // 404（updates 分支还没有清单）等 HTTP 错误显式化，别把 HTML 错误页喂解码器。
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// 版本检查编排：取清单 → 校验 → 比版本 → 回调。
/// 决策逻辑（节流/跳过/静默）全部可测：fetcher / clock / localVersion / store 全注入，
/// 线程包装（runInBackground/onMain）仿 TransferEngine——测试注入同步闭包不死锁。
final class UpdateChecker {
    /// 检查结果（UI 侧据此弹窗/回显）。
    enum Outcome {
        case upToDate                     // 已是最新（含「节流跳过」吗？不含——throttled 单列）
        case available(UpdateManifest)    // 有新版（UI 携 version/notes 弹窗）
        case skipped                      // 自动路：该版本被用户跳过 → 静默
        case throttled                    // 自动路：距上次检查 <24h → 静默
        case failed                       // 网络/清单无效（自动路静默，手动路回显失败）
    }

    static let checkInterval: TimeInterval = 24 * 3600

    /// 本机 CPU 架构键（"arm64"/"x86_64"）：sysctl hw.optional.arm64=1 → arm64。
    /// 用硬件位而非进程架构：Apple Silicon 上即便 app 跑在 Rosetta（x86_64 切片）下，
    /// hw.optional.arm64 恒 1 → 仍选 arm64 包（原生优于转译）；Intel 上该 sysctl 不存在 → x86_64。
    static func detectArchKey() -> String {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 {
            return UpdateManifest.arm64Key
        }
        return UpdateManifest.x86_64Key
    }

    let manifestURL: URL
    private let fetcher: UpdateFetching
    private let store: UpdateStore
    /// 当前 app 版本（UpdateFlow 回显「已是最新 vX」也要读 → internal）。
    let localVersion: String
    /// 本清单按此架构键选产物（默认探测本机 CPU）。
    let archKey: String
    /// 可注入时钟（仿 TransferEngine.progressClock.now），测试冻结/脚本化 24h 边界。
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }
    /// 后台/主线程派发（测试注同步闭包）。
    var runInBackground: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.global(qos: .utility).async(execute: work)
    }
    var onMain: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.async(execute: work)
    }

    init(manifestURL: URL = URL(string: "https://raw.githubusercontent.com/gybcb/fly_commander/updates/latest.json")!,
         fetcher: UpdateFetching = URLSessionUpdateFetcher(),
         store: UpdateStore = .shared,
         localVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
         archKey: String = UpdateChecker.detectArchKey()) {
        self.manifestURL = manifestURL
        self.fetcher = fetcher
        self.store = store
        self.localVersion = localVersion
        self.archKey = archKey
    }

    /// 检查一次。manual=true（菜单/命令）→ 忽略节流与跳过，一切结果都回调；
    /// 自动路（启动/定时器）→ 节流命中或版本被跳过或失败 → 静默（回调 throttled/skipped/failed，
    /// UI 侧只对 available 动作）。回调恒在主线程。
    func check(manual: Bool, completion: @escaping (Outcome) -> Void) {
        if !manual, let last = store.lastCheck, now() - last < Self.checkInterval {
            onMain { completion(.throttled) }
            return
        }
        // 记时点放在检查**开始时**：失败也计——否则启动即断网会每分钟重试打网络。
        store.lastCheck = now()
        let url = manifestURL
        let local = localVersion
        let skipped = store.skippedVersion
        let arch = archKey
        runInBackground { [fetcher] in
            let outcome: Outcome
            do {
                let manifest = try UpdateManifest.decode(try fetcher.fetch(url), arch: arch)
                if VersionCompare.isUpdate(manifest.version, newerThan: local) {
                    outcome = (!manual && manifest.version == skipped) ? .skipped : .available(manifest)
                } else {
                    outcome = .upToDate
                }
            } catch {
                outcome = .failed
            }
            self.onMain { completion(outcome) }
        }
    }
}
