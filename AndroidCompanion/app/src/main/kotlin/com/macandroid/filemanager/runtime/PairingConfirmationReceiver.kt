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
 * Кнопки подтверждения/отклонения сопряжения из уведомления (ТЗ 2.2).
 * Receiver не экспортируется (exported=false), PendingIntent с FLAG_IMMUTABLE.
 */
class PairingConfirmationReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_CONFIRM -> {
                val confirmed = EmbeddedServer.confirmPendingPairing()
                Log.i(TAG, "Сопряжение подтверждено пользователем (одобрено: $confirmed)")
                DaemonLog.write(context, "Сопряжение одобрено пользователем (ожидается повторное подключение)")
            }
            ACTION_REJECT -> {
                EmbeddedServer.rejectPendingPairing()
                Log.i(TAG, "Сопряжение отклонено пользователем")
                DaemonLog.write(context, "Сопряжение отклонено пользователем")
            }
        }
        cancelNotification(context)
    }

    companion object {
        private const val TAG = "PairingConfirmation"
        private const val CHANNEL_ID = "macdroid_pairing_channel"
        private const val NOTIFICATION_ID = 1003

        const val ACTION_CONFIRM = "com.macandroid.filemanager.PAIRING_CONFIRM"
        const val ACTION_REJECT = "com.macandroid.filemanager.PAIRING_REJECT"

        /**
         * Уведомление с отпечатком клиентского ключа и кнопками «Принять» / «Отклонить».
         */
        fun showConfirmationNotification(context: Context, clientKeyFingerprint: String) {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Сопряжение Mac", NotificationManager.IMPORTANCE_HIGH)
            )

            val confirmIntent = Intent(context, PairingConfirmationReceiver::class.java).apply {
                action = ACTION_CONFIRM
            }
            val rejectIntent = Intent(context, PairingConfirmationReceiver::class.java).apply {
                action = ACTION_REJECT
            }

            val confirm = PendingIntent.getBroadcast(
                context, 0, confirmIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val reject = PendingIntent.getBroadcast(
                context, 1, rejectIntent,
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
                .setTimeoutAfter(60_000L)
                .addAction(0, "Принять", confirm)
                .addAction(0, "Отклонить", reject)
                .build()

            nm.notify(NOTIFICATION_ID, notification)
        }

        fun cancelNotification(context: Context) {
            try {
                context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
            } catch (e: Exception) {
                Log.w(TAG, "Не удалось отменить уведомление сопряжения", e)
            }
        }
    }
}
