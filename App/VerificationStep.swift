import SwiftUI

/// 引导第四步：执行环境检测并展示结果。
struct VerificationStep: View {

    @ObservedObject var setup: SetupCoordinator
    @Binding var report: VerificationReport
    @Binding var isVerifying: Bool
    let onRun: () async -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if report.results.isEmpty {
                emptyState
            } else {
                summaryCard
                resultList
                actionRow
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(AppLocalization.string("还没有检测结果"))
                .font(.headline)
            Text(AppLocalization.string("点击下方按钮开始检测。检测会逐项验证证书信任、代理链路与改写引擎。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await onRun() }
            } label: {
                HStack {
                    if isVerifying { ProgressView().tint(.white) }
                    Text(AppLocalization.string("开始检测"))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            Image(systemName: report.isAllPassed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(report.isAllPassed ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(report.isAllPassed
                     ? AppLocalization.string("环境检测通过")
                     : AppLocalization.string("有项目未通过"))
                    .font(.headline)
                Text(report.isAllPassed
                     ? AppLocalization.string("可以开始使用虚拟定位了。")
                     : AppLocalization.string("可以继续，但未通过的项目可能导致定位不生效。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: GlassMetrics.cardCornerRadius))
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            ForEach(Array(report.results.enumerated()), id: \.offset) { index, result in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: result.outcome.symbol)
                            .foregroundStyle(color(for: result.outcome))
                        Text(result.title)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(statusText(for: result.outcome))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color(for: result.outcome))
                    }

                    if !result.detail.isEmpty {
                        Text(result.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 28)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)

                if index != report.results.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: GlassMetrics.cardCornerRadius))
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await onRun() }
            } label: {
                Label(AppLocalization.string("重新检测"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .disabled(isVerifying)

            Button {
                UIPasteboard.general.string = report.textReport()
                copied = true
                RuntimeLogger.info("APP", "Setup", "检测报告已复制")
            } label: {
                Label(
                    copied ? AppLocalization.string("已复制") : AppLocalization.string("复制报告"),
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
    }

    private func color(for outcome: VerificationResult.Outcome) -> Color {
        switch outcome {
        case .passed: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }

    private func statusText(for outcome: VerificationResult.Outcome) -> String {
        switch outcome {
        case .passed: return AppLocalization.string("通过")
        case .failed: return AppLocalization.string("未通过")
        case .skipped: return AppLocalization.string("跳过")
        }
    }
}
