package com.macdrop.mobile.net

import android.net.Uri

data class Peer(
    val name: String,
    val host: String,
    val port: Int,
    val manual: Boolean = false,
    /** 同一台设备的其它可用地址：首选地址连不通时依次尝试 */
    val alternatives: List<String> = emptyList()
) {
    val id: String get() = "$name@$host:$port"
    val endpoint: String get() = "$host:$port"
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
