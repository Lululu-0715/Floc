import UIKit

/// 屏幕**物理圆角**（pt）。
///
/// 地图底部那张大卡片要跟屏幕的圆角**同心** —— 而两个同心圆的半径差，
/// 就是卡片到屏幕外沿的那 12pt 留边：屏幕 62 → 卡片 50，屏幕 55 → 卡片 43。
/// 所以「同心」这件事的第一步是先知道**这台机器的屏幕圆角是多少**。
///
/// 取值顺序（前一步拿不到才走下一步）：
///
///   1. 运行时读 `UIScreen` 的私有属性 `_displayCornerRadius`（KVC）。
///      这是唯一能覆盖**所有机型**、且以后出新机型也不用改代码的方式。
///   2. 读不到就用机型表兜底（`knownRadii`，值取自公开的实机实测汇总：
///      X/11 Pro 系 39、XR/11 41.5、12/13 mini 44、12~14 与 16e 47.33、
///      12~14 的 Max/Plus 53.33、14 Pro 之后到 16 Plus 55、16 Pro 起与
///      17 系及 Air 62）。
///   3. 表里也查不到（以后的新机型）用 `fallback`（55）：它是当前在售机型里
///      出现最多的圆角，猜错的偏差最小。
///
/// **下限 `minimum`（39）**：iPhone 4~8 与 SE 的屏幕是直角，这里算出来的
/// 圆角没有意义（会变成负数）。那些机器本来就谈不上「跟屏幕同心」，
/// 一律按最小的圆角屏 39 处理 —— 卡片圆角退到 27，看得出来不是为它设计的，
/// 但不至于让整张卡片塌成一块方板。
///
/// **1.0.13 及以前写死 44 就是错在这里**：44 是按「屏幕 55 − 留边 12」算的，
/// 而 55 只是 iPhone 14 Pro / 15 / 16 那一代的值；16 Pro Max 的屏幕圆角是 62，
/// 同心值应当是 50。差这 6pt，两条弧的圆心就错开 6pt —— 用户的原话是
/// 「卡片下面两个圆角跟我的 16 Pro Max 手机圆角不协调，不是同心圆角」。
///
/// 私有 API 的代价是上架审核有风险（本工程走自签名分发，不受影响）；
/// 取不到就是取不到，兜底完整，不会崩，也不会因此少画一个圆角。
enum ScreenCornerRadius {

    /// 屏幕圆角（pt）。
    static var value: CGFloat { resolved }

    /// 机型表和运行时都拿不到时的默认值。
    static let fallback: CGFloat = 55

    /// 圆角下限，见类型说明。
    static let minimum: CGFloat = 39

    /// 只在第一次问系统，之后走缓存 —— 屏幕圆角在一次运行里不会变。
    ///
    /// `static let` 是惰性初始化，所以这里不会在 App 启动时就做一次 KVC。
    private static let resolved: CGFloat = resolve()

    private static func resolve() -> CGFloat {
        if let raw = displayCornerRadius {
            return max(raw, minimum)
        }
        return max(tableRadius(for: deviceIdentifier) ?? fallback, minimum)
    }

    /// 机型表查询。
    ///
    /// 单独抽出来是为了能单测「主力机型一个都没漏」—— 这次修的 bug 恰恰是
    /// 「把一个不属于这台机器的圆角写死在代码里」，兜底表漏一行就是重演一次。
    ///
    /// - Returns: 表里有这个机型就返回它的屏幕圆角，没有返回 nil（交给 `fallback`）。
    static func tableRadius(for identifier: String) -> CGFloat? {
        knownRadii[identifier]
    }

    /// 私有属性 `_displayCornerRadius`。系统改名 / 被裁剪时返回 nil，交给兜底表。
    ///
    /// 走 `NSNumber` 而不是直接 `as? CGFloat`：KVC 把 CGFloat 装箱成 NSNumber，
    /// 直接转换在部分系统版本上会失败（拿到 nil），那条兜底就白写了。
    private static var displayCornerRadius: CGFloat? {
        guard let number = UIScreen.main.value(forKey: "_displayCornerRadius") as? NSNumber,
              number.doubleValue > 0 else {
            return nil
        }
        return CGFloat(number.doubleValue)
    }

    /// 硬件机型标识（`utsname.machine`，如 `iPhone17,2`）。模拟器上拿到的是
    /// `arm64` / `x86_64`，表里当然没有 —— 于是走 `fallback`。
    private static var deviceIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    /// 实机实测的屏幕圆角表。**只在运行时读不到时才用**，所以不必求全 ——
    /// 同一代、同一圆角的机型都列在一起，将来新增机型遗漏了也只是退到 `fallback`。
    private static let knownRadii: [String: CGFloat] = [
        // 39 —— X 那一代起的第一批圆角屏（含 6.5 吋的大号）
        "iPhone10,3": 39, "iPhone10,6": 39,
        "iPhone11,2": 39, "iPhone11,4": 39, "iPhone11,6": 39,
        "iPhone12,3": 39, "iPhone12,5": 39,

        // 41.5 —— XR / 11 的 LCD 屏，圆角比 X 略大
        "iPhone11,8": 41.5, "iPhone12,1": 41.5,

        // 44 —— 12 mini / 13 mini
        "iPhone13,1": 44, "iPhone14,4": 44,

        // 47.33 —— 12 / 12 Pro / 13 / 13 Pro / 14 / 16e
        "iPhone13,2": 47.33, "iPhone13,3": 47.33,
        "iPhone14,5": 47.33, "iPhone14,2": 47.33,
        "iPhone15,5": 47.33, "iPhone17,5": 47.33,

        // 53.33 —— 12 Pro Max / 13 Pro Max / 14 Plus
        "iPhone13,4": 53.33, "iPhone14,3": 53.33, "iPhone15,6": 53.33,

        // 55 —— 14 Pro / 14 Pro Max / 15 全系 / 16 / 16 Plus
        "iPhone15,2": 55, "iPhone15,3": 55, "iPhone15,4": 55,
        "iPhone16,0": 55, "iPhone16,1": 55, "iPhone16,2": 55,
        "iPhone17,3": 55, "iPhone17,4": 55,

        // 62 —— 16 Pro / 16 Pro Max（本轮用户报的那台）
        "iPhone17,1": 62, "iPhone17,2": 62,
    ]
}
