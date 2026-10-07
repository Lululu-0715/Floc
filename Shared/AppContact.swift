import Foundation

/// 对外联系方式。
///
/// 空着的项在界面上不会显示，所以**没确定的留空即可**，不用担心露出
/// `xxx@example.com` 这种占位符。填上就会出现在「设置 → 关于 → 联系我们」，
/// 同时也是「升级套餐」页里引导用户找你购买卡的入口。
///
/// 发布前建议至少填一项（邮件或微信），否则用户想买卡找不到人。
enum AppContact {

    /// 客服 / 购买咨询邮箱。
    static let supportEmail = ""

    /// 微信 / QQ 号，用于购买与售后。
    static let wechat = ""

    /// 问题反馈用的仓库地址。用户在这里提 Issue，你能收到通知。
    static let issuesURL = "https://github.com/Lululu-0715/Floc/issues"

    /// 项目主页。
    static let homepageURL = "https://github.com/Lululu-0715/Floc"

    /// 是否有任何一条「能直接联系到你」的方式。
    static var hasDirectContact: Bool {
        !supportEmail.trimmingCharacters(in: .whitespaces).isEmpty
            || !wechat.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
