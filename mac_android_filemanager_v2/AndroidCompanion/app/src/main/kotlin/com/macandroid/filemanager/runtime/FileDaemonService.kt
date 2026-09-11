package com.macandroid.filemanager.runtime

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import com.macandroid.filemanager.R
import com.macandroid.filemanager.server.EmbeddedServer

class FileDaemonService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var server: EmbeddedServer? = null
    private var discoveryHelper: NsdDiscoveryHelper? = null

    override fun onCreate() {
        super.onCreate()
        val channelId = "daemon_sync_channel"
        val channel = NotificationChannel(
            channelId,
            "MacDroid File Sync Daemon",
            NotificationManager.IMPORTANCE_LOW
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)

        val notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Mac ↔ Android Companion")
            .setContentText("Фоновый файловый демон активен (SFTP :2222)")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .build()

        startForeground(1001, notification)

        // Удержание WakeLock для защиты от засыпания CPU при передаче
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MacDroid::TransferLock").apply {
            acquire(6 * 60 * 60 * 1000L) // до 6 часов (лимит Android 15 dataSync)
        }

        // Запуск SSHD сервера и mDNS публикации
        server = EmbeddedServer(this, port = 2222)
        server?.start()

        discoveryHelper = NsdDiscoveryHelper(this)
        discoveryHelper?.registerService(2222)
    }

    override fun onDestroy() {
        discoveryHelper?.unregisterService()
        server?.stop()
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
