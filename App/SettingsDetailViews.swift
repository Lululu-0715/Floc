import SwiftUI

// 设置页各分组的二级页面。
//
// 主设置页只保留「一眼能看完的摘要」，具体配置全部下沉到这里。
// 这样主页面从原来的一长条变成五组，滚动长度砍掉一半以上；
// 代价是每个入口多一次点击，所以入口右侧都带上当前取值，
// 不进二级页也知道现在是什么状态。

// MARK: - 运行模式

/// 运行模式选择。
struct RuntimeModePickerView: View {

    @ObservedObject var runtimeMode: RuntimeModeStore
    /// 切换模式要顺带停代理并重置引导，动作留在 SettingsView 里统一做。
    let onSelect: (ProxyRuntimeMode) -> Void

    var body: some View {
        List {
            Section {
                ForEach(ProxyRuntimeMode.allCases) { mode in
                    optionRow(mode)
                }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("运行模式"))
            } footer: {
                Text(AppLocalization.string("切换模式会停止当前代理并重新走一遍配置引导，已保存的收藏和证书不受影响。"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("运行模式"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func optionRow(_ mode: ProxyRuntimeMode) -> some View {
        let isSelected = runtimeMode.mode == mode
        return Button {
            onSelect(mode)
        } label: {
            HStack(alignment: .top, spacing: SettingsMetrics.iconSpacing) {
                SettingsIconBadge(systemImage: mode.systemImage)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.displayName)
                        .font(SettingsMetrics.titleFont)
                        .foregroundStyle(.primary)
                    Text(mode.summary)
                        .font(SettingsMetrics.subtitleFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.blue)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }
}

// MARK: - 语言

/// 界面语言选择。
struct LanguageSettingsView: View {

    @State private var selection: String = AppLocalization.overrideLanguage ?? "system"

    var body: some View {
        List {
            Section {
                optionRow(
                    key: "system",
                    title: AppLocalization.string("跟随系统"),
                    subtitle: nil
                )
                ForEach(AppLocalization.supportedLanguages, id: \.code) { language in
                    optionRow(
                        key: language.code,
                        title: language.name,
                        subtitle: nil
                    )
                }
            } footer: {
                Text(AppLocalization.string("切换语言后部分界面需要重新进入才会完全生效。"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("语言"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func optionRow(key: String, title: String, subtitle: String?) -> some View {
        Button {
            selection = key
            AppLocalization.overrideLanguage = key == "system" ? nil : key
            NotificationCenter.default.post(name: AppLocalization.didChangeNotification, object: nil)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsMetrics.titleFont)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(SettingsMetrics.subtitleFont)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if selection == key {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.blue)
                }
            }
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 字体大小

/// 应用内字号。
struct FontSizeSettingsView: View {

    @ObservedObject var store: FontScaleStore

    var body: some View {
        List {
            Section {
                ForEach(FontScaleSize.allCases) { size in
                    Button {
                        store.size = size
                    } label: {
                        HStack(spacing: 10) {
                            Text(size.displayName)
                                .font(.system(size: 16 * size.scale))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if store.size == size {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.blue)
                            }
                        }
                        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("字体大小"))
            } footer: {
                Text(AppLocalization.string("调整后立即生效，只影响本应用，不会改动系统的显示设置。"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("字体大小"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 定位模拟

/// 精度、运动状态模拟与自检。
struct SimulationSettingsView: View {

    @ObservedObject var state: MapLocationState

    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var runtimeMode = RuntimeModeStore.shared

    @State private var selfCheckResult: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: SettingsMetrics.iconSpacing) {
                    SettingsIconBadge(systemImage: "scope")

                    Text(AppLocalization.string("精度"))
                        .font(SettingsMetrics.titleFont)

                    Spacer(minLength: 8)

                    Picker(AppLocalization.string("精度"), selection: $state.accuracy) {
                        Text("10 m").tag(10)
                        Text("25 m").tag(25)
                        Text("50 m").tag(50)
                        Text("100 m").tag(100)
                        Text("500 m").tag(500)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.vertical, SettingsMetrics.rowVerticalPadding)

                HStack(spacing: SettingsMetrics.iconSpacing) {
                    SettingsIconBadge(systemImage: "figure.walk")

                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppLocalization.string("运动状态模拟"))
                            .font(SettingsMetrics.titleFont)
                        Text(AppLocalization.string("在选定位置附近轻微漂移，更接近真实 GPS。"))
                            .font(SettingsMetrics.subtitleFont)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Picker(AppLocalization.string("运动状态模拟"), selection: motionDriftBinding) {
                        ForEach(MotionDriftOption.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("定位模拟"))
            } footer: {
                Text(runtimeMode.mode == .thirdParty
                     ? AppLocalization.string("精度与运动状态模拟都会写入客户端配置。")
                     : AppLocalization.string("精度直接影响系统对定位可信度的判断，通常 25 米较为自然。"))
            }

            Section {
                Button {
                    selfCheckResult = proxy.runSelfCheck(
                        latitude: state.selection?.wgs84.latitude ?? 22.281508,
                        longitude: state.selection?.wgs84.longitude ?? 114.174700,
                        accuracy: state.accuracy
                    )
                } label: {
                    SettingsLabel(
                        systemImage: "checkmark.seal",
                        title: AppLocalization.string("运行改写引擎自检")
                    )
                }

                if let selfCheckResult {
                    Text(selfCheckResult)
                        .font(.caption.monospaced())
                        .foregroundStyle(selfCheckResult.hasPrefix("ok:") ? Color.green : Color.red)
                }
            } footer: {
                Text(AppLocalization.string("自检只在本地跑一遍坐标转换与改写逻辑，不会改动当前生效的配置。"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("定位模拟"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 界面上下拉给的是档位原始值（0 / 5 / 10 / 20），写回前收敛一次，
    /// 避免脏值传进 Core。
    private var motionDriftBinding: Binding<Int> {
        Binding(
            get: { state.motionDriftRadius },
            set: { state.motionDriftRadius = MotionDriftOption.normalized($0).rawValue }
        )
    }
}

// MARK: - 收藏位置

/// 收藏位置管理。
struct FavoritesSettingsView: View {

    @ObservedObject var favorites: FavoriteLocationStore

    @State private var showClearConfirmation = false

    var body: some View {
        List {
            Section {
                SettingsStatusRow(
                    systemImage: "star.fill",
                    title: AppLocalization.string("已收藏"),
                    value: "\(favorites.favorites.count)"
                )

                ForEach(favorites.favorites) { favorite in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(favorite.name)
                            .font(SettingsMetrics.titleFont)
                        Text(String(format: "%.6f, %.6f",
                                    favorite.pair.wgs84.latitude,
                                    favorite.pair.wgs84.longitude))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, SettingsMetrics.rowVerticalPadding)
                }
                .onDelete { offsets in
                    offsets.map { favorites.favorites[$0].id }.forEach { favorites.remove(id: $0) }
                }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("收藏位置"))
            } footer: {
                Text(AppLocalization.string("在地图上选点后点地名旁的星标即可收藏，左滑可以删除单条。"))
            }

            if !favorites.favorites.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        SettingsLabel(
                            systemImage: "trash",
                            title: AppLocalization.string("清空全部收藏"),
                            tint: .red
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("收藏位置"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            AppLocalization.string("清空全部收藏？"),
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("清空"), role: .destructive) {
                favorites.removeAll()
            }
            Button(AppLocalization.string("取消"), role: .cancel) {}
        }
    }
}

// MARK: - 第三方代理

/// 第三方客户端的模块与连通性。
struct ThirdPartySettingsView: View {

    @ObservedObject var thirdParty: ThirdPartyProxyManager

    @State private var showModuleURLSheet = false
    @State private var moduleURLInput = ""
    /// 复制本身没有界面变化，不给反馈用户会怀疑到底点上没有。
    @State private var didCopyModuleURL = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                HStack(spacing: SettingsMetrics.iconSpacing) {
                    SettingsIconBadge(systemImage: "shield.lefthalf.filled")

                    Text(AppLocalization.string("客户端"))
                        .font(SettingsMetrics.titleFont)

                    Spacer(minLength: 8)

                    Picker(AppLocalization.string("客户端"), selection: $thirdParty.selectedClient) {
                        ForEach(ThirdPartyProxyClient.allCases) { client in
                            Text(client.displayName).tag(client)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .padding(.vertical, SettingsMetrics.rowVerticalPadding)

                SettingsStatusRow(
                    systemImage: "link",
                    title: thirdParty.selectedClient.displayName,
                    value: thirdParty.state.displayText,
                    valueColor: thirdParty.state.isUsable ? .green : .orange
                )

                // 仓库里有 5 个 wloc.* 模块文件，把当前客户端该用哪个直接写出来，
                // 省得用户对着文件名猜。
                SettingsStatusRow(
                    systemImage: "doc.text",
                    title: AppLocalization.string("模块文件"),
                    value: thirdParty.moduleFileName,
                    monospacedValue: true
                )
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("第三方代理"))
            } footer: {
                Text(AppLocalization.string("模块由第三方客户端执行拦截，本应用只负责写入坐标。"))
            }

            Section {
                if let url = thirdParty.moduleSubscriptionURL {
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                        RuntimeLogger.info("APP", "Settings", "模块地址已复制")
                        showCopyFeedback()
                    } label: {
                        SettingsLabel(
                            systemImage: didCopyModuleURL ? "checkmark.circle.fill" : "doc.on.doc",
                            title: didCopyModuleURL
                                ? AppLocalization.string("已复制到剪贴板")
                                : AppLocalization.string("复制模块订阅地址"),
                            tint: didCopyModuleURL ? .green : .blue
                        )
                    }

                    Text(url.absoluteString)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Button {
                    moduleURLInput = ThirdPartyProxyManager.defaultModuleBaseURL
                    showModuleURLSheet = true
                } label: {
                    SettingsLabel(
                        systemImage: "link",
                        title: AppLocalization.string("自定义模块托管地址")
                    )
                }

                Button {
                    thirdParty.selectedClient.open()
                } label: {
                    SettingsLabel(
                        systemImage: "arrow.up.forward.app",
                        title: AppLocalization.string("打开 %@", thirdParty.selectedClient.displayName)
                    )
                }
                .disabled(!thirdParty.selectedClient.isInstalled)

                Button {
                    Task { await thirdParty.refresh() }
                } label: {
                    SettingsLabel(
                        systemImage: "arrow.clockwise",
                        title: AppLocalization.string("重新检测连通性")
                    )
                }
            } footer: {
                Text(AppLocalization.string("在客户端里导入模块后，本应用写入的坐标才会生效。"))
            }

            Section {
                Button(role: .destructive) {
                    Task { await thirdParty.clear() }
                } label: {
                    SettingsLabel(
                        systemImage: "xmark.circle",
                        title: AppLocalization.string("清除客户端坐标"),
                        tint: .red
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("第三方代理"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showModuleURLSheet) { moduleURLSheet }
    }

    private var moduleURLSheet: some View {
        NavigationView {
            List {
                Section {
                    TextField(AppLocalization.string("托管地址前缀"), text: $moduleURLInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text(AppLocalization.string("填写模块文件所在目录的地址前缀，不带文件名。"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(AppLocalization.string("模块托管地址"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("取消")) { showModuleURLSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("保存")) {
                        AppGroup.defaults.set(moduleURLInput, forKey: "thirdPartyModuleBaseURL")
                        showModuleURLSheet = false
                    }
                }
            }
        }
    }

    private func showCopyFeedback() {
        copyFeedbackTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { didCopyModuleURL = true }
        copyFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.15)) { didCopyModuleURL = false }
            }
        }
    }
}

// MARK: - 证书与环境

/// 证书信任、Wi-Fi 代理与跳转。
struct CertificateEnvironmentView: View {

    @ObservedObject var state: MapLocationState

    @ObservedObject private var proxy = ProxyManager.shared

    /// 跳不过去时的提示。iOS 不允许直接落到「配置代理」那一屏，
    /// 只能把路径写出来让用户自己点两下。
    @State private var jumpHint: String?

    var body: some View {
        List {
            Section {
                SettingsStatusRow(
                    systemImage: "checkmark.shield.fill",
                    title: AppLocalization.string("证书信任"),
                    value: proxy.certificateTrustState.displayText,
                    valueColor: proxy.certificateTrustState.isTrusted ? .green : .orange
                )
                SettingsStatusRow(
                    systemImage: "wifi.router",
                    title: AppLocalization.string("代理状态"),
                    value: proxy.status.displayText
                )
                SettingsStatusRow(
                    systemImage: "link",
                    title: AppLocalization.string("Wi-Fi 代理"),
                    value: proxy.wiFiProxyState.displayText,
                    valueColor: proxy.wiFiProxyState == .configured ? .green : .orange
                )
                if !proxy.currentWiFiName.isEmpty {
                    SettingsStatusRow(
                        systemImage: "wifi",
                        title: AppLocalization.string("当前网络"),
                        value: proxy.currentWiFiName
                    )
                }

                Button {
                    Task {
                        await proxy.verifyCertificateTrust()
                        await proxy.verifyWiFiProxy()
                    }
                } label: {
                    SettingsLabel(
                        systemImage: "arrow.clockwise",
                        title: AppLocalization.string("重新检测环境")
                    )
                }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("证书与环境"))
            }

            Section {
                if let url = proxy.certificateDownloadURL {
                    Button {
                        CertificateTrustVerifier.openCertificateDownload(url: url)
                    } label: {
                        SettingsLabel(
                            systemImage: "arrow.down.circle",
                            title: AppLocalization.string("下载 CA 证书")
                        )
                    }
                }

                Button {
                    SystemSettingsNavigator.openCertificateTrustSettings()
                } label: {
                    SettingsLabel(
                        systemImage: "lock.shield",
                        title: AppLocalization.string("打开证书信任设置")
                    )
                }

                Button {
                    let reached = SystemSettingsNavigator.openWiFiSettings()
                    jumpHint = reached
                        ? AppLocalization.string("已打开「无线局域网」。点当前网络右侧的 ⓘ，进去把「配置代理」设为「手动」，服务器填 127.0.0.1、端口 8888。")
                        : AppLocalization.string("没能直接跳到 Wi-Fi 设置。请手动打开：设置 → 无线局域网 → 当前网络右侧 ⓘ → 配置代理 → 手动，服务器 127.0.0.1、端口 8888。")
                } label: {
                    SettingsLabel(
                        systemImage: "wifi",
                        title: AppLocalization.string("打开 Wi-Fi 代理设置")
                    )
                }

                if let jumpHint {
                    Text(jumpHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("手动代理"))
            } footer: {
                Text(AppLocalization.string("iOS 不提供直接跳到「配置代理」那一屏的接口，只能先到无线局域网列表再点两下。"))
            }

            Section {
                Button(role: .destructive) {
                    CertificateAuthorityStore.delete()
                    proxy.stop()
                    BackgroundKeepAlive.shared.stop()
                    state.disable()
                    RuntimeLogger.info("APP", "Settings", "已重置本机证书")
                } label: {
                    SettingsLabel(
                        systemImage: "trash",
                        title: AppLocalization.string("重置本机证书"),
                        tint: .red
                    )
                }
            } footer: {
                Text(AppLocalization.string("重置证书后需要重新下载并在系统设置中再次信任。"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("证书与环境"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 升级套餐

/// 套餐与推荐。授权卡片 + 推荐奖励都在这里。
struct MembershipView: View {

    @ObservedObject var manager: LicenseManager

    var body: some View {
        List {
            Section {
                LicenseCardView(manager: manager)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            Section {
                NavigationLink {
                    ReferralView(manager: manager)
                } label: {
                    HStack(spacing: SettingsMetrics.iconSpacing) {
                        SettingsIconBadge(systemImage: "gift.fill", tint: .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalization.string("推荐好友"))
                                .font(SettingsMetrics.titleFont)
                            Text(AppLocalization.string("好友连续使用 3 天，你就能获得天数奖励。"))
                                .font(SettingsMetrics.subtitleFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, SettingsMetrics.rowVerticalPadding)
                }
            }

            Section {
                NavigationLink {
                    ContactView()
                } label: {
                    SettingsLabel(
                        systemImage: "cart",
                        title: AppLocalization.string("购买与续费")
                    )
                }
            } footer: {
                Text(AppLocalization.string("卡密按设备绑定，一台设备一张卡，换手机可在本页自助解绑 1 次。"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("升级套餐"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 关于 Floc

/// 版本、发动机与法律声明。
struct AboutFlocView: View {

    @ObservedObject var setup: SetupCoordinator

    @ObservedObject private var remoteConfiguration = AppRemoteConfigurationStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var showResetConfirmation = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 68, height: 68)
                        .overlay(
                            Image(systemName: "location.north.line.fill")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(.white)
                        )

                    Text("Floc")
                        .font(.title3.bold())

                    Text(AppLocalization.string("%@（构建号 %@）", Bundle.main.appVersion, Bundle.main.buildNumber))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                SettingsStatusRow(
                    systemImage: "info.circle",
                    title: AppLocalization.string("应用版本"),
                    value: Bundle.main.appVersion
                )
                SettingsStatusRow(
                    systemImage: "hammer",
                    title: AppLocalization.string("构建号"),
                    value: Bundle.main.buildNumber
                )
                SettingsStatusRow(
                    systemImage: "cpu",
                    title: AppLocalization.string("内核版本"),
                    value: CoreBridge.coreVersion
                )
                SettingsStatusRow(
                    systemImage: "square.stack.3d.up",
                    title: AppLocalization.string("数据共享"),
                    value: AppGroup.isAvailable
                        ? AppLocalization.string("已启用")
                        : AppLocalization.string("不可用")
                )

                if remoteConfiguration.systemVersionBlocked {
                    Label(
                        AppLocalization.string("当前系统版本可能不受支持"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("版本信息"))
            }

            Section {
                NavigationLink {
                    PrinciplesView()
                } label: {
                    SettingsLabel(
                        systemImage: "gearshape.2",
                        title: AppLocalization.string("工作原理")
                    )
                }
            } footer: {
                Text(AppLocalization.string("本应用用于定位服务的开发测试与研究，请仅在你拥有或获得授权的设备与网络环境中使用。"))
            }

            Section {
                Button {
                    showResetConfirmation = true
                } label: {
                    SettingsLabel(
                        systemImage: "arrow.counterclockwise",
                        title: AppLocalization.string("重置引导流程")
                    )
                }
            } footer: {
                Text(AppLocalization.string("重置后需要重新完成当前模式的配置引导。已保存的收藏和证书不受影响。"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("关于 Floc"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            AppLocalization.string("重置引导流程？"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("重置"), role: .destructive) {
                setup.reset()
                dismiss()
            }
            Button(AppLocalization.string("取消"), role: .cancel) {}
        }
    }
}

// MARK: - 工作原理

/// 工作原理说明。
struct PrinciplesView: View {

    private static var principles: [String] {
        [
            AppLocalization.string("Floc 在本机运行一个代理，拦截并改写系统定位服务返回的坐标。"),
            AppLocalization.string("改写只作用于定位响应，其他请求原样转发，不会修改内容。"),
            AppLocalization.string("停止虚拟定位后立即恢复真实位置，不会留下持久改动。"),
        ]
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.principles, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            Text(line)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("工作原理"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 用户指南

/// 用户指南：使用方法 + 生效/失效说明 + 工作原理，一处收齐。
struct UserGuideView: View {

    var body: some View {
        List {
            Section {
                NavigationLink {
                    UsageGuideView()
                } label: {
                    SettingsLabel(
                        systemImage: "book",
                        title: AppLocalization.string("使用方法"),
                        isSecondary: true
                    )
                }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("快速上手"))
            } footer: {
                Text(AppLocalization.string("配置完成后位置没变，基本都能在这一页找到原因。"))
            }

            Section {
                ForEach(Self.entries, id: \.label) { entry in
                    NavigationLink {
                        TipDetailView(kind: entry.kind)
                    } label: {
                        SettingsLabel(
                            systemImage: entry.kind.systemImage,
                            title: entry.label,
                            isSecondary: true
                        )
                    }
                }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("说明"))
            }

            Section {
                NavigationLink {
                    PrinciplesView()
                } label: {
                    SettingsLabel(
                        systemImage: "gearshape.2",
                        title: AppLocalization.string("工作原理"),
                        isSecondary: true
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("用户指南"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private static var entries: [(label: String, kind: TipCard.Kind)] {
        [
            (AppLocalization.string("生效说明"), .enableSpoofing),
            (AppLocalization.string("失效说明"), .disableSpoofing),
            (AppLocalization.string("关闭 WiFi 代理"), .disableWiFiProxy),
            (TipCard.Kind.certificateTrust.settingsLabel, .certificateTrust),
            (TipCard.Kind.thirdPartyMode.settingsLabel, .thirdPartyMode),
        ]
    }
}

// MARK: - 意见反馈

/// 意见反馈：报告、日志、联系方式。
struct FeedbackView: View {

    @ObservedObject var state: MapLocationState

    @State private var showBugReport = false
    @State private var showDiagnostics = false

    var body: some View {
        List {
            Section {
                Button {
                    showBugReport = true
                } label: {
                    SettingsLabel(
                        systemImage: "exclamationmark.bubble",
                        title: AppLocalization.string("生成问题报告"),
                        isSecondary: true
                    )
                }

                Button {
                    showDiagnostics = true
                } label: {
                    SettingsLabel(
                        systemImage: "doc.text.magnifyingglass",
                        title: AppLocalization.string("运行日志与诊断"),
                        isSecondary: true
                    )
                }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("意见反馈"))
            } footer: {
                Text(AppLocalization.string("报告会自动脱敏（去掉坐标、设备标识等），生成后可以先自己看一眼再发出去。遇到问题请附带报告，能省掉一大轮来回。"))
            }

            Section {
                NavigationLink {
                    ContactView()
                } label: {
                    SettingsLabel(
                        systemImage: "envelope",
                        title: AppLocalization.string("联系我们"),
                        isSecondary: true
                    )
                }
            } footer: {
                Text(AppLocalization.string("功能建议、使用疑问、购买咨询都可以直接联系，不必非得是 bug。"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("意见反馈"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBugReport) {
            BugReportView()
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(state: state)
        }
    }
}

// MARK: - 联系我们

/// 联系方式。
struct ContactView: View {

    @State private var copiedItem: String?

    var body: some View {
        List {
            if AppContact.hasDirectContact {
                Section {
                    if !AppContact.supportEmail.isEmpty {
                        contactRow(
                            icon: "envelope.fill",
                            title: AppLocalization.string("邮箱"),
                            value: AppContact.supportEmail
                        )
                    }
                    if !AppContact.wechat.isEmpty {
                        contactRow(
                            icon: "message.fill",
                            title: AppLocalization.string("微信"),
                            value: AppContact.wechat
                        )
                    }
                } header: {
                    SettingsSectionHeader(title: AppLocalization.string("直接联系"))
                } footer: {
                    Text(AppLocalization.string("点一下即可复制。购买卡密、续费、换设备解绑都可以直接找这里。"))
                }
            }

            Section {
                Button {
                    copy(AppContact.issuesURL, label: AppLocalization.string("反馈地址"))
                } label: {
                    SettingsLabel(
                        systemImage: "ladybug",
                        title: AppLocalization.string("复制问题反馈地址"),
                        isSecondary: true
                    )
                }

                if let url = URL(string: AppContact.homepageURL) {
                    Link(destination: url) {
                        SettingsLabel(
                            systemImage: "link",
                            title: AppLocalization.string("打开项目主页"),
                            isSecondary: true
                        )
                    }
                }
            } header: {
                SettingsSectionHeader(title: AppLocalization.string("反馈与主页"))
            }

            if !AppContact.hasDirectContact {
                Section {
                    Text(AppLocalization.string("作者还没有填写联系方式。发布前请在 Shared/AppContact.swift 里补上邮箱或微信，否则用户想购买时找不到入口。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.string("联系我们"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func contactRow(icon: String, title: String, value: String) -> some View {
        Button {
            copy(value, label: title)
        } label: {
            HStack(spacing: SettingsMetrics.iconSpacing) {
                SettingsIconBadge(systemImage: icon)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsMetrics.titleFont)
                        .foregroundStyle(.primary)
                    Text(value)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: copiedItem == title ? "checkmark" : "doc.on.doc")
                    .font(.subheadline)
                    .foregroundStyle(copiedItem == title ? Color.green : Color.secondary)
            }
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copy(_ value: String, label: String) {
        UIPasteboard.general.string = value
        withAnimation(.easeInOut(duration: 0.15)) { copiedItem = label }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if copiedItem == label { copiedItem = nil }
                }
            }
        }
    }
}
