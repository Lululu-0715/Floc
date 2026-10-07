// 纯净版（`PURE_BUILD`）不带卡密，这里的卡密激活 / 套餐 / 推荐的界面整体不参与编译。
// 口味开关见 `Shared/BuildFlavor.swift`。
#if !PURE_BUILD
import SwiftUI

/// 授权卡片：显示当前状态与剩余天数，可展开输入卡密。
///
/// 放在设置页顶部。设计上沿用项目现有的 `GlassCard` 玻璃风格。
struct LicenseCardView: View {

    @ObservedObject var manager: LicenseManager
    @State private var showActivateSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().opacity(0.35)
            detail
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .sheet(isPresented: $showActivateSheet) {
            ActivateSheet(manager: manager)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.string(manager.displayNameKey))
                    .font(.headline)
                Text(manager.remainingText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            actionButton
        }
    }

    // MARK: - 明细

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let type = manager.cardTypeLabel {
                row(AppLocalization.string("卡密类型"), type)
            }
            if manager.bonusDays > 0 {
                row(
                    AppLocalization.string("推荐奖励"),
                    String(format: AppLocalization.string("+%ld 天"), manager.bonusDays)
                )
            }
            if manager.isTestLicense {
                Text(AppLocalization.string("测试授权由应用内置，不占用真实卡密额度，也不会同步到服务端。到期后会自动回到未激活状态。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if manager.isLocalMode {
                Text(AppLocalization.string("尚未配置授权服务端，当前不做授权校验，全部功能已放行。部署 Worker 并把 LicenseConfig.baseURL 换成真实域名后会自动恢复。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if manager.status == .trial {
                Text(AppLocalization.string("试用期内功能与正式版一致，到期后需输入卡密"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if manager.status == .offline {
                Text(AppLocalization.string(
                    "当前处于离线状态，使用的是最近一次校验结果（最多宽限 %ld 天）",
                    LicenseConfig.offlineGraceDays
                ))
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline).monospacedDigit()
        }
    }

    // MARK: - 按钮

    @ViewBuilder
    private var actionButton: some View {
        if manager.isBusy {
            ProgressView().controlSize(.small)
        } else if manager.isTestLicense {
            // 测试授权在服务端没有记录，「解绑」这个词对不上，直说要干什么。
            Button(AppLocalization.string("清除测试授权")) {
                Task { await manager.unbind() }
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
        } else if manager.status == .active || manager.status == .bonus {
            Button(AppLocalization.string("解绑设备")) {
                Task { await manager.unbind() }
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
        } else {
            // 本地模式也给这个按钮：内置测试卡密是离线生效的，
            // 后端没部署时正是唯一能验完「输入卡密 → 激活」这条链路的入口。
            Button(AppLocalization.string("输入卡密")) { showActivateSheet = true }
                .font(.subheadline)
                .buttonStyle(.borderedProminent)
        }
    }

    private var statusIcon: String {
        if manager.isTestLicense { return "hammer.fill" }
        if manager.isLocalMode { return "wrench.and.screwdriver.fill" }
        switch manager.status {
        case .active:       return "checkmark.seal.fill"
        case .trial:        return "clock.badge.checkmark"
        case .bonus:        return "gift.fill"
        case .offline:      return "wifi.slash"
        case .expired, .trialExpired: return "exclamationmark.triangle.fill"
        case .unregistered: return "lock.fill"
        }
    }

    private var statusColor: Color {
        if manager.isTestLicense { return .purple }
        if manager.isLocalMode { return .blue }
        switch manager.status {
        case .active, .trial, .bonus: return .green
        case .offline:                return .orange
        default:                      return .red
        }
    }
}

// MARK: - 激活弹窗

/// 输入卡密激活。
struct ActivateSheet: View {

    @ObservedObject var manager: LicenseManager
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        // 用 NavigationView 而不是 NavigationStack：工程最低支持 iOS 15，
        // NavigationStack 要 iOS 16。其余页面（SettingsView / MapHomeView /
        // DiagnosticsView / BugReportView）也都是 NavigationView，保持一致。
        NavigationView {
            Form {
                Section {
                    TextField("FLOC-XXXX-XXXX-XXXX", text: $input)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .focused($focused)
                } header: {
                    Text(AppLocalization.string("卡密"))
                } footer: {
                    Text(AppLocalization.string("卡密不区分大小写。一台设备一张卡，换手机可自助解绑 1 次。"))
                        .font(.caption)
                }

                // 只有服务端还没配好时才露出测试卡密：那正是「开发者自测」的
                // 窗口期。换成真实域名后这段整块消失，不会跟着正式包发出去。
                if LicenseConfig.showsTestCardHint {
                    Section {
                        Button {
                            if let testKey = LicenseConfig.testCardKeys.first {
                                input = testKey
                            }
                        } label: {
                            SettingsLabel(
                                systemImage: "wrench.and.screwdriver.fill",
                                title: AppLocalization.string("填入内置测试卡密"),
                                isSecondary: true
                            )
                        }
                        .disabled(LicenseConfig.testCardKeys.isEmpty)
                    } header: {
                        Text(AppLocalization.string("测试卡密"))
                    } footer: {
                        Text(AppLocalization.string("授权服务端尚未配置，用这个内置卡密可以在离线状态下走完激活流程、看到倒计时，不会发出任何网络请求。把 baseURL 换成真实域名后这段提示会自动消失。"))
                            .font(.caption)
                    }
                }

                if let error = manager.lastErrorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button {
                        Task {
                            let ok = await manager.activate(cardKey: input)
                            if ok { dismiss() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if manager.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(AppLocalization.string("激活"))
                            }
                            Spacer()
                        }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty
                              || manager.isBusy)
                }
            }
            .navigationTitle(AppLocalization.string("激活卡密"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("取消")) { dismiss() }
                }
            }
            .onAppear {
                manager.lastErrorMessage = nil
                focused = true
            }
        }
    }
}

// MARK: - 推荐页

/// 推荐好友页：展示邀请码、进度阶梯、已得奖励。
struct ReferralView: View {

    @ObservedObject var manager: LicenseManager
    @State private var inputCode = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                myCodeCard
                progressCard
                bindCard
                rulesCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(AppLocalization.string("推荐好友"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await manager.loadReferralStatus()
            if manager.referral?.code == nil {
                await manager.loadReferralCode()
            }
        }
        .alert(AppLocalization.string("提示"), isPresented: errorBinding) {
            Button(AppLocalization.string("好")) { manager.lastErrorMessage = nil }
        } message: {
            Text(manager.lastErrorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { manager.lastErrorMessage != nil },
            set: { if !$0 { manager.lastErrorMessage = nil } }
        )
    }

    // MARK: 我的邀请码

    private var myCodeCard: some View {
        VStack(spacing: 12) {
            Text(AppLocalization.string("我的邀请码"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(manager.referral?.code ?? AppLocalization.string("获取中…"))
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)

            Button {
                guard let code = manager.referral?.code else { return }
                UIPasteboard.general.string = code
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run { copied = false }
                }
            } label: {
                Label(
                    copied
                        ? AppLocalization.string("已复制")
                        : AppLocalization.string("复制邀请码"),
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
                .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .disabled(manager.referral?.code == nil)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    // MARK: 进度

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(AppLocalization.string("推荐进度")).font(.headline)
                Spacer()
                if let r = manager.referral {
                    Text(String(format: AppLocalization.string("已邀请 %d 人"), r.invitedCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let r = manager.referral {
                ForEach(Array(LicenseConfig.referralTiers.enumerated()), id: \.offset) { _, tier in
                    tierRow(tier: tier, current: r.invitedCount)
                }

                Divider().opacity(0.35)

                HStack {
                    Label(AppLocalization.string("已获得"), systemImage: "gift.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: AppLocalization.string("%d 天"), r.bonusDays))
                        .font(.headline)
                        .foregroundStyle(.green)
                }

                if let next = r.nextTier {
                    Text(String(
                        format: AppLocalization.string("再邀请 %d 人，可再得 %d 天"),
                        r.towardNext, next.days
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(AppLocalization.string("已达到最高档位"))
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Text(String(
                    format: AppLocalization.string("奖励可叠加使用，累计封顶 %d 年"),
                    r.capDays / 365
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func tierRow(
        tier: (count: Int, days: Int),
        current: Int
    ) -> some View {
        let reached = current >= tier.count
        return HStack(spacing: 10) {
            Image(systemName: reached ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(reached ? Color.green : Color.secondary.opacity(0.5))
                .font(.subheadline)

            Text(String(format: AppLocalization.string("邀请 %d 人"), tier.count))
                .font(.subheadline)
                .foregroundStyle(reached ? .primary : .secondary)

            Spacer()

            Text(String(format: AppLocalization.string("+%d 天"), tier.days))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(reached ? Color.green : .secondary)
        }
    }

    // MARK: 填别人的码

    private var bindCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let referred = manager.referral?.asReferred {
                // 已绑定过：展示进度
                Text(AppLocalization.string("已接受好友推荐")).font(.headline)
                HStack {
                    Text(AppLocalization.string("连续使用"))
                    Spacer()
                    Text(String(
                        format: AppLocalization.string("%d/%d 天"),
                        referred.streakDays, referred.requiredDays
                    ))
                    .monospacedDigit()
                    .foregroundStyle(referred.qualified ? .green : .primary)
                }
                .font(.subheadline)

                if !referred.qualified {
                    Text(String(
                        format: AppLocalization.string("连续使用满 %d 天后，你的好友将获得推荐奖励"),
                        referred.requiredDays
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        AppLocalization.string("已达成，好友已获得奖励"),
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }
            } else {
                Text(AppLocalization.string("填写好友邀请码")).font(.headline)
                Text(String(
                    format: AppLocalization.string("填写后连续使用 %d 天，你的好友即可获得奖励。"),
                    LicenseConfig.referralRequiredDays
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    TextField("FLOC-XXXXXX", text: $inputCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.subheadline, design: .monospaced))

                    Button(AppLocalization.string("提交")) {
                        Task {
                            let ok = await manager.bindReferral(code: inputCode)
                            if ok { inputCode = "" }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inputCode.trimmingCharacters(in: .whitespaces).isEmpty || manager.isBusy)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: 规则

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.string("活动规则")).font(.headline)

            rule("1", AppLocalization.string("好友下载并填写你的邀请码"))
            rule("2", String(
                format: AppLocalization.string("好友连续使用 %d 天（每天打开 App 即可）"),
                LicenseConfig.referralRequiredDays
            ))
            rule("3", AppLocalization.string("达成后奖励自动发放，按档位累加，不会跳档"))
            rule("4", String(
                format: AppLocalization.string("好友后续购买卡密，你额外再得 %d 天"),
                LicenseConfig.referralPaidBonusDays
            ))
            rule("5", String(
                format: AppLocalization.string("奖励与卡密时长叠加，累计封顶 %d 年"),
                LicenseConfig.referralCapDays / 365
            ))
            rule("6", AppLocalization.string("同一台设备只能被推荐一次，自己不能用自己的邀请码"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func rule(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
