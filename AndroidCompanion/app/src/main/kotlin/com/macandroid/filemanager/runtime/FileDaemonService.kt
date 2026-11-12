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
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.macandroid.filemanager.server.EmbeddedServer
import com.macandroid.filemanager.ui.MainActivity
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class FileDaemonService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var server: EmbeddedServer? = null
    /** Адрес, на котором сейчас слушает sshd (null — все интерфейсы). */
    private var boundHost: String? = null
    private var discoveryHelper: NsdDiscoveryHelper? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    /** Все переходы сервера (старт, стоп, перепривязка к сети, повтор) выполняются под этим lock. */
    private val lifecycleLock = Any()
    @Volatile
    private var stopped = false

    /** Единственный ожидающий повтор запуска сервера. Доступ только под lifecycleLock. */
    private var retryJob: Job? = null
    /** Неудачные попытки подряд; сбрасывается при успешном старте. Доступ только под lifecycleLock. */
    private var retryAttempt = 0
    /** Пауза ожидающего повтора, мс (для текста уведомления). Доступ только под lifecycleLock. */
    private var retryDelayMs = 0L

    companion object {
        private const val TAG = "FileDaemonService"
        private const val CHANNEL_ID = "daemon_sync_channel"
        private const val NOTIFICATION_ID = 1001
        private const val ALERT_NOTIFICATION_ID = 1002
        private const val SFTP_PORT = 2222
        private const val PREFS_NAME = "daemon_prefs"
        private const val KEY_USER_STOPPED = "user_stopped"

        /** Паузы повтора после неудачного старта: 5, 10, 20, 40, 60 с, далее 60 с без ограничения попыток. */
        private val RETRY_DELAYS_MS = longArrayOf(5_000L, 10_000L, 20_000L, 40_000L, 60_000L)

        /** Период проверки, что sshd реально принимает подключения (пока служба работает). */
        private const val HEALTH_CHECK_INTERVAL_MS = 30_000L

        /** Таймауты TCP-пробы порта sshd: первая и повторная (перед перезапуском). */
        private const val PROBE_TIMEOUT_MS = 1_000
        private const val PROBE_RETRY_TIMEOUT_MS = 3_000

        const val ACTION_STOP = "com.macandroid.filemanager.ACTION_STOP"
        const val ACTION_ACTIVE_SYNC_START = "com.macandroid.filemanager.ACTION_ACTIVE_SYNC_START"
        const val ACTION_ACTIVE_SYNC_STOP = "com.macandroid.filemanager.ACTION_ACTIVE_SYNC_STOP"

        @Volatile
        var isRunning: Boolean = false
            internal set

        /** true, пока sshd реально слушает порт. Сбрасывается при остановке и неудачном старте. */
        @Volatile
        var isServerListening: Boolean = false
            internal set

        /** true, если пользователь остановил демон вручную: автозапуск при возврате в приложение не выполняется. */
        fun isUserStopped(context: Context): Boolean =
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getBoolean(KEY_USER_STOPPED, false)

        fun setUserStopped(context: Context, value: Boolean) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_USER_STOPPED, value)
                .apply()
        }

        /**
         * Есть ли доступ ко всем файлам: MANAGE_EXTERNAL_STORAGE (API 30+) или runtime-разрешения (API 26-29).
         * Единая проверка для MainActivity и автозапуска после перезагрузки/обновления.
         */
        fun hasStoragePermission(context: Context): Boolean =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Environment.isExternalStorageManager()
            } else {
                context.checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED &&
                    context.checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
            }

        /** Условия автозапуска: доступ к файлам есть и пользователь не останавливал демон вручную. */
        fun shouldAutostart(context: Context): Boolean =
            hasStoragePermission(context) && !isUserStopped(context)

        /**
         * Автозапуск демона без открытия приложения (BOOT_COMPLETED, MY_PACKAGE_REPLACED).
         * Исключения запуска логируются и не пробрасываются, чтобы не уронить процесс приёмника.
         */
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
        if (System.getProperty("user.home").isNullOrEmpty()) {
            System.setProperty("user.home", filesDir.absolutePath)
        }
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

        registerNetworkCallback()

        // Запуск sshd и mDNS вне главного потока (исключение ANR)
        serviceScope.launch {
            synchronized(lifecycleLock) { ensureServerLocked(refreshDiscovery = true) }
        }

        // Периодическая самопроверка: сервер «запущен», но порт не принимает подключения — перезапуск
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
                // Повторы не должны стартовать сервер между этим событием и onDestroy
                stopped = true
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_ACTIVE_SYNC_START -> acquireTransferLocks()
            ACTION_ACTIVE_SYNC_STOP -> releaseTransferLocks()
            else -> {
                // Запуск из приложения: проверяем sshd и поднимаем сервер, если он не работает или не отвечает
                serviceScope.launch { checkServerHealth(fromApp = true) }
            }
        }
        return START_STICKY
    }

    /**
     * Самопроверка: sshd считается запущенным, но порт может не принимать подключения
     * (сокет закрыт системой). Проба идёт вне lifecycleLock — её до 4 с не держат onDestroy на главном потоке;
     * решение о перезапуске принимается под lock, только если состояние за время пробы не изменилось.
     * [fromApp] — запуск из приложения: во время паузы повтора сервер поднимается сразу, не дожидаясь таймера.
     */
    private fun checkServerHealth(fromApp: Boolean = false) {
        val host: String?
        val probed: EmbeddedServer
        synchronized(lifecycleLock) {
            if (stopped) return
            if (retryJob != null) {
                // Периодическая проверка не опережает ожидающий повтор; приложение — поднимает сервер сразу
                if (fromApp) ensureServerLocked(refreshDiscovery = false)
                return
            }
            val current = server
            if (current == null || EmbeddedServer.findWifiIpv4Address() != boundHost) {
                // Сервера нет или сменился адрес — обычный путь без пробы
                ensureServerLocked(refreshDiscovery = false)
                return
            }
            host = boundHost
            probed = current
        }
        // Перезапуск рвёт активные сессии: одной медленной пробы мало, нужна и вторая, с запасом
        val failure = probeSftpPort(host, PROBE_TIMEOUT_MS)?.let { probeSftpPort(host, PROBE_RETRY_TIMEOUT_MS) } ?: return
        synchronized(lifecycleLock) {
            if (stopped || server !== probed) return
            Log.w(TAG, "SFTP-порт не принимает подключения ($failure), перезапуск сервера")
            ensureServerLocked(refreshDiscovery = false, restartReason = "проба порта ${addressLabel(host)} не прошла: $failure")
        }
    }

    /**
     * Поднимает sshd и mDNS, если они не работают, либо перепривязывает sshd к текущему Wi-Fi адресу.
     * [restartReason] — перезапустить работающий сервер (проба порта не прошла).
     * Вызывать только под lifecycleLock.
     */
    private fun ensureServerLocked(refreshDiscovery: Boolean, restartReason: String? = null) {
        if (stopped) return
        val wanted = EmbeddedServer.findWifiIpv4Address()
        if (server != null) {
            if (restartReason != null) {
                DaemonLog.write(this, "Перезапуск сервера: $restartReason")
            } else if (wanted == boundHost) {
                if (refreshDiscovery) registerDiscoveryLocked()
                return
            } else {
                DaemonLog.write(this, "Адрес сервера изменился: ${addressLabel(boundHost)} → ${addressLabel(wanted)}")
            }
        }

        stopServerLocked()
        try {
            val newServer = EmbeddedServer(this, port = SFTP_PORT, bindHost = wanted)
            newServer.start()
            server = newServer
            boundHost = wanted
            isServerListening = true
            DaemonLog.write(this, "SFTP-сервер запущен (адрес ${addressLabel(wanted)}, порт $SFTP_PORT)")
            // Сервер поднят: ожидающий повтор и счётчик неудач больше не нужны
            retryAttempt = 0
            cancelRetryLocked()
            registerDiscoveryLocked()
            updateNotification(statusText(wanted))
            // Оповещение о прошлом сбое больше не актуально
            getSystemService(NotificationManager::class.java).cancel(ALERT_NOTIFICATION_ID)
        } catch (e: Exception) {
            // Ошибку показываем пользователю, а не падаем: иначе START_STICKY даст крэш-цикл
            Log.e(TAG, "Не удалось запустить SFTP-сервер", e)
            // Гасим всё, что могло подняться до сбоя (частично занятый порт, mDNS)
            stopServerLocked()
            val reason = e.message ?: e.javaClass.simpleName
            DaemonLog.write(this, "Сбой запуска SFTP-сервера: $reason")
            // Alert — только на первый сбой серии; повторы обновляют уведомление
            if (retryAttempt == 0) postAlert("SFTP-сервер не запущен", reason)
            scheduleRetryLocked(reason)
        }
    }

    /**
     * Проба порта sshd: TCP-подключение к [host] (или loopback, если адрес не привязан) с таймаутом [timeoutMs].
     * Соединение сразу закрывается. Исключения не пробрасываются. Блокирующая: только вне главного потока и lock.
     * @return null — порт принял подключение; иначе тип и текст ошибки (для daemon.log).
     */
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

    private fun addressLabel(host: String?): String = host ?: "все интерфейсы"

    /**
     * Планирует один повтор запуска сервера с паузой 5, 10, 20, 40, 60 с (далее 60 с).
     * Уже ожидающий повтор не дублируется. Вызывать только под lifecycleLock.
     */
    private fun scheduleRetryLocked(reason: String) {
        if (stopped) return
        if (retryJob == null) {
            val delayMs = RETRY_DELAYS_MS[minOf(retryAttempt, RETRY_DELAYS_MS.lastIndex)]
            retryAttempt++
            retryDelayMs = delayMs
            // Job пишется под тем же lock, что и проверка ниже: повтор не увидит «себя» раньше времени
            retryJob = serviceScope.launch {
                val self = coroutineContext[Job]
                delay(delayMs)
                synchronized(lifecycleLock) {
                    // Повтор отменён (сеть подняла сервер, служба остановлена) — ничего не делаем
                    if (retryJob !== self) return@synchronized
                    retryJob = null
                    ensureServerLocked(refreshDiscovery = true)
                }
            }
        }
        updateNotification("Сервер не запущен: $reason. Повтор через ${retryDelayMs / 1000} с")
    }

    /** Отменяет ожидающий повтор. Вызывать только под lifecycleLock. */
    private fun cancelRetryLocked() {
        retryJob?.cancel()
        retryJob = null
    }

    /** Останавливает sshd и mDNS. Вызывать только под lifecycleLock. */
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
        // Остановка сервера закрывает все сессии: блокировки сна больше не нужны
        releaseTransferLocks()
    }

    private fun registerDiscoveryLocked() {
        discoveryHelper?.unregisterService()
        discoveryHelper = NsdDiscoveryHelper(this).also { it.registerService(SFTP_PORT) }
    }

    private fun registerNetworkCallback() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = onNetworkChanged(refreshDiscovery = true)
            override fun onLost(network: Network) = onNetworkChanged(refreshDiscovery = true)
            // DHCP может изменить IPv4 без потери самого Network. Перепривязываем
            // sshd при новом IP; одно изменение DNS не требует перерегистрации NSD.
            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) =
                onNetworkChanged(refreshDiscovery = false)
        }
        networkCallback = callback
        try {
            // Wi-Fi остаётся важен для локального SFTP, даже если default — VPN или cellular.
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            cm.registerNetworkCallback(request, callback)
        } catch (e: Exception) {
            Log.w(TAG, "Не удалось подписаться на изменения сети", e)
            networkCallback = null
        }
    }

    private fun onNetworkChanged(refreshDiscovery: Boolean) {
        serviceScope.launch {
            synchronized(lifecycleLock) { ensureServerLocked(refreshDiscovery = refreshDiscovery) }
        }
    }

    /**
     * Wi-Fi lock и WakeLock берутся на первую активную сессию и отпускаются на последней
     * (а также при остановке сервера и службы). Срока у WakeLock нет: с 30-минутным сроком
     * простаивающая сессия теряла его и рвалась по молчанию, когда телефон засыпал.
     * Зависшую сессию sshd закрывает сам по idle-timeout, после чего блокировки отпускаются.
     */
    private fun acquireTransferLocks() {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        if (wakeLock == null) {
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MacDroid::TransferLock")
        }
        val wasHeld = wakeLock?.isHeld == true
        if (!wasHeld) {
            @Suppress("WakelockTimeout")
            wakeLock?.acquire()
        }
        if (wifiLock == null) {
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

    override fun onDestroy() {
        isRunning = false
        stopped = true
        networkCallback?.let {
            try {
                getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it)
            } catch (e: Exception) {
                Log.w(TAG, "Не удалось отписаться от изменений сети", e)
            }
        }
        networkCallback = null
        synchronized(lifecycleLock) {
            cancelRetryLocked()
            stopServerLocked()
        }
        releaseTransferLocks()
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onTimeout(startId: Int) {
        super.onTimeout(startId)
        // SYS-02 FIX: Корректная обработка 6-часового лимита dataSync на Android 14+ (API 34)
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
            "Фоновый файловый демон активен (SFTP :$SFTP_PORT, Wi-Fi не найден)"
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
