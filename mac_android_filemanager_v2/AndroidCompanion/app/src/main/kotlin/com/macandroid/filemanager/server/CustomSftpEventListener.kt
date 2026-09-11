package com.macandroid.filemanager.server

import android.content.Context
import com.macandroid.filemanager.storage.StorageGateway
import kotlinx.coroutines.runBlocking
import org.apache.sshd.server.session.ServerSession
import org.apache.sshd.sftp.server.AbstractSftpEventListenerAdapter
import java.io.File
import java.nio.file.Path

class CustomSftpEventListener(
    private val context: Context,
    private val storageGateway: StorageGateway
) : AbstractSftpEventListenerAdapter() {

    override fun moving(session: ServerSession, src: Path, dst: Path, opts: Collection<Any>) {
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
