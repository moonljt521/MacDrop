package com.macdrop.mobile

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build

/**
 * 当前连接的 Wi-Fi 名称。
 *
 * 系统把 SSID 当位置数据保护，而且规则分几代：
 *  - Android 12 起：读取要运行时权限，没给只会拿到 "<unknown ssid>"
 *  - Android 13 起：以 API 33 为目标时还要 **NEARBY_WIFI_DEVICES**，
 *    不少 OEM（国产 ROM）不给就直接把名字抹掉，哪怕位置权限已经给了
 *  - 只给「大致位置」时同样拿不到名字
 *  - **系统定位服务总开关关着时也拿不到**：定位服务一关，
 *    系统把所有位置衍生的数据（包括 SSID）一起脱敏，权限再全也没用
 *
 * 所以这里不只读名字，还要说清楚「缺哪一样」，否则用户只会反复点。
 */
object WiFiName {

    /** 系统给出的占位符，代表名字被抹掉了 */
    private const val UNKNOWN_SSID = "<unknown ssid>"

    /** 读取结果的状态：名字为什么拿不到 */
    enum class Status {
        /** 读到了 */
        OK,

        /** 没连 Wi-Fi */
        NOT_ON_WIFI,

        /** 还没申请过权限 */
        NOT_ASKED,

        /** 只给了「大致位置」，系统不给名字 */
        APPROXIMATE_LOCATION,

        /** Android 13+ 缺「附近的设备」权限 */
        MISSING_NEARBY,

        /** 系统定位服务总开关关着 */
        LOCATION_SERVICE_OFF,

        /** 权限都齐了，系统还是不给名字 */
        REDACTED
    }

    /** 是否连着 Wi-Fi（不需要任何权限） */
    fun isOnWifi(context: Context): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val capabilities = manager?.getNetworkCapabilities(manager.activeNetwork)
        if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) return true
        // 有些设备用以太网承载流量但 Wi-Fi 仍连着：看 Wi-Fi 自己有没有连上
        return try {
            val info = context.getSystemService(WifiManager::class.java)?.connectionInfo
            info != null && info.networkId != -1
        } catch (_: Exception) {
            false
        }
    }

    /** 有精确位置权限吗（只有它才能读到真实名字） */
    fun hasLocationPermission(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /** 只给了大致位置吗 */
    fun hasApproximateLocation(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED && !hasLocationPermission(context)

    /** 有「附近的设备」权限吗（Android 13+ 才需要） */
    fun hasNearbyPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        return context.checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) ==
            PackageManager.PERMISSION_GRANTED
    }

    /** 系统定位服务总开关开着吗：关着的话 SSID 一律拿不到 */
    fun locationServiceEnabled(context: Context): Boolean = try {
        val manager = context.getSystemService(LocationManager::class.java)
        manager != null && manager.isLocationEnabled
    } catch (_: Exception) {
        true
    }

    /** 当前 Wi-Fi 名称；拿不到时返回空 */
    fun current(context: Context): String {
        if (!isOnWifi(context)) return ""
        if (!hasLocationPermission(context)) return ""
        if (!hasNearbyPermission(context)) return ""
        // 两条路都试：有的 ROM 抹掉 getConnectionInfo，transportInfo 里还留着
        val candidates = listOf(
            try {
                context.getSystemService(WifiManager::class.java)?.connectionInfo?.ssid.orEmpty()
            } catch (_: Exception) {
                ""
            },
            try {
                val manager = context.getSystemService(ConnectivityManager::class.java)
                val capabilities = manager?.getNetworkCapabilities(manager.activeNetwork)
                (capabilities?.transportInfo as? WifiInfo)?.ssid.orEmpty()
            } catch (_: Exception) {
                ""
            }
        )
        return candidates
            .map { it.trim().trim('"') }
            .firstOrNull { it.isNotEmpty() && it != UNKNOWN_SSID }
            .orEmpty()
    }

    /** 现在是什么状态 */
    fun status(context: Context): Status {
        if (!isOnWifi(context)) return Status.NOT_ON_WIFI
        if (!hasLocationPermission(context)) {
            return if (hasApproximateLocation(context)) {
                Status.APPROXIMATE_LOCATION
            } else {
                Status.NOT_ASKED
            }
        }
        if (!hasNearbyPermission(context)) return Status.MISSING_NEARBY
        if (current(context).isNotEmpty()) return Status.OK
        // 权限齐了还是读不到：先看系统定位服务是不是关着（关着就一律脱敏）
        return if (locationServiceEnabled(context)) {
            Status.REDACTED
        } else {
            Status.LOCATION_SERVICE_OFF
        }
    }

    /** 还缺哪些权限，一次性问齐，别让用户点好几轮 */
    fun missingPermissions(context: Context): Array<String> {
        val needed = mutableListOf<String>()
        if (!hasLocationPermission(context)) {
            needed += Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (Build.VERSION.SDK_INT >= 33 && !hasNearbyPermission(context)) {
            needed += Manifest.permission.NEARBY_WIFI_DEVICES
        }
        return needed.toTypedArray()
    }
}
