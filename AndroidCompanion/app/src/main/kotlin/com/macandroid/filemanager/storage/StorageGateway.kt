package com.macandroid.filemanager.storage

import android.content.Context
import android.media.MediaScannerConnection
import com.macandroid.filemanager.data.ActionJournalDb
import com.macandroid.filemanager.data.ActionReceipt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.util.Collections

class StorageGateway(private val context: Context) {
    private val db = ActionJournalDb.getDatabase(context)
    private val dao = db.actionReceiptDao()

    suspend fun commitFileAtomic(
        actionId: String,
        requestHash: String,
        tempPartFile: File,
        finalTargetFile: File
    ): Boolean {
        // Проверка идемпотентности: возможно операция уже была закоммичена
        val existing = dao.getReceipt(actionId)
        if (existing != null && existing.status == "COMMITTED" && finalTargetFile.exists()) {
            return true
        }

        // Атомарное переименование
        val renamed = tempPartFile.renameTo(finalTargetFile)
        if (renamed) {
            val receipt = ActionReceipt(
                actionId = actionId,
                requestHash = requestHash,
                sourcePath = tempPartFile.absolutePath,
                targetPath = finalTargetFile.absolutePath,
                status = "COMMITTED",
                timestamp = System.currentTimeMillis()
            )
            dao.insertReceipt(receipt)

            // Уведомление системной медиатеки Android о новом файле
            notifyMediaScanner(finalTargetFile.absolutePath)
            return true
        }
        return false
    }

    suspend fun deleteFileVerified(
        actionId: String,
        requestHash: String,
        fileToDelete: File
    ): Boolean {
        if (!fileToDelete.exists()) {
            return true // Идемпотентно считаем удаленным
        }
        val deleted = fileToDelete.delete()
        if (deleted) {
            val receipt = ActionReceipt(
                actionId = actionId,
                requestHash = requestHash,
                sourcePath = fileToDelete.absolutePath,
                targetPath = "",
                status = "DELETED",
                timestamp = System.currentTimeMillis()
            )
            dao.insertReceipt(receipt)

            // Удаление записи из системного каталога MediaStore, чтобы исключить 'битые' превью
            try {
                val uri = android.provider.MediaStore.Files.getContentUri("external")
                context.contentResolver.delete(
                    uri,
                    "${android.provider.MediaStore.MediaColumns.DATA} = ?",
                    arrayOf(fileToDelete.absolutePath)
                )
            } catch (ignored: Exception) {}
            notifyMediaScanner(fileToDelete.absolutePath)
        }
        return deleted
    }

    suspend fun recordCommit(
        actionId: String,
        requestHash: String,
        sourcePath: String,
        finalTargetFile: File
    ) {
        val receipt = ActionReceipt(
            actionId = actionId,
            requestHash = requestHash,
            sourcePath = sourcePath,
            targetPath = finalTargetFile.absolutePath,
            status = "COMMITTED",
            timestamp = System.currentTimeMillis()
        )
        dao.insertReceipt(receipt)
        notifyMediaScanner(finalTargetFile.absolutePath)
    }

    suspend fun recordDeletion(
        actionId: String,
        requestHash: String,
        deletedFile: File
    ) {
        val receipt = ActionReceipt(
            actionId = actionId,
            requestHash = requestHash,
            sourcePath = deletedFile.absolutePath,
            targetPath = "",
            status = "DELETED",
            timestamp = System.currentTimeMillis()
        )
        dao.insertReceipt(receipt)

        // Удаление записи из системного каталога MediaStore, чтобы исключить 'битые' превью
        try {
            val uri = android.provider.MediaStore.Files.getContentUri("external")
            context.contentResolver.delete(
                uri,
                "${android.provider.MediaStore.MediaColumns.DATA} = ?",
                arrayOf(deletedFile.absolutePath)
            )
        } catch (ignored: Exception) {}
        notifyMediaScanner(deletedFile.absolutePath)
    }

    // Буфер для пакетирования запросов сканирования MediaScanner
    private val pendingScans = Collections.synchronizedList(mutableListOf<String>())
    private val scanScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var scanJob: Job? = null

    // Одиночное или пакетное сканирование с умным дебаунсом (500 мс или по достижении 50 файлов)
    fun notifyMediaScanner(path: String) {
        pendingScans.add(path)
        synchronized(pendingScans) {
            if (pendingScans.size >= 50) {
                flushMediaScans()
                return
            }
        }
        
        synchronized(this) {
            scanJob?.cancel()
            scanJob = scanScope.launch {
                delay(500)
                flushMediaScans()
            }
        }
    }

    fun flushMediaScans() {
        val toScan: List<String>
        synchronized(pendingScans) {
            if (pendingScans.isEmpty()) return
            toScan = ArrayList(pendingScans)
            pendingScans.clear()
        }
        scanFilesBatch(toScan)
    }

    // Пакетное сканирование порциями по 100 путей (защита от TransactionTooLargeException в Binder)
    fun scanFilesBatch(paths: List<String>) {
        if (paths.isEmpty()) return
        paths.chunked(100).forEach { chunk ->
            try {
                MediaScannerConnection.scanFile(
                    context,
                    chunk.toTypedArray(),
                    null
                ) { _, _ -> }
            } catch (ignored: Exception) {}
        }
    }
}
