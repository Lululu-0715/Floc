import SwiftUI

/// 引导流程的容器视图。
///
/// 四个步骤依次是：选模式 → 授权限 → 配代理 → 做检测。
/// 顶部有步骤指示器，用户可以点击回看已完成的步骤。
struct SetupFlowView: View {

    @ObservedObject var setup: SetupCoordinator
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var thirdParty = ThirdPartyProxyManager.shared

    @State private var locationPermissionRequested = false
    @State private var isVerifying = false
    @State private var report = VerificationReport()

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    switch setup.currentStep {
                    case .modeSelection:
                        ModeSelectionStep(setup: setup)

                    case .permissionRequest:
                        PermissionStep(
                            setup: setup,
                            requested: $locationPermissionRequested
                        )

                    case .proxySetup:
                        ProxySetupStep(setup: setup)

                    case .verification:
                        VerificationStep(
                            setup: setup,
                            report: $report,
                            isVerifying: $isVerifying,
                            onRun: runVerification
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }

            bottomBar
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 步骤指示器

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(SetupCoordinator.Step.allCases, id: \.rawValue) { step in
                let isActive = step == setup.currentStep
                let isDone = step < setup.currentStep

                Button {
                    setup.jump(to: step)
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(isDone ? Color.accentColor : (isActive ? Color.accentColor : Color(.tertiarySystemFill)))
                                .frame(width: 28, height: 28)
                            if isDone {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(step.rawValue + 1)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(isActive ? .white : .secondary)
                            }
                        }
                        Text(step.title)
                            .font(.system(size: 10))
                            .foregroundStyle(isActive ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .buttonStyle(.plain)
                .disabled(step > setup.currentStep)

                if step != SetupCoordinator.Step.allCases.last {
                    Rectangle()
                        .fill(isDone ? Color.accentColor : Color(.tertiarySystemFill))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 18)
                }
            }
        }
    }

    // MARK: - 标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(setup.currentStep.title)
                .font(.largeTitle.bold())
            Text(stepDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var stepDescription: String {
        switch setup.currentStep {
        case .modeSelection:
            return AppLocalization.string("先确定拦截在哪里执行。这一步之后仍可随时切换。")
        case .permissionRequest:
            return AppLocalization.string("地图显示与 Wi-Fi 名称读取需要定位权限，本应用不会上传任何位置数据。")
        case .proxySetup:
            return setup.selectedMode == .localProxy
                ? AppLocalization.string("需要安装本机证书，并把当前 Wi-Fi 的代理指向本机。")
                : AppLocalization.string("需要在你的代理客户端中导入模块，并开启对应主机名的解密。")
        case .verification:
            return AppLocalization.string("运行完整检测，确认每个环节都通了再开始使用。")
        }
    }

    // MARK: - 底部操作栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if setup.currentStep != .modeSelection {
                Button {
                    setup.goBack()
                } label: {
                    Text(AppLocalization.string("上一步"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
            }

            Button {
                handlePrimaryAction()
            } label: {
                HStack {
                    if isVerifying {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(primaryButtonTitle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying || (setup.currentStep == .modeSelection && !setup.runtimeMode.hasSelectedMode))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var primaryButtonTitle: String {
        switch setup.currentStep {
        case .modeSelection: return AppLocalization.string("下一步")
        case .permissionRequest: return AppLocalization.string("下一步")
        case .proxySetup: return AppLocalization.string("开始检测")
        case .verification: return AppLocalization.string("完成")
        }
    }

    private func handlePrimaryAction() {
        switch setup.currentStep {
        case .verification:
            // 允许用户在没有全部通过的情况下完成引导——有些环境天然过不了
            // Wi-Fi 代理检测（例如只能用蜂窝网络），不应把用户卡死。
            setup.complete()
        case .proxySetup:
            setup.advance()
            Task { await runVerification() }
        default:
            setup.advance()
        }
    }

    // MARK: - 环境检测

    private func runVerification() async {
        isVerifying = true
        defer { isVerifying = false }

        var collected = VerificationReport()

        // 改写引擎自检：这一项不依赖任何外部条件，永远能跑。
        let selfCheck = proxy.runSelfCheck(latitude: 22.281508, longitude: 114.174700, accuracy: 25)
        collected.results.append(VerificationResult(
            kind: .rewriteEngine,
            outcome: selfCheck.hasPrefix("ok:") ? .passed : .failed(selfCheck),
            detail: selfCheck
        ))

        switch setup.selectedMode {
        case .localProxy:
            // 证书信任：需要有证书服务在跑。
            if proxy.isCertificateServiceRunning {
                await proxy.verifyCertificateTrust()
                switch proxy.certificateTrustState {
                case .trusted:
                    collected.results.append(VerificationResult(
                        kind: .certificateTrust, outcome: .passed,
                        detail: AppLocalization.string("系统已信任本机根证书")
                    ))
                case .notTrusted:
                    collected.results.append(VerificationResult(
                        kind: .certificateTrust, outcome: .failed(
                            AppLocalization.string("证书未安装或未开启完全信任")
                        ),
                        detail: proxy.certificateDownloadURL?.absoluteString ?? ""
                    ))
                case .failed(let reason):
                    collected.results.append(VerificationResult(
                        kind: .certificateTrust, outcome: .failed(reason), detail: ""
                    ))
                case .unknown:
                    collected.results.append(VerificationResult(
                        kind: .certificateTrust, outcome: .skipped(
                            AppLocalization.string("证书服务未启动")
                        ),
                        detail: ""
                    ))
                }
            } else {
                collected.results.append(VerificationResult(
                    kind: .certificateTrust,
                    outcome: .skipped(AppLocalization.string("请先启动代理")),
                    detail: ""
                ))
            }

            // Wi-Fi 代理链路。
            if proxy.status.isRunning {
                await proxy.verifyWiFiProxy()
                let passed = proxy.wiFiProxyState == .configured
                collected.results.append(VerificationResult(
                    kind: .wifiProxy,
                    outcome: passed ? .passed : .failed(
                        AppLocalization.string("请求没有经过本机代理，请检查 Wi-Fi 代理配置")
                    ),
                    detail: "\(ProxyManager.proxyHost):\(ProxyManager.proxyPort)"
                ))
            } else {
                collected.results.append(VerificationResult(
                    kind: .wifiProxy,
                    outcome: .skipped(AppLocalization.string("代理未启动")),
                    detail: ""
                ))
            }

        case .thirdParty:
            await thirdParty.refresh()
            switch thirdParty.state {
            case .connected, .connectedNoCoordinate:
                collected.results.append(VerificationResult(
                    kind: .thirdPartyModule, outcome: .passed,
                    detail: AppLocalization.string("客户端已响应配置接口")
                ))
            case .clientMissing:
                collected.results.append(VerificationResult(
                    kind: .thirdPartyModule, outcome: .failed(
                        AppLocalization.string("未检测到已安装的 %@", thirdParty.selectedClient.displayName)
                    ),
                    detail: ""
                ))
            case .moduleNotInstalled:
                collected.results.append(VerificationResult(
                    kind: .thirdPartyModule, outcome: .failed(
                        AppLocalization.string("模块未生效，请确认已导入并开启解密")
                    ),
                    detail: ""
                ))
            case .failed(let reason):
                collected.results.append(VerificationResult(
                    kind: .thirdPartyModule, outcome: .failed(reason), detail: ""
                ))
            case .unknown, .checking:
                collected.results.append(VerificationResult(
                    kind: .thirdPartyModule, outcome: .skipped(AppLocalization.string("未完成检测")),
                    detail: ""
                ))
            }
        }

        report = collected
        RuntimeLogger.info("APP", "Setup", "环境检测完成", details: [
            "passed": String(collected.isAllPassed),
            "failedCount": String(collected.failedResults.count),
        ])
    }
}
