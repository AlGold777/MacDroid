package com.macandroid.filemanager

import android.app.Application

class CompanionApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val appHome = filesDir.absolutePath
        if (System.getProperty("user.home").isNullOrEmpty()) {
            System.setProperty("user.home", appHome)
        }
    }
}
