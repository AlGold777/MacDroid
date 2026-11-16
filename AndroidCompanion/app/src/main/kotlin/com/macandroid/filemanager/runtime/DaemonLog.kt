package com.macandroid.filemanager.runtime

import android.content.Context
import android.util.Log
import java.io.File
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter

/**
 * Журнал событий демона (запуск, стоп, сбои, перезапуски по пробе).
 * Файл: getExternalFilesDir(null)/daemon.log — доступен для чтения с Mac по SFTP.
 * При превышении 256 КБ оставляются последние ~128 КБ.
 */
object DaemonLog {
    private const val TAG = "DaemonLog"
    private const val FILE_NAME = "daemon.log"
    private const val MAX_BYTES = 256L * 1024
    private const val KEEP_BYTES = 128 * 1024
    private const val NEWLINE: Byte = 10
    private val FORMATTER = DateTimeFormatter.ISO_OFFSET_DATE_TIME

    /** Дописывает строку «ISO-время сообщение». Ошибки только логируются. */
    @Synchronized
    fun write(context: Context, message: String) {
        try {
            val dir = context.getExternalFilesDir(null) ?: return
            val file = File(dir, FILE_NAME)
            if (file.exists() && file.length() > MAX_BYTES) trim(file)
            val time = OffsetDateTime.now().format(FORMATTER)
            file.appendText("$time $message\n", Charsets.UTF_8)
        } catch (e: Exception) {
            Log.w(TAG, "Не удалось записать daemon.log", e)
        }
    }

    /** Оставляет последние ~KEEP_BYTES байт, начиная с целой строки. */
    internal fun trim(file: File) {
        val bytes = file.readBytes()
        var start = maxOf(0, bytes.size - KEEP_BYTES)
        while (start < bytes.size && bytes[start] != NEWLINE) start++
        val from = (start + 1).coerceAtMost(bytes.size)
        file.writeBytes(bytes.copyOfRange(from, bytes.size))
    }
}
