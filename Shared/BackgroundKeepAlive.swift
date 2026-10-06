import AVFoundation
import Foundation
import UIKit

/// 后台保活。
///
/// 应用内代理依赖本进程存活，但 iOS 在 App 进入后台后会很快挂起它。
/// 这里用「播放静音音频」这一经典手段换取后台运行时间——代价是需要在
/// Info.plist 里声明 audio 后台模式，且这属于系统允许但审核敏感的能力，
/// 仅在自签自用场景下有意义，不要提交到 App Store。
@MainActor
final class BackgroundKeepAlive {

    static let shared = BackgroundKeepAlive()

    private var audioPlayer: AVAudioPlayer?
    private var isActive = false

    private init() {}

    /// 开始保活。需要在合适的时机调用（例如代理启动成功后）。
    func start() {
        guard !isActive else { return }
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
        RuntimeLogger.info("APP", "KeepAlive", "后台保活已开启")
    }

    /// 停止保活。
    func stop() {
        guard isActive else { return }
        audioPlayer?.stop()
        audioPlayer = nil
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        RuntimeLogger.info("APP", "KeepAlive", "后台保活已关闭")
    }

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
