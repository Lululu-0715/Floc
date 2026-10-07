import AVFoundation
import Foundation
import UIKit

/// 后台保活。
///
/// 应用内代理依赖本进程存活，但 iOS 在 App 进入后台后会很快挂起它。
/// 这里用「播放静音音频」这一经典手段换取后台运行时间——代价是需要在
/// Info.plist 里声明 audio 后台模式，且这属于系统允许但审核敏感的能力，
/// 仅在自签自用场景下有意义，不要提交到 App Store。
///
/// **为什么要盯着播放状态**：静音音频不是「播一次就一劳永逸」。电话、
/// Siri、别的应用抢独占音频、拔耳机这些都会中断会话，系统把播放停掉，
/// 紧接着就把整个进程挂起——代理端口随之消失，定位立刻退回真实位置。
/// 用户看到的现象就是「用一会儿就失效，切到别的应用更明显」。
/// 所以这里做了两件事：
///   1. 订阅音频会话的中断 / 线路变化通知，中断结束后主动重播；
///   2. 对外提供 `isAlive` 与 `resumeIfNeeded()`，让回前台的链路自愈逻辑
///      不要相信一个布尔标志，而是真的去问播放器「你还在响吗」。
@MainActor
final class BackgroundKeepAlive {

    static let shared = BackgroundKeepAlive()

    private var audioPlayer: AVAudioPlayer?
    private var isActive = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// 保活是否真的在起作用。
    ///
    /// 判据是播放器的实际播放状态，不是我们自己记的 `isActive`——后者在
    /// 被系统中断后仍然是 `true`，拿它当依据就会出现「以为在保活、其实早就
    /// 被挂起」。
    var isAlive: Bool {
        isActive && (audioPlayer?.isPlaying ?? false)
    }

    /// 开始保活。需要在合适的时机调用（例如代理启动成功后）。
    func start() {
        guard !isActive else {
            // 已经启动过：只补一次健康检查，播放若已被系统掐掉要重新拉起。
            resumeIfNeeded()
            return
        }
        guard configureAudioSession() else {
            RuntimeLogger.warn("APP", "KeepAlive", "音频会话配置失败，后台保活不可用")
            return
        }
        guard let player = makeSilentPlayer() else {
            RuntimeLogger.warn("APP", "KeepAlive", "静音音频构造失败，后台保活不可用")
            return
        }

        player.numberOfLoops = -1
        player.volume = 0
        guard player.play() else {
            RuntimeLogger.warn("APP", "KeepAlive", "静音音频播放失败，后台保活不可用")
            return
        }

        audioPlayer = player
        isActive = true
        registerObservers()
        RuntimeLogger.info("APP", "KeepAlive", "后台保活已开启")
    }

    /// 停止保活。
    func stop() {
        guard isActive else { return }
        removeObservers()
        audioPlayer?.stop()
        audioPlayer = nil
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        RuntimeLogger.info("APP", "KeepAlive", "后台保活已关闭")
    }

    /// 播放若已停掉就重新拉起。
    ///
    /// 调用点是「应用进入后台」与「应用回到前台」两处：前者是最后一次
    /// 自救机会（一旦被挂起就再也跑不了代码），后者用于修复在后台期间
    /// 被中断、没能自行恢复的情况。
    ///
    /// `start()` 是幂等的，重复调用只会走到这里做一次检查。
    func resumeIfNeeded() {
        guard isActive else { return }
        guard let player = audioPlayer, !player.isPlaying else { return }

        RuntimeLogger.warn("APP", "KeepAlive", "静音音频已停止，重新拉起")

        // 会话可能被别的应用抢走了，先抢回来再播。
        if !configureAudioSession() {
            // 抢不回来通常是别的应用正在独占输出，等下一次机会再试。
            // 这里不做任何降级：代理本身还在，只是活不过后台。
            RuntimeLogger.warn("APP", "KeepAlive", "音频会话未能重新激活，保活暂时失效")
            return
        }

        if player.play() {
            RuntimeLogger.info("APP", "KeepAlive", "静音音频已恢复播放")
        } else {
            RuntimeLogger.warn("APP", "KeepAlive", "静音音频恢复失败，保活暂时失效")
        }
    }

    // MARK: - 中断处理

    /// 订阅音频会话的中断与线路变化。
    ///
    /// 这两件事都会让播放停下来，而播放一停，后台运行时间就没了。
    private func registerObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        // 通知里只取原始值再跳主线程：`Notification` 不是 Sendable，
        // 整个对象跨 actor 传递在严格并发下会报警告。
        // 这里也不用 `MainActor.assumeIsolated`——它是 iOS 17 起才有的 API，
        // 而本工程最低支持 iOS 15。
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(typeRaw: typeRaw, optionRaw: optionRaw)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        })

        // 系统重启音频栈（长时间后台后偶发）时播放器会彻底作废，只能重建。
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                RuntimeLogger.warn("APP", "KeepAlive", "媒体服务被系统重置，重建静音音频")
                self.audioPlayer?.stop()
                self.audioPlayer = nil
                self.isActive = false
                self.start()
            }
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    /// 中断开始 → 记录；中断结束 → 根据系统建议决定是否重播。
    ///
    /// 关键在 `.shouldResume`：系统认为「现在可以继续播了」才去恢复，
    /// 否则会与来电、导航播报之类的音频打架。
    private func handleInterruption(typeRaw: UInt?, optionRaw: UInt?) {
        guard isActive,
              let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            RuntimeLogger.warn("APP", "KeepAlive", "音频会话被中断，后台保活暂时失效")

        case .ended:
            let options = optionRaw.map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            guard options.contains(.shouldResume) else {
                RuntimeLogger.warn("APP", "KeepAlive", "音频会话中断结束，但系统未允许自动恢复")
                return
            }
            resumeIfNeeded()

        @unknown default:
            break
        }
    }

    /// 线路变化（拔耳机、切换蓝牙）会让部分设备的播放停掉，顺手检查一次。
    private func handleRouteChange(reasonRaw: UInt?) {
        guard isActive,
              let reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }

        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .routeConfigurationChange:
            resumeIfNeeded()
        default:
            break
        }
    }

    // MARK: - 音频构造

    private func configureAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            // mixWithOthers 让我们不影响用户正在播放的音乐。
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            return true
        } catch {
            RuntimeLogger.warn("APP", "KeepAlive", "音频会话异常", details: [
                "error": error.localizedDescription,
            ])
            return false
        }
    }

    /// 生成一段极短的静音 PCM 数据供循环播放。
    private func makeSilentPlayer() -> AVAudioPlayer? {
        let sampleRate = 8000
        let durationSeconds = 1
        let frameCount = sampleRate * durationSeconds

        var samples = [Int16](repeating: 0, count: frameCount)
        let dataSize = samples.count * MemoryLayout<Int16>.size

        var wav = Data()
        // RIFF 头
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(littleEndian: UInt32(36 + dataSize))
        wav.append(contentsOf: Array("WAVE".utf8))
        // fmt 块
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(littleEndian: UInt32(16))            // 块大小
        wav.append(littleEndian: UInt16(1))             // PCM
        wav.append(littleEndian: UInt16(1))             // 单声道
        wav.append(littleEndian: UInt32(sampleRate))    // 采样率
        wav.append(littleEndian: UInt32(sampleRate * 2))// 字节率
        wav.append(littleEndian: UInt16(2))             // 块对齐
        wav.append(littleEndian: UInt16(16))            // 位深
        // data 块
        wav.append(contentsOf: Array("data".utf8))
        wav.append(littleEndian: UInt32(dataSize))
        samples.withUnsafeBufferPointer { buffer in
            wav.append(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
        }

        return try? AVAudioPlayer(data: wav)
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { self.append(contentsOf: $0) }
    }
}
