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
