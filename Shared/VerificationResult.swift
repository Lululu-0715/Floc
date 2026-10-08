import Foundation

/// 环境检测的结果模型。
struct VerificationResult: Equatable {
    enum Kind: Equatable {
        case certificateTrust
        case wifiProxy
        case thirdPartyModule
        case rewriteEngine
    }

    enum Outcome: Equatable {
        case passed
        case failed(String)
        case skipped(String)

        var symbol: String {
            switch self {
            case .passed: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .skipped: return "minus.circle"
            }
        }

        var isPassed: Bool { self == .passed }
    }

    let kind: Kind
    let outcome: Outcome
    let detail: String

    var title: String {
        switch kind {
        case .certificateTrust: return AppLocalization.string("证书信任")
        case .wifiProxy: return AppLocalization.string("Wi-Fi 代理链路")
        case .thirdPartyModule: return AppLocalization.string("第三方模块连通")
        case .rewriteEngine: return AppLocalization.string("改写引擎自检")
        }
    }
}

/// 一整套环境检测的结果集合。
struct VerificationReport {
    var results: [VerificationResult] = []

    /// 所有非跳过项是否都通过。
    var isAllPassed: Bool {
        results.allSatisfy { result in
            switch result.outcome {
            case .passed, .skipped: return true
            case .failed: return false
            }
        }
    }

    var failedResults: [VerificationResult] {
        results.filter {
            if case .failed = $0.outcome { return true }
            return false
        }
    }

    /// 生成可复制的文本报告。
    func textReport() -> String {
        var lines: [String] = []
        lines.append("=== \(AppLocalization.string("环境检测报告")) ===")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        lines.append("\(AppLocalization.string("生成时间")): \(formatter.string(from: Date()))")
        lines.append("")

        for result in results {
            let status: String
            switch result.outcome {
            case .passed: status = "PASS"
            case .failed: status = "FAIL"
            case .skipped: status = "SKIP"
            }
            lines.append("[\(status)] \(result.title)")
            if !result.detail.isEmpty {
                lines.append("       \(result.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
