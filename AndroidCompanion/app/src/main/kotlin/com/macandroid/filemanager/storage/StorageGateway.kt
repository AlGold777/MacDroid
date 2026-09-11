package com.macandroid.filemanager.storage

import android.content.Context
import android.media.MediaScannerConnection
import com.macandroid.filemanager.data.ActionJournalDb
import com.macandroid.filemanager.data.ActionReceipt
import java.io.File

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

    // Одиночное сканирование с обработкой ошибок
    fun notifyMediaScanner(path: String) {
        try {
            MediaScannerConnection.scanFile(
                context,
                arrayOf(path),
                null
            ) { _, _ -> }
        } catch (ignored: Exception) {}
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
