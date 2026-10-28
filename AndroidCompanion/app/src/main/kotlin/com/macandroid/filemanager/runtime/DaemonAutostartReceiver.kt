package com.macandroid.filemanager.runtime

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Поднимает FileDaemonService без открытия приложения: после перезагрузки телефона
 * (BOOT_COMPLETED) и после обновления самого приложения (MY_PACKAGE_REPLACED).
 * Условия те же, что у автозапуска из MainActivity: доступ к файлам и отсутствие ручной остановки.
 */
class DaemonAutostartReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        FileDaemonService.autostartIfAllowed(context, reason = action)
    }
}
