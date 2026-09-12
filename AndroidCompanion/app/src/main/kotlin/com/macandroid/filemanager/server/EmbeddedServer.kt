package com.macandroid.filemanager.server

import android.content.Context
import org.apache.sshd.common.file.virtualfs.VirtualFileSystemFactory
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.pubkey.PublickeyAuthenticator
import org.apache.sshd.server.keyprovider.SimpleGeneratorHostKeyProvider
import org.apache.sshd.sftp.server.SftpSubsystemFactory
import java.io.File
import java.nio.file.Paths
import java.security.PublicKey
import java.util.Base64
import java.util.Collections

class EmbeddedServer(
    private val context: Context,
    private val port: Int = 2222
) {
    private var sshd: SshServer? = null
    private val authorizedKeysFile = File(context.filesDir, "authorized_keys")

    fun start() {
        if (sshd != null) return

        if (System.getProperty("user.home").isNullOrEmpty()) {
            System.setProperty("user.home", context.filesDir.absolutePath)
        }

        sshd = SshServer.setUpDefaultServer().apply {
            this.port = this@EmbeddedServer.port

            // Хост-ключи сервера
            val hostKeyFile = File(context.filesDir, "hostkey.ser")
            keyPairProvider = SimpleGeneratorHostKeyProvider(hostKeyFile.toPath())

            // SEC-01 FIX: Отключаем парольный вход без авторизации.
            // Применяем строгую проверку открытого ключа (Public Key Auth)
            passwordAuthenticator = null

            publickeyAuthenticator = PublickeyAuthenticator { username, key: PublicKey, session ->
                val encodedKey = Base64.getEncoder().encodeToString(key.encoded)
                if (!authorizedKeysFile.exists() || authorizedKeysFile.length() == 0L) {
                    // SEC-03 FIX: Проверка источника подключения для защиты от несанкционированного TOFU.
                    // Через USB (ADB loopback 127.0.0.1) подключение локально доверенное.
                    // По Wi-Fi сопряжение разрешено только при активном экране/режиме сопряжения.
                    val clientAddress = session.clientAddress
                    val isLoopback = (clientAddress as? java.net.InetSocketAddress)?.address?.isLoopbackAddress == true
                    if (isLoopback || isPairingModeActive) {
                        authorizedKeysFile.writeText(encodedKey)
                        true
                    } else {
                        false
                    }
                } else {
                    // Последующие подключения сверяются со списком сохраненных доверенных ключей (по одному на строку)
                    val authorizedKeys = authorizedKeysFile.readLines()
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                    encodedKey in authorizedKeys
                }
            }

            // Корневой путь хранилища Android (поддержка внутренней памяти и SD/OTG карт)
            val rootPath = Paths.get("/storage")
            fileSystemFactory = VirtualFileSystemFactory(rootPath)

            // Обработка команд SSH exec (df, ping и служебные запросы MacHost)
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
                        if (trimmed.startsWith("df")) {
                            try {
                                val stat = android.os.StatFs(android.os.Environment.getExternalStorageDirectory().path)
                                val blockSize = stat.blockSizeLong
                                val totalBlocks = stat.blockCountLong
                                val availBlocks = stat.availableBlocksLong
                                val totalBytes = totalBlocks * blockSize
                                val availBytes = availBlocks * blockSize
                                val usedBytes = totalBytes - availBytes

                                val output = "Filesystem 1B-blocks Used Available Use% Mounted on\n" +
                                        "/storage/emulated/0 $totalBytes $usedBytes $availBytes 50% /storage/emulated/0\n"
                                outStream?.write(output.toByteArray(java.nio.charset.StandardCharsets.UTF_8))
                                outStream?.flush()
                                exitCallback?.onExit(0)
                            } catch (e: Exception) {
                                outStream?.write("df error: ${e.message}\n".toByteArray(java.nio.charset.StandardCharsets.UTF_8))
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
            sftpFactory.addSftpEventListener(CustomSftpEventListener(context))
            subsystemFactories = Collections.singletonList(sftpFactory)

            // Perf fix: Увеличиваем буферы I/O и SSH channel window.
            // Apache SSHD: пакет 320 КБ (для 256 КБ SFTP чанка + SFTP и SSH заголовки),
            // окно 8 МБ для непрерывного pipelining без частых ожиданий window-adjust ACK.
            val serverProps = this.properties
            serverProps["io-buffer-size"] = (320 * 1024).toString()
            serverProps["window-size"] = (8L * 1024 * 1024).toString()
            serverProps["max-packet-length"] = (320 * 1024).toString()
        }

        sshd?.start()
    }

    fun stop() {
        sshd?.stop(true)
        sshd = null
    }

    /**
     * Сброс сопряжения: удаляет файл authorized_keys,
     * чтобы при следующем подключении сработал механизм TOFU.
     * @return true, если файл был успешно удален или не существовал
     */
    fun resetPairing(): Boolean {
        return if (authorizedKeysFile.exists()) {
            authorizedKeysFile.delete()
        } else {
            true
        }
    }

    /**
     * Проверяет наличие сохраненных доверенных ключей (статус сопряжения).
     */
    fun isPaired(): Boolean {
        return authorizedKeysFile.exists() && authorizedKeysFile.length() > 0L
    }

    companion object {
        @Volatile
        var isPairingModeActive: Boolean = true
    }
}
