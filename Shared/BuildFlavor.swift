import Foundation

/// 构建口味。
///
/// `./build.sh` 一次会产出两个包，差别只在这里：
///
///   - **标准版**：带卡密 / 授权 / 推荐那一套
///   - **纯净版**：带 `PURE_BUILD` 编译条件，把授权功能整体摘掉
///
/// 用**编译条件**而不是运行时开关是有意的。运行时开关只是把界面藏起来，
/// 激活接口、服务端地址、卡密校验规则照样留在包里；纯净版的定义就是
/// 「没有这套东西」，所以 `LicenseAPI` 与授权界面在纯净版下**根本不参与编译**，
/// 纯净版想调激活接口都编译不过。
///
/// 构建脚本里两个包走的是同一个 target、同一份源码，只差
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 里有没有 `PURE_BUILD`。
enum BuildFlavor {

    /// 是不是纯净版。
    static var isPure: Bool {
        #if PURE_BUILD
        return true
        #else
        return false
        #endif
    }

    /// 跟在版本号后面的口味标记，标准版为空串。
    ///
    /// 「关于」页靠它区分手上装的是哪一个：两个包的显示名（都是 Floc）、
    /// Bundle ID、版本号完全一样，不标一下就只能靠「账号分组里有没有卡密」去猜。
    static var editionSuffix: String {
        isPure ? AppLocalization.string("（纯净版）") : ""
    }
}
