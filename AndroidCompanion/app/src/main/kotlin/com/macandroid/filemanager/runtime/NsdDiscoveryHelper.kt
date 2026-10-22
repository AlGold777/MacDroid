package com.macandroid.filemanager.runtime

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build

class NsdDiscoveryHelper(private val context: Context) {
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var registrationListener: NsdManager.RegistrationListener? = null

    fun registerService(port: Int) {
        val brand = Build.BRAND.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
        val manufacturer = Build.MANUFACTURER.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
        val primaryBrand = if (brand.isNotBlank() && !brand.equals("Android", ignoreCase = true)) brand else manufacturer
        val model = Build.MODEL
        val devName = if (model.startsWith(primaryBrand, ignoreCase = true)) model else "$primaryBrand $model"
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "$devName (MacDroid)"
            serviceType = "_macphone_sftp._tcp"
            setPort(port)
        }

        registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {}
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
        }

        nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
    }

    fun unregisterService() {
        registrationListener?.let {
            try {
                nsdManager.unregisterService(it)
            } catch (ignored: Exception) {}
        }
        registrationListener = null
    }
}
