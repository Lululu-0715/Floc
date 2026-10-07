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
    @ObservedObject private var fontScale = FontScaleStore.shared
    @ObservedObject private var license = LicenseManager.shared
    @ObservedObject private var profile = ProfileStore.shared

    @Environment(\.dismiss) private var dismiss

    /// 启停代理过程中的错误，展示在「连接状态」里而不是弹窗——
    /// 用户正在这页操作，内联提示比模态弹窗少一次点击。
    @State private var statusMessage: String?

    /// 语言是在二级页里改的，改完回到这页要能立刻看到新的语言名。
    /// `AppLocalization` 是静态查表，没有发布者，只能靠通知手动顶一下。
    @State private var languageTick = 0

    /// 输入卡密直接在这页弹，不必先绕进「升级套餐」。
    @State private var showActivateSheet = false

    var body: some View {
        let _ = languageTick

        return NavigationView {
            List {
                accountSection
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
            .sheet(isPresented: $showActivateSheet) {
                ActivateSheet(manager: license)
            }
        }
    }

    // MARK: - 账号

    /// 账号。
    ///
    /// 三行分别回答三个问题：我是谁（头像昵称）、这台机器是谁（设备码）、
    /// 我还能用多久（剩余时间 + 升级入口）。
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

                    Text(license.remainingText)
                        .font(SettingsMetrics.valueFont)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(AppLocalization.string("升级套餐"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
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
    /// 上面两行是「现在通不通」，下面四个入口是「不通的时候去哪儿修」。
    private var connectionSection: some View {
        Section {
            if runtimeMode.mode == .localProxy {
                SettingsToggleRow(
                    systemImage: "play.circle.fill",
                    title: AppLocalization.string("本机代理"),
                    isOn: Binding(
                        get: { proxy.status.isRunning },
                        set: { setLocalProxy(enabled: $0) }
                    )
                )
            } else {
                SettingsStatusRow(
                    systemImage: "link",
                    title: thirdParty.selectedClient.displayName,
                    value: thirdParty.state.displayText,
                    valueColor: thirdParty.state.isUsable ? .green : .orange
                )
            }

            SettingsStatusRow(
                systemImage: "location.north.line",
                title: AppLocalization.string("虚拟定位"),
                value: state.isEnabled
                    ? AppLocalization.string("已开启")
                    : AppLocalization.string("已关闭"),
                valueColor: state.isEnabled ? .green : .secondary
            )

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
            }

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
            // 主题用行内菜单而不是分段控件：分段控件必须独占一行，
            // 三个选项横着铺开把这一行撑得很高，而主题是个几乎不会改的
            // 设置项，跟语言、字体大小一样收进右侧菜单就够了。
            HStack(spacing: SettingsMetrics.iconSpacing) {
                SettingsIconBadge(systemImage: appearance.mode.systemImage)

                Text(AppLocalization.string("主题"))
                    .font(SettingsMetrics.titleFont)

                Spacer(minLength: 8)

                Picker(AppLocalization.string("主题"), selection: $appearance.mode) {
                    ForEach(AppearanceStore.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(AppLocalization.string("主题"))
            }
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)

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

    /// 启停本机代理。
    ///
    /// 与主界面「开启/停止虚拟定位」保持同一套动作顺序：先改改写配置、
    /// 再停代理、最后复位开关，避免关闭过程中的请求仍被改写。
    private func setLocalProxy(enabled isOn: Bool) {
        statusMessage = nil

        guard isOn else {
            proxy.updateCoordinates(
                latitude: 0,
                longitude: 0,
                enabled: false,
                accuracy: state.accuracy,
                motionRadius: 0
            )
            proxy.stop()
            BackgroundKeepAlive.shared.stop()
            state.disable()
            return
        }

        // 没有选点时也允许只启动代理——安装证书本身就需要证书服务在跑。
        let pair = state.selection
        Task {
            do {
                try await proxy.start(
                    latitude: pair?.wgs84.latitude ?? 0,
                    longitude: pair?.wgs84.longitude ?? 0,
                    enabled: state.isEnabled,
                    accuracy: state.accuracy,
                    motionRadius: state.motionDriftRadius
                )
                BackgroundKeepAlive.shared.start()
                await proxy.verifyCertificateTrust()
                await proxy.verifyWiFiProxy()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}
