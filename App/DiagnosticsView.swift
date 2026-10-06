import SwiftUI

/// 诊断页：运行日志与环境检查。
struct DiagnosticsView: View {

    @ObservedObject var state: MapLocationState

    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var thirdParty = ThirdPartyProxyManager.shared
    @ObservedObject private var runtimeMode = RuntimeModeStore.shared

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
            KeyValueRow(AppLocalization.string("代理状态"), value: proxy.status.displayText)
            KeyValueRow(
                AppLocalization.string("虚拟定位"),
                value: state.isEnabled
                    ? AppLocalization.string("已开启")
                    : AppLocalization.string("已关闭")
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
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
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
