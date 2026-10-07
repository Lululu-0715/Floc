import Foundation

/// 对外联系方式。
///
/// 空着的项在界面上不会显示，所以**没确定的留空即可**，不用担心露出
/// `xxx@example.com` 这种占位符。填上就会出现在「设置 → 关于 → 联系我们」，
/// 同时也是「升级套餐 → 购买与续费」页里引导用户找你买卡的入口。
///
/// 发布前建议至少填一项（邮箱或公众号），否则用户想买卡找不到人。
///
/// 这里刻意**不再放仓库地址和主页**：仓库里还挂着模块脚本的 raw 地址，
/// 对外露出去等于把「脚本从哪儿来」也一起告诉用户，改动起来要顾虑的
/// 兼容面反而更大。对外只留能直接找到人的两个入口。
enum AppContact {

    /// 客服 / 购买咨询邮箱。
    static let supportEmail = ""

    /// 公众号 / 微信号，用于购买、售后与版本更新通知。
    static let officialAccount = ""

    /// 是否有任何一条「能直接联系到你」的方式。
    static var hasDirectContact: Bool {
        !supportEmail.trimmingCharacters(in: .whitespaces).isEmpty
            || !officialAccount.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
