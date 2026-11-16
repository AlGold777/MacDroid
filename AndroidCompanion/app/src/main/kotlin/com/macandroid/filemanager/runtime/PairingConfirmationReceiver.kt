package com.macandroid.filemanager.runtime

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationCompat
import com.macandroid.filemanager.server.EmbeddedServer

/**
 * H2: подтверждение сопряжения на телефоне.
 *
 * Раньше в открытом 60-секундном окне первый предъявленный клиентский ключ
 * записывался в authorized_keys без какого-либо подтверждения: зарегистрировать
 * ключ мог любой хост в LAN или любой локальный процесс через `adb forward`.
 *
 * Теперь первый ключ только запоминается как заявка, а пользователь видит
 * уведомление с отпечатком клиентского ключа и подтверждает/отклоняет запись.
 * Отпечаток в формате `SHA256:...` совпадает с тем, что Mac показывает в окне
 * сопряжения, — сверка выполняется глазами на двух экранах.
 */
class PairingConfirmationReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_CONFIRM -> {
                val written = EmbeddedServer.confirmPendingPairing(context.filesDir)
                Log.i(TAG, "Сопряжение подтверждено пользователем (ключ записан: $written)")
                DaemonLog.write(context, "Сопряжение подтверждено пользователем (ключ записан: $written)")
            }
            ACTION_REJECT -> {
                EmbeddedServer.rejectPendingPairing()
                Log.i(TAG, "Сопряжение отклонено пользователем")
                DaemonLog.write(context, "Сопряжение отклонено пользователем")
            }
        }
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    companion object {
        private const val TAG = "PairingConfirmation"
        private const val CHANNEL_ID = "macdroid_pairing_channel"
        private const val NOTIFICATION_ID = 1003

        const val ACTION_CONFIRM = "com.macandroid.filemanager.PAIRING_CONFIRM"
        const val ACTION_REJECT = "com.macandroid.filemanager.PAIRING_REJECT"

        /** Уведомление с отпечатком клиентского ключа и кнопками решения. */
        fun showConfirmationNotification(context: Context, clientKeyFingerprint: String) {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Сопряжение Mac", NotificationManager.IMPORTANCE_HIGH)
            )
            val confirm = PendingIntent.getBroadcast(
                context, 0, Intent(context, PairingConfirmationReceiver::class.java).setAction(ACTION_CONFIRM),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val reject = PendingIntent.getBroadcast(
                context, 1, Intent(context, PairingConfirmationReceiver::class.java).setAction(ACTION_REJECT),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle("Сопряжение с Mac")
                .setContentText("Разрешить доступ к файлам телефона? Ключ: $clientKeyFingerprint")
                .setStyle(
                    NotificationCompat.BigTextStyle().bigText(
                        "Mac запрашивает сопряжение (полный доступ к файлам телефона).\n" +
                        "Ключ Mac: $clientKeyFingerprint\n" +
                        "Разрешайте, только если окно сопряжения открывали вы и отпечаток " +
                        "совпадает с показанным на Mac."
                    )
                )
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(false)
                // P1.2 (dev-review): уведомление умирает вместе с окном сопряжения
                // (EmbeddedServer.PAIRING_WINDOW_MILLIS = 60 с). Без этого «Разрешить»
                // через 2 минуты молча ничего не делало: окно истекло, заявка очищалась.
                .setTimeoutAfter(60_000L)
                .addAction(0, "Разрешить", confirm)
                .addAction(0, "Отклонить", reject)
                .build()
            nm.notify(NOTIFICATION_ID, notification)
        }
    }
}
