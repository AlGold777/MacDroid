package com.macandroid.filemanager.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.macandroid.filemanager.R
import com.macandroid.filemanager.runtime.DaemonLog
import com.macandroid.filemanager.runtime.FileDaemonService
import com.macandroid.filemanager.runtime.SessionStateTracker
import com.macandroid.filemanager.runtime.WifiAddressProvider
import com.macandroid.filemanager.server.EmbeddedServer

/**
 * Главный экран управления сопряжением и мониторинга SFTP-сервера AndroidCompanion (v2.2).
 */
class MainActivity : Activity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val REQUEST_LEGACY_STORAGE = 1002
        private const val REQUEST_POST_NOTIFICATIONS = 1001
        private const val STATUS_TICK_MS = 1_000L
    }

    private val embeddedServer by lazy { EmbeddedServer(applicationContext) }
    private var hostKeyFingerprint: String? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var fgsStartError: String? = null

    private lateinit var cardStorageWarning: LinearLayout

    private lateinit var tvServerStatus: TextView
    private lateinit var tvIpAddress: TextView
    private lateinit var tvPort: TextView
    private lateinit var tvMacHint: TextView
    private lateinit var tvHostFingerprint: TextView

    private lateinit var tvPairingStatus: TextView
    private lateinit var tvPairingDesc: TextView
    private lateinit var tvTrustedKeys: TextView
    private lateinit var btnResetPairing: Button
    private lateinit var btnEnablePairing: Button

    private lateinit var tvBatteryStatus: TextView
    private lateinit var tvBatteryLevel: TextView
    private lateinit var tvBatteryWarning: TextView
    private lateinit var btnBatterySettings: Button

    private lateinit var tvStorageStatus: TextView
    private lateinit var tvStorageMetrics: TextView
    private lateinit var btnStoragePermission: Button

    private lateinit var btnToggleServer: Button
    private lateinit var btnRefresh: Button

    private val statusHandler = Handler(Looper.getMainLooper())
    private val statusTick = object : Runnable {
        override fun run() {
            val keepTicking = hasStoragePermission() &&
                !FileDaemonService.isServerListening &&
                !FileDaemonService.isUserStopped(this@MainActivity)
            refreshDisplay()
            if (keepTicking) statusHandler.postDelayed(this, STATUS_TICK_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildUi()

        // ТЗ 7.1: Первичная проверка прав и автостарт только при savedInstanceState == null (без сброса на поворот)
        if (savedInstanceState == null) {
            checkInitialPermissions()

            if (hasStoragePermission() && !FileDaemonService.isUserStopped(this)) {
                startDaemonServiceSafe()
            }
        }
    }

    override fun onResume() {
        super.onResume()

        // Регистрация fallback-диалога сопряжения при foreground (ТЗ 2.2)
        EmbeddedServer.foregroundPromptCallback = { fingerprint ->
            runOnUiThread {
                showPairingConfirmationDialog(fingerprint)
            }
        }

        if (hasStoragePermission()) {
            if (!isServerRunning() && !FileDaemonService.isUserStopped(this)) {
                startDaemonServiceSafe()
            } else if (!FileDaemonService.isUserStopped(this)) {
                try {
                    startService(Intent(this, FileDaemonService::class.java))
                } catch (e: Exception) {
                    Log.w(TAG, "Не удалось обновить службу FileDaemonService", e)
                }
            }
        }

        refreshDisplay()
        statusHandler.removeCallbacks(statusTick)
        statusHandler.postDelayed(statusTick, STATUS_TICK_MS)
    }

    override fun onPause() {
        EmbeddedServer.foregroundPromptCallback = null
        statusHandler.removeCallbacks(statusTick)
        super.onPause()
    }

    override fun onStart() {
        super.onStart()
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                runOnUiThread { refreshDisplay() }
            }

            override fun onLost(network: Network) {
                runOnUiThread { refreshDisplay() }
            }
        }
        networkCallback = callback
        try {
            cm.registerDefaultNetworkCallback(callback)
        } catch (e: Exception) {
            Log.w(TAG, "Не удалось подписаться на изменения сети", e)
            networkCallback = null
        }
    }

    override fun onStop() {
        networkCallback?.let {
            try {
                getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it)
            } catch (e: Exception) {
                Log.w(TAG, "Не удалось отписаться от изменений сети", e)
            }
        }
        networkCallback = null
        super.onStop()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_LEGACY_STORAGE) {
            refreshDisplay()
            if (hasStoragePermission() && !isServerRunning() && !FileDaemonService.isUserStopped(this)) {
                startDaemonServiceSafe()
            }
        }
    }

    private fun appVersionName(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: ""
    } catch (e: Exception) {
        ""
    }

    private fun buildUi() {
        val rootLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFF121212.toInt())
            setPadding(dp(20), dp(32), dp(20), dp(32))
        }

        val tvHeader = TextView(this).apply {
            text = "Mac ↔ Android Commander ${appVersionName()}"
            textSize = 22f
            setTextColor(Color.WHITE)
            typeface = Typeface.DEFAULT_BOLD
        }
        rootLayout.addView(tvHeader)

        val tvSubheader = TextView(this).apply {
            text = "Фоновый SFTP-сервер и управление сопряжением"
            textSize = 13f
            setTextColor(0xFF888888.toInt())
            setPadding(0, dp(4), 0, dp(16))
        }
        rootLayout.addView(tvSubheader)

        // Предупреждение об отсутствии доступа к файлам
        cardStorageWarning = createCard().apply {
            background = GradientDrawable().apply {
                setColor(0xFF381414.toInt())
                cornerRadius = dp(12).toFloat()
                setStroke(dp(2), 0xFFEF5350.toInt())
            }
            visibility = if (hasStoragePermission()) View.GONE else View.VISIBLE
        }
        val tvWarningTitle = TextView(this).apply {
            text = "⚠️ ТРЕБУЕТСЯ ДОСТУП К ФАЙЛАМ"
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(0xFFFF8A80.toInt())
            setPadding(0, 0, 0, dp(4))
        }
        cardStorageWarning.addView(tvWarningTitle)

        val tvWarningDesc = TextView(this).apply {
            text = "Без разрешения «Доступ ко всем файлам» MacDroid Commander на Mac не видит папки и не может передавать файлы."
            textSize = 13f
            setTextColor(0xFFEEEEEE.toInt())
            setPadding(0, 0, 0, dp(10))
        }
        cardStorageWarning.addView(tvWarningDesc)

        val btnGrantStorageTop = createButton("Разрешить доступ ко всем файлам", 0xFFD32F2F.toInt()).apply {
            setOnClickListener { requestStoragePermission() }
        }
        cardStorageWarning.addView(btnGrantStorageTop)
        rootLayout.addView(cardStorageWarning)

        // Карточка 1: Параметры сервера SFTP
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

        tvHostFingerprint = TextView(this).apply {
            textSize = 13f
            setTextColor(0xFFE0E0E0.toInt())
            typeface = Typeface.MONOSPACE
            setTextIsSelectable(true)
            setPadding(0, 0, 0, dp(12))
        }
        cardServer.addView(tvHostFingerprint)

        btnToggleServer = createButton("Запустить сервер", 0xFF2E7D32.toInt()).apply {
            setOnClickListener {
                if (isServerRunning()) {
                    stopDaemonService()
                } else {
                    FileDaemonService.setUserStopped(this@MainActivity, false)
                    startDaemonServiceSafe()
                }
                statusHandler.postDelayed({ refreshDisplay() }, 300)
            }
        }
        cardServer.addView(btnToggleServer)
        rootLayout.addView(cardServer)

        // Карточка 2: Статус сопряжения (TOFU)
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
            setPadding(0, 0, 0, dp(6))
        }
        cardPairing.addView(tvPairingDesc)

        tvTrustedKeys = TextView(this).apply {
            textSize = 12f
            typeface = Typeface.MONOSPACE
            setTextColor(0xFF81C784.toInt())
            setPadding(0, 0, 0, dp(10))
            setTextIsSelectable(true)
        }
        cardPairing.addView(tvTrustedKeys)

        // ТЗ 7.2: Сброс сопряжения с confirm-диалогом
        btnResetPairing = createButton("Сбросить сопряжение", 0xFFC62828.toInt()).apply {
            setOnClickListener {
                showResetPairingConfirmDialog()
            }
        }
        cardPairing.addView(btnResetPairing)

        btnEnablePairing = createButton("Разрешить сопряжение на 60 секунд", 0xFF1565C0.toInt()).apply {
            setOnClickListener {
                EmbeddedServer.openPairingWindow()
                Toast.makeText(
                    this@MainActivity,
                    "Первое SSH-сопряжение по USB и Wi-Fi разрешено на 60 секунд.",
                    Toast.LENGTH_LONG
                ).show()
                refreshDisplay()
                statusHandler.postDelayed({ refreshDisplay() }, 60_100L)
            }
        }
        cardPairing.addView(btnEnablePairing)
        rootLayout.addView(cardPairing)

        // Карточка 3: Оптимизация батареи
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
            setOnClickListener { openBatterySettings() }
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
            setOnClickListener { requestStoragePermission() }
        }
        cardStorage.addView(btnStoragePermission)
        rootLayout.addView(cardStorage)

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

    private fun checkInitialPermissions() {
        if (!hasStoragePermission()) {
            showStoragePermissionDialog()
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), REQUEST_POST_NOTIFICATIONS)
            }
        }
        // ТЗ 7.1: Настройки батареи НИКОГДА не открывать автоматически
    }

    private fun showStoragePermissionDialog() {
        AlertDialog.Builder(this)
            .setTitle("Требуется доступ к файлам")
            .setMessage("Для работы MacDroid Commander приложению необходим доступ ко всем файлам смартфона.\n\nНажмите «Разрешить», затем включите тумблер в открывшемся системном окне настроек.")
            .setPositiveButton("Разрешить") { _, _ -> requestStoragePermission() }
            .setNegativeButton("Позже", null)
            .show()
    }

    private fun showResetPairingConfirmDialog() {
        AlertDialog.Builder(this)
            .setTitle("Сброс сопряжения")
            .setMessage("Вы уверены, что хотите удалить сохранённые доверенные ключи Mac? Текущие сессии будут закрыты, для подключения потребуется повторное сопряжение.")
            .setPositiveButton("Сбросить") { _, _ ->
                val success = embeddedServer.resetPairing()
                if (success) {
                    Toast.makeText(
                        this,
                        "Сопряжение сброшено. Откройте окно сопряжения на 60 секунд для нового подключения.",
                        Toast.LENGTH_LONG
                    ).show()
                } else {
                    Toast.makeText(this, "Не удалось сбросить сопряжение.", Toast.LENGTH_SHORT).show()
                }
                refreshDisplay()
            }
            .setNegativeButton("Отмена", null)
            .show()
    }

    private fun showPairingConfirmationDialog(fingerprint: String) {
        AlertDialog.Builder(this)
            .setTitle("Запрос сопряжения с Mac")
            .setMessage("Mac запрашивает доступ к файлам телефона.\n\nОтпечаток ключа:\n$fingerprint\n\nРазрешить сопряжение?")
            .setPositiveButton("Принять") { _, _ ->
                val confirmed = EmbeddedServer.confirmPendingPairing()
                DaemonLog.write(this, "Сопряжение одобрено в диалоге (результат: $confirmed, $fingerprint)")
                Toast.makeText(this, "Сопряжение одобрено. Ожидание подключения с Mac…", Toast.LENGTH_SHORT).show()
                refreshDisplay()
            }
            .setNegativeButton("Отклонить") { _, _ ->
                EmbeddedServer.rejectPendingPairing()
                DaemonLog.write(this, "Сопряжение отклонено в диалоге ($fingerprint)")
                refreshDisplay()
            }
            .setCancelable(false)
            .show()
    }

    private fun refreshDisplay() {
        // 1. IP-адрес через единый WifiAddressProvider (ТЗ 3.4)
        val wifiIp = WifiAddressProvider.getWifiIpv4Address(this)
        if (wifiIp != null) {
            tvIpAddress.text = "Wi-Fi IP: $wifiIp"
            tvPort.text = "Port: 2222"
            tvMacHint.text = "Подключение с Mac по Wi-Fi:\nsftp -P 2222 $wifiIp"
        } else {
            tvIpAddress.text = "Wi-Fi: не подключен (доступ только по USB)"
            tvPort.text = "Port: 2222 (127.0.0.1)"
            tvMacHint.text = "Подключение с Mac по USB-кабелю:\nadb forward tcp:2222 tcp:2222\nsftp -P 2222 127.0.0.1"
        }

        // Отпечаток хост-ключа
        if (hostKeyFingerprint == null) {
            hostKeyFingerprint = embeddedServer.hostKeyFingerprint()
        }
        tvHostFingerprint.text = "Отпечаток ключа телефона (сверьте с Mac):\n" +
                (hostKeyFingerprint ?: "ключ ещё не создан, запустите сервер")

        // 2. Статус сервера и активных сессий (ТЗ 7.5)
        val running = isServerRunning()
        val activeSessions = SessionStateTracker.activeSftpSessions
        val isTransferring = SessionStateTracker.isTransferring

        if (running) {
            if (FileDaemonService.isServerListening) {
                val sessionLabel = when {
                    isTransferring -> " • Передача данных ($activeSessions сессий)"
                    activeSessions > 0 -> " • Подключено ($activeSessions сессий)"
                    else -> ""
                }
                tvServerStatus.text = "Статус сервера: Запущен$sessionLabel"
                tvServerStatus.setTextColor(0xFF81C784.toInt())
            } else {
                tvServerStatus.text = "Статус сервера: Запускается…"
                tvServerStatus.setTextColor(0xFFFFB74D.toInt())
            }
            btnToggleServer.text = "Остановить сервер"
            btnToggleServer.background = createButtonDrawable(0xFFC62828.toInt())
        } else {
            val errorNotice = if (fgsStartError != null) " ($fgsStartError)" else ""
            tvServerStatus.text = "Статус сервера: Остановлен$errorNotice"
            tvServerStatus.setTextColor(0xFFE57373.toInt())
            btnToggleServer.text = "Запустить сервер"
            btnToggleServer.background = createButtonDrawable(0xFF2E7D32.toInt())
        }

        // 3. Статус сопряжения TOFU (ТЗ 2.4, 2.5, 7.2)
        val paired = embeddedServer.isPaired()
        val trustedKeys = embeddedServer.getTrustedKeyFingerprints()

        if (paired) {
            tvPairingStatus.text = "Сопряжено"
            tvPairingStatus.setTextColor(0xFF81C784.toInt())
            tvPairingDesc.text = "Доверенные клиенты авторизованы. Ключи сохранены в authorized_keys."
            tvTrustedKeys.text = "Доверенные ключи:\n" + trustedKeys.joinToString("\n")
            tvTrustedKeys.visibility = View.VISIBLE
            btnResetPairing.visibility = View.VISIBLE
            btnEnablePairing.visibility = View.GONE
        } else {
            tvPairingStatus.text = if (EmbeddedServer.isPairingModeActive) "Окно сопряжения открыто" else "Сопряжение отключено"
            tvPairingStatus.setTextColor(0xFFFFB74D.toInt())
            tvPairingDesc.text = if (EmbeddedServer.isPairingModeActive) {
                "Первый SSH-ключ может быть принят в течение 60 секунд. Подключайте только доверенный Mac."
            } else {
                "Для первого подключения по USB или Wi-Fi нажмите кнопку ниже. Окно закроется после подтверждения первого ключа или через 60 секунд."
            }
            tvTrustedKeys.visibility = View.GONE
            btnResetPairing.visibility = View.GONE
            btnEnablePairing.visibility = View.VISIBLE
        }

        // 4. Оптимизация батареи
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

        try {
            val bm = getSystemService(BATTERY_SERVICE) as? BatteryManager
            val batteryPct = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
            if (batteryPct >= 0) {
                tvBatteryLevel.text = "Текущий уровень заряда: $batteryPct%"
                tvBatteryLevel.visibility = View.VISIBLE
            } else {
                tvBatteryLevel.visibility = View.GONE
            }
        } catch (_: Exception) {
            tvBatteryLevel.visibility = View.GONE
        }

        // 5. Разрешения файловой системы
        val storageGranted = hasStoragePermission()
        cardStorageWarning.visibility = if (storageGranted) View.GONE else View.VISIBLE
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
            } catch (e: Exception) {
                Log.w(TAG, "Не удалось прочитать метрики памяти", e)
                tvStorageMetrics.visibility = View.GONE
            }
        } else {
            tvStorageStatus.text = "Разрешение All Files Access: Не предоставлено ⚠️"
            tvStorageStatus.setTextColor(0xFFE57373.toInt())
            btnStoragePermission.visibility = View.VISIBLE
            tvStorageMetrics.visibility = View.GONE
        }
    }

    private fun isServerRunning(): Boolean = FileDaemonService.isRunning

    private fun isBatteryOptimizationDisabled(): Boolean {
        val pm = getSystemService(POWER_SERVICE) as? PowerManager ?: return false
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun openBatterySettings() {
        try {
            val directIntent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(directIntent)
            return
        } catch (_: Exception) {}

        val vendorIntents = listOf(
            Intent().setComponent(
                ComponentName("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity")
            ).apply {
                putExtra("package_name", packageName)
                putExtra("package_label", getString(R.string.app_name))
            },
            Intent().setComponent(
                ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")
            ),
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        )

        for (intent in vendorIntents) {
            try {
                startActivity(intent)
                return
            } catch (_: Exception) {}
        }

        try {
            val appDetailsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(appDetailsIntent)
        } catch (e: Exception) {
            Toast.makeText(this, "Не удалось открыть настройки: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    private fun hasStoragePermission(): Boolean = FileDaemonService.hasStoragePermission(this)

    private fun requestStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            } catch (e: Exception) {
                Log.w(TAG, "Экран ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION недоступен", e)
                try {
                    startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                } catch (e2: Exception) {
                    Toast.makeText(this, "Не удалось открыть настройки доступа к файлам", Toast.LENGTH_LONG).show()
                }
            }
        } else {
            requestPermissions(
                arrayOf(
                    android.Manifest.permission.READ_EXTERNAL_STORAGE,
                    android.Manifest.permission.WRITE_EXTERNAL_STORAGE
                ),
                REQUEST_LEGACY_STORAGE
            )
        }
    }

    /**
     * ТЗ 4.6: Безопасный запуск FGS с перехватом ForegroundServiceStartNotAllowedException и др.
     */
    private fun startDaemonServiceSafe() {
        try {
            fgsStartError = null
            val serviceIntent = Intent(this, FileDaemonService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        } catch (e: Exception) {
            val msg = "Ошибка запуска службы: ${e.javaClass.simpleName}: ${e.message}"
            Log.e(TAG, msg, e)
            fgsStartError = e.javaClass.simpleName
            DaemonLog.write(this, msg)
            Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
        }
    }

    /**
     * ТЗ 4.6: Остановка службы: при незапущенном сервисе не шлём startService(ACTION_STOP).
     */
    private fun stopDaemonService() {
        FileDaemonService.setUserStopped(this, true)
        if (FileDaemonService.isRunning) {
            val stopIntent = Intent(this, FileDaemonService::class.java).apply {
                action = FileDaemonService.ACTION_STOP
            }
            try {
                startService(stopIntent)
            } catch (e: Exception) {
                Log.w(TAG, "stopDaemonService: ошибка отправки ACTION_STOP", e)
            }
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun createCard(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(16), dp(16), dp(16))
        background = GradientDrawable().apply {
            setColor(0xFF1E1E1E.toInt())
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

    private fun createSectionHeader(title: String): TextView = TextView(this).apply {
        text = title
        textSize = 12f
        typeface = Typeface.DEFAULT_BOLD
        setTextColor(0xFF9E9E9E.toInt())
        letterSpacing = 0.05f
        setPadding(0, 0, 0, dp(8))
    }

    private fun createButton(title: String, bgColor: Int): Button = Button(this).apply {
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

    private fun createButtonDrawable(color: Int): GradientDrawable = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(8).toFloat()
    }
}
