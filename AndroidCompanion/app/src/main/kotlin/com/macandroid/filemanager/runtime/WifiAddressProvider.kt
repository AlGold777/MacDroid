package com.macandroid.filemanager.runtime

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections

/**
 * Единый источник Wi-Fi IPv4-адреса для bind-решений сервера, UI и NSD (ТЗ 3.4).
 * Предпочтительный источник: LinkProperties активной Wi-Fi-сети (TRANSPORT_WIFI, не VPN).
 * Fallback: интерфейсы STA wlan* (исключая p2p/AP).
 */
object WifiAddressProvider {

    private const val TAG = "WifiAddressProvider"

    fun getWifiIpv4Address(context: Context): String? {
        // 1. Предпочтительный источник: ConnectivityManager (LinkProperties сети TRANSPORT_WIFI)
        try {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            if (cm != null) {
                for (network in cm.allNetworks) {
                    val caps = cm.getNetworkCapabilities(network) ?: continue
                    if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                        val lp = cm.getLinkProperties(network) ?: continue
                        for (la in lp.linkAddresses) {
                            val addr = la.address
                            if (addr is Inet4Address && !addr.isLoopbackAddress) {
                                val host = addr.hostAddress
                                if (!host.isNullOrEmpty()) {
                                    return host
                                }
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Ошибка определения Wi-Fi IPv4 через ConnectivityManager", e)
        }

        // 2. Fallback: перечисление интерфейсов wlan*
        try {
            val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces())
            for (iface in interfaces) {
                if (!iface.isUp || iface.isLoopback) continue
                val name = iface.name.lowercase()
                // Исключаем AP/hotspot и p2p интерфейсы
                if (!name.startsWith("wlan")) continue
                if (name.contains("p2p") || name.contains("ap")) continue

                for (addr in Collections.list(iface.inetAddresses)) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val host = addr.hostAddress
                        if (!host.isNullOrEmpty()) {
                            return host
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Ошибка перечисления NetworkInterfaces для Wi-Fi", e)
        }

        return null
    }
}
