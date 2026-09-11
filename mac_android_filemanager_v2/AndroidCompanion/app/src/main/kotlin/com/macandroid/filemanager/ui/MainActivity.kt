package com.macandroid.filemanager.ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.text.format.Formatter
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.macandroid.filemanager.runtime.FileDaemonService

class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 64, 48, 48)
        }

        val tvTitle = TextView(this).apply {
            text = "Mac ↔ Android Commander"
            textSize = 22f
            paint.isFakeBoldText = true
        }
        layout.addView(tvTitle)

        val tvStatus = TextView(this).apply {
            textSize = 15f
            setPadding(0, 24, 0, 24)
            text = "Проверка разрешений хранилища..."
        }
        layout.addView(tvStatus)

        val scrollView = ScrollView(this).apply {
            addView(layout)
        }
        setContentView(scrollView)

        // 1. Проверка разрешения All Files Access (MANAGE_EXTERNAL_STORAGE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (!Environment.isExternalStorageManager()) {
                tvStatus.text = "Требуется разрешение 'Доступ ко всем файлам' (All Files Access).\nОткрываю настройки..."
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            } else {
                tvStatus.text = "Разрешение All Files Access: ПОДТВЕРЖДЕНО"
            }
        }

        // 2. Получение локального IP-адреса Wi-Fi
        val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        val ipAddress = Formatter.formatIpAddress(wm.connectionInfo.ipAddress)

        // 3. Запуск фоновой службы
        val serviceIntent = Intent(this, FileDaemonService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }

        val tvDetails = TextView(this).apply {
            textSize = 14f
            setPadding(0, 16, 0, 16)
            text = """
                [OK] Демон запущен на порту 2222 (SFTP/SSH)
                [OK] Адрес для прямого подключения на Mac:
                     $ipAddress:2222

                Совет для Xiaomi (MIUI / HyperOS):
                1. Зайдите в 'Безопасность' -> 'Автозапуск' и включите автозапуск для этого приложения.
                2. В настройках приложения выберите 'Контроль активности' -> 'Нет ограничений'.
            """.trimIndent()
        }
        layout.addView(tvDetails)
    }
}
