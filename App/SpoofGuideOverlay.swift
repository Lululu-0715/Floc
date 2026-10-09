import SwiftUI

/// 「开启虚拟定位成功之后，去关一下定位服务」的引导卡片。
///
/// ## 为什么是自绘而不是 `.alert` / `.sheet`
///
/// - **`.alert`**：系统样式，放不下分步说明，也不跟配色主题走。原实现
///   （1.0.11）就是一条 alert，文案被挤成一大段。
/// - **`.sheet` + `presentationDetents`**：半高 sheet 是 **iOS 16** 的 API，
///   本工程最低支持 15.0（见 `Tests/check_swift_sources.py` 第 9 项），用不了；
///   `.sheet` 在这里只能是全屏卡片，比弹窗还重。
///
/// 所以自绘一层遮罩 + 玻璃卡片：iOS 15 就能用，圆角与材质全部走 `GlassMetrics`
/// 和 `glassCard()`，跟其余界面是一套东西。
///
/// ## 两个按钮的分工
///
/// - **「去设置」**：跳到系统设置的定位服务页（`SystemSettingsNavigator`），
///   顺手记一笔次数，然后**收起本层**（由调用方 `MapHomeView` 决定），
///   但**不写持久化** —— 下次开启虚拟定位还会提醒。
/// - **「不再提示」**：永久关闭（`SpoofGuideStore.dismissForever()`）。
///   它与定位服务当前开着还是关着**无关**，这是用户明确要求的语义。
struct SpoofGuideOverlay: View {

    /// 跳系统设置。
    let onOpenSettings: () -> Void
    /// 永久关闭。
    let onDismissForever: () -> Void

    @Environment(\.themeAccent) private var accent

    var body: some View {
        ZStack {
            // 遮罩不吃点击关闭：这条提示是「做一次就好」的，误触关掉等于白弹，
            // 用户下次还得自己想起这件事。要关只能用下面两个按钮之一。
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 16) {
                header

                // 三步分开放：整段写成两行文字时，用户在系统设置里切来切去
                // 很容易漏掉中间那一步。
                VStack(alignment: .leading, spacing: 10) {
                    step(1, AppLocalization.string("打开「设置 → 隐私与安全性 → 定位服务」"))
                    step(2, AppLocalization.string("把定位服务总开关关掉，等 5 秒以上"))
                    step(3, AppLocalization.string("再打开总开关，回到本应用"))
                }

                Text(AppLocalization.string("定位服务把上一次的坐标缓存在系统里，关开一次才会重新取。一次不行就多试几次。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                actions
            }
            .padding(20)
            // 用卡片这一档（16）：弹窗是「卡片类容器」，不是地图浮层，
            // 也不该用到面板那档 44。
            .glassCard(cornerRadius: GlassMetrics.cardCornerRadius, shadowRadius: 20)
            .padding(.horizontal, 28)
        }
    }

    // MARK: - 分块

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.viewfinder")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: GlassMetrics.inlineCornerRadius,
                                     style: .continuous)
                        .fill(accent.opacity(0.14))
                )

            Text(AppLocalization.string("虚拟定位已开启"))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            Button(action: onOpenSettings) {
                Text(AppLocalization.string("去设置"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        // 46pt 高的按钮取半高 23 —— 就是 `buttonCornerRadius`，
                        // 视觉上等同胶囊，但把「高度 → 圆角」这个依赖写成了常量。
                        RoundedRectangle(cornerRadius: GlassMetrics.buttonCornerRadius,
                                         style: .continuous)
                            .fill(accent)
                    )
                    .contentShape(
                        RoundedRectangle(cornerRadius: GlassMetrics.buttonCornerRadius,
                                         style: .continuous)
                    )
            }
            .glassPressEffect(scale: 0.96)
            .accessibilityLabel(AppLocalization.string("去设置"))

            Button(action: onDismissForever) {
                Text(AppLocalization.string("不再提示"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("不再提示"))
        }
        .padding(.top, 2)
    }

    /// 一步。序号用小圆点，正文用 footnote —— 三行以内一眼扫完。
    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
                .background(accent.opacity(0.14), in: Circle())

            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

#if DEBUG
#Preview {
    SpoofGuideOverlay(onOpenSettings: {}, onDismissForever: {})
}
#endif
