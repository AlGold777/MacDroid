package com.macandroid.filemanager.runtime

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import com.macandroid.filemanager.server.EmbeddedServer
import com.macandroid.filemanager.ui.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class FileDaemonService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var server: EmbeddedServer? = null

    /** Адрес, на котором сейчас слушает sshd (null — loopback-only 127.0.0.1). */
    private var boundHost: String? = null

    /** Отложенный адрес для ребайнда, если смена сети произошла во время активных сессий (ТЗ 3.1). */
    private var pendingRebindHost: String? = null

    private var discoveryHelper: NsdDiscoveryHelper? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycleExecutor = Executors.newSingleThreadExecutor()

    /** Главный Handler для потокобезопасного acquire/release локов (ТЗ 4.2). */
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Все переходы сервера выполняются под этим lock. */
    private val lifecycleLock = Any()

    @Volatile
    private var stopped = false

    private var retryJob: Job? = null
    private var retryAttempt = 0
    private var retryDelayMs = 0L

    private var pendingRefreshDiscovery = false
    private var networkDebounceJob: Job? = null

    /**
     * Слушатель событий смены количества сессий из единого SessionStateTracker (ТЗ 4.1).
     */
    private val sessionCountListener = SessionStateTracker.SessionCountListener { current, previous ->
        mainHandler.post {
            if (current > 0 && previous == 0) {
                acquireTransferLocks()
            } else if (current == 0 && previous > 0) {
                releaseTransferLocks()
            }
        }

        // ТЗ 3.1: Закрытие последней сессии проверяет наличие pendingRebind
        if (current == 0 && previous > 0) {
            serviceScope.launch {
                synchronized(lifecycleLock) {
                    if (stopped) return@launch
                    val pending = pendingRebindHost
                    if (pending != null && SessionStateTracker.activeSftpSessions == 0) {
                        pendingRebindHost = null
                        DaemonLog.write(
                            this@FileDaemonService,
                            "Все сессии завершены, выполнение отложенного ребайнда на ${addressLabel(pending)}"
                        )
                        ensureServerLocked(refreshDiscovery = (pending != null))
                    }
                }
            }
        }
    }

    companion object {
        private const val TAG = "FileDaemonService"
        private const val CHANNEL_ID = "daemon_sync_channel"
        private const val NOTIFICATION_ID = 1001
        private const val ALERT_NOTIFICATION_ID = 1002
        private const val SFTP_PORT = 2222
        private const val PREFS_NAME = "daemon_prefs"
        private const val KEY_USER_STOPPED = "user_stopped"

        private val RETRY_DELAYS_MS = longArrayOf(5_000L, 10_000L, 20_000L, 40_000L, 60_000L)
        private const val HEALTH_CHECK_INTERVAL_MS = 30_000L
        private const val PROBE_TIMEOUT_MS = 1_000
        private const val PROBE_RETRY_TIMEOUT_MS = 3_000

        const val ACTION_STOP = "com.macandroid.filemanager.ACTION_STOP"

        @Volatile
        var isRunning: Boolean = false
            internal set

        @Volatile
        var isServerListening: Boolean = false
            internal set

        fun isUserStopped(context: Context): Boolean =
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getBoolean(KEY_USER_STOPPED, false)

        fun setUserStopped(context: Context, value: Boolean) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_USER_STOPPED, value)
                .apply()
        }

        fun hasStoragePermission(context: Context): Boolean =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Environment.isExternalStorageManager()
            } else {
                context.checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED &&
                    context.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
            }

        fun shouldAutostart(context: Context): Boolean =
            hasStoragePermission(context) && !isUserStopped(context)

        fun autostartIfAllowed(context: Context, reason: String) {
            if (!shouldAutostart(context)) {
                Log.i(TAG, "Автозапуск пропущен ($reason): нет доступа к файлам или демон остановлен пользователем")
                return
            }
            try {
                context.startForegroundService(Intent(context, FileDaemonService::class.java))
                Log.i(TAG, "Автозапуск демона выполнен ($reason)")
            } catch (e: Exception) {
                Log.e(TAG, "Автозапуск демона не выполнен ($reason)", e)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        stopped = false

        val channel = NotificationChannel(
            CHANNEL_ID,
            "MacDroid File Sync Daemon",
            NotificationManager.IMPORTANCE_LOW
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)

        val notification = buildNotification("Запуск SFTP-сервера…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Подписываемся на единый SessionStateTracker (ТЗ 4.1)
        SessionStateTracker.addListener(sessionCountListener)

        registerNetworkCallback()

        // Запуск sshd и mDNS вне главного потока
        serviceScope.launch {
            synchronized(lifecycleLock) { ensureServerLocked(refreshDiscovery = true) }
        }

        // Периодическая самопроверка
        serviceScope.launch {
            while (isActive) {
                delay(HEALTH_CHECK_INTERVAL_MS)
                if (stopped) break
                checkServerHealth()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                DaemonLog.write(this, "Остановлено пользователем (ACTION_STOP)")
                setUserStopped(this, true)
                stopped = true
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                serviceScope.launch { checkServerHealth(fromApp = true) }
            }
        }
        return START_STICKY
    }

    /**
     * Самопроверка SFTP-сервера с guard активных сессий и файлового I/O (ТЗ 3.3).
     */
    private fun checkServerHealth(fromApp: Boolean = false) {
        val host: String?
        val probed: EmbeddedServer
        synchronized(lifecycleLock) {
            if (stopped) return

            // ТЗ 3.3: Если активны сессии или был файловый I/O за последние 30 с — пропускаем рестарт
            val activeSessions = SessionStateTracker.activeSftpSessions
            val lastIo = SessionStateTracker.lastIoElapsedRealtime
            val recentIo = lastIo > 0L && (SystemClock.elapsedRealtime() - lastIo < 30_000L)
            if (activeSessions > 0 || recentIo) {
                Log.d(TAG, "checkServerHealth: пропуск пробы (сессии: $activeSessions, недавний I/O: $recentIo)")
                return
            }

            if (retryJob != null) {
                if (fromApp) ensureServerLocked(refreshDiscovery = false)
                return
            }

            val current = server
            val wanted = WifiAddressProvider.getWifiIpv4Address(this)
            if (current == null || wanted != boundHost) {
                ensureServerLocked(refreshDiscovery = (wanted != null))
                return
            }
            host = boundHost
            probed = current
        }

        val failure = probeSftpPort("127.0.0.1", PROBE_TIMEOUT_MS)
            ?: (if (host != null) probeSftpPort(host, PROBE_RETRY_TIMEOUT_MS)?.let { probeSftpPort("127.0.0.1", PROBE_RETRY_TIMEOUT_MS) } else null)
            ?: return

        synchronized(lifecycleLock) {
            if (stopped || server !== probed) return
            // Повторная проверка guard перед рестартом
            if (SessionStateTracker.activeSftpSessions > 0) return
            Log.w(TAG, "SFTP-порт не принимает подключения ($failure), перезапуск сервера")
            ensureServerLocked(
                refreshDiscovery = false,
                restartReason = "проба порта ${addressLabel(host)} не прошла: $failure"
            )
        }
    }

    /**
     * Поднимает sshd и mDNS либо перепривязывает sshd к текущему Wi-Fi адресу (ТЗ 2.1, 3.1).
     */
    private fun ensureServerLocked(refreshDiscovery: Boolean, restartReason: String? = null) {
        if (stopped) return
        val wanted = WifiAddressProvider.getWifiIpv4Address(this)

        if (server != null) {
            if (restartReason != null) {
                DaemonLog.write(this, "Перезапуск сервера: $restartReason")
            } else if (wanted == boundHost) {
                if (refreshDiscovery) registerDiscoveryLocked(wanted)
                return
            } else {
                // ТЗ 3.1: Смена адреса при activeSftpSessions > 0 откладывает ребайнд (pending-rebind)
                if (SessionStateTracker.activeSftpSessions > 0) {
                    pendingRebindHost = wanted
                    DaemonLog.write(
                        this,
                        "Адрес сети изменился: ${addressLabel(boundHost)} → ${addressLabel(wanted)}, но активно ${SessionStateTracker.activeSftpSessions} сессий. Ребайнд отложен."
                    )
                    return
                }
                DaemonLog.write(
                    this,
                    "Адрес сервера изменился: ${addressLabel(boundHost)} → ${addressLabel(wanted)}"
                )
            }
        }

        stopServerLocked()
        try {
            // ТЗ 2.1: Fail-closed: wanted == null -> bindHost = null (EmbeddedServer слушает ТОЛЬКО 127.0.0.1:2222)
            val newServer = EmbeddedServer(this, port = SFTP_PORT, bindHost = wanted)
            newServer.start()
            server = newServer
            boundHost = wanted
            isServerListening = true

            // Освобождаем блокировки, если нет активных передач
            if (SessionStateTracker.activeSftpSessions == 0) {
                mainHandler.post { releaseTransferLocks() }
            }

            DaemonLog.write(
                this,
                "SFTP-сервер запущен (адрес ${addressLabel(wanted)}, порт $SFTP_PORT, хост-ключ ${newServer.hostKeyFingerprint() ?: "неизвестен"})"
            )

            retryAttempt = 0
            cancelRetryLocked()
            registerDiscoveryLocked(wanted)
            updateNotification(statusText(wanted))
            getSystemService(NotificationManager::class.java).cancel(ALERT_NOTIFICATION_ID)
        } catch (e: Exception) {
            Log.e(TAG, "Не удалось запустить SFTP-сервер", e)
            stopServerLocked()
            val reason = e.message ?: e.javaClass.simpleName
            DaemonLog.write(this, "Сбой запуска SFTP-сервера: $reason")
            if (retryAttempt == 0) postAlert("SFTP-сервер не запущен", reason)
            scheduleRetryLocked(reason)
        }
    }

    private fun probeSftpPort(host: String?, timeoutMs: Int): String? =
        try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(host ?: "127.0.0.1", SFTP_PORT), timeoutMs)
            }
            null
        } catch (e: Exception) {
            "${e.javaClass.simpleName}: ${e.message}".also {
                Log.w(TAG, "Проба порта ${addressLabel(host)}:$SFTP_PORT не прошла: $it")
            }
        }

    private fun addressLabel(host: String?): String = host ?: "127.0.0.1 (только USB)"

    private fun scheduleRetryLocked(reason: String) {
        if (stopped) return
        if (retryJob == null) {
            val delayMs = RETRY_DELAYS_MS[minOf(retryAttempt, RETRY_DELAYS_MS.lastIndex)]
            retryAttempt++
            retryDelayMs = delayMs
            retryJob = serviceScope.launch {
                val self = coroutineContext[Job]
                delay(delayMs)
                synchronized(lifecycleLock) {
                    if (retryJob !== self) return@synchronized
                    retryJob = null
                    ensureServerLocked(refreshDiscovery = true)
                }
            }
        }
        updateNotification("Сервер не запущен: $reason. Повтор через ${retryDelayMs / 1000} с")
    }

    private fun cancelRetryLocked() {
        retryJob?.cancel()
        retryJob = null
    }

    private fun stopServerLocked() {
        discoveryHelper?.unregisterService()
        discoveryHelper = null
        try {
            server?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "Ошибка при остановке SFTP-сервера", e)
        }
        server = null
        boundHost = null
        isServerListening = false
    }

    /**
     * ТЗ 2.1: NSD регистрируется ТОЛЬКО когда сервер слушает Wi-Fi адрес.
     * При loopback-only (wifiIpv4 == null) NSD unregister и не регистрируется.
     */
    private fun registerDiscoveryLocked(wifiIpv4: String?) {
        discoveryHelper?.unregisterService()
        discoveryHelper = null
        if (wifiIpv4 != null) {
            discoveryHelper = NsdDiscoveryHelper(this).also { it.registerService(SFTP_PORT) }
        }
    }

    private fun registerNetworkCallback() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = onNetworkChanged(refreshDiscovery = true)
            override fun onLost(network: Network) = onNetworkChanged(refreshDiscovery = true)
            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) =
                onNetworkChanged(refreshDiscovery = false)
        }
        networkCallback = callback
        try {
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            cm.registerNetworkCallback(request, callback)
        } catch (e: Exception) {
            Log.w(TAG, "Не удалось подписаться на изменения сети", e)
            networkCallback = null
        }
    }

    /**
     * ТЗ 3.2: Дебаунс сетевых событий 2 с с OR-аккумуляцией и без lifecycleLock на main-потоке.
     */
    private fun onNetworkChanged(refreshDiscovery: Boolean) {
        serviceScope.launch {
            synchronized(lifecycleLock) {
                if (stopped) return@launch
                pendingRefreshDiscovery = pendingRefreshDiscovery || refreshDiscovery
                networkDebounceJob?.cancel()
                networkDebounceJob = serviceScope.launch {
                    delay(2_000)
                    synchronized(lifecycleLock) {
                        if (stopped) return@launch
                        val refresh = pendingRefreshDiscovery
                        pendingRefreshDiscovery = false
                        networkDebounceJob = null
                        ensureServerLocked(refreshDiscovery = refresh)
                    }
                }
            }
        }
    }

    /**
     * ТЗ 4.2: WakeLock и WifiLock потокобезопасны — все операции строго на mainHandler.
     * setReferenceCounted(false) на обоих локах.
     * Политика по умолчанию — session-long (F13).
     * WIFI_MODE_FULL_HIGH_PERF устарел на API 34; PARTIAL_WAKE_LOCK и исключение из Doze
     * обеспечивают работу при выключенном экране.
     */
    private fun acquireTransferLocks() {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        if (wakeLock == null) {
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MacDroid::TransferLock").apply {
                setReferenceCounted(false)
            }
        }
        val wasHeld = wakeLock?.isHeld == true
        if (!wasHeld) {
            @Suppress("WakelockTimeout")
            wakeLock?.acquire()
        }

        if (wifiLock == null) {
            @Suppress("DEPRECATION")
            wifiLock = (applicationContext.getSystemService(WIFI_SERVICE) as? WifiManager)
                ?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "MacDroid::WifiLock")
                ?.apply { setReferenceCounted(false) }
        }
        if (wifiLock?.isHeld == false) {
            wifiLock?.acquire()
        }

        if (!wasHeld) DaemonLog.write(this, "Блокировки сна взяты: открыта сессия")
    }

    private fun releaseTransferLocks() {
        if (wakeLock?.isHeld == true) DaemonLog.write(this, "Блокировки сна отпущены")
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wifiLock?.let {
            if (it.isHeld) it.release()
        }
    }

    /**
     * ТЗ 4.4: onDestroy без блокировки main-потока.
     */
    override fun onDestroy() {
        isRunning = false
        stopped = true

        SessionStateTracker.removeListener(sessionCountListener)

        networkCallback?.let {
            try {
                getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it)
            } catch (e: Exception) {
                Log.w(TAG, "Не удалось отписаться от изменений сети", e)
            }
        }
        networkCallback = null

        // Немедленная остановка foreground и освобождение локов на main
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (e: Exception) {
            Log.w(TAG, "stopForeground завершился с ошибкой", e)
        }
        releaseTransferLocks()

        // Очистку сервера и отмену повторов отправляем на фоновый executor без ожидания на main
        lifecycleExecutor.execute {
            synchronized(lifecycleLock) {
                cancelRetryLocked()
                stopServerLocked()
            }
        }
        lifecycleExecutor.shutdown()

        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onTimeout(startId: Int) {
        super.onTimeout(startId)
        Log.w(TAG, "Лимит фоновой работы dataSync исчерпан, сервис останавливается")
        DaemonLog.write(this, "Лимит фоновой работы dataSync исчерпан, служба остановлена системой")
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (e: Exception) {
            Log.w(TAG, "stopForeground завершился с ошибкой", e)
        }
        postAlert(
            "Фоновый демон остановлен системой",
            "Лимит фоновой работы Android исчерпан. Откройте приложение и запустите сервер снова."
        )
        stopSelf(startId)
    }

    private fun statusText(host: String?): String =
        if (host != null) {
            "Фоновый файловый демон активен (SFTP $host:$SFTP_PORT)"
        } else {
            "Wi-Fi недоступен — доступ только по кабелю (USB)"
        }

    private fun buildNotification(text: String): Notification {
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

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Mac ↔ Android Companion")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentIntent(mainPendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Остановить", stopPendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun postAlert(title: String, text: String) {
        val mainPendingIntent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentIntent(mainPendingIntent)
            .setAutoCancel(true)
            .build()
        getSystemService(NotificationManager::class.java).notify(ALERT_NOTIFICATION_ID, notification)
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
