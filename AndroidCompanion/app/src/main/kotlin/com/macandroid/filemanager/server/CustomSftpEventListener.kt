package com.macandroid.filemanager.server

import android.content.Context
import android.content.Intent
import com.macandroid.filemanager.runtime.FileDaemonService
import com.macandroid.filemanager.storage.StorageGateway
import kotlinx.coroutines.runBlocking
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

    private val activeSessions = AtomicInteger(0)

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
        } catch (ignored: Exception) {}
    }

    override fun initialized(session: ServerSession, version: Int) {
        if (activeSessions.incrementAndGet() > 0) {
            setSyncActive(true)
        }
    }

    override fun destroying(session: ServerSession) {
        if (activeSessions.decrementAndGet() <= 0) {
            activeSessions.set(0)
            setSyncActive(false)
        }
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
        // Подтверждение активности при передаче байтов
        setSyncActive(true)
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
        // Подтверждение активности при чтении
        setSyncActive(true)
    }

    override fun moving(session: ServerSession, src: Path, dst: Path, opts: Collection<java.nio.file.CopyOption>) {
        val srcFile = src.toFile()
        val dstFile = dst.toFile()

        // Перехват атомарного переименования временного файла .part в целевое имя
        if (srcFile.name.contains(".part.")) {
            val actionId = srcFile.name.substringAfter(".part.")
            runBlocking {
                storageGateway.commitFileAtomic(
                    actionId = actionId,
                    requestHash = "sftp_rename_$actionId",
                    tempPartFile = srcFile,
                    finalTargetFile = dstFile
                )
            }
        }
    }

    override fun removing(session: ServerSession, path: Path, isDirectory: Boolean) {
        val file = path.toFile()
        val actionId = "del_${file.name}_${System.currentTimeMillis()}"
        runBlocking {
            storageGateway.deleteFileVerified(
                actionId = actionId,
                requestHash = "sftp_remove_${file.name}",
                fileToDelete = file
            )
        }
    }
}
