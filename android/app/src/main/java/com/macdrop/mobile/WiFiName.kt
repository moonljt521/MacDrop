package com.macdrop.mobile

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager

/**
 * 当前连接的 Wi-Fi 名称。
 *
 * 系统把 SSID 当位置数据保护：Android 10 起，没拿到「精确位置」权限时
 * [WifiManager.getConnectionInfo] 的 SSID 会返回 "<unknown ssid>"。
 * 所以这里只在用户主动点「Wi-Fi」时才申请权限，拿不到就如实说「已连接」，
 * 不猜、不编名字。
 */
object WiFiName {

    /** 没拿到名字时的占位：Android 会用这个字符串代替真实 SSID */
    private const val UNKNOWN_SSID = "<unknown ssid>"

    /** 是否连着 Wi-Fi（走网络能力判断，不需要任何权限） */
    fun isOnWifi(context: Context): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
        val network = manager.activeNetwork ?: return false
        val capabilities = manager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
    }

    /** 已经有精确位置权限了吗（拿到它才可能读到真实 SSID） */
    fun hasLocationPermission(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /** 当前 Wi-Fi 名称；没有权限或没连 Wi-Fi 时返回空 */
    fun current(context: Context): String {
        if (!hasLocationPermission(context)) return ""
        if (!isOnWifi(context)) return ""
        return try {
            val manager = context.getSystemService(WifiManager::class.java) ?: return ""
            val ssid = manager.connectionInfo?.ssid.orEmpty()
            val trimmed = ssid.trim('"')
            if (trimmed.isEmpty() || trimmed == UNKNOWN_SSID) "" else trimmed
        } catch (_: Exception) {
            ""
        }
    }
}
