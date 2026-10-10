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
///
/// 两个可选参数是诊断页加上的，**不传时与旧版逐像素一致**：
///
/// - `valueColor`：值默认是次要色。诊断页的「虚拟定位」要显示生效结论
///   （已生效绿 / 未生效橙 / 验证中蓝 / 未验证灰），得按状态染色。
/// - `help`：标题右侧挂一个「带圆圈的小问号」，点开弹一段说明。诊断页的
///   「代理状态」在两种运行模式下指的不是同一个东西（内置代理 vs 第三方
///   模块），光看「未启动」会误判成故障，所以需要就地解释。
///
/// 问号**不整行可点**：这行的其余部分仍然只是陈述，让整行响应点击会
/// 诱导用户以为点进去有别的页面。图标自己的命中区放大到 28×22，
/// 比 13pt 的符号大一圈，手指够得着。
struct KeyValueRow: View {

    private let title: String
    private let value: String
    private let valueColor: Color?
    private let help: String?

    @State private var showingHelp = false

    init(_ title: String, value: String, valueColor: Color? = nil, help: String? = nil) {
        self.title = title
        self.value = value
        self.valueColor = valueColor
        self.help = help
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 2) {
                Text(title)
                if let help {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { showingHelp = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(AppLocalization.string("说明"))
                        .accessibilityHint(help)
                }
            }
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(valueColor ?? Color.secondary)
                .multilineTextAlignment(.trailing)
        }
        .alert(Text(title), isPresented: $showingHelp) {
            Button(AppLocalization.string("知道了"), role: .cancel) {}
        } message: {
            Text(help ?? "")
        }
    }
}
