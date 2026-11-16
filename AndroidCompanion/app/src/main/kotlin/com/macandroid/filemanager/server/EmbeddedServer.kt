package com.macandroid.filemanager.server

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import com.macandroid.filemanager.runtime.DaemonLog
import com.macandroid.filemanager.runtime.PairingConfirmationReceiver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.apache.sshd.common.AttributeRepository
import org.apache.sshd.common.config.keys.AuthorizedKeyEntry
import org.apache.sshd.common.config.keys.KeyUtils
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.file.virtualfs.VirtualFileSystemFactory
import org.apache.sshd.common.session.Session
import org.apache.sshd.common.session.SessionListener
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.pubkey.PublickeyAuthenticator
import org.apache.sshd.server.channel.ChannelSessionFactory
import org.apache.sshd.server.command.Command
import org.apache.sshd.server.command.CommandFactory
import org.apache.sshd.server.forward.RejectAllForwardingFilter
import org.apache.sshd.server.keyprovider.SimpleGeneratorHostKeyProvider
import org.apache.sshd.sftp.server.SftpSubsystemFactory
import java.io.File
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Paths
import java.nio.file.StandardCopyOption
import java.security.PublicKey
import java.text.SimpleDateFormat
import java.util.Base64
import java.util.Collections
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * SFTP/SSH-сервер телефона (ТЗ 2.1 - 2.4, 4.3, 5.2, 8.1).
 *
 * @param bindHost адрес для прослушивания. Если null — привязка ТОЛЬКО к 127.0.0.1 (ТЗ 2.1).
 */
class EmbeddedServer(
    private val context: Context,
    private val port: Int = 2222,
    private val bindHost: String? = null
) {
    private var sshd: SshServer? = null
    private var sftpListener: CustomSftpEventListener? = null
    private val authorizedKeysFile = File(context.filesDir, "authorized_keys")

    fun start() {
        if (sshd != null) return

        val server = SshServer.setUpDefaultServer().apply {
            this.port = this@EmbeddedServer.port

            // ТЗ 2.1: Fail-closed привязка к loopback:
            // При отсутствии Wi-Fi (bindHost == null) сервер слушает ТОЛЬКО 127.0.0.1:2222.
            // При наличии Wi-Fi слушаем Wi-Fi адрес и loopback для adb forward.
            this.host = if (bindHost != null) {
                listOf(bindHost, "127.0.0.1").distinct().joinToString(",")
            } else {
                "127.0.0.1"
            }

            // ТЗ 2.4: Хост-ключи сервера.
            // setAlgorithm("Ed25519") только для генерации нового ключа.
            // setOverwriteAllowed(false) — повреждённый файл вызывает ошибку, а не тихую перегенерацию.
            val hostKeyFile = File(context.filesDir, "hostkey.ser")
            keyPairProvider = SimpleGeneratorHostKeyProvider(hostKeyFile.toPath()).apply {
                setAlgorithm("Ed25519")
                setOverwriteAllowed(false)
            }

            // ТЗ 4.3: Idle-timeout 5 минут и серверный heartbeat (каждые 20 с, wait 60 с)
            this.properties["idle-timeout"] = TimeUnit.MINUTES.toMillis(5).toString()
            this.properties["heartbeat-interval"] = TimeUnit.SECONDS.toMillis(20).toString()
            this.properties["heartbeat-reply-wait"] = TimeUnit.SECONDS.toMillis(60).toString()

            // ТЗ 2.3: Ограничение возможностей SSH
            passwordAuthenticator = null
            keyboardInteractiveAuthenticator = null
            forwardingFilter = RejectAllForwardingFilter.INSTANCE
            channelFactories = listOf(ChannelSessionFactory.INSTANCE)

            // ТЗ 2.2: TOFU с подтверждением и доказательством владения ключом (F6)
            publickeyAuthenticator = PublickeyAuthenticator { _, key: PublicKey, session ->
                val keyBytes = key.encoded
                val remoteIp = (session.ioSession.remoteAddress as? InetSocketAddress)?.address?.hostAddress ?: "unknown"
                val fingerprint = try { KeyUtils.getFingerPrint(key) } catch (e: Exception) { "unknown" }

                synchronized(pairingLock) {
                    if (isKeyAuthorized(key, authorizedKeysFile)) {
                        session.setAttribute(ENROLLED_SESSION_KEY, true)
                        return@PublickeyAuthenticator true
                    }

                    if (!isPairingModeActive) {
                        DaemonLog.write(context, "Отказ в сопряжении (окно закрыто): отпечаток $fingerprint, IP $remoteIp")
                        return@PublickeyAuthenticator false
                    }

                    val approved = approvedPairing
                    if (approved != null && timeSource() < approved.expiresAt) {
                        if (approved.keyBytes.contentEquals(keyBytes)) {
                            // Ключ одобрен пользователем! Возвращаем true, чтобы MINA проверила криптографическую подпись.
                            // Ключ НЕ записывается в authorized_keys здесь (будет записан только в SessionListener.Event.Authenticated).
                            Log.i(TAG, "Ключ $fingerprint одобрен, передача на проверку подписи MINA")
                            return@PublickeyAuthenticator true
                        } else {
                            DaemonLog.write(context, "Отказ в сопряжении: ключ $fingerprint не совпадает с одобренным ${approved.fingerprint}")
                            return@PublickeyAuthenticator false
                        }
                    }

                    // Если слот свободен — сохраняем заявку и показываем prompt
                    if (pendingPairing == null) {
                        pendingPairing = PendingPairing(
                            key = key,
                            keyBytes = keyBytes,
                            fingerprint = fingerprint,
                            sourceIp = remoteIp,
                            createdAt = timeSource()
                        )
                        DaemonLog.write(context, "Заявка на сопряжение: ключ $fingerprint, IP $remoteIp — ожидает подтверждения")
                        showPairingPrompt(context, fingerprint)
                        return@PublickeyAuthenticator false
                    } else {
                        // Защита от флуда и подмены отпечатка
                        DaemonLog.write(context, "Повторный offer проигнорирован (слот заявки занят): ключ $fingerprint, IP $remoteIp")
                        return@PublickeyAuthenticator false
                    }
                }
            }

            // ТЗ 2.2 (Требование A): первый ключ записывается ТОЛЬКО в Event.Authenticated после проверки подписи
            addSessionListener(object : SessionListener {
                override fun sessionEvent(session: Session, event: SessionListener.Event) {
                    if (event == SessionListener.Event.Authenticated) {
                        onSessionAuthenticated(session, context)
                    }
                }
            })

            // Корневой путь хранилища Android
            val rootPath = Paths.get("/storage")
            fileSystemFactory = VirtualFileSystemFactory(rootPath)

            // Обработка команд SSH exec (ТЗ 5.2, 8.1)
            commandFactory = CommandFactory { _, command ->
                object : Command {
                    private var outStream: java.io.OutputStream? = null
                    private var exitCallback: org.apache.sshd.server.ExitCallback? = null

                    override fun setInputStream(`in`: java.io.InputStream?) {}
                    override fun setOutputStream(out: java.io.OutputStream?) { this.outStream = out }
                    override fun setErrorStream(err: java.io.OutputStream?) {}
                    override fun setExitCallback(callback: org.apache.sshd.server.ExitCallback?) { this.exitCallback = callback }

                    override fun start(channel: org.apache.sshd.server.channel.ChannelSession?, env: org.apache.sshd.server.Environment?) {
                        val trimmed = command.trim()
                        if (trimmed == "df" || trimmed.startsWith("df ")) {
                            try {
                                val stat = android.os.StatFs(android.os.Environment.getExternalStorageDirectory().path)
                                val blockSize = stat.blockSizeLong
                                val totalBlocks = stat.blockCountLong
                                val availBlocks = stat.availableBlocksLong
                                val totalBytes = totalBlocks * blockSize
                                val availBytes = availBlocks * blockSize
                                val usedBytes = totalBytes - availBytes
                                val usedPercent = if (totalBytes > 0) (usedBytes * 100 + totalBytes - 1) / totalBytes else 0L

                                val output = "Filesystem 1B-blocks Used Available Use% Mounted on\n" +
                                        "/storage/emulated/0 $totalBytes $usedBytes $availBytes $usedPercent% /storage/emulated/0\n"
                                outStream?.write(output.toByteArray(StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(0)
                            } catch (e: Exception) {
                                Log.e(TAG, "df: ошибка чтения StatFs", e)
                                outStream?.write("df error: ${e.message}\n".toByteArray(StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(1)
                            }
                        } else if (trimmed.startsWith("authorize_key ")) {
                            val newKey = trimmed.substringAfter("authorize_key ").trim()
                            val sessionEnrolled = channel?.session?.getAttribute(ENROLLED_SESSION_KEY) == true
                            if (!isPairingModeActive && !sessionEnrolled) {
                                outStream?.write("ERROR_NOT_ALLOWED\n".toByteArray(StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(1)
                            } else if (newKey.isEmpty()) {
                                outStream?.write("ERROR_EMPTY_KEY\n".toByteArray(StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(1)
                            } else if (parseSingleAuthorizedKey(newKey) == null) {
                                outStream?.write("ERROR_INVALID_KEY\n".toByteArray(StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(1)
                            } else {
                                synchronized(pairingLock) {
                                    val success = writeAuthorizedKeyAtomic(context.filesDir, newKey)
                                    if (success) {
                                        DaemonLog.write(context, "authorize_key: добавлен ключ $newKey")
                                        outStream?.write("AUTHORIZED_OK\n".toByteArray(StandardCharsets.UTF_8))
                                        outStream?.flush()
                                        exitCallback?.onExit(0)
                                    } else {
                                        outStream?.write("ERROR_WRITE_FAILED\n".toByteArray(StandardCharsets.UTF_8))
                                        outStream?.flush()
                                        exitCallback?.onExit(1)
                                    }
                                }
                            }
                        } else {
                            // ТЗ 8.1: Неизвестная команда — exit 1 и "UNKNOWN COMMAND\n"
                            outStream?.write("UNKNOWN COMMAND\n".toByteArray(StandardCharsets.UTF_8))
                            outStream?.flush()
                            exitCallback?.onExit(1)
                        }
                    }

                    override fun destroy(channel: org.apache.sshd.server.channel.ChannelSession?) {}
                }
            }

            // SFTP Subsystem
            val sftpFactory = SftpSubsystemFactory.Builder().build()
            val listener = CustomSftpEventListener(context)
            sftpListener = listener
            sftpFactory.addSftpEventListener(listener)
            subsystemFactories = Collections.singletonList(sftpFactory)

            // Буферы I/O и лимиты
            val serverProps = this.properties
            serverProps["nio2-read-buf-size"] = (256 * 1024).toString()
            serverProps["window-size"] = (8L * 1024 * 1024).toString()
            serverProps["packet-size"] = (64 * 1024).toString()
            serverProps["max-open-handles-per-session"] = "32"
            serverProps["sftp-fs-read-buffer-size"] = (256 * 1024).toString()
            serverProps["sftp-fs-write-buffer-size"] = (256 * 1024).toString()
            serverProps["sftp-max-readdata-packet-length"] = (256 * 1024).toString()
            serverProps["sftp-max-writedata-packet-length"] = (256 * 1024).toString()
        }

        try {
            server.start()
        } catch (e: Exception) {
            try {
                server.stop(true)
            } catch (stopError: Exception) {
                Log.w(TAG, "Не удалось освободить частично запущенный sshd", stopError)
            }
            sftpListener?.dispose()
            sftpListener = null
            throw e
        }
        sshd = server
        liveSshd = server

        // Очистка осиротевших временных файлов при старте
        val listener = sftpListener
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val roots = mutableListOf(context.filesDir)
                val ext = android.os.Environment.getExternalStorageDirectory()
                if (ext != null && ext.exists()) roots.add(ext)
                listener?.collectStalePartFiles(roots)
            } catch (e: Exception) {
                Log.w(TAG, "Фоновая очистка при старте завершилась ошибкой", e)
            }
        }
    }

    fun stop() {
        val server = sshd ?: return
        sshd = null
        if (liveSshd === server) liveSshd = null
        sftpListener?.dispose()
        sftpListener = null
        server.stop(true)
    }

    /**
     * Сброс сопряжения: удаляет файл authorized_keys, закрывает активные сессии.
     */
    fun resetPairing(): Boolean {
        closePairingWindow(context)
        val deleted = synchronized(pairingLock) {
            if (authorizedKeysFile.exists()) authorizedKeysFile.delete() else true
        }
        liveSshd?.activeSessions?.forEach { session ->
            try {
                session.close(true)
            } catch (e: Exception) {
                Log.w(TAG, "resetPairing: не удалось закрыть сессию", e)
            }
        }
        return deleted
    }

    /**
     * ТЗ 2.4: Проверяет наличие корректно разобранных доверенных ключей (а не по длине файла).
     */
    fun isPaired(): Boolean {
        return synchronized(pairingLock) {
            getParsedAuthorizedKeys(authorizedKeysFile).isNotEmpty()
        }
    }

    /**
     * Список отпечатков всех доверенных ключей для UI (ТЗ 2.5).
     */
    fun getTrustedKeyFingerprints(): List<String> {
        return synchronized(pairingLock) {
            getParsedAuthorizedKeys(authorizedKeysFile).mapNotNull { key ->
                try { KeyUtils.getFingerPrint(key) } catch (e: Exception) { null }
            }
        }
    }

    /**
     * SHA256-отпечаток хост-ключа sshd.
     */
    fun hostKeyFingerprint(): String? {
        val hostKeyFile = File(context.filesDir, "hostkey.ser")
        if (!hostKeyFile.exists() || hostKeyFile.length() == 0L) return null
        return try {
            val provider = object : SimpleGeneratorHostKeyProvider(hostKeyFile.toPath()) {
                override fun generateKeyPair(algorithm: String?): java.security.KeyPair? = null
            }
            val keyPair = provider.loadKeys(null).firstOrNull()
            keyPair?.public?.let { KeyUtils.getFingerPrint(it) }
        } catch (e: Exception) {
            Log.w(TAG, "Не удалось прочитать отпечаток хост-ключа", e)
            null
        }
    }

    companion object {
        private const val TAG = "EmbeddedServer"
        private const val PAIRING_WINDOW_MILLIS = 60_000L

        init {
            if (java.security.Security.getProvider("EdDSA") == null) {
                java.security.Security.addProvider(net.i2p.crypto.eddsa.EdDSASecurityProvider())
            }
        }

        @Volatile
        var timeSource: () -> Long = { SystemClock.elapsedRealtime() }

        /** Общий lock на сопряжение и authorized_keys. */
        val pairingLock = Any()

        /** Признак авторизованной сессии. */
        private val ENROLLED_SESSION_KEY = AttributeRepository.AttributeKey<Boolean>()

        @Volatile
        private var liveSshd: SshServer? = null

        @Volatile
        var pairingWindowEndsAt: Long = 0L
            private set

        val isPairingModeActive: Boolean
            get() = timeSource() < pairingWindowEndsAt

        data class PendingPairing(
            val key: PublicKey,
            val keyBytes: ByteArray,
            val fingerprint: String,
            val sourceIp: String,
            val createdAt: Long
        )

        data class ApprovedPairing(
            val key: PublicKey,
            val keyBytes: ByteArray,
            val fingerprint: String,
            val expiresAt: Long
        )

        @Volatile
        var pendingPairing: PendingPairing? = null
            private set

        @Volatile
        var approvedPairing: ApprovedPairing? = null
            private set

        /**
         * Обработчик для показа диалога сопряжения в foreground Activity,
         * если POST_NOTIFICATIONS отклонено (ТЗ 2.2 fallback).
         */
        @Volatile
        var foregroundPromptCallback: ((fingerprint: String) -> Unit)? = null

        fun openPairingWindow() {
            synchronized(pairingLock) {
                pendingPairing = null
                approvedPairing = null
                pairingWindowEndsAt = timeSource() + PAIRING_WINDOW_MILLIS
            }
        }

        fun closePairingWindow(context: Context? = null) {
            synchronized(pairingLock) {
                val pending = pendingPairing
                if (pending != null && context != null) {
                    DaemonLog.write(context, "Окно сопряжения закрыто: заявка на ключ ${pending.fingerprint} аннулирована по таймауту")
                }
                pendingPairing = null
                approvedPairing = null
                pairingWindowEndsAt = 0L
            }
            context?.let { PairingConfirmationReceiver.cancelNotification(it) }
        }

        /**
         * Подтверждение сопряжения пользователем («Принять» в уведомлении или диалоге).
         * Переводит заявку в APPROVED для конкретных байтов ключа. Ключ ЕЩЁ НЕ записан.
         */
        fun confirmPendingPairing(): Boolean {
            synchronized(pairingLock) {
                val pending = pendingPairing ?: return false
                if (!isPairingModeActive) {
                    pendingPairing = null
                    return false
                }
                approvedPairing = ApprovedPairing(
                    key = pending.key,
                    keyBytes = pending.keyBytes,
                    fingerprint = pending.fingerprint,
                    expiresAt = pairingWindowEndsAt
                )
                pendingPairing = null
                return true
            }
        }

        /**
         * Отклонение заявки сопряжения («Отклонить»).
         */
        fun rejectPendingPairing() {
            synchronized(pairingLock) {
                pendingPairing = null
                approvedPairing = null
            }
        }

        /**
         * Показ prompt'а сопряжения с fallback при отсутствии POST_NOTIFICATIONS.
         */
        private fun showPairingPrompt(context: Context, fingerprint: String) {
            val notificationsEnabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
            if (notificationsEnabled) {
                PairingConfirmationReceiver.showConfirmationNotification(context, fingerprint)
            } else {
                val callback = foregroundPromptCallback
                if (callback != null) {
                    // MainActivity на переднем плане
                    callback.invoke(fingerprint)
                } else {
                    // ТЗ 2.2: Приложение в фоне без уведомлений — fail-closed!
                    DaemonLog.write(
                        context,
                        "Отказ в сопряжении: нет разрешения на уведомления и приложение в фоне ($fingerprint)"
                    )
                }
            }
        }

        /**
         * Вызывается из SessionListener при наступлении Event.Authenticated.
         * Выполняет атомарную запись ключа ТОЛЬКО после успешной проверки криптографической подписи.
         */
        private fun onSessionAuthenticated(session: Session, context: Context) {
            synchronized(pairingLock) {
                val approved = approvedPairing
                if (approved != null && timeSource() < approved.expiresAt) {
                    val openSshLine = openSshLineFor(approved.key)
                    val written = writeAuthorizedKeyAtomic(context.filesDir, openSshLine)
                    if (written) {
                        DaemonLog.write(
                            context,
                            "Сопряжение успешно: ключ ${approved.fingerprint} записан в authorized_keys после подтверждения подписи"
                        )
                        session.setAttribute(ENROLLED_SESSION_KEY, true)
                        approvedPairing = null
                        pendingPairing = null
                        closePairingWindow(context)
                    } else {
                        DaemonLog.write(context, "Сбой записи authorized_keys для ключа ${approved.fingerprint}")
                    }
                }
            }
        }

        /**
         * Атомарная запись в authorized_keys (ТЗ 2.4).
         */
        fun writeAuthorizedKeyAtomic(filesDir: File, newLine: String): Boolean {
            val target = File(filesDir, "authorized_keys")
            val tmp = File(filesDir, "authorized_keys.tmp")
            return try {
                val currentLines = if (target.exists()) {
                    target.readLines(StandardCharsets.UTF_8).filter { it.isNotBlank() }
                } else {
                    emptyList()
                }

                if (!currentLines.contains(newLine)) {
                    val updated = (currentLines + newLine).joinToString("\n") + "\n"
                    tmp.writeText(updated, StandardCharsets.UTF_8)
                    try {
                        Files.move(
                            tmp.toPath(),
                            target.toPath(),
                            StandardCopyOption.ATOMIC_MOVE,
                            StandardCopyOption.REPLACE_EXISTING
                        )
                    } catch (e: java.nio.file.AtomicMoveNotSupportedException) {
                        Log.w(TAG, "ATOMIC_MOVE не поддерживается, fallback renameTo", e)
                        if (!tmp.renameTo(target)) {
                            target.writeText(updated, StandardCharsets.UTF_8)
                            tmp.delete()
                        }
                    }
                }
                true
            } catch (e: Exception) {
                Log.e(TAG, "Не удалось атомарно записать authorized_keys", e)
                try { tmp.delete() } catch (_: Exception) {}
                false
            }
        }

        /**
         * Проверка ключа по authorized_keys. Поддерживает OpenSSH и legacy Base64 (ТЗ 2.4).
         */
        fun isKeyAuthorized(key: PublicKey, authorizedKeysFile: File): Boolean {
            if (!authorizedKeysFile.exists() || authorizedKeysFile.length() == 0L) return false
            val parsedKeys = getParsedAuthorizedKeys(authorizedKeysFile)
            for (authorizedKey in parsedKeys) {
                if (KeyUtils.compareKeys(key, authorizedKey) || key.encoded.contentEquals(authorizedKey.encoded)) {
                    return true
                }
            }
            return false
        }

        /**
         * Разбор всех валидных ключей из authorized_keys.
         */
        fun getParsedAuthorizedKeys(authorizedKeysFile: File): List<PublicKey> {
            if (!authorizedKeysFile.exists() || authorizedKeysFile.length() == 0L) return emptyList()
            val result = mutableListOf<PublicKey>()
            try {
                val lines = authorizedKeysFile.readLines(StandardCharsets.UTF_8)
                    .map { it.trim() }
                    .filter { it.isNotEmpty() && !it.startsWith("#") }

                for (line in lines) {
                    val key = parseSingleAuthorizedKey(line)
                    if (key != null) {
                        result.add(key)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Ошибка чтения authorized_keys", e)
            }
            return result
        }

        /**
         * Разбор одной строки authorized_keys (OpenSSH или raw Base64 DER).
         */
        fun parseSingleAuthorizedKey(line: String): PublicKey? {
            if (line.contains('\n') || line.contains('\r')) return null

            // 1. Формат OpenSSH (ssh-ed25519, ecdsa-sha2-, ssh-rsa)
            if (line.startsWith("ssh-") || line.startsWith("ecdsa-")) {
                return try {
                    AuthorizedKeyEntry.parseAuthorizedKeyEntry(line)?.resolvePublicKey(null, null, null)
                } catch (e: Exception) {
                    null
                }
            }

            // 2. Legacy-формат сырого Base64 DER (обратная совместимость)
            return try {
                val bytes = Base64.getDecoder().decode(line)
                val keySpec = java.security.spec.X509EncodedKeySpec(bytes)
                // Пробуем доступные фабрики
                for (algo in listOf("EdDSA", "Ed25519", "EC", "RSA")) {
                    try {
                        val kf = if (algo == "EdDSA" && java.security.Security.getProvider("EdDSA") != null) {
                            java.security.KeyFactory.getInstance("EdDSA", "EdDSA")
                        } else {
                            java.security.KeyFactory.getInstance(algo)
                        }
                        return kf.generatePublic(keySpec)
                    } catch (_: Exception) {}
                }
                null
            } catch (e: Exception) {
                null
            }
        }

        internal fun setPendingPairingForTesting(pending: PendingPairing?) {
            pendingPairing = pending
        }

        internal fun setApprovedPairingForTesting(approved: ApprovedPairing?) {
            approvedPairing = approved
        }

        /**
         * Генерация строки в формате OpenSSH: `ssh-ed25519 AAAA... macdroid-<дата>`
         */
        fun openSshLineFor(key: PublicKey): String {
            val dateStr = SimpleDateFormat("yyyyMMdd", Locale.US).format(Date())
            val comment = "macdroid-$dateStr"
            return try {
                val raw = PublicKeyEntry.toString(key).trim()
                if (raw.isNotEmpty() && parseSingleAuthorizedKey(raw) != null) {
                    "$raw $comment"
                } else {
                    Base64.getEncoder().encodeToString(key.encoded)
                }
            } catch (e: Exception) {
                Base64.getEncoder().encodeToString(key.encoded)
            }
        }
    }
}
