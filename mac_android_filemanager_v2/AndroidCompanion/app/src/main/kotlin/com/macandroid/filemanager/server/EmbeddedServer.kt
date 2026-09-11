package com.macandroid.filemanager.server

import android.content.Context
import com.macandroid.filemanager.storage.StorageGateway
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.password.AcceptAllPasswordAuthenticator
import org.apache.sshd.server.keyprovider.SimpleGeneratorHostKeyProvider
import org.apache.sshd.sftp.server.SftpSubsystemFactory
import java.io.File

class EmbeddedServer(
    private val context: Context,
    private val port: Int = 2222
) {
    private var sshd: SshServer? = null
    private val storageGateway = StorageGateway(context)

    fun start() {
        if (sshd != null) return
        sshd = SshServer.setUpDefaultServer().apply {
            this.port = this@EmbeddedServer.port
            keyPairProvider = SimpleGeneratorHostKeyProvider(File(context.filesDir, "host_ed25519.ser").toPath())
            passwordAuthenticator = AcceptAllPasswordAuthenticator.INSTANCE
            
            val sftpFactory = SftpSubsystemFactory()
            sftpFactory.addSftpEventListener(CustomSftpEventListener(context, storageGateway))
            subsystemFactories = listOf(sftpFactory)
        }
        sshd?.start()
    }

    fun stop() {
        sshd?.stop()
        sshd = null
    }
}
