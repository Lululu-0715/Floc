import SwiftUI

/// `LabeledContent(_:value:)` 的 iOS 15 兼容替身。
///
/// 项目的最低部署目标写死在 project.yml 里（iOS 15.0），而 SwiftUI 的
/// `LabeledContent` 是 iOS 16 才引入的，直接用它会让整个 target 编译不过。
///
/// 这里保持与 `LabeledContent(_:value:)` 完全一致的调用签名，
/// 视觉上也对齐（标题在左、值靠右并置灰）。
/// 将来若把部署目标提到 iOS 16，把调用点换回 `LabeledContent` 即可，
/// 不需要改动这一层的调用代码。
struct KeyValueRow: View {

    private let title: String
    private let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
