import SwiftUI

/// 设置页。
///
/// 版式参照参考图：`List` + `.insetGrouped` 给出独立的白色卡片，
/// 每行以圆形图标起头，右侧按内容性质给出四种控件——
/// 勾选（模式）/ 开关（可切换项）/ 只读状态文字（无箭头）/ 跳转箭头。
///
/// 这一版刻意只留五组：账号 / 运行模式 / 连接状态 / 外观及个性化 / 关于。
/// 具体配置全部下沉到二级页——主页每行右边都带着当前取值，
/// 不进二级页也知道现在是什么状态，滚动长度却砍掉了一半以上。
///
/// 背景不额外铺色：`.insetGrouped` 的底色本来就是 `systemGroupedBackground`，
/// 自己再叠一层反而会和系统色在深色模式下打架。
struct SettingsView: View {

    @ObservedObject var setup: SetupCoordinator
    @ObservedObject var state: MapLocationState

    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var thirdParty = ThirdPartyProxyManager.shared
    @ObservedObject private var runtimeMode = RuntimeModeStore.shared
    @ObservedObject private var remoteConfiguration = AppRemoteConfigurationStore.shared
    @ObservedObject private var appearance = AppearanceStore.shared
    @ObservedObject private var theme = ThemeStore.shared
    @ObservedObject private var fontScale = FontScaleStore.shared
    #if !PURE_BUILD
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var profile = ProfileStore.shared
    #endif

    @Environment(\.dismiss) private var dismiss

    /// 语言是在二级页里改的，改完回到这页要能立刻看到新的语言名。
    /// `AppLocalization` 是静态查表，没有发布者，只能靠通知手动顶一下。
    @State private var languageTick = 0

    #if !PURE_BUILD
    /// 输入卡密直接在这页弹，不必先绕进「升级套餐」。
    @State private var showActivateSheet = false
    #endif

    var body: some View {
        let _ = languageTick

        return NavigationView {
            List {
                // 纯净版整组拿掉：这一组的三行分别是「我是谁（头像昵称）」
                // 「这台机器是谁（设备码）」「我还能用多久（剩余时间 + 升级）」，
                // 后两项本来就属于卡密那套，头像昵称留着也只是半组空壳。
                // 用户明确要求「纯净版设置里面不要有账号这类」。
                #if !PURE_BUILD
                accountSection
                #endif
                modeSection
                connectionSection
                appearanceSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(AppLocalization.string("设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("完成")) { dismiss() }
                }
            }
            .task {
                await remoteConfiguration.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: AppLocalization.didChangeNotification)) { _ in
                languageTick &+= 1
            }
            #if !PURE_BUILD
            .sheet(isPresented: $showActivateSheet) {
                ActivateSheet(manager: license)
            }
            #endif
        }
    }

    // MARK: - 账号

    /// 账号。
    ///
    /// 三行分别回答三个问题：我是谁（头像昵称）、这台机器是谁（设备码）、
    /// 我还能用多久（剩余时间 + 升级入口）。
    ///
    /// 整组只在标准版出现：后两行本来就属于卡密那套东西，纯净版里连头像昵称
    /// 也一并去掉——见 `body` 里的调用点。
    // 整组（含下面的 licenseBadge）一起放进条件编译：纯净版既不显示这一组，
    // 也就不需要编译它的辅助视图，省得留下「编译得到但没人引用」的警告。
    #if !PURE_BUILD
    private var accountSection: some View {
        Section {
            NavigationLink {
                ProfileView(profile: profile)
            } label: {
                HStack(spacing: SettingsMetrics.iconSpacing) {
                    ProfileAvatarView(
                        image: profile.avatar,
                        initial: profile.avatarInitial,
                        size: SettingsMetrics.iconSize + 8
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                            .font(SettingsMetrics.titleFont)
                        Text(AppLocalization.string("点按设置头像和昵称"))
                            .font(SettingsMetrics.subtitleFont)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: SettingsMetrics.iconSpacing) {
                SettingsIconBadge(systemImage: "iphone")

                Text(AppLocalization.string("设备码"))
                    .font(SettingsMetrics.titleFont)

                Spacer(minLength: 8)

                Text(DeviceIdentity.displayCode)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)

                licenseBadge
            }
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)

            NavigationLink {
                MembershipView(manager: license)
            } label: {
                HStack(spacing: SettingsMetrics.iconSpacing) {
                    SettingsIconBadge(systemImage: "hourglass")

                    Text(AppLocalization.string("剩余时间"))
                        .font(SettingsMetrics.titleFont)

                    Spacer(minLength: 8)

                    // 这里只放「大概还有多久」。精确到分钟的文案在列表行里
                    // （图标 + 标题 + 取值 + 箭头）一定会被截断，完整信息
                    // 留给二级页——一级页扫一眼知道个数量级就够了。
                    Text(license.remainingSummaryText)
                        .font(SettingsMetrics.valueFont)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            }

            Button {
                showActivateSheet = true
            } label: {
                HStack(spacing: SettingsMetrics.iconSpacing) {
                    SettingsIconBadge(systemImage: "key.fill", tint: .orange)

                    Text(AppLocalization.string("输入卡密"))
                        .font(SettingsMetrics.titleFont)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, SettingsMetrics.rowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("账号"))
        }
    }

    /// 授权状态小胶囊。颜色跟着「能不能用」走，而不是跟着具体状态枚举——
    /// 用户只需要一眼看出「现在是好的还是不好的」。
    private var licenseBadge: some View {
        Text(AppLocalization.string(license.displayNameKey))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(badgeColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(badgeColor.opacity(0.14)))
    }

    private var badgeColor: Color {
        if license.isTestLicense { return .purple }
        if license.isLocalMode { return .blue }
        return license.isUsable ? .green : .red
    }
    #endif

    // MARK: - 运行模式

    private var modeSection: some View {
        Section {
            NavigationLink {
                RuntimeModePickerView(runtimeMode: runtimeMode, onSelect: switchMode)
            } label: {
                HStack(spacing: SettingsMetrics.iconSpacing) {
                    SettingsIconBadge(systemImage: runtimeMode.mode.systemImage)
                    Text(AppLocalization.string("运行模式"))
                        .font(SettingsMetrics.titleFont)
                    Spacer(minLength: 8)
                    Text(runtimeMode.mode.displayName)
                        .font(SettingsMetrics.valueFont)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            }
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("运行模式"))
        } footer: {
            Text(runtimeMode.mode.summary)
        }
    }

    // MARK: - 连接状态

    /// 连接状态。
    ///
    /// 顺序固定为「环境 / 客户端 → 虚拟定位 → 定位模拟」，两种模式一致：
    ///
    ///   - 原来首行是「本机代理」开关 / 第三方客户端状态，和下面的二级入口
    ///     说的是同一件事（一个可点、一个不可点），删掉首行只留入口。
    ///     本机代理的开关挪进了「证书与环境」——它本来就属于那边的内容。
    ///   - 第三方代理入口上移到「虚拟定位」之前：先确认链路，再看开关状态，
    ///     最后才调参数，读起来是一条因果链。
    private var connectionSection: some View {
        Section {
            if runtimeMode.mode == .localProxy {
                detailLink(
                    systemImage: "checkmark.shield.fill",
                    title: AppLocalization.string("证书与环境"),
                    value: proxy.certificateTrustState.isTrusted
                        ? proxy.certificateTrustState.displayText
                        : proxy.wiFiProxyState.displayText
                ) {
                    CertificateEnvironmentView(state: state)
                }
            } else {
                detailLink(
                    systemImage: "shield.lefthalf.filled",
                    title: AppLocalization.string("第三方代理"),
                    value: thirdParty.state.displayText
                ) {
                    ThirdPartySettingsView(thirdParty: thirdParty)
                }
            }

            SettingsStatusRow(
                systemImage: "location.north.line",
                title: AppLocalization.string("虚拟定位"),
                value: state.isEnabled
                    ? AppLocalization.string("已开启")
                    : AppLocalization.string("已关闭"),
                valueColor: state.isEnabled ? .green : .secondary
            )

            detailLink(
                systemImage: "scope",
                title: AppLocalization.string("定位模拟"),
                value: String(format: AppLocalization.string("精度 %@ 米"), "\(state.accuracy)")
            ) {
                SimulationSettingsView(state: state)
            }
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("连接状态"))
        }
    }

    /// 二级页入口：图标 + 标题 + 当前取值 + 箭头。
    private func detailLink<Destination: View>(
        systemImage: String,
        title: String,
        value: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: SettingsMetrics.iconSpacing) {
                SettingsIconBadge(systemImage: systemImage)

                Text(title)
                    .font(SettingsMetrics.titleFont)

                Spacer(minLength: 8)

                Text(value)
                    .font(SettingsMetrics.valueFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)
        }
    }

    // MARK: - 外观及个性化

    private var appearanceSection: some View {
        Section {
            // 主题用行内分段控件：三个选项必须一眼看全、点一下就切，
            // 收进右侧菜单等于多一次点击，也看不出当前有几个选项。
            // 分段控件本身就占满一行宽度，所以把标题压到最左、控件靠右，
            // 两者共用一行，比让主题单独占一行矮一半。
            HStack(spacing: SettingsMetrics.iconSpacing) {
                SettingsIconBadge(systemImage: appearance.mode.systemImage)

                Text(AppLocalization.string("主题"))
                    .font(SettingsMetrics.titleFont)
                    .fixedSize()

                Spacer(minLength: 6)

                Picker(AppLocalization.string("主题"), selection: $appearance.mode) {
                    ForEach(AppearanceStore.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)

            detailLink(
                systemImage: "paintpalette.fill",
                title: AppLocalization.string("配色主题"),
                value: theme.palette.displayName
            ) {
                ColorThemeSettingsView(store: theme)
            }

            detailLink(
                systemImage: "globe",
                title: AppLocalization.string("语言"),
                value: currentLanguageName
            ) {
                LanguageSettingsView()
            }

            detailLink(
                systemImage: "textformat.size",
                title: AppLocalization.string("字体大小"),
                value: fontScale.size.displayName
            ) {
                FontSizeSettingsView(store: fontScale)
            }
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("外观及个性化"))
        } footer: {
            Text(AppLocalization.string("切换语言后部分界面需要重新进入才会完全生效。"))
        }
    }

    private var currentLanguageName: String {
        guard let code = AppLocalization.overrideLanguage else {
            return AppLocalization.string("跟随系统")
        }
        return AppLocalization.supportedLanguages.first { $0.code == code }?.name ?? code
    }

    // MARK: - 关于

    /// 关于。
    ///
    /// 「说明 / 工作原理 / 支持」原来各占一个分组，其实都是
    /// 「出问题了再回来查」的内容，收进这里三个入口后面更清爽。
    private var aboutSection: some View {
        Section {
            detailLink(
                systemImage: "info.circle",
                title: AppLocalization.string("关于 Floc"),
                value: Bundle.main.appVersion
            ) {
                AboutFlocView(setup: setup)
            }

            detailLink(
                systemImage: "book",
                title: AppLocalization.string("用户指南"),
                value: ""
            ) {
                UserGuideView()
            }

            detailLink(
                systemImage: "exclamationmark.bubble",
                title: AppLocalization.string("意见反馈"),
                value: ""
            ) {
                FeedbackView(state: state)
            }

            detailLink(
                systemImage: "envelope",
                title: AppLocalization.string("联系我们"),
                value: ""
            ) {
                ContactView()
            }
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("关于"))
        } footer: {
            Text(AppLocalization.string(
                "本应用用于定位服务的开发测试与研究，请仅在你拥有或获得授权的设备与网络环境中使用。"
            ))
        }
    }

    // MARK: - 操作

    /// 切换运行模式。两套链路不能同时开着，所以先停掉当前代理再切。
    private func switchMode(to mode: ProxyRuntimeMode) {
        guard mode != runtimeMode.mode else { return }
        if proxy.status.isRunning { proxy.stop() }
        BackgroundKeepAlive.shared.stop()
        runtimeMode.select(mode)
        setup.reset()
        dismiss()
    }
}
