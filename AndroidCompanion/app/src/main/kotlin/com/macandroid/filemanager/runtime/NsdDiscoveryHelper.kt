package com.macandroid.filemanager.runtime

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

class NsdDiscoveryHelper(private val context: Context) {
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val handler = Handler(Looper.getMainLooper())
    private var registrationListener: NsdManager.RegistrationListener? = null

    /** Поколение регистрации: устаревшие колбэки и отложенные повторы игнорируются. */
    private var generation = 0
    private var port = 0
    private var retriesLeft = 0

    fun registerService(port: Int) {
        this.port = port
        retriesLeft = MAX_RETRIES
        generation++
        register(generation)
    }

    private fun register(gen: Int) {
        val brand = Build.BRAND.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
        val manufacturer = Build.MANUFACTURER.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
        val primaryBrand = if (brand.isNotBlank() && !brand.equals("Android", ignoreCase = true)) brand else manufacturer
        val model = Build.MODEL
        val devName = if (model.startsWith(primaryBrand, ignoreCase = true)) model else "$primaryBrand $model"
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "$devName (MacDroid)"
            serviceType = "_macphone_sftp._tcp"
            // Внутри apply `port` — это NsdServiceInfo.port (0), поэтому явно берём порт хелпера
            setPort(this@NsdDiscoveryHelper.port)
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "NSD: сервис зарегистрирован (${serviceInfo.serviceName})")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD: регистрация не удалась, код $errorCode")
                if (gen == generation && retriesLeft > 0) {
                    retriesLeft--
                    handler.postDelayed({ if (gen == generation) register(gen) }, RETRY_DELAY_MS)
                }
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD: снятие регистрации не удалось, код $errorCode")
            }
        }

        registrationListener = listener
        try {
            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            Log.w(TAG, "NSD: registerService бросил исключение", e)
        }
    }

    fun unregisterService() {
        generation++
        handler.removeCallbacksAndMessages(null)
        registrationListener?.let {
            try {
                nsdManager.unregisterService(it)
            } catch (e: Exception) {
                Log.w(TAG, "NSD: unregisterService бросил исключение", e)
            }
        }
        registrationListener = null
    }

    companion object {
        private const val TAG = "NsdDiscoveryHelper"
        private const val MAX_RETRIES = 3
        private const val RETRY_DELAY_MS = 5_000L
    }
}
