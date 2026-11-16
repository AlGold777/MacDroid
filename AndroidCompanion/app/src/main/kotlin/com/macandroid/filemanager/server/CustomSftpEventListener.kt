package com.macandroid.filemanager.server

import android.content.Context
import android.content.Intent
import android.util.Log
import com.macandroid.filemanager.runtime.FileDaemonService
import com.macandroid.filemanager.storage.StorageGateway
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
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

    // C1: Асинхронный scope для операций StorageGateway с обработчиком ошибок
    private val ioScope = CoroutineScope(
        SupervisorJob() + Dispatchers.IO +
        CoroutineExceptionHandler { _, throwable ->
            Log.e(TAG, "Необработанное исключение в ioScope-хуке", throwable)
        }
    )

    /** Отмена фоновых операций при остановке сервера. */
    fun dispose() = gracefulDispose()

    // M20 (MUX): остановка/перепривязка ждёт завершения pending-квитанций
    // и отложенного MediaScanner-скана вместо мгновенной отмены очереди
    fun gracefulDispose(timeoutMs: Long = 1500) {
        try {
            runBlocking {
                withTimeoutOrNull(timeoutMs) {
                    ioScope.coroutineContext[Job]?.let { job ->
                        job.children.forEach { it.join() }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "gracefulDispose: ожидание очереди завершилось ошибкой", e)
        } finally {
            ioScope.cancel()
        }
    }

    private fun setSyncActive(active: Boolean, sessionCount: Int = 0) {
        try {
            val intent = Intent(context, FileDaemonService::class.java).apply {
                action = if (active) {
                    FileDaemonService.ACTION_ACTIVE_SYNC_START
                } else {
                    FileDaemonService.ACTION_ACTIVE_SYNC_STOP
                }
                putExtra(FileDaemonService.EXTRA_SESSION_COUNT, sessionCount)
            }
            context.startService(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Не удалось отправить сигнал активной передачи сервису", e)
        }
    }

    override fun initialized(session: ServerSession, version: Int) {
        val count = activeSessions.incrementAndGet()
        setSyncActive(true, count)
    }

    override fun destroying(session: ServerSession) {
        val left = activeSessions.updateAndGet { if (it > 0) it - 1 else 0 }
        if (left == 0) {
            setSyncActive(false, 0)
        } else {
            setSyncActive(true, left)
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
        // L21 (MUX): elapsedRealtime() вместо wall-clock
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastWakeLockPing > 30_000L) {
            lastWakeLockPing = now
            setSyncActive(true, activeSessions.get())
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
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastWakeLockPing > 30_000L) {
            lastWakeLockPing = now
            setSyncActive(true, activeSessions.get())
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

            // H4 (MUX): строго суффикс .mcdpart от MacHost (без ложных срабатываний на *.part.*)
            val isPart = srcFile.name.endsWith(".mcdpart")
            if (isPart) {
                val actionId = srcFile.name.removePrefix(".").substringBeforeLast(".mcdpart")
                // C3 (Qwen): синхронная запись квитанции до ACK rename
                try {
                    storageGateway.recordCommitSync(
                        actionId = "mv_${actionId}_${System.nanoTime()}",
                        requestHash = "sftp_rename_$actionId",
                        sourcePath = srcFile.absolutePath,
                        finalTargetFile = dstFile
                    )
                } catch (e: Exception) {
                    Log.e(TAG, "recordCommitSync (moved) завершился ошибкой", e)
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
            // C2 (Qwen/PT-3): очистка временных .mcdpart самим оркестратором не является пользовательским удалением
            if (file.name.endsWith(".mcdpart")) return
            val actionId = "del_${file.name}_${System.nanoTime()}"
            ioScope.launch {
                runCatching {
                    storageGateway.recordDeletion(
                        actionId = actionId,
                        requestHash = "sftp_remove_${file.name}",
                        deletedFile = file
                    )
                }.onFailure { Log.e(TAG, "recordDeletion завершился ошибкой", it) }
            }
        }
    }

    // M22 (MUX): серверный GC осиротевших .mcdpart старше 24 ч
    fun collectStalePartFiles(rootDirs: List<File>, olderThanMs: Long = 24L * 60 * 60 * 1000) {
        val now = System.currentTimeMillis()
        for (root in rootDirs) {
            try {
                if (!root.exists() || !root.isDirectory) continue
                root.walkTopDown()
                    .filter { it.name.endsWith(".mcdpart") && now - it.lastModified() > olderThanMs }
                    .forEach { part ->
                        if (part.delete()) {
                            Log.i(TAG, "GC: удалён осиротевший .mcdpart ${part.absolutePath}")
                        }
                    }
            } catch (e: Exception) {
                Log.w(TAG, "GC .mcdpart по ${root.absolutePath} завершился ошибкой", e)
            }
        }
    }
}
