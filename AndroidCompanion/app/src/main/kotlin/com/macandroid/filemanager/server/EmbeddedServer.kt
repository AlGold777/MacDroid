package com.macandroid.filemanager.server

import android.content.Context
import android.util.Log
import com.macandroid.filemanager.storage.StorageGateway
import org.apache.sshd.common.AttributeRepository
import org.apache.sshd.common.config.keys.AuthorizedKeyEntry
import org.apache.sshd.common.config.keys.KeyUtils
import org.apache.sshd.common.file.virtualfs.VirtualFileSystemFactory
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.pubkey.PublickeyAuthenticator
import org.apache.sshd.server.keyprovider.SimpleGeneratorHostKeyProvider
import org.apache.sshd.sftp.server.SftpSubsystemFactory
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.nio.file.Paths
import java.security.PublicKey
import java.util.Base64
import java.util.Collections

/**
 * SFTP/SSH-сервер телефона. Слушает только Wi-Fi-адрес (wlan*), если он определён;
 * иначе (Wi-Fi недоступен) — все интерфейсы (поведение по решению, см. документацию).
 *
 * @param bindHost адрес для прослушивания; null — все интерфейсы.
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

        if (System.getProperty("user.home").isNullOrEmpty()) {
            System.setProperty("user.home", context.filesDir.absolutePath)
        }

        val server = SshServer.setUpDefaultServer().apply {
            this.port = this@EmbeddedServer.port
            // Кроме Wi-Fi адреса слушаем loopback: через него идёт `adb forward` (подключение по кабелю).
            // MINA SSHD принимает список адресов через запятую.
            bindHost?.let { this.host = "$it,127.0.0.1" }

            // Хост-ключи сервера
            val hostKeyFile = File(context.filesDir, "hostkey.ser")
            keyPairProvider = SimpleGeneratorHostKeyProvider(hostKeyFile.toPath())

            // SEC-01 FIX: Отключаем парольный вход без авторизации.
            // Применяем строгую проверку открытого ключа (Public Key Auth)
            passwordAuthenticator = null

            publickeyAuthenticator = PublickeyAuthenticator { _, key: PublicKey, session ->
                var accepted = false
                synchronized(pairingLock) {
                    val encodedKey = Base64.getEncoder().encodeToString(key.encoded)
                    if (!authorizedKeysFile.exists() || authorizedKeysFile.length() == 0L) {
                        // Первый ключ принимается только в окне сопряжения, окно закрывается сразу после записи.
                        if (isPairingModeActive) {
                            authorizedKeysFile.writeText(encodedKey + "\n")
                            closePairingWindow()
                            accepted = true
                        }
                    } else {
                        // Последующие подключения должны совпадать с уже сохранёнными ключами.
                        val authorizedKeys = authorizedKeysFile.readLines()
                            .map { it.trim() }
                            .filter { it.isNotEmpty() }

                        val knownKey = if (encodedKey in authorizedKeys) {
                            true
                        } else {
                            authorizedKeys.any { line ->
                                line.startsWith("ssh-") && try {
                                    val entry = AuthorizedKeyEntry.parseAuthorizedKeyEntry(line)
                                    val resolved = entry?.resolvePublicKey(null, null, null)
                                    resolved != null && KeyUtils.compareKeys(key, resolved)
                                } catch (e: Exception) {
                                    Log.w(TAG, "Не удалось разобрать строку authorized_keys", e)
                                    false
                                }
                            }
                        }
                        accepted = knownKey
                    }
                }
                // Право на authorize_key получают только сессии, принятые в окне сопряжения (первый ключ)
                // либо вошедшие уже сохранённым ключом (миграция legacy-устройств при закрытом окне).
                session.setAttribute(ENROLLED_SESSION_KEY, accepted)
                accepted
            }

            // Корневой путь хранилища Android (поддержка внутренней памяти и SD/OTG карт).
            // Принятый риск: корень целиком /storage (Android/data и obb на API 30+ недоступны и так);
            // сужение до allowlist ломает доступ к SD/OTG-картам и не делается в этом исправлении.
            val rootPath = Paths.get("/storage")
            fileSystemFactory = VirtualFileSystemFactory(rootPath)

            // Обработка команд SSH exec (df, ping, authorize_key и служебные запросы MacHost)
            commandFactory = org.apache.sshd.server.command.CommandFactory { _, command ->
                object : org.apache.sshd.server.command.Command {
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
                                // Реальный процент занятости (округление вверх, как в coreutils df)
                                val usedPercent = if (totalBytes > 0) (usedBytes * 100 + totalBytes - 1) / totalBytes else 0L

                                val output = "Filesystem 1B-blocks Used Available Use% Mounted on\n" +
                                        "/storage/emulated/0 $totalBytes $usedBytes $availBytes $usedPercent% /storage/emulated/0\n"
                                outStream?.write(output.toByteArray(java.nio.charset.StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(0)
                            } catch (e: Exception) {
                                Log.e(TAG, "df: ошибка чтения StatFs", e)
                                outStream?.write("df error: ${e.message}\n".toByteArray(java.nio.charset.StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(1)
                            }
                        } else if (trimmed.startsWith("authorize_key ")) {
                            val newKey = trimmed.substringAfter("authorize_key ").trim()
                            val sessionEnrolled = channel?.session?.getAttribute(ENROLLED_SESSION_KEY) == true
                            if (!isPairingModeActive && !sessionEnrolled) {
                                outStream?.write("ERROR_NOT_ALLOWED\n".toByteArray(java.nio.charset.StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(1)
                            } else if (newKey.isEmpty()) {
                                outStream?.write("ERROR_EMPTY_KEY\n".toByteArray(java.nio.charset.StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(1)
                            } else if (parseSingleAuthorizedKey(newKey) == null) {
                                outStream?.write("ERROR_INVALID_KEY\n".toByteArray(java.nio.charset.StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(1)
                            } else {
                                try {
                                    synchronized(pairingLock) {
                                        val currentKeys = if (authorizedKeysFile.exists()) {
                                            authorizedKeysFile.readLines().map { it.trim() }.filter { it.isNotEmpty() }
                                        } else {
                                            emptyList()
                                        }
                                        if (!currentKeys.contains(newKey)) {
                                            authorizedKeysFile.appendText(newKey + "\n")
                                        }
                                    }
                                    outStream?.write("AUTHORIZED_OK\n".toByteArray(java.nio.charset.StandardCharsets.UTF_8))
                                    outStream?.flush()
                                    exitCallback?.onExit(0)
                                } catch (e: Exception) {
                                    Log.e(TAG, "authorize_key: не удалось записать authorized_keys", e)
                                    outStream?.write("ERROR: ${e.message}\n".toByteArray(java.nio.charset.StandardCharsets.UTF_8))
                                    outStream?.flush()
                                    exitCallback?.onExit(1)
                                }
                            }
                        } else if (trimmed.startsWith("mediastore_query ")) {
                            val folder = trimmed.substringAfter("mediastore_query ").trim()
                            try {
                                val storageGateway = StorageGateway(context)
                                val result = storageGateway.queryMediaFolder(folder)
                                outStream?.write(result.toByteArray(java.nio.charset.StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(0)
                            } catch (e: Exception) {
                                Log.e(TAG, "mediastore_query: ошибка запроса", e)
                                outStream?.write("ERROR: ${e.message}\n".toByteArray(java.nio.charset.StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(1)
                            }
                        } else {
                            outStream?.write("OK\n".toByteArray(java.nio.charset.StandardCharsets.UTF_8))
                            outStream?.flush()
                            exitCallback?.onExit(0)
                        }
                    }

                    override fun destroy(channel: org.apache.sshd.server.channel.ChannelSession?) {}
                }
            }

            // SFTP Subsystem с перехватчиком событий коммита
            val sftpFactory = SftpSubsystemFactory.Builder()
                .build()
            val listener = CustomSftpEventListener(context)
            sftpListener = listener
            sftpFactory.addSftpEventListener(listener)
            subsystemFactories = Collections.singletonList(sftpFactory)

            // Perf & FS Limiter: Увеличиваем буферы I/O и SSH channel window, ограничиваем дескрипторы для защиты памяти
            // Apache SSHD: пакет 320 КБ (для 256 КБ SFTP чанка + SFTP и SSH заголовки),
            // окно 8 МБ для непрерывного pipelining без частых ожиданий window-adjust ACK.
            val serverProps = this.properties
            serverProps["io-buffer-size"] = (320 * 1024).toString()
            serverProps["window-size"] = (8L * 1024 * 1024).toString()
            serverProps["max-packet-length"] = (320 * 1024).toString()
            // Property names verified against Apache MINA SSHD 2.12.0 SftpModuleProperties.
            serverProps["max-open-handles-per-session"] = "32"
            serverProps["sftp-fs-read-buffer-size"] = (256 * 1024).toString()
            serverProps["sftp-fs-write-buffer-size"] = (256 * 1024).toString()
            serverProps["sftp-max-readdata-packet-length"] = (256 * 1024).toString()
            serverProps["sftp-max-writedata-packet-length"] = (256 * 1024).toString()
        }

        try {
            server.start()
        } catch (e: Exception) {
            sftpListener?.dispose()
            sftpListener = null
            throw e
        }
        sshd = server
        liveSshd = server
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
     * Сброс сопряжения: удаляет файл authorized_keys, закрывает живые SSH-сессии,
     * чтобы при следующем подключении сработал механизм сопряжения (TOFU).
     * @return true, если файл был успешно удален или не существовал
     */
    fun resetPairing(): Boolean {
        closePairingWindow()
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
     * Проверяет наличие сохраненных доверенных ключей (статус сопряжения).
     */
    fun isPaired(): Boolean {
        return authorizedKeysFile.exists() && authorizedKeysFile.length() > 0L
    }

    /**
     * SHA256-отпечаток хост-ключа sshd в формате `ssh-keygen -lf` (SHA256:...).
     * Читает тот же hostkey.ser, что и сервер; null, если ключ ещё не создан.
     */
    fun hostKeyFingerprint(): String? {
        val hostKeyFile = File(context.filesDir, "hostkey.ser")
        if (!hostKeyFile.exists()) return null
        return try {
            val keyPair = SimpleGeneratorHostKeyProvider(hostKeyFile.toPath()).loadKeys(null).firstOrNull()
            keyPair?.public?.let { KeyUtils.getFingerPrint(it) }
        } catch (e: Exception) {
            Log.w(TAG, "Не удалось прочитать отпечаток хост-ключа", e)
            null
        }
    }

    companion object {
        private const val TAG = "EmbeddedServer"
        private const val PAIRING_WINDOW_MILLIS = 60_000L

        /** Общий lock на файл authorized_keys (auth, authorize_key, сброс). */
        private val pairingLock = Any()

        /** Признак сессии, вошедшей уже сохранённым ключом. */
        private val ENROLLED_SESSION_KEY = AttributeRepository.AttributeKey<Boolean>()

        /** Запущенный sshd (для закрытия живых сессий из других экземпляров, например MainActivity). */
        @Volatile
        private var liveSshd: SshServer? = null

        @Volatile
        private var pairingWindowEndsAt: Long = 0L

        val isPairingModeActive: Boolean
            get() = android.os.SystemClock.elapsedRealtime() < pairingWindowEndsAt

        fun openPairingWindow() {
            pairingWindowEndsAt = android.os.SystemClock.elapsedRealtime() + PAIRING_WINDOW_MILLIS
        }

        fun closePairingWindow() {
            pairingWindowEndsAt = 0L
        }

        /**
         * IPv4-адрес активного Wi-Fi-интерфейса (wlan*), без loopback. null, если определить нельзя.
         */
        fun findWifiIpv4Address(): String? {
            return try {
                Collections.list(NetworkInterface.getNetworkInterfaces())
                    .filter { it.isUp && !it.isLoopback && it.name.startsWith("wlan", ignoreCase = true) }
                    .flatMap { Collections.list(it.inetAddresses) }
                    .firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
                    ?.hostAddress
            } catch (e: Exception) {
                Log.w(TAG, "Не удалось определить адрес Wi-Fi", e)
                null
            }
        }

        /**
         * Одна строка открытого ключа в формате authorized_keys (без переводов строк).
         * @return разобранный публичный ключ или null, если строка некорректна.
         */
        private fun parseSingleAuthorizedKey(line: String): PublicKey? {
            if (line.contains('\n') || line.contains('\r')) return null
            if (!line.startsWith("ssh-") && !line.startsWith("ecdsa-sha2-")) return null
            return try {
                AuthorizedKeyEntry.parseAuthorizedKeyEntry(line)?.resolvePublicKey(null, null, null)
            } catch (e: Exception) {
                Log.w(TAG, "authorize_key: строка ключа не разобрана", e)
                null
            }
        }
    }
}
