package com.macandroid.filemanager.storage

import android.content.Context
import android.media.MediaScannerConnection
import android.provider.MediaStore
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.util.Collections

/**
 * Легковесный помощник синхронизации с системным MediaStore и MediaScanner (ТЗ 5.1).
 * Заменяет прежний write-only журнал Room и синхронную запись квитанций в сокете.
 * Сканирует обновлённые файлы и удаляет записи MediaStore для удалённых файлов.
 */
class MediaSyncHelper(private val context: Context) {

    companion object {
        private const val TAG = "MediaSyncHelper"
        private const val BATCH_THRESHOLD = 50
        private const val SCAN_DEBOUNCE_MS = 500L
        private const val SCAN_CHUNK_SIZE = 100

        @Volatile
        private var instance: MediaSyncHelper? = null

        fun getInstance(context: Context): MediaSyncHelper {
            return instance ?: synchronized(this) {
                instance ?: MediaSyncHelper(context.applicationContext).also { instance = it }
            }
        }
    }

    private val pendingScans = Collections.synchronizedList(mutableListOf<String>())
    private val scanScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var scanJob: Job? = null

    /**
     * Оповещение MediaScanner о добавлении или изменении файла с дебаунсом и батчингом.
     */
    fun notifyMediaScanner(path: String) {
        pendingScans.add(path)
        synchronized(pendingScans) {
            if (pendingScans.size >= BATCH_THRESHOLD) {
                flushMediaScans()
                return
            }
        }

        synchronized(this) {
            scanJob?.cancel()
            scanJob = scanScope.launch {
                delay(SCAN_DEBOUNCE_MS)
                flushMediaScans()
            }
        }
    }

    /**
     * Обработка удаления файла: удаление записи из системного MediaStore (чтобы не было битых превью)
     * и повторный скан пути.
     */
    fun onFileDeleted(file: File) {
        try {
            val uri = MediaStore.Files.getContentUri("external")
            context.contentResolver.delete(
                uri,
                "${MediaStore.MediaColumns.DATA} = ?",
                arrayOf(file.absolutePath)
            )
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore: не удалось удалить запись для ${file.absolutePath}", e)
        }
        notifyMediaScanner(file.absolutePath)
    }

    /**
     * Принудительная отправка накопленных путей на сканирование MediaScanner.
     */
    fun flushMediaScans() {
        val toScan: List<String>
        synchronized(pendingScans) {
            if (pendingScans.isEmpty()) return
            toScan = ArrayList(pendingScans)
            pendingScans.clear()
        }
        scanFilesBatch(toScan)
    }

    /**
     * Пакетное сканирование порциями по 100 путей (защита от TransactionTooLargeException в Binder).
     */
    fun scanFilesBatch(paths: List<String>) {
        if (paths.isEmpty()) return
        for (i in paths.indices step SCAN_CHUNK_SIZE) {
            val chunk = paths.subList(i, minOf(i + SCAN_CHUNK_SIZE, paths.size)).toTypedArray()
            try {
                MediaScannerConnection.scanFile(context, chunk, null) { path, uri ->
                    if (uri == null) {
                        Log.d(TAG, "MediaScanner: пропущен или не распознан: $path")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Ошибка вызова MediaScannerConnection.scanFile", e)
            }
        }
    }

    /**
     * Сброс отложенных сканирований при остановке сервера.
     */
    fun dispose() {
        synchronized(this) {
            scanJob?.cancel()
            scanJob = null
        }
        flushMediaScans()
    }
}
