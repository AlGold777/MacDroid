package com.macandroid.filemanager

import android.app.Application
import net.i2p.crypto.eddsa.EdDSASecurityProvider
import java.security.Security

class CompanionApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val appHome = filesDir.absolutePath
        if (System.getProperty("user.home").isNullOrEmpty()) {
            System.setProperty("user.home", appHome)
        }
        if (Security.getProvider("EdDSA") == null) {
            Security.addProvider(EdDSASecurityProvider())
        }
    }
}
