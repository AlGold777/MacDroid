package com.macandroid.filemanager.runtime

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.macandroid.filemanager.server.EmbeddedServer
import com.macandroid.filemanager.ui.MainActivity

class FileDaemonService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: android.net.wifi.WifiManager.WifiLock? = null
    private var server: EmbeddedServer? = null
    private var discoveryHelper: NsdDiscoveryHelper? = null

    companion object {
        const val ACTION_STOP = "com.macandroid.filemanager.ACTION_STOP"
        const val ACTION_ACTIVE_SYNC_START = "com.macandroid.filemanager.ACTION_ACTIVE_SYNC_START"
        const val ACTION_ACTIVE_SYNC_STOP = "com.macandroid.filemanager.ACTION_ACTIVE_SYNC_STOP"

        @Volatile
        var isRunning: Boolean = false
            internal set
    }

    override fun onCreate() {
        if (System.getProperty("user.home").isNullOrEmpty()) {
            System.setProperty("user.home", filesDir.absolutePath)
        }
        super.onCreate()
        isRunning = true
        val channelId = "daemon_sync_channel"
        val channel = NotificationChannel(
            channelId,
            "MacDroid File Sync Daemon",
            NotificationManager.IMPORTANCE_LOW
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)

        val stopIntent = Intent(this, FileDaemonService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val mainIntent = Intent(this, MainActivity::class.java)
        val mainPendingIntent = PendingIntent.getActivity(
            this, 0, mainIntent,
            PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Mac ↔ Android Companion")
            .setContentText("Фоновый файловый демон активен (SFTP :2222)")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentIntent(mainPendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Остановить", stopPendingIntent)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(1001, notification)
        }

        // Запуск SSHD сервера и mDNS публикации
        server = EmbeddedServer(this, port = 2222)
        server?.start()

        val wm = applicationContext.getSystemService(WIFI_SERVICE) as? android.net.wifi.WifiManager
        wifiLock = wm?.createWifiLock(android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF, "MacDroid::WifiLock")
        wifiLock?.acquire()

        discoveryHelper = NsdDiscoveryHelper(this)
        discoveryHelper?.registerService(2222)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_ACTIVE_SYNC_START -> {
                // SYS-01 FIX: Активируем WakeLock только на время активной передачи данных
                val pm = getSystemService(POWER_SERVICE) as PowerManager
                if (wakeLock == null) {
                    wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MacDroid::TransferLock")
                }
                if (wakeLock?.isHeld == false) {
                    wakeLock?.acquire(30 * 60 * 1000L) // до 30 мин на сессию активной передачи
                }
            }
            ACTION_ACTIVE_SYNC_STOP -> {
                // Освобождаем процессор в режиме ожидания для предотвращения расхода батареи Doze
                wakeLock?.let {
                    if (it.isHeld) it.release()
                }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        discoveryHelper?.unregisterService()
        server?.stop()
        wifiLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
