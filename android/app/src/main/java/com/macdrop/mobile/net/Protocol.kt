package com.macdrop.mobile.net

import android.net.Uri

data class Peer(
    val name: String,
    val host: String,
    val port: Int,
    val manual: Boolean = false,
    /** 同一台设备的其它可用地址：首选地址连不通时依次尝试 */
    val alternatives: List<String> = emptyList(),
    /** 通过点对点（链路本地地址）连上：对方不在当前 Wi-Fi，而是在附近直连 */
    val peerToPeer: Boolean = false,
    /** 对方自己上报的设备类型（mac / phone / pad），不靠名字猜 */
    val deviceType: String = ""
) {
    val id: String get() = "$name@$host:$port"
    val endpoint: String get() = "$host:$port"
}

/** 设备类型：由对方自己上报（Bonjour TXT 与 /macdrop/ping 都带 type） */
object PeerKind {
    const val MAC = "mac"
    const val PHONE = "phone"
    const val PAD = "pad"

    /** 对应形状的图标资源 */
    fun iconFor(type: String): Int = when (type) {
        PHONE -> com.macdrop.mobile.R.drawable.ic_moon_phone
        PAD -> com.macdrop.mobile.R.drawable.ic_moon_pad
        else -> com.macdrop.mobile.R.drawable.ic_moon_computer
    }

    /** 无障碍朗读用的类型名；认不出来就返回空 */
    fun label(type: String): String = when (type) {
        PHONE -> com.macdrop.mobile.ui.MoonStrings.t("手机")
        PAD -> com.macdrop.mobile.ui.MoonStrings.t("平板")
        MAC -> com.macdrop.mobile.ui.MoonStrings.t("电脑")
        else -> ""
    }
}

data class OutgoingFile(
    val uri: Uri,
    val name: String,
    val relativePath: String,
    val size: Long
)

object NetUtil {

    fun sanitizeName(name: String): String {
        var value = name.replace('/', '_').replace(':', '_').trim()
        if (value.isEmpty() || value == "." || value == "..") value = "_"
        return value
    }

    fun formatHost(host: String): String =
        if (host.contains(':') && !host.startsWith("[")) "[$host]" else host

    fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val units = arrayOf("KB", "MB", "GB", "TB")
        var value = bytes.toDouble()
        var unit = -1
        while (value >= 1024 && unit < units.lastIndex) {
            value /= 1024
            unit++
        }
        return String.format(java.util.Locale.US, "%.1f %s", value, units[unit])
    }
}
