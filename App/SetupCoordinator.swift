import Foundation

/// 首次配置的引导流程协调器。
///
/// 负责回答两个问题：
///   1. 该设备的代理环境配置是否已经走完？
///   2. 现在应该展示引导页还是主界面？
///
/// 引导三步：授权限 → 配代理 → 做检测。
/// （1.0.8 之前第一步是「选择运行模式」，只剩应用内代理之后这一步没有意义了。）
@MainActor
final class SetupCoordinator: ObservableObject {

    @Published private(set) var runtimeMode: RuntimeModeStore
    @Published private(set) var isCompleted: Bool

    /// 三页欢迎页是否已经看过。
    ///
    /// 与 `isCompleted` 刻意分开记录：欢迎页只是一段介绍，不承载任何配置。
    /// 用户在设置页点「重置引导流程」时应该回到配置步骤，而不是被
    /// 重新塞一遍介绍页面。
    @Published private(set) var hasSeenWelcome: Bool

    /// 引导流程的当前步骤。
    @Published var currentStep: Step = .permissionRequest

    private enum Key {
        static let welcomeSeen = "welcomeOnboardingSeen"
    }

    private let defaults: UserDefaults

    enum Step: Int, CaseIterable, Comparable {
        case permissionRequest
        case proxySetup
        case verification

        static func < (lhs: Step, rhs: Step) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var title: String {
            switch self {
            case .permissionRequest: return AppLocalization.string("授予必要权限")
            case .proxySetup: return AppLocalization.string("配置代理环境")
            case .verification: return AppLocalization.string("执行环境检测")
            }
        }
    }

    init(
        runtimeMode: RuntimeModeStore = .shared,
        defaults: UserDefaults = AppGroup.defaults
    ) {
        self.runtimeMode = runtimeMode
        self.defaults = defaults
        self.hasSeenWelcome = defaults.bool(forKey: Key.welcomeSeen)
        self.isCompleted = runtimeMode.isInitialized
    }

    /// 记下欢迎页已看过，之后不再展示。
    func markWelcomeSeen() {
        guard !hasSeenWelcome else { return }
        hasSeenWelcome = true
        defaults.set(true, forKey: Key.welcomeSeen)
    }

    /// 前进到下一步。
    func advance() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else {
            complete()
            return
        }
        currentStep = next
    }

    /// 后退一步。
    func goBack() {
        guard let previous = Step(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = previous
    }

    /// 跳到指定步骤（用于用户直接点侧边指示器）。
    func jump(to step: Step) {
        guard step <= currentStep else { return }
        currentStep = step
    }

    /// 标记引导已完成，进入主界面。
    func complete() {
        runtimeMode.markInitialized()
        isCompleted = true
        RuntimeLogger.info("APP", "Setup", "引导流程完成")
    }

    /// 重新走一遍引导（设置页里的「重置配置」）。
    func reset() {
        runtimeMode.resetInitialization()
        isCompleted = false
        currentStep = .permissionRequest
        RuntimeLogger.info("APP", "Setup", "引导流程已重置")
    }
}
