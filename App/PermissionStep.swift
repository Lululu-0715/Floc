import CoreLocation
import SwiftUI

/// 引导第二步：申请必要权限。
///
/// 这一页只放**真正需要用户点一下系统弹窗**的权限。
/// Wi-Fi 信息（SSID）曾经也占一行，但它是「读得到就读、读不到也不影响开工」
/// 的诊断信息，而且应用内的代理设置页本来就会显示当前 Wi-Fi 名称——
/// 在引导里再要一次只是徒增一步，用户明确要求删掉。SSID 的读取入口仍在
/// `ProxyManager.verifyWiFiProxy()`，由设置页与问题报告按需触发。
struct PermissionStep: View {

    @ObservedObject var setup: SetupCoordinator
    @Binding var requested: Bool

    @StateObject private var locator = PermissionLocator()

    var body: some View {
        VStack(spacing: 14) {
            PermissionRow(
                icon: "location.fill",
                title: AppLocalization.string("定位权限"),
                description: AppLocalization.string("用于在地图上显示真实位置，便于与虚拟位置对照。"),
                state: locationStateText,
                isGranted: locator.authorizationStatus == .authorizedWhenInUse
                    || locator.authorizationStatus == .authorizedAlways
            ) {
                locator.request()
                requested = true
            }

            infoBox
        }
        .onAppear {
            locator.refresh()
            autoRequestIfNeeded()
        }
    }

    /// 进入这一页就自动弹系统授权框，不用用户再点一次按钮。
    ///
    /// 用户明确要求「定位授权要自动跳出来」：这一页只有一件事要做，
    /// 让用户先读一段说明再手动点「授权」纯属多余。
    ///
    /// 延迟 400ms 是为了让页面先画出来 —— 系统弹窗从一个还是空白的页面上
    /// 盖下来会显得莫名其妙。再点之前重新查一次状态：这 400ms 里用户可能
    /// 已经从别处（欢迎页的自动申请）授权过了，重复请求会白弹一次。
    private func autoRequestIfNeeded() {
        guard locator.authorizationStatus == .notDetermined else { return }
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard locator.authorizationStatus == .notDetermined else { return }
            locator.request()
            requested = true
        }
    }

    private var locationStateText: String {
        switch locator.authorizationStatus {
        case .notDetermined: return AppLocalization.string("未授权")
        case .restricted: return AppLocalization.string("受限")
        case .denied: return AppLocalization.string("已拒绝")
        case .authorizedWhenInUse: return AppLocalization.string("使用期间")
        case .authorizedAlways: return AppLocalization.string("始终")
        @unknown default: return AppLocalization.string("未知")
        }
    }

    private var infoBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppLocalization.string("关于隐私"), systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))

            Text(AppLocalization.string(
                "本应用不包含遥测，不上传位置数据。运行日志只保存在设备本地，自动保留最近 3 天，"
                + "在提交问题报告时会自动对经纬度、令牌等信息做脱敏处理。"
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 权限行的通用外观。
struct PermissionRow: View {

    let icon: String
    let title: String
    let description: String
    let state: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 34, height: 34)
                .foregroundStyle(isGranted ? Color.green : Color.orange)
                .background(
                    (isGranted ? Color.green : Color.orange).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 9)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                    Text(state)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            (isGranted ? Color.green : Color.orange).opacity(0.15),
                            in: Capsule()
                        )
                        .foregroundStyle(isGranted ? Color.green : Color.orange)
                }
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if !isGranted {
                Button(AppLocalization.string("授权"), action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 仅用于申请定位权限的轻量 CLLocationManager 包装。
@MainActor
final class PermissionLocator: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }

    func refresh() {
        authorizationStatus = manager.authorizationStatus
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            // 已经被拒绝过就不会再弹系统弹窗，只能引导去设置。
            SystemSettingsNavigator.openAppSettings()
        default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }
}

/// 首次启动时自动申请定位权限。
///
/// 用户要求「刚下载进去的时候定位授权要自动跳出来」：全新安装后第一次打开
/// 应用，不等用户翻完欢迎页、选完运行模式，系统授权框就该弹出来。
/// 定位是这个应用的硬前提（地图要画真实位置、要和虚拟位置对照），
/// 早问一次比让用户自己找入口要直接。
///
/// 这里持有自己的 `CLLocationManager` 而不是复用某处的实例：静态属性保证
/// 它在整个进程生命周期内存活，不会出现「弹窗还没被响应，manager 先被释放」。
@MainActor
enum LocationPermissionAutoRequester {

    private static let manager = CLLocationManager()

    /// 当前还未询问过。已经授权或已拒绝都不该再弹（系统也不会再弹）。
    static var isUndetermined: Bool { manager.authorizationStatus == .notDetermined }

    /// 如果还没问过，就弹一次系统授权框。
    ///
    /// - Parameter delay: 延迟多久再弹。默认 800ms，让首屏先渲染出来。
    static func requestIfUndetermined(delay: UInt64 = 800_000_000) {
        guard isUndetermined else { return }
        Task {
            try? await Task.sleep(nanoseconds: delay)
            // 再确认一次：这段延迟里用户可能已经从引导页的权限步骤授权过了。
            guard isUndetermined else { return }
            RuntimeLogger.info("APP", "Permission", "首次启动自动申请定位权限")
            manager.requestWhenInUseAuthorization()
        }
    }
}
