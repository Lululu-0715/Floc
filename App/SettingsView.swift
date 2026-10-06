import SwiftUI

/// 设置页。
///
/// 版式参照参考图：`List` + `.insetGrouped` 给出独立的白色卡片，
/// 每行以 36×36 的蓝色圆形图标起头，右侧按内容性质给出四种控件——
/// 勾选（模式）/ 开关（可切换项）/ 只读状态文字（无箭头）/ 跳转箭头。
///
/// 背景不额外铺色：`.insetGrouped` 的底色本来就是 `systemGroupedBackground`，
/// 自己再叠一层反而会和系统色在深色模式下打架。
struct SettingsView: View {

    @ObservedObject var setup: SetupCoordinator
    @ObservedObject var state: MapLocationState
    @ObservedObject var favorites: FavoriteLocationStore

    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var thirdParty = ThirdPartyProxyManager.shared
    @ObservedObject private var runtimeMode = RuntimeModeStore.shared
    @ObservedObject private var remoteConfiguration = AppRemoteConfigurationStore.shared
    @ObservedObject private var appearance = AppearanceStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var showResetConfirmation = false
    @State private var showClearFavoritesConfirmation = false
    @State private var showModuleURLSheet = false
    @State private var moduleURLInput = ""
    @State private var selfCheckResult: String?
    /// 启停代理过程中的错误，展示在「状态」分组里而不是弹窗——
    /// 用户正在这页操作，内联提示比模态弹窗少一次点击。
    @State private var statusMessage: String?
    /// 「复制模块订阅地址」的即时回馈。复制本身没有界面变化，不给反馈
    /// 用户会怀疑到底点上没有。
    @State private var didCopyModuleURL = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
            List {
                modeSection
                statusSection

                // 「第三方代理」紧跟「状态」：用户在这一步最想确认的就是
                // 客户端到底连上没有，排在下面的说明文字之后要翻很久。
                if runtimeMode.mode == .thirdParty {
                    thirdPartySection
                }

                simulationSection

                if runtimeMode.mode == .localProxy {
                    environmentSection
                }

                favoritesSection
                appearanceSection
                languageSection

                // 「说明」「工作原理」紧挨着「支持」：这三块都是
                // 「出问题了再回来查」的内容，放在一起不用来回翻。
                notesSection
                principlesSection
                supportSection
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
            } message: {
                Text(AppLocalization.string("重置后需要重新完成当前模式的配置引导。已保存的收藏和证书不受影响。"))
            }
            .confirmationDialog(
                AppLocalization.string("清空全部收藏？"),
                isPresented: $showClearFavoritesConfirmation,
                titleVisibility: .visible
            ) {
                Button(AppLocalization.string("清空"), role: .destructive) {
                    favorites.removeAll()
                }
                Button(AppLocalization.string("取消"), role: .cancel) {}
            }
            .sheet(isPresented: $showModuleURLSheet) {
                moduleURLSheet
            }
            .task {
                await remoteConfiguration.refresh()
            }
        }
    }

    // MARK: - 运行模式

    private var modeSection: some View {
        Section {
            ForEach(ProxyRuntimeMode.allCases) { mode in
                modeOptionRow(mode)
            }
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("运行模式"))
        } footer: {
            Text(runtimeMode.mode.summary)
        }
    }

    /// 模式选项行：普通文字 + 选中项右侧的蓝色勾选。
    private func modeOptionRow(_ mode: ProxyRuntimeMode) -> some View {
        let isSelected = runtimeMode.mode == mode
        return Button {
            switchMode(to: mode)
        } label: {
            HStack {
                Text(mode.displayName)
                    .font(SettingsMetrics.titleFont)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.blue)
                }
            }
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    // MARK: - 状态

    private var statusSection: some View {
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
                    value: thirdParty.state.displayText
                )
            }

            SettingsStatusRow(
                systemImage: "location.north.line",
                title: AppLocalization.string("虚拟定位"),
                value: state.isEnabled
                    ? AppLocalization.string("已开启")
                    : AppLocalization.string("已关闭")
            )

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
            }
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("状态"))
        }
    }

    // MARK: - 定位模拟

    private var simulationSection: some View {
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
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("定位模拟"))
        } footer: {
            Text(runtimeMode.mode == .thirdParty
                 ? AppLocalization.string("精度与运动状态模拟都会写入客户端配置。")
                 : AppLocalization.string("精度直接影响系统对定位可信度的判断，通常 25 米较为自然。"))
        }
    }

    /// 「运动状态模拟」的选择：界面上下拉给的是档位原始值（0 / 5 / 10 / 20），
    /// 写回前收敛一次，避免脏值传进 Core。
    private var motionDriftBinding: Binding<Int> {
        Binding(
            get: { state.motionDriftRadius },
            set: { state.motionDriftRadius = MotionDriftOption.normalized($0).rawValue }
        )
    }

    // MARK: - 说明

    private var notesSection: some View {
        Section {
            tipLink(kind: .enableSpoofing, systemImage: "checkmark.circle")
            tipLink(kind: .disableSpoofing, systemImage: "arrow.uturn.backward.circle")
            tipLink(kind: .disableWiFiProxy, systemImage: "wifi.slash")
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("说明"))
        }
    }

    private func tipLink(kind: TipCard.Kind, systemImage: String) -> some View {
        NavigationLink {
            TipDetailView(kind: kind)
        } label: {
            SettingsLabel(
                systemImage: systemImage,
                title: kind.settingsLabel,
                isSecondary: true
            )
        }
    }

    // MARK: - 工作原理

    private var principlesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
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
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("工作原理"))
        }
    }

    private static var principles: [String] {
        [
            AppLocalization.string("Floc 在本机运行一个代理，拦截并改写系统定位服务返回的坐标。"),
            AppLocalization.string("改写只作用于定位响应，其他请求原样转发，不会修改内容。"),
            AppLocalization.string("停止虚拟定位后立即恢复真实位置，不会留下持久改动。"),
        ]
    }

    // MARK: - 证书与环境（应用内代理）

    private var environmentSection: some View {
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
                SystemSettingsNavigator.openWiFiSettings()
            } label: {
                SettingsLabel(
                    systemImage: "wifi",
                    title: AppLocalization.string("打开 Wi-Fi 设置")
                )
            }

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
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("证书与环境"))
        } footer: {
            Text(AppLocalization.string("重置证书后需要重新下载并在系统设置中再次信任。"))
        }
    }

    // MARK: - 第三方代理

    private var thirdPartySection: some View {
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

            // 仓库里有 5 个 wloc.* 模块文件，把当前客户端该用哪个直接写出来，
            // 省得用户对着文件名猜。
            SettingsStatusRow(
                systemImage: "doc.text",
                title: AppLocalization.string("模块文件"),
                value: thirdParty.moduleFileName,
                monospacedValue: true
            )

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

            Button(role: .destructive) {
                Task { await thirdParty.clear() }
            } label: {
                SettingsLabel(
                    systemImage: "xmark.circle",
                    title: AppLocalization.string("清除客户端坐标"),
                    tint: .red
                )
            }
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("第三方代理"))
        } footer: {
            Text(AppLocalization.string("模块由第三方客户端执行拦截，本应用只负责写入坐标。"))
        }
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

    // MARK: - 收藏

    private var favoritesSection: some View {
        Section {
            SettingsStatusRow(
                systemImage: "star.fill",
                title: AppLocalization.string("已收藏"),
                value: "\(favorites.favorites.count)"
            )
            if !favorites.favorites.isEmpty {
                Button(role: .destructive) {
                    showClearFavoritesConfirmation = true
                } label: {
                    SettingsLabel(
                        systemImage: "trash",
                        title: AppLocalization.string("清空全部收藏"),
                        tint: .red
                    )
                }
            }
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("收藏位置"))
        }
    }

    // MARK: - 外观

    /// 外观：白天 / 黑暗 / 跟随系统。
    ///
    /// 分段控件横排占满一行，而不是挤进「行首图标 + 标题 + 控件」的单行里——
    /// 一个图标加三个中文标签，横向空间不够会被压成「跟…统」。
    /// 实际生效靠根节点上的 `.preferredColorScheme`（见 FlocApp）。
    private var appearanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: SettingsMetrics.iconSpacing) {
                    SettingsIconBadge(systemImage: appearance.mode.systemImage)

                    Text(AppLocalization.string("显示模式"))
                        .font(SettingsMetrics.titleFont)

                    Spacer(minLength: 0)
                }

                Picker(AppLocalization.string("显示模式"), selection: $appearance.mode) {
                    ForEach(AppearanceStore.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("外观"))
        }
    }

    // MARK: - 语言

    private var languageSection: some View {
        Section {
            HStack(spacing: SettingsMetrics.iconSpacing) {
                SettingsIconBadge(systemImage: "globe")

                Text(AppLocalization.string("界面语言"))
                    .font(SettingsMetrics.titleFont)

                Spacer(minLength: 8)

                Picker(AppLocalization.string("界面语言"), selection: Binding(
                    get: { AppLocalization.overrideLanguage ?? "system" },
                    set: { newValue in
                        AppLocalization.overrideLanguage = newValue == "system" ? nil : newValue
                        NotificationCenter.default.post(name: AppLocalization.didChangeNotification, object: nil)
                    }
                )) {
                    Text(AppLocalization.string("跟随系统")).tag("system")
                    ForEach(AppLocalization.supportedLanguages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .padding(.vertical, SettingsMetrics.rowVerticalPadding)
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("语言"))
        } footer: {
            Text(AppLocalization.string("切换语言后部分界面需要重新进入才会完全生效。"))
        }
    }

    // MARK: - 支持

    private var supportSection: some View {
        Section {
            NavigationLink {
                UsageGuideView()
            } label: {
                SettingsLabel(
                    systemImage: "book",
                    title: AppLocalization.string("使用方法")
                )
            }

            NavigationLink {
                DiagnosticsView(state: state)
            } label: {
                SettingsLabel(
                    systemImage: "doc.text.magnifyingglass",
                    title: AppLocalization.string("运行日志与诊断")
                )
            }

            NavigationLink {
                BugReportView()
            } label: {
                SettingsLabel(
                    systemImage: "exclamationmark.bubble",
                    title: AppLocalization.string("生成问题报告")
                )
            }

            Button {
                showResetConfirmation = true
            } label: {
                SettingsLabel(
                    systemImage: "arrow.counterclockwise",
                    title: AppLocalization.string("重置引导流程")
                )
            }
        } header: {
            SettingsSectionHeader(title: AppLocalization.string("支持"))
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
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
            SettingsSectionHeader(title: AppLocalization.string("关于"))
        } footer: {
            Text(AppLocalization.string(
                "本应用用于定位服务的开发测试与研究，请仅在你拥有或获得授权的设备与网络环境中使用。"
            ))
        }
    }

    // MARK: - 操作

    /// 展示一次「已复制」回馈，2 秒后自动恢复。
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
