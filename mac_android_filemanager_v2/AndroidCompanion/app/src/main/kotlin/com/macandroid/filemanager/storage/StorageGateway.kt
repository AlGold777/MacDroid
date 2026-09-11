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
            MediaScannerConnection.scanFile(
                context,
                arrayOf(finalTargetFile.absolutePath),
                null
            ) { _, _ -> }
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
        }
        return deleted
    }
}
