package com.macandroid.filemanager.server

import android.content.Context
import android.content.Intent
import android.util.Log
import com.macandroid.filemanager.runtime.FileDaemonService
import com.macandroid.filemanager.storage.StorageGateway
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.apache.sshd.server.session.ServerSession
import org.apache.sshd.sftp.server.AbstractSftpEventListenerAdapter
import org.apache.sshd.sftp.server.FileHandle
import java.io.File
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicInteger

class CustomSftpEventListener(
    private val context: Context,
    private val storageGateway: StorageGateway = StorageGateway(context)
) : AbstractSftpEventListenerAdapter() {

    companion object {
        private const val TAG = "CustomSftpListener"
    }

    private val activeSessions = AtomicInteger(0)

    // Асинхронный scope для операций StorageGateway (SQLite + MediaScanner)
    // вместо runBlocking, который блокировал SSH-воркер
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Отмена фоновых операций при остановке сервера. */
    fun dispose() {
        ioScope.cancel()
    }

    private fun setSyncActive(active: Boolean) {
        try {
            val intent = Intent(context, FileDaemonService::class.java).apply {
                action = if (active) {
                    FileDaemonService.ACTION_ACTIVE_SYNC_START
                } else {
                    FileDaemonService.ACTION_ACTIVE_SYNC_STOP
                }
            }
            context.startService(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Не удалось отправить сигнал активной передачи сервису", e)
        }
    }

    override fun initialized(session: ServerSession, version: Int) {
        activeSessions.incrementAndGet()
        setSyncActive(true)
    }

    override fun destroying(session: ServerSession) {
        // Атомарное уменьшение без потери параллельных инкрементов
        val left = activeSessions.updateAndGet { if (it > 0) it - 1 else 0 }
        if (left == 0) {
            setSyncActive(false)
        }
    }

    @Volatile
    private var lastWakeLockPing: Long = 0

    override fun writing(
        session: ServerSession,
        remoteHandle: String,
        handle: FileHandle,
        offset: Long,
        data: ByteArray,
        dataOffset: Int,
        dataLen: Int
    ) {
        // Продлеваем WakeLock во время активной передачи не чаще раза в 30 секунд (предотвращает засыпание при долгих передачах без IPC флуда)
        val now = System.currentTimeMillis()
        if (now - lastWakeLockPing > 30_000L) {
            lastWakeLockPing = now
            setSyncActive(true)
        }
    }

    override fun reading(
        session: ServerSession,
        remoteHandle: String,
        handle: FileHandle,
        offset: Long,
        data: ByteArray,
        dataOffset: Int,
        dataLen: Int
    ) {
        val now = System.currentTimeMillis()
        if (now - lastWakeLockPing > 30_000L) {
            lastWakeLockPing = now
            setSyncActive(true)
        }
    }

    override fun moved(
        session: ServerSession,
        src: Path,
        dst: Path,
        opts: Collection<java.nio.file.CopyOption>,
        thrown: Throwable?
    ) {
        if (thrown == null) {
            val srcFile = src.toFile()
            val dstFile = dst.toFile()

            // Перехват успешного переименования временного файла (.part или .mcdpart от MacHost) в целевое имя
            val isPart = srcFile.name.contains(".part.") || srcFile.name.endsWith(".mcdpart") || srcFile.name.contains(".mcdpart")
            if (isPart) {
                val actionId = if (srcFile.name.contains(".part.")) {
                    srcFile.name.substringAfter(".part.")
                } else {
                    srcFile.name.removePrefix(".").substringBeforeLast(".mcdpart")
                }
                // Perf fix: асинхронный launch вместо runBlocking,
                // чтобы не блокировать SSH-воркер на время SQLite + MediaScanner
                // actionId берётся из имени файла, которое задаёт клиент: делаем ключ уникальным,
                // чтобы повторное имя не перезаписывало чужую квитанцию (REPLACE в журнале)
                val receiptId = "mv_${actionId}_${System.nanoTime()}"
                ioScope.launch {
                    storageGateway.recordCommit(
                        actionId = receiptId,
                        requestHash = "sftp_rename_$actionId",
                        sourcePath = srcFile.absolutePath,
                        finalTargetFile = dstFile
                    )
                }
            }
        }
    }

    override fun removed(
        session: ServerSession,
        path: Path,
        isDirectory: Boolean,
        thrown: Throwable?
    ) {
        if (thrown == null) {
            val file = path.toFile()
            val actionId = "del_${file.name}_${System.nanoTime()}"
            // Perf fix: асинхронный launch вместо runBlocking
            ioScope.launch {
                storageGateway.recordDeletion(
                    actionId = actionId,
                    requestHash = "sftp_remove_${file.name}",
                    deletedFile = file
                )
            }
        }
    }
}
