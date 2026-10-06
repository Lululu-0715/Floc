import SwiftUI

/// 设置页。
struct SettingsView: View {

    @ObservedObject var setup: SetupCoordinator
    @ObservedObject var state: MapLocationState
    @ObservedObject var favorites: FavoriteLocationStore

    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var thirdParty = ThirdPartyProxyManager.shared
    @ObservedObject private var runtimeMode = RuntimeModeStore.shared
    @ObservedObject private var remoteConfiguration = AppRemoteConfigurationStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var showResetConfirmation = false
    @State private var showClearFavoritesConfirmation = false
    @State private var showModuleURLSheet = false
    @State private var moduleURLInput = ""
    @State private var selfCheckResult: String?

    var body: some View {
        NavigationView {
            Form {
                modeSection
                if runtimeMode.mode == .localProxy {
                    localProxySection
                } else {
                    thirdPartySection
                }
                spoofSection
                favoritesSection
                languageSection
                supportSection
                aboutSection
            }
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
            Picker(AppLocalization.string("运行模式"), selection: Binding(
                get: { runtimeMode.mode },
                set: { newMode in
                    guard newMode != runtimeMode.mode else { return }
                    // 切换模式前先停掉当前链路，避免两套代理同时生效。
                    if proxy.status.isRunning { proxy.stop() }
                    runtimeMode.select(newMode)
                    setup.reset()
                    dismiss()
                }
            )) {
                ForEach(ProxyRuntimeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Text(runtimeMode.mode.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(AppLocalization.string("运行模式"))
        } footer: {
            Text(AppLocalization.string("切换后会重新进入配置引导，两种模式的配置互不影响。"))
        }
    }

    // MARK: - 应用内代理

    private var localProxySection: some View {
        Section {
            KeyValueRow(AppLocalization.string("代理状态"), value: proxy.status.displayText)
            KeyValueRow(AppLocalization.string("证书信任"), value: proxy.certificateTrustState.displayText)
            KeyValueRow(AppLocalization.string("Wi-Fi 代理"), value: proxy.wiFiProxyState.displayText)
            if !proxy.currentWiFiName.isEmpty {
                KeyValueRow(AppLocalization.string("当前网络"), value: proxy.currentWiFiName)
            }

            Button {
                Task {
                    await proxy.verifyCertificateTrust()
                    await proxy.verifyWiFiProxy()
                }
            } label: {
                Label(AppLocalization.string("重新检测环境"), systemImage: "arrow.clockwise")
            }

            if let url = proxy.certificateDownloadURL {
                Button {
                    CertificateTrustVerifier.openCertificateDownload(url: url)
                } label: {
                    Label(AppLocalization.string("下载 CA 证书"), systemImage: "arrow.down.circle")
                }
            }

            Button {
                SystemSettingsNavigator.openCertificateTrustSettings()
            } label: {
                Label(AppLocalization.string("打开证书信任设置"), systemImage: "lock.shield")
            }

            Button {
                SystemSettingsNavigator.openWiFiSettings()
            } label: {
                Label(AppLocalization.string("打开 Wi-Fi 设置"), systemImage: "wifi")
            }

            Button(role: .destructive) {
                CertificateAuthorityStore.delete()
                proxy.stop()
                RuntimeLogger.info("APP", "Settings", "已重置本机证书")
            } label: {
                Label(AppLocalization.string("重置本机证书"), systemImage: "trash")
            }
        } header: {
            Text(AppLocalization.string("应用内代理"))
        } footer: {
            Text(AppLocalization.string("重置证书后需要重新下载并在系统设置中再次信任。"))
        }
    }

    // MARK: - 第三方代理

    private var thirdPartySection: some View {
        Section {
            Picker(AppLocalization.string("客户端"), selection: $thirdParty.selectedClient) {
                ForEach(ThirdPartyProxyClient.allCases) { client in
                    Text(client.displayName).tag(client)
                }
            }

            KeyValueRow(AppLocalization.string("连接状态"), value: thirdParty.state.displayText)

            if let url = thirdParty.moduleSubscriptionURL {
                Button {
                    UIPasteboard.general.string = url.absoluteString
                    RuntimeLogger.info("APP", "Settings", "模块地址已复制")
                } label: {
                    Label(AppLocalization.string("复制模块订阅地址"), systemImage: "doc.on.doc")
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
                Label(AppLocalization.string("自定义模块托管地址"), systemImage: "link")
            }

            Button {
                thirdParty.selectedClient.open()
            } label: {
                Label(AppLocalization.string("打开 %@", thirdParty.selectedClient.displayName),
                      systemImage: "arrow.up.forward.app")
            }
            .disabled(!thirdParty.selectedClient.isInstalled)

            Button {
                Task { await thirdParty.refresh() }
            } label: {
                Label(AppLocalization.string("重新检测连通性"), systemImage: "arrow.clockwise")
            }

            Button(role: .destructive) {
                Task { await thirdParty.clear() }
            } label: {
                Label(AppLocalization.string("清除客户端坐标"), systemImage: "xmark.circle")
            }
        } header: {
            Text(AppLocalization.string("第三方代理"))
        } footer: {
            Text(AppLocalization.string("模块由第三方客户端执行拦截，本应用只负责写入坐标。"))
        }
    }

    private var moduleURLSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField(AppLocalization.string("托管地址前缀"), text: $moduleURLInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text(AppLocalization.string("填写模块文件所在目录的地址前缀，不带文件名。"))
                }
            }
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

    // MARK: - 虚拟定位参数

    private var spoofSection: some View {
        Section {
            Picker(AppLocalization.string("模拟精度"), selection: $state.accuracy) {
                Text("10 m").tag(10)
                Text("25 m").tag(25)
                Text("50 m").tag(50)
                Text("100 m").tag(100)
                Text("500 m").tag(500)
            }

            Toggle(
                AppLocalization.string("模拟静止状态"),
                isOn: $state.motionSimulationEnabled
            )
            .disabled(runtimeMode.mode == .thirdParty)

            Button {
                selfCheckResult = proxy.runSelfCheck(
                    latitude: state.selection?.wgs84.latitude ?? 22.281508,
                    longitude: state.selection?.wgs84.longitude ?? 114.174700,
                    accuracy: state.accuracy
                )
            } label: {
                Label(AppLocalization.string("运行改写引擎自检"), systemImage: "checkmark.seal")
            }

            if let selfCheckResult {
                Text(selfCheckResult)
                    .font(.caption.monospaced())
                    .foregroundStyle(selfCheckResult.hasPrefix("ok:") ? Color.green : Color.red)
            }
        } header: {
            Text(AppLocalization.string("虚拟定位参数"))
        } footer: {
            Text(runtimeMode.mode == .thirdParty
                 ? AppLocalization.string("精度会写入客户端配置；运动状态模拟仅在应用内代理模式下可用。")
                 : AppLocalization.string("精度直接影响系统对定位可信度的判断，通常 25 米较为自然。"))
        }
    }

    // MARK: - 收藏

    private var favoritesSection: some View {
        Section {
            KeyValueRow(AppLocalization.string("已收藏"), value: "\(favorites.favorites.count)")
            if !favorites.favorites.isEmpty {
                Button(role: .destructive) {
                    showClearFavoritesConfirmation = true
                } label: {
                    Label(AppLocalization.string("清空全部收藏"), systemImage: "trash")
                }
            }
        } header: {
            Text(AppLocalization.string("收藏位置"))
        }
    }

    // MARK: - 语言

    private var languageSection: some View {
        Section {
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
        } header: {
            Text(AppLocalization.string("语言"))
        } footer: {
            Text(AppLocalization.string("切换语言后部分界面需要重新进入才会完全生效。"))
        }
    }

    // MARK: - 支持

    private var supportSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView(state: state)
            } label: {
                Label(AppLocalization.string("运行日志与诊断"), systemImage: "doc.text.magnifyingglass")
            }

            NavigationLink {
                BugReportView()
            } label: {
                Label(AppLocalization.string("生成问题报告"), systemImage: "exclamationmark.bubble")
            }

            Button {
                showResetConfirmation = true
            } label: {
                Label(AppLocalization.string("重置引导流程"), systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text(AppLocalization.string("支持"))
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            KeyValueRow(AppLocalization.string("应用版本"), value: Bundle.main.appVersion)
            KeyValueRow(AppLocalization.string("构建号"), value: Bundle.main.buildNumber)
            KeyValueRow(AppLocalization.string("内核版本"), value: CoreBridge.coreVersion)
            KeyValueRow(
                AppLocalization.string("数据共享"),
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
            Text(AppLocalization.string("关于"))
        } footer: {
            Text(AppLocalization.string(
                "本应用用于定位服务的开发测试与研究，请仅在你拥有或获得授权的设备与网络环境中使用。"
            ))
        }
    }
}
