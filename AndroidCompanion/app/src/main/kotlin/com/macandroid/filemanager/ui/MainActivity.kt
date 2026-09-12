package com.macandroid.filemanager.ui

import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.macandroid.filemanager.R
import com.macandroid.filemanager.runtime.FileDaemonService
import com.macandroid.filemanager.server.EmbeddedServer
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections

/**
 * Главный экран управления сопряжением и мониторинга SFTP-сервера AndroidCompanion.
 * Реализует отображение статуса сервера, IP/порта, механизм TOFU и проверку оптимизации батареи HyperOS/MIUI.
 */
class MainActivity : Activity() {

    // Экземпляр EmbeddedServer для проверки статуса сопряжения и сброса ключа
    private val embeddedServer by lazy { EmbeddedServer(applicationContext) }

    // Текстовые поля статуса
    private lateinit var tvServerStatus: TextView
    private lateinit var tvIpAddress: TextView
    private lateinit var tvPort: TextView
    private lateinit var tvMacHint: TextView

    private lateinit var tvPairingStatus: TextView
    private lateinit var tvPairingDesc: TextView
    private lateinit var btnResetPairing: Button

    private lateinit var tvBatteryStatus: TextView
    private lateinit var tvBatteryLevel: TextView
    private lateinit var tvBatteryWarning: TextView
    private lateinit var btnBatterySettings: Button

    private lateinit var tvStorageStatus: TextView
    private lateinit var tvStorageMetrics: TextView
    private lateinit var btnStoragePermission: Button

    private lateinit var btnToggleServer: Button
    private lateinit var btnRefresh: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Построение программного интерфейса без XML
        buildUi()

        // Проверка необходимых разрешений Android 13+ и 11+
        checkInitialPermissions()

        // Запуск фоновой службы при наличии доступа к файловой системе
        if (hasStoragePermission()) {
            startDaemonService()
        }
    }

    override fun onResume() {
        super.onResume()

        // При активном открытом экране разрешаем сопряжение с Mac по Wi-Fi
        com.macandroid.filemanager.server.EmbeddedServer.isPairingModeActive = true

        // При возврате на экран (например, после выдачи разрешений) проверяем запуск службы и обновляем данные
        if (hasStoragePermission() && !isServerRunning()) {
            startDaemonService()
        }

        refreshDisplay()
    }

    /**
     * Построение программной разметки интерфейса на базе ScrollView и LinearLayout.
     */
    private fun buildUi() {
        val rootLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFF121212.toInt()) // Темная тема оформления
            setPadding(dp(20), dp(32), dp(20), dp(32))
        }

        // Заголовок приложения
        val tvHeader = TextView(this).apply {
            text = "Mac ↔ Android Commander"
            textSize = 22f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        rootLayout.addView(tvHeader)

        val tvSubheader = TextView(this).apply {
            text = "Фоновый SFTP-сервер и управление сопряжением"
            textSize = 13f
            setTextColor(0xFF888888.toInt())
            setPadding(0, dp(4), 0, dp(20))
        }
        rootLayout.addView(tvSubheader)

        // Карточка 1: Статус сервера и сеть
        val cardServer = createCard()
        val lblServerHeader = createSectionHeader("ПАРАМЕТРЫ СЕРВЕРА SFTP")
        cardServer.addView(lblServerHeader)

        tvServerStatus = TextView(this).apply {
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(4), 0, dp(6))
        }
        cardServer.addView(tvServerStatus)

        tvIpAddress = TextView(this).apply {
            textSize = 15f
            setTextColor(0xFFE0E0E0.toInt())
            setPadding(0, 0, 0, dp(4))
        }
        cardServer.addView(tvIpAddress)

        tvPort = TextView(this).apply {
            textSize = 15f
            setTextColor(0xFFE0E0E0.toInt())
            setPadding(0, 0, 0, dp(10))
        }
        cardServer.addView(tvPort)

        tvMacHint = TextView(this).apply {
            textSize = 13f
            setTextColor(0xFF64B5F6.toInt())
            typeface = Typeface.MONOSPACE
            setTextIsSelectable(true)
            setPadding(0, 0, 0, dp(12))
        }
        cardServer.addView(tvMacHint)

        btnToggleServer = createButton("Запустить сервер", 0xFF2E7D32.toInt()).apply {
            setOnClickListener {
                if (isServerRunning()) {
                    stopDaemonService()
                } else {
                    startDaemonService()
                }
                // Небольшая пауза перед обновлением, пока сервис инициализируется
                postDelayed({ refreshDisplay() }, 300)
            }
        }
        cardServer.addView(btnToggleServer)
        rootLayout.addView(cardServer)

        // Карточка 2: Сопряжение по SSH-ключам (TOFU)
        val cardPairing = createCard()
        val lblPairingHeader = createSectionHeader("СТАТУС СОПРЯЖЕНИЯ (TOFU)")
        cardPairing.addView(lblPairingHeader)

        tvPairingStatus = TextView(this).apply {
            textSize = 17f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(4), 0, dp(6))
        }
        cardPairing.addView(tvPairingStatus)

        tvPairingDesc = TextView(this).apply {
            textSize = 13f
            setTextColor(0xFFB0B0B0.toInt())
            setPadding(0, 0, 0, dp(12))
        }
        cardPairing.addView(tvPairingDesc)

        btnResetPairing = createButton("Сбросить сопряжение", 0xFFC62828.toInt()).apply {
            setOnClickListener {
                val success = embeddedServer.resetPairing()
                if (success) {
                    Toast.makeText(
                        this@MainActivity,
                        "Сопряжение сброшено. Ожидание первого подключения (TOFU).",
                        Toast.LENGTH_LONG
                    ).show()
                } else {
                    Toast.makeText(
                        this@MainActivity,
                        "Не удалось удалить файл сопряжения.",
                        Toast.LENGTH_SHORT
                    ).show()
                }
                refreshDisplay()
            }
        }
        cardPairing.addView(btnResetPairing)
        rootLayout.addView(cardPairing)

        // Карточка 3: Оптимизация батареи (HyperOS / MIUI / Doze)
        val cardBattery = createCard()
        val lblBatteryHeader = createSectionHeader("ОПТИМИЗАЦИЯ БАТАРЕИ (HYPEROS / MIUI)")
        cardBattery.addView(lblBatteryHeader)

        tvBatteryStatus = TextView(this).apply {
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(4), 0, dp(6))
        }
        cardBattery.addView(tvBatteryStatus)

        tvBatteryLevel = TextView(this).apply {
            textSize = 14f
            setTextColor(0xFFE0E0E0.toInt())
            setPadding(0, 0, 0, dp(6))
        }
        cardBattery.addView(tvBatteryLevel)

        tvBatteryWarning = TextView(this).apply {
            textSize = 13f
            setTextColor(0xFFFFCC80.toInt())
            setPadding(0, 0, 0, dp(10))
        }
        cardBattery.addView(tvBatteryWarning)

        btnBatterySettings = createButton("Открыть настройки батареи", 0xFFEF6C00.toInt()).apply {
            setOnClickListener {
                openBatterySettings()
            }
        }
        cardBattery.addView(btnBatterySettings)
        rootLayout.addView(cardBattery)

        // Карточка 4: Разрешения файловой системы
        val cardStorage = createCard()
        val lblStorageHeader = createSectionHeader("ДОСТУП К ФАЙЛАМ И ПАМЯТЬ")
        cardStorage.addView(lblStorageHeader)

        tvStorageStatus = TextView(this).apply {
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, dp(4), 0, dp(6))
        }
        cardStorage.addView(tvStorageStatus)

        tvStorageMetrics = TextView(this).apply {
            textSize = 14f
            setTextColor(0xFF64B5F6.toInt())
            setPadding(0, 0, 0, dp(10))
        }
        cardStorage.addView(tvStorageMetrics)

        btnStoragePermission = createButton("Выдать доступ ко всем файлам", 0xFF1565C0.toInt()).apply {
            setOnClickListener {
                requestStoragePermission()
            }
        }
        cardStorage.addView(btnStoragePermission)
        rootLayout.addView(cardStorage)

        // Кнопка принудительного обновления информации
        btnRefresh = createButton("Обновить статус", 0xFF424242.toInt()).apply {
            setOnClickListener {
                refreshDisplay()
                Toast.makeText(this@MainActivity, "Данные обновлены", Toast.LENGTH_SHORT).show()
            }
        }
        rootLayout.addView(btnRefresh)

        val scrollView = ScrollView(this).apply {
            addView(rootLayout)
        }
        setContentView(scrollView)
    }

    /**
     * Первичная проверка прав доступа: MANAGE_EXTERNAL_STORAGE и POST_NOTIFICATIONS (Android 13+).
     */
    private fun checkInitialPermissions() {
        if (!hasStoragePermission()) {
            requestStoragePermission()
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
            }
        }

        // SYS-03 FIX: Проверка режима энергосбережения Doze / HyperOS / OneUI при запуске
        if (!isBatteryOptimizationDisabled()) {
            openBatterySettings()
        }
    }

    /**
     * Обновление всех компонентов интерфейса с актуальными данными:
     * - IP-адрес через NetworkInterface (wlan0 / non-loopback)
     * - Порт SFTP
     * - Статус работы службы
     * - Статус сопряжения TOFU (isPaired())
     * - Проверка оптимизации батареи Doze / MIUI
     * - Статус разрешения MANAGE_EXTERNAL_STORAGE
     */
    private fun refreshDisplay() {
        // 1. IP-адрес и порт
        val ipAddress = getDeviceIpAddress()
        tvIpAddress.text = "IP: $ipAddress"
        tvPort.text = "Port: 2222"
        tvMacHint.text = "Подключение с Mac:\nsftp -P 2222 $ipAddress"

        // 2. Статус сервера
        val running = isServerRunning()
        if (running) {
            tvServerStatus.text = "Статус сервера: Запущен"
            tvServerStatus.setTextColor(0xFF81C784.toInt()) // Светло-зеленый
            btnToggleServer.text = "Остановить сервер"
            btnToggleServer.background = createButtonDrawable(0xFFC62828.toInt())
        } else {
            tvServerStatus.text = "Статус сервера: Остановлен"
            tvServerStatus.setTextColor(0xFFE57373.toInt()) // Светло-красный
            btnToggleServer.text = "Запустить сервер"
            btnToggleServer.background = createButtonDrawable(0xFF2E7D32.toInt())
        }

        // 3. Статус сопряжения TOFU
        val paired = embeddedServer.isPaired()
        if (paired) {
            tvPairingStatus.text = "Сопряжено"
            tvPairingStatus.setTextColor(0xFF81C784.toInt())
            tvPairingDesc.text = "Клиент авторизован. Открытый ключ сохранен в authorized_keys."
            btnResetPairing.visibility = View.VISIBLE
        } else {
            tvPairingStatus.text = "Ожидание первого подключения (TOFU)"
            tvPairingStatus.setTextColor(0xFFFFB74D.toInt()) // Оранжевый
            tvPairingDesc.text = "Ключ еще не сохранен. Первое входящее подключение с Mac будет доверенным (Trust On First Use)."
            btnResetPairing.visibility = View.VISIBLE
        }

        // 4. Проверка оптимизации батареи (HyperOS / MIUI / Doze)
        val batteryOptimDisabled = isBatteryOptimizationDisabled()
        if (batteryOptimDisabled) {
            tvBatteryStatus.text = "Оптимизация батареи: Отключена ✓"
            tvBatteryStatus.setTextColor(0xFF81C784.toInt())
            tvBatteryWarning.visibility = View.GONE
            btnBatterySettings.visibility = View.GONE
        } else {
            tvBatteryStatus.text = "Оптимизация батареи: Включена (ограничена)"
            tvBatteryStatus.setTextColor(0xFFFF8A65.toInt())
            tvBatteryWarning.visibility = View.VISIBLE
            tvBatteryWarning.text = "Внимание: HyperOS / MIUI может завершить SFTP-демон при блокировке экрана. " +
                    "Рекомендуется выбрать «Без ограничений» и включить «Автозапуск»."
            btnBatterySettings.visibility = View.VISIBLE
        }

        // 4.1. Уровень заряда аккумулятора
        try {
            val bm = getSystemService(BATTERY_SERVICE) as? BatteryManager
            val batteryPct = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
            if (batteryPct >= 0) {
                tvBatteryLevel.text = "Текущий уровень заряда: $batteryPct%"
                tvBatteryLevel.visibility = View.VISIBLE
            } else {
                tvBatteryLevel.visibility = View.GONE
            }
        } catch (ignored: Exception) {
            tvBatteryLevel.visibility = View.GONE
        }

        // 5. Разрешение на доступ ко всем файлам и метрики памяти
        val storageGranted = hasStoragePermission()
        if (storageGranted) {
            tvStorageStatus.text = "Разрешение All Files Access: Предоставлено ✓"
            tvStorageStatus.setTextColor(0xFF81C784.toInt())
            btnStoragePermission.visibility = View.GONE

            try {
                val stat = StatFs(Environment.getExternalStorageDirectory().path)
                val freeGb = (stat.availableBlocksLong * stat.blockSizeLong).toDouble() / (1024.0 * 1024.0 * 1024.0)
                val totalGb = (stat.blockCountLong * stat.blockSizeLong).toDouble() / (1024.0 * 1024.0 * 1024.0)
                tvStorageMetrics.text = String.format("Память: %.2f ГБ свободно из %.2f ГБ", freeGb, totalGb)
                tvStorageMetrics.visibility = View.VISIBLE
            } catch (ignored: Exception) {
                tvStorageMetrics.visibility = View.GONE
            }
        } else {
            tvStorageStatus.text = "Разрешение All Files Access: Не предоставлено ⚠️"
            tvStorageStatus.setTextColor(0xFFE57373.toInt())
            btnStoragePermission.visibility = View.VISIBLE
            tvStorageMetrics.visibility = View.GONE
        }
    }

    /**
     * Получение локального IPv4-адреса устройства через NetworkInterface.
     * В первую очередь выполняется поиск интерфейса wlan0 (Wi-Fi),
     * если не найден — возвращается любой активный non-loopback IPv4 адрес.
     */
    private fun getDeviceIpAddress(): String {
        try {
            val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces())
            var fallbackIp: String? = null

            // 1. Поиск активного интерфейса Wi-Fi (wlan0, wlan1 и т.д.)
            for (networkInterface in interfaces) {
                if (!networkInterface.isUp || networkInterface.isLoopback) continue
                val isWlan = networkInterface.name.startsWith("wlan", ignoreCase = true)
                val addresses = Collections.list(networkInterface.inetAddresses)
                for (addr in addresses) {
                    if (!addr.isLoopbackAddress && addr is Inet4Address) {
                        val host = addr.hostAddress ?: continue
                        if (isWlan) {
                            return host
                        }
                        if (fallbackIp == null) {
                            fallbackIp = host
                        }
                    }
                }
            }

            return fallbackIp ?: "127.0.0.1 (нет Wi-Fi)"
        } catch (e: Exception) {
            return "Не удалось определить: ${e.message}"
        }
    }

    /**
     * Проверка активности службы FileDaemonService.
     */
    private fun isServerRunning(): Boolean {
        if (FileDaemonService.isRunning) return true

        val manager = getSystemService(ACTIVITY_SERVICE) as? ActivityManager ?: return false
        @Suppress("DEPRECATION")
        for (service in manager.getRunningServices(Int.MAX_VALUE)) {
            if (FileDaemonService::class.java.name == service.service.className) {
                return true
            }
        }
        return false
    }

    /**
     * Проверка, отключена ли оптимизация батареи для данного приложения.
     * Возвращает true, если приложение находится в списке исключений (не подвержено Doze).
     */
    private fun isBatteryOptimizationDisabled(): Boolean {
        val pm = getSystemService(POWER_SERVICE) as? PowerManager ?: return false
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * Открытие настроек батареи и фоновой активности с поддержкой интерфейсов HyperOS / MIUI.
     */
    private fun openBatterySettings() {
        // 1. Прямой системный запрос на добавление в исключения оптимизации батареи
        try {
            val directIntent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(directIntent)
            return
        } catch (ignored: Exception) {}

        // 2. Специфичные Intent для оболочки Xiaomi MIUI / HyperOS
        val vendorIntents = listOf(
            // Контроль фоновой активности приложения в MIUI (PowerKeeper)
            Intent().setComponent(
                ComponentName(
                    "com.miui.powerkeeper",
                    "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"
                )
            ).apply {
                putExtra("package_name", packageName)
                putExtra("package_label", getString(R.string.app_name))
            },
            // Автозапуск приложений MIUI
            Intent().setComponent(
                ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity"
                )
            ),
            // Стандартный список игнорирования оптимизации батареи
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        )

        for (intent in vendorIntents) {
            try {
                startActivity(intent)
                return
            } catch (ignored: Exception) {}
        }

        // 3. Fallback: переход на общую страницу настроек приложения
        try {
            val appDetailsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(appDetailsIntent)
        } catch (e: Exception) {
            Toast.makeText(this, "Не удалось открыть настройки: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    /**
     * Проверка наличия разрешения MANAGE_EXTERNAL_STORAGE (Android 11+).
     */
    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true
        }
    }

    /**
     * Запрос системного разрешения MANAGE_EXTERNAL_STORAGE.
     */
    private fun requestStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            } catch (e: Exception) {
                val fallbackIntent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                startActivity(fallbackIntent)
            }
        }
    }

    /**
     * Запуск службы файлового демона как Foreground Service.
     */
    private fun startDaemonService() {
        val serviceIntent = Intent(this, FileDaemonService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    /**
     * Остановка службы файлового демона.
     */
    private fun stopDaemonService() {
        val stopIntent = Intent(this, FileDaemonService::class.java).apply {
            action = FileDaemonService.ACTION_STOP
        }
        startService(stopIntent)
    }

    // Вспомогательные методы создания UI-компонентов

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private fun createCard(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
            background = GradientDrawable().apply {
                setColor(0xFF1E1E1E.toInt()) // Карточка темного оттенка
                cornerRadius = dp(12).toFloat()
                setStroke(dp(1), 0xFF2C2C2C.toInt())
            }
            val params = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                setMargins(0, 0, 0, dp(14))
            }
            layoutParams = params
        }
    }

    private fun createSectionHeader(title: String): TextView {
        return TextView(this).apply {
            text = title
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(0xFF9E9E9E.toInt())
            letterSpacing = 0.05f
            setPadding(0, 0, 0, dp(8))
        }
    }

    private fun createButton(title: String, bgColor: Int): Button {
        return Button(this).apply {
            text = title
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            isAllCaps = false
            setPadding(dp(16), dp(12), dp(16), dp(12))
            background = createButtonDrawable(bgColor)
            val params = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                setMargins(0, dp(6), 0, 0)
            }
            layoutParams = params
        }
    }

    private fun createButtonDrawable(color: Int): GradientDrawable {
        return GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(8).toFloat()
        }
    }
}
