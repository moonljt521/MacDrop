import Foundation
import CoreLocation
import Network
import NetworkExtension
import UIKit

/// 当前连接的 Wi-Fi 名称。
///
/// 系统把 SSID 当位置数据保护，拿到名字要同时满足：
/// 1. App 带 **Access Wi-Fi Information** 能力（见 MoonDrop.entitlements）
/// 2. 用户授予**精确位置**授权
///
/// 少一条都拿不到名字。所以这里只在用户主动点「Wi-Fi」时才去申请授权，
/// 拿不到就如实显示「已连接」，不猜、不编名字。
@MainActor
final class WiFiInfo: NSObject, ObservableObject {

    /// 能否读取 Wi-Fi 名称的权限状态
    enum Access {
        /// 还没问过
        case notAsked
        /// 已授权（能读名字）
        case granted
        /// 用户拒绝了，需要去系统设置里改
        case denied
        /// 系统限制（如家长控制），改不了
        case restricted
    }

    /// 已知的 Wi-Fi 名称；空表示还没拿到
    @Published private(set) var name: String = ""
    /// 是否连着 Wi-Fi（走网络路径判断，不需要任何权限）
    @Published private(set) var isOnWiFi: Bool = false
    @Published private(set) var access: Access = .notAsked

    private let locationManager = CLLocationManager()
    private let pathMonitor = NWPathMonitor()

    override init() {
        super.init()
        locationManager.delegate = self
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOnWiFi = path.usesInterfaceType(.wifi)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.macdrop.mobile.wifi.path"))
        access = Self.currentAccess(of: locationManager)
    }

    /// 已经拿到名字了就不必再打扰用户；
    /// 已授权但系统仍然不给名字（比如用户选了「大致位置」）时也不再重复请求
    var canRequest: Bool { name.isEmpty && isOnWiFi && access != .granted }

    /// 用户点了「Wi-Fi」：有授权就读名字，没授权就按状态走
    func request() {
        switch access {
        case .granted:
            fetchName()
        case .notAsked:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            // 已经拒绝过，系统不会再弹；直接把人送到设置页
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    /// 回到前台时刷新一次：用户可能换网络了
    func refresh() {
        guard access == .granted else { return }
        fetchName()
    }

    private func fetchName() {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            Task { @MainActor in
                guard let self else { return }
                self.name = network?.ssid ?? ""
            }
        }
    }

    private static func currentAccess(of manager: CLLocationManager) -> Access {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }
}

extension WiFiInfo: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.access = Self.currentAccess(of: manager)
            if self.access == .granted {
                self.fetchName()
            }
        }
    }
}
