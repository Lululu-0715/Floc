import Foundation

/// 「开启虚拟定位之后去关一下定位服务」这条引导的**持久化开关**。
///
/// ## 为什么必须有这个类
///
/// 1.0.11 及以前这件事是用 `MapHomeView` 里的两个 `@State` 做的：
/// `showLocationRefreshPrompt`（本次要不要弹）和 `didShowLocationRefreshPrompt`
/// （本次启动弹过没有）。`@State` 的生命周期就是视图，**冷启动必然归零**，
/// 于是这条提示每次打开 App 都弹一遍。
///
/// 用户这次要的是「不再提示」——点了之后**永远**别再弹，而且这件事
/// **与定位服务的开关状态无关**（不是「等生效了就别弹」，是「我点过了就别弹」）。
/// 要跨启动就得落盘，所以单独抽一个 store，别塞回视图里。
///
/// ## 存哪
///
/// `AppGroup.defaults`，和工程里其它偏好一致（主题、运行模式都在那儿）。
/// App Group 不可用时它自己会退化成标准 defaults，不需要在这里兜底。
@MainActor
final class SpoofGuideStore: ObservableObject {

    static let shared = SpoofGuideStore()

    private enum Key {
        /// 用户点过「不再提示」。只有这一个键参与判断。
        static let dismissed = "spoofGuideDismissed"
        /// 「去设置」的累计点击次数。只给诊断页看，**不参与任何判断**。
        static let openSettingsCount = "spoofGuideOpenSettingsCount"
    }

    private let defaults: UserDefaults

    /// 是否已被用户永久关闭。视图读它决定弹不弹。
    @Published private(set) var isDismissed: Bool

    /// 「去设置」累计点了多少次。纯粹是留痕，用来回答「这提示到底有没有人看」。
    @Published private(set) var openSettingsCount: Int

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        isDismissed = defaults.bool(forKey: Key.dismissed)
        openSettingsCount = defaults.integer(forKey: Key.openSettingsCount)
    }

    /// 这次该不该弹。
    ///
    /// 只在**开启虚拟定位成功之后**问一次；开着的时候反复进出前台不再弹。
    var shouldPresent: Bool { !isDismissed }

    /// 用户点了「不再提示」：永久关掉，以后任何情况下都不再弹。
    func dismissForever() {
        guard !isDismissed else { return }
        isDismissed = true
        defaults.set(true, forKey: Key.dismissed)
        RuntimeLogger.info("APP", "SpoofGuide", "用户选择不再提示定位刷新引导")
    }

    /// 用户点了「去设置」。
    ///
    /// **不关闭引导** —— 用户只是这会儿去操作了，下次开启虚拟定位该提醒还得提醒。
    /// 真想关掉只能用「不再提示」。
    func noteOpenSettings() {
        openSettingsCount += 1
        defaults.set(openSettingsCount, forKey: Key.openSettingsCount)
        RuntimeLogger.info("APP", "SpoofGuide", "用户从引导里跳转定位服务设置", details: [
            "count": "\(openSettingsCount)",
        ])
    }

    /// 恢复成「还会弹」。设置页的重置入口与单测用。
    func reset() {
        isDismissed = false
        openSettingsCount = 0
        defaults.removeObject(forKey: Key.dismissed)
        defaults.removeObject(forKey: Key.openSettingsCount)
    }
}
