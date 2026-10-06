import SwiftUI

/// 问题报告生成页。
///
/// 目标是降低用户提 Issue 的门槛，同时避免把隐私信息带出去。生成的内容
/// 会经过 `Redactor` 处理，用户也能在提交前先预览一遍。
struct BugReportView: View {

    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var thirdParty = ThirdPartyProxyManager.shared
    @ObservedObject private var runtimeMode = RuntimeModeStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var description = ""
    @State private var includeLogs = true
    @State private var canReproduce = true
    @State private var report = ""
    @State private var copied = false
    @State private var isGenerating = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextEditor(text: $description)
                        .frame(minHeight: 110)
                        .overlay(alignment: .topLeading) {
                            if description.isEmpty {
                                Text(AppLocalization.string("说明一下遇到的问题，例如：开启虚拟定位后地图仍显示真实位置。"))
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text(AppLocalization.string("问题描述"))
                }

                Section {
                    Toggle(AppLocalization.string("可以稳定复现"), isOn: $canReproduce)
                    Toggle(AppLocalization.string("附带运行日志"), isOn: $includeLogs)
                } footer: {
                    Text(AppLocalization.string("日志会先做脱敏处理，去除经纬度、令牌、MAC 等敏感内容。"))
                }

                Section {
                    Button {
                        Task { await generateReport() }
                    } label: {
                        HStack {
                            Label(AppLocalization.string("生成报告"), systemImage: "doc.badge.plus")
                            Spacer()
                            if isGenerating { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(isGenerating || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !report.isEmpty {
                        Button {
                            UIPasteboard.general.string = report
                            copied = true
                        } label: {
                            Label(
                                copied ? AppLocalization.string("已复制到剪贴板") : AppLocalization.string("复制报告"),
                                systemImage: copied ? "checkmark" : "doc.on.doc"
                            )
                        }
                    }
                }

                if !report.isEmpty {
                    Section {
                        Text(report)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        Text(AppLocalization.string("报告预览"))
                    } footer: {
                        Text(AppLocalization.string("请确认内容没有你不希望公开的信息后再提交。"))
                    }
                }
            }
            .navigationTitle(AppLocalization.string("问题报告"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("关闭")) { dismiss() }
                }
            }
        }
    }

    private func generateReport() async {
        isGenerating = true
        defer { isGenerating = false }

        // 生成前跑一轮环境检查，让报告里带上真实状态。
        if runtimeMode.mode == .localProxy {
            await proxy.verifyCertificateTrust()
            await proxy.verifyWiFiProxy()
        } else {
            await thirdParty.refresh()
        }

        var lines: [String] = []
        lines.append("## \(AppLocalization.string("环境信息"))")
        lines.append("- \(AppLocalization.string("应用版本")): \(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
        lines.append("- \(AppLocalization.string("内核版本")): \(CoreBridge.coreVersion)")
        lines.append("- iOS: \(UIDevice.current.systemVersion)")
        lines.append("- \(AppLocalization.string("设备型号")): \(deviceModel())")
        lines.append("- \(AppLocalization.string("运行模式")): \(runtimeMode.mode.displayName)")

        lines.append("")
        lines.append("## \(AppLocalization.string("环境状态"))")
        switch runtimeMode.mode {
        case .localProxy:
            lines.append("- \(AppLocalization.string("代理状态")): \(proxy.status.displayText)")
            lines.append("- \(AppLocalization.string("证书信任")): \(proxy.certificateTrustState.displayText)")
            lines.append("- Wi-Fi \(AppLocalization.string("代理")): \(proxy.wiFiProxyState.displayText)")
            lines.append("- \(AppLocalization.string("当前网络")): \(proxy.currentWiFiName.isEmpty ? "未知" : proxy.currentWiFiName)")
        case .thirdParty:
            lines.append("- \(AppLocalization.string("客户端")): \(thirdParty.selectedClient.displayName)")
            lines.append("- \(AppLocalization.string("连接状态")): \(thirdParty.state.displayText)")
        }
        lines.append("- \(AppLocalization.string("数据共享")): \(AppGroup.isAvailable ? "可用" : "不可用")")

        lines.append("")
        lines.append("## \(AppLocalization.string("问题描述"))")
        lines.append(description.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("- \(AppLocalization.string("可以稳定复现")): \(canReproduce ? "是" : "否")")

        if includeLogs {
            lines.append("")
            lines.append("## \(AppLocalization.string("运行日志"))")
            lines.append("```")
            lines.append(RuntimeLogger.exportText())
            lines.append("```")
        }

        // 最终再过一遍脱敏，防止设备型号之类的组合信息间接暴露身份。
        report = Redactor.redact(lines.joined(separator: "\n"))
        RuntimeLogger.info("APP", "BugReport", "报告已生成")
    }

    /// 只取「iPhone」这一级，不带具体型号后缀，降低可识别性。
    private func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        if identifier.hasPrefix("iPhone") { return "iPhone" }
        if identifier.hasPrefix("iPad") { return "iPad" }
        if identifier.hasPrefix("arm64") || identifier.hasPrefix("x86_64") { return "Simulator" }
        return "Unknown"
    }
}
