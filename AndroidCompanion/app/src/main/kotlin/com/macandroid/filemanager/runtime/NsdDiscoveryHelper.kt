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
    private var retryTask: Runnable? = null

    fun registerService(port: Int) {
        onMain {
            generation++
            cancelRetry()
            unregisterCurrent()
            this.port = port
            retriesLeft = MAX_RETRIES
            register(generation)
        }
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
                val registeredListener = this
                onMain {
                    if (gen != generation || registrationListener !== registeredListener) {
                        // Снятие регистрации могло опередить callback успешной регистрации.
                        try { nsdManager.unregisterService(registeredListener) } catch (_: Exception) {}
                    } else {
                        Log.i(TAG, "NSD: сервис зарегистрирован (${serviceInfo.serviceName})")
                    }
                }
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                val failedListener = this
                onMain {
                    if (gen != generation || registrationListener !== failedListener) return@onMain
                    registrationListener = null
                    Log.w(TAG, "NSD: регистрация не удалась, код $errorCode")
                    scheduleRetry(gen)
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
            registrationListener = null
            scheduleRetry(gen)
        }
    }

    fun unregisterService() {
        onMain {
            generation++
            cancelRetry()
            unregisterCurrent()
        }
    }

    /** Lifecycle, NSD callbacks и отложенные повторы меняют состояние на одном потоке. */
    private fun onMain(action: () -> Unit) {
        handler.post { action() }
    }

    private fun scheduleRetry(gen: Int) {
        if (gen != generation || retriesLeft <= 0) return
        retriesLeft--
        cancelRetry()
        retryTask = Runnable {
            retryTask = null
            if (gen == generation) register(gen)
        }.also { handler.postDelayed(it, RETRY_DELAY_MS) }
    }

    private fun cancelRetry() {
        retryTask?.let { handler.removeCallbacks(it) }
        retryTask = null
    }

    private fun unregisterCurrent() {
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
