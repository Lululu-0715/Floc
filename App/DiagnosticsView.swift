import SwiftUI

/// 诊断页：运行日志与环境检查。
struct DiagnosticsView: View {

    @ObservedObject var state: MapLocationState

    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var thirdParty = ThirdPartyProxyManager.shared
    @ObservedObject private var runtimeMode = RuntimeModeStore.shared
    /// 虚拟定位的生效校验结论。「当前配置」里那一行显示它，与设置页
    /// 「连接状态」、地图页底部卡片读的是**同一个单例**，三处永远不会打架。
    @ObservedObject private var verifier = SpoofEffectVerifier.shared

    @Environment(\.dismiss) private var dismiss

    @State private var entries: [RuntimeLogger.Entry] = []
    @State private var levelFilter: RuntimeLogger.Level? = nil
    @State private var searchText = ""
    @State private var autoRefresh = true
    @State private var refreshTask: Task<Void, Never>?
    @State private var copied = false
    @State private var showClearConfirmation = false
    @State private var environmentChecks: [VerificationResult] = []
    @State private var isChecking = false

    var body: some View {
        NavigationView {
            List {
                environmentSection
                if !environmentChecks.isEmpty {
                    resultsSection
                }
                configurationSection
                logsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(AppLocalization.string("诊断"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: AppLocalization.string("筛选日志"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("关闭")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker(AppLocalization.string("日志级别"), selection: $levelFilter) {
                            Text(AppLocalization.string("全部")).tag(RuntimeLogger.Level?.none)
                            Text("INFO").tag(RuntimeLogger.Level?.some(.info))
                            Text("WARN").tag(RuntimeLogger.Level?.some(.warn))
                            Text("ERROR").tag(RuntimeLogger.Level?.some(.error))
                        }
                        Toggle(AppLocalization.string("自动刷新"), isOn: $autoRefresh)
                        Divider()
                        Button {
                            UIPasteboard.general.string = RuntimeLogger.exportText()
                            copied = true
                        } label: {
                            Label(AppLocalization.string("复制全部日志"), systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            Label(AppLocalization.string("清空日志"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                reload()
                startAutoRefresh()
            }
            .onDisappear {
                refreshTask?.cancel()
            }
            .onChange(of: autoRefresh) { _ in
                startAutoRefresh()
            }
            .confirmationDialog(
                AppLocalization.string("清空全部日志？"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(AppLocalization.string("清空"), role: .destructive) {
                    RuntimeLogger.clear()
                    reload()
                }
                Button(AppLocalization.string("取消"), role: .cancel) {}
            }
        }
    }

    // MARK: - 环境检查

    private var environmentSection: some View {
        Section {
            Button {
                Task { await runChecks() }
            } label: {
                HStack {
                    Label(AppLocalization.string("重新检查环境"), systemImage: "stethoscope")
                    Spacer()
                    if isChecking {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isChecking)
        } header: {
            Text(AppLocalization.string("环境检查"))
        }
    }

    private var resultsSection: some View {
        Section {
            ForEach(Array(environmentChecks.enumerated()), id: \.offset) { _, result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: result.outcome.symbol)
                            .foregroundStyle(color(for: result.outcome))
                        Text(result.title)
                            .font(.subheadline)
                        Spacer()
                    }
                    if !result.detail.isEmpty {
                        Text(result.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(AppLocalization.string("检查结果"))
        }
    }

    // MARK: - 当前配置

    private var configurationSection: some View {
        Section {
            KeyValueRow(AppLocalization.string("运行模式"), value: runtimeMode.mode.displayName)
            // 「代理状态」报的是**本机内置代理服务**（Go 核，监听 127.0.0.1:8888）
            // 的启停状态。切到第三方代理后这条路不走，本机代理压根不启动，
            // 于是恒为「未启动」—— 不是故障，但光看这一行会误判，所以挂个问号
            // 就地解释。这一行的取值**故意不跟运行模式分流**：内置模式下它必须
            // 如实反映本机代理，第三方模式下则由问号说明它此刻没有意义。
            KeyValueRow(
                AppLocalization.string("代理状态"),
                value: proxy.status.displayText,
                help: AppLocalization.string(
                    "这一行说的是本机内置代理服务（监听 127.0.0.1:8888）。它只在「内置应用代理」模式下工作；切到「第三方代理」时不走这条路，本机代理不会启动，显示「未启动」是正常的。"
                )
            )
            // 「虚拟定位」显示**生效结论**而不是开关快照。写「已开启」等于把
            // 「开关亮着但其实没生效」这个最该被看见的状态盖住 —— 与设置页
            // 「连接状态」同一套口径（`SettingsView.virtualLocationSummary`）。
            KeyValueRow(
                AppLocalization.string("虚拟定位"),
                value: state.isEnabled
                    ? verifier.status.pillText
                    : AppLocalization.string("已关闭"),
                valueColor: state.isEnabled ? verifier.status.pillColor : .secondary
            )
            if let pair = state.selection {
                KeyValueRow(
                    AppLocalization.string("当前坐标 (WGS-84)"),
                    value: String(format: "%.6f, %.6f", pair.wgs84.latitude, pair.wgs84.longitude)
                )
                KeyValueRow(
                    AppLocalization.string("当前坐标 (GCJ-02)"),
                    value: String(format: "%.6f, %.6f", pair.gcj02.latitude, pair.gcj02.longitude)
                )
            }
            KeyValueRow(AppLocalization.string("模拟精度"), value: "\(state.accuracy) m")
            KeyValueRow(
                AppLocalization.string("运动状态模拟"),
                value: MotionDriftOption.normalized(state.motionDriftRadius).displayName
            )
            KeyValueRow(
                AppLocalization.string("地图坐标体系"),
                value: state.mapCoordinateSystem.diagnosticName
            )
            KeyValueRow(
                AppLocalization.string("日志条数"),
                value: "\(entries.count)"
            )
        } header: {
            Text(AppLocalization.string("当前配置"))
        }
    }

    // MARK: - 日志

    private var logsSection: some View {
        Section {
            if filteredEntries.isEmpty {
                Text(AppLocalization.string("暂无匹配的日志"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredEntries) { entry in
                    LogRow(entry: entry)
                }
            }
        } header: {
            HStack {
                Text(AppLocalization.string("运行日志"))
                Spacer()
                if copied {
                    Text(AppLocalization.string("已复制"))
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        } footer: {
            Text(AppLocalization.string("日志仅保存在本机，自动保留最近 3 天，复制时会自动脱敏。"))
        }
    }

    private var filteredEntries: [RuntimeLogger.Entry] {
        entries.filter { entry in
            if let levelFilter, entry.level != levelFilter { return false }
            guard !searchText.isEmpty else { return true }
            return entry.message.localizedCaseInsensitiveContains(searchText)
                || entry.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - 行为

    private func reload() {
        entries = RuntimeLogger.snapshot().reversed()
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        guard autoRefresh else { return }
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                // 顺便把 Core 侧积压日志搬过来。
                proxy.flushCoreLogs()
                await MainActor.run { reload() }
            }
        }
    }

    private func runChecks() async {
        isChecking = true
        defer { isChecking = false }

        var results: [VerificationResult] = []

        let selfCheck = proxy.runSelfCheck(
            latitude: state.selection?.wgs84.latitude ?? 22.281508,
            longitude: state.selection?.wgs84.longitude ?? 114.174700,
            accuracy: state.accuracy
        )
        results.append(VerificationResult(
            kind: .rewriteEngine,
            outcome: selfCheck.hasPrefix("ok:") ? .passed : .failed(selfCheck),
            detail: selfCheck
        ))

        switch runtimeMode.mode {
        case .localProxy:
            await proxy.verifyCertificateTrust()
            results.append(VerificationResult(
                kind: .certificateTrust,
                outcome: proxy.certificateTrustState.isTrusted
                    ? .passed
                    : .failed(proxy.certificateTrustState.displayText),
                detail: proxy.certificateDownloadURL?.absoluteString ?? ""
            ))

            await proxy.verifyWiFiProxy()
            results.append(VerificationResult(
                kind: .wifiProxy,
                outcome: proxy.wiFiProxyState == .configured
                    ? .passed
                    : .failed(proxy.wiFiProxyState.displayText),
                detail: "\(ProxyManager.proxyHost):\(ProxyManager.proxyPort)"
            ))

        case .thirdParty:
            await thirdParty.refresh()
            results.append(VerificationResult(
                kind: .thirdPartyModule,
                outcome: thirdParty.state.isUsable ? .passed : .failed(thirdParty.state.displayText),
                detail: thirdParty.selectedClient.displayName
            ))
        }

        environmentChecks = results
        reload()
    }

    private func color(for outcome: VerificationResult.Outcome) -> Color {
        switch outcome {
        case .passed: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }
}

/// 单条日志行。
private struct LogRow: View {

    let entry: RuntimeLogger.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.level.rawValue)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: GlassMetrics.inlineCornerRadius))
                    .foregroundStyle(color)

                Text("\(entry.source)/\(entry.category)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(entry.formattedTime)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Text(entry.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            if !entry.details.isEmpty {
                Text(entry.details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private var color: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }
}
