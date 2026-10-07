import SwiftUI
import UIKit

/// 个人资料：头像与昵称。
///
/// 纯本地信息，不上传、不参与授权校验——所以这里没有「保存失败」这类
/// 状态，改完立刻落盘。昵称走 `ProfileStore.nickname` 的 didSet，
/// 头像走文件写入。
struct ProfileView: View {

    @ObservedObject var profile: ProfileStore

    @State private var showPicker = false
    @State private var showRemoveConfirmation = false
    @FocusState private var nicknameFocused: Bool

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ProfileAvatarView(
                        image: profile.avatar,
                        initial: profile.avatarInitial,
                        size: 88
                    )

                    HStack(spacing: 12) {
                        Button {
                            showPicker = true
                        } label: {
                            Text(AppLocalization.string("更换头像"))
                        }
                        .buttonStyle(.borderedProminent)

                        if profile.avatar != nil {
                            Button(role: .destructive) {
                                showRemoveConfirmation = true
                            } label: {
                                Text(AppLocalization.string("移除"))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                TextField(AppLocalization.string("昵称"), text: $profile.nickname)
                    .focused($nicknameFocused)
                    .submitLabel(.done)
                    .onSubmit { nicknameFocused = false }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("昵称"))
            } footer: {
                Text(AppLocalization.string("昵称只在这台设备上显示，不会上传。留空时使用默认称呼。"))
            }

            // 设备码唯一的用途就是绑卡密，纯净版里没有任何地方会用到它，
            // 留着只会让用户困惑「这串码是要发给谁」——整段拿掉。
            #if !PURE_BUILD
            Section {
                SettingsStatusRow(
                    systemImage: "iphone",
                    title: AppLocalization.string("设备码"),
                    value: DeviceIdentity.displayCode,
                    monospacedValue: true
                )

                Button {
                    UIPasteboard.general.string = DeviceIdentity.current
                    RuntimeLogger.info("APP", "Profile", "设备码已复制")
                } label: {
                    SettingsLabel(
                        systemImage: "doc.on.doc",
                        title: AppLocalization.string("复制完整设备码"),
                        isSecondary: true
                    )
                }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("设备"))
            } footer: {
                Text(AppLocalization.string("设备码用于把卡密绑定到这台设备。换机后可以凭它联系我们处理。"))
            }
            #endif
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("账号"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            ImagePicker(sourceType: .photoLibrary) { image in
                profile.updateAvatar(image)
            }
        }
        .confirmationDialog(
            AppLocalization.string("移除头像？"),
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("移除"), role: .destructive) {
                profile.removeAvatar()
            }
            Button(AppLocalization.string("取消"), role: .cancel) {}
        }
    }
}

// MARK: - 相册

/// `UIImagePickerController` 的 SwiftUI 包装。
///
/// 没用 `PhotosPicker` 是因为它要 iOS 16，而本工程最低支持 iOS 15。
/// 只需要「选一张图」这一个能力，UIImagePickerController 足够了。
private struct ImagePicker: UIViewControllerRepresentable {

    let sourceType: UIImagePickerController.SourceType
    let onPicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = sourceType
        controller.allowsEditing = true
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

        private let onPicked: (UIImage) -> Void
        private let onFinish: () -> Void

        init(onPicked: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) {
                onPicked(image)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}
