package com.macandroid.filemanager.server

import android.content.Context
import android.util.Log
import com.macandroid.filemanager.runtime.SessionStateTracker
import com.macandroid.filemanager.storage.MediaSyncHelper
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

class CustomSftpEventListener(
    private val context: Context,
    private val mediaSyncHelper: MediaSyncHelper = MediaSyncHelper.getInstance(context)
) : AbstractSftpEventListenerAdapter() {

    companion object {
        private const val TAG = "CustomSftpListener"

        /**
         * Строгий контракт временных файлов (ТЗ 5.3):
         * - .<name>.mcdpart
         * - <name>.mcdpart
         * - .part.<id>.<name>
         * - .<name>.part
         *
         * Файлы вроде "my.part.notes.txt" НЕ соответствуют паттерну.
         */
        val PART_FILE_REGEX = Regex("""^(?:\.(.+)\.mcdpart|\.part\.[^.]+\.(.+)|(.+)\.mcdpart|(?:\.(.+)\.part))$""")

        fun isPartFile(filename: String): Boolean {
            return PART_FILE_REGEX.matches(filename)
        }
    }

    // Асинхронный scope для операций MediaSyncHelper с обработчиком ошибок
    private val ioScope = CoroutineScope(
        SupervisorJob() + Dispatchers.IO +
        CoroutineExceptionHandler { _, throwable ->
            Log.e(TAG, "Необработанное исключение в ioScope-хуке", throwable)
        }
    )

    /** Отмена фоновых операций при остановке сервера. */
    fun dispose() = gracefulDispose()

    fun gracefulDispose(timeoutMs: Long = 1500) {
        try {
            mediaSyncHelper.dispose()
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

    override fun initialized(session: ServerSession, version: Int) {
        SessionStateTracker.onSessionOpened()
    }

    override fun destroying(session: ServerSession) {
        SessionStateTracker.onSessionClosed()
    }

    override fun writing(
        session: ServerSession,
        remoteHandle: String,
        handle: FileHandle,
        offset: Long,
        data: ByteArray,
        dataOffset: Int,
        dataLen: Int
    ) {
        SessionStateTracker.recordIo()
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
        SessionStateTracker.recordIo()
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

            if (isPartFile(srcFile.name)) {
                // Асинхронное оповещение MediaScanner без блокировки сокета (ТЗ 5.1)
                ioScope.launch {
                    try {
                        mediaSyncHelper.notifyMediaScanner(dstFile.absolutePath)
                    } catch (e: Exception) {
                        Log.e(TAG, "notifyMediaScanner (moved) завершился ошибкой", e)
                    }
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
            // Очистка временных .mcdpart не является пользовательским удалением
            if (isPartFile(file.name)) return

            ioScope.launch {
                runCatching {
                    mediaSyncHelper.onFileDeleted(file)
                }.onFailure { Log.e(TAG, "onFileDeleted завершился ошибкой", it) }
            }
        }
    }

    /** Серверный GC осиротевших .mcdpart старше 24 ч */
    fun collectStalePartFiles(rootDirs: List<File>, olderThanMs: Long = 24L * 60 * 60 * 1000) {
        val now = System.currentTimeMillis()
        for (root in rootDirs) {
            try {
                if (!root.exists() || !root.isDirectory) continue
                root.walkTopDown()
                    .filter { isPartFile(it.name) && now - it.lastModified() > olderThanMs }
                    .forEach { part ->
                        if (part.delete()) {
                            Log.i(TAG, "GC: удалён осиротевший временный файл ${part.absolutePath}")
                        }
                    }
            } catch (e: Exception) {
                Log.w(TAG, "GC временных файлов по ${root.absolutePath} завершился ошибкой", e)
            }
        }
    }
}
