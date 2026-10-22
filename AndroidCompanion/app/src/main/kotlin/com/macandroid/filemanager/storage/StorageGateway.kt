package com.macandroid.filemanager.storage

import android.content.Context
import android.media.MediaScannerConnection
import android.util.Log
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
    companion object {
        private const val TAG = "StorageGateway"
    }

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
            } catch (e: Exception) {
                Log.w(TAG, "MediaStore: не удалось удалить запись", e)
            }
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
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore: не удалось удалить запись", e)
        }
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
            } catch (e: Exception) {
                Log.w(TAG, "MediaScanner: сбой пакета сканирования", e)
            }
        }
    }

    // Быстрый опрос медиа-каталога через MediaStore без медленного I/O обхода дерева
    fun queryMediaFolder(folderPath: String): String {
        val cleanPath = folderPath.trimEnd('/')
        val projection = arrayOf(
            android.provider.MediaStore.MediaColumns.DISPLAY_NAME,
            android.provider.MediaStore.MediaColumns.SIZE,
            android.provider.MediaStore.MediaColumns.DATE_MODIFIED,
            android.provider.MediaStore.MediaColumns.MIME_TYPE,
            android.provider.MediaStore.MediaColumns.DATA
        )
        val uri = android.provider.MediaStore.Files.getContentUri("external")
        // LIKE со спецсимволами пути (% и _ из имени папки) экранируем символом '\'
        val selection = "${android.provider.MediaStore.MediaColumns.DATA} LIKE ? ESCAPE '\\'"
        val selectionArgs = arrayOf(escapeLikePattern(cleanPath) + "/%")
        val sb = StringBuilder()
        
        try {
            context.contentResolver.query(
                uri,
                projection,
                selection,
                selectionArgs,
                "${android.provider.MediaStore.MediaColumns.DISPLAY_NAME} ASC"
            )?.use { cursor ->
                val nameCol = cursor.getColumnIndex(android.provider.MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeCol = cursor.getColumnIndex(android.provider.MediaStore.MediaColumns.SIZE)
                val dateCol = cursor.getColumnIndex(android.provider.MediaStore.MediaColumns.DATE_MODIFIED)
                val mimeCol = cursor.getColumnIndex(android.provider.MediaStore.MediaColumns.MIME_TYPE)
                val dataCol = cursor.getColumnIndex(android.provider.MediaStore.MediaColumns.DATA)

                while (cursor.moveToNext()) {
                    val filePath = if (dataCol >= 0) sanitizeField(cursor.getString(dataCol) ?: "") else ""
                    val name = if (nameCol >= 0) sanitizeField(cursor.getString(nameCol) ?: "") else ""
                    val size = if (sizeCol >= 0) cursor.getLong(sizeCol) else 0L
                    val mtime = if (dateCol >= 0) cursor.getLong(dateCol) else 0L
                    val mime = if (mimeCol >= 0) sanitizeField(cursor.getString(mimeCol) ?: "") else ""

                    if (name.isNotEmpty()) {
                        sb.append(name).append("\t")
                            .append(size).append("\t")
                            .append(mtime).append("\t")
                            .append(mime).append("\t")
                            .append(filePath).append("\n")
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "mediastore_query: сбой запроса MediaStore", e)
            return "ERROR: ${e.message}\n"
        }
        return sb.toString()
    }

    /** Экранирование спецсимволов LIKE: '\', '%' и '_'. */
    private fun escapeLikePattern(value: String): String {
        val out = StringBuilder(value.length)
        for (ch in value) {
            if (ch == '\\' || ch == '%' || ch == '_') out.append('\\')
            out.append(ch)
        }
        return out.toString()
    }

    /** Управляющие символы (включая \t, \n, \r) в полях построчного ответа заменяются пробелом. */
    private fun sanitizeField(value: String): String =
        value.replace(Regex("[\\u0000-\\u001F\\u007F]"), " ")
}
