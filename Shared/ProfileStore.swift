import SwiftUI
import UIKit

/// 本机个人资料：昵称 + 头像。
///
/// 为什么单独存而不跟着卡密走：头像昵称是纯本地展示信息，不参与授权校验，
/// 也不该因为换卡密而被清掉。头像图片写在 App Group 容器里（不是
/// UserDefaults），否则一张几 MB 的照片塞进 plist 会让每次读写都变慢。
@MainActor
final class ProfileStore: ObservableObject {

    static let shared = ProfileStore()

    private enum Key {
        static let nickname = "profile.nickname"
        static let avatarFile = "profile.avatarFile"
    }

    /// 头像最长边超过这个值就等比缩小再存。
    ///
    /// 相册里原图动辄 4000×3000，直接落盘既浪费空间，每次进设置页
    /// 解码一次也会卡一下。512 在 44pt 的圆头像上已经远超屏幕像素密度。
    private static let avatarMaxSide: CGFloat = 512

    @Published var nickname: String {
        didSet { defaults.set(nickname, forKey: Key.nickname) }
    }

    @Published private(set) var avatar: UIImage?

    private let defaults = AppGroup.defaults

    private init() {
        nickname = defaults.string(forKey: Key.nickname) ?? ""
        avatar = Self.loadAvatar(fileName: defaults.string(forKey: Key.avatarFile))
    }

    // MARK: - 对外

    /// 展示用昵称。没设置时给一个中性占位，避免那一行空着。
    var displayName: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppLocalization.string("未设置昵称") : trimmed
    }

    var hasNickname: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 头像为空时，用昵称首字母画一个占位圆。
    var avatarInitial: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "F" }
        return String(first).uppercased()
    }

    // MARK: - 写入

    func updateAvatar(_ image: UIImage) {
        let resized = Self.resized(image, maxSide: Self.avatarMaxSide)
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return }

        removeAvatarFile()

        let fileName = "avatar-\(UUID().uuidString).jpg"
        let url = AppGroup.containerURL.appendingPathComponent(fileName)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }

        defaults.set(fileName, forKey: Key.avatarFile)
        avatar = resized
        RuntimeLogger.info("APP", "Profile", "头像已更新", details: [
            "bytes": "\(data.count)",
        ])
    }

    func removeAvatar() {
        removeAvatarFile()
        defaults.removeObject(forKey: Key.avatarFile)
        avatar = nil
    }

    // MARK: - 内部

    private func removeAvatarFile() {
        guard let name = defaults.string(forKey: Key.avatarFile) else { return }
        let url = AppGroup.containerURL.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadAvatar(fileName: String?) -> UIImage? {
        guard let fileName else { return nil }
        let url = AppGroup.containerURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 等比缩放到最长边不超过 `maxSide`。已经够小就原样返回，避免无谓重绘。
    private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide, longest > 0 else { return image }

        let ratio = maxSide / longest
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// 圆形头像。有图显示图，没图显示昵称首字母。
struct ProfileAvatarView: View {

    let image: UIImage?
    let initial: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.blue, Color.cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
