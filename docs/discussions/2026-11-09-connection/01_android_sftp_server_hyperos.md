Ты — инженер Android-платформы с глубоким опытом в сетевом стеке Linux/Android, Apache MINA SSHD, foreground-службах и ограничениях фоновой работы в прошивках Xiaomi (MIUI/HyperOS). Тебе нужно найти причину, по которой SFTP-сервер внутри Android-приложения перестаёт принимать подключения, и предложить надёжную архитектуру сервера. Отвечай по-русски.

# Система

MacDroid Commander — двухпанельный файловый менеджер Mac ↔ Android. Mac подключается к телефону по SSH/SFTP (системный OpenSSH на Mac). На телефоне работает приложение-компаньон: в нём встроенный SFTP-сервер на Apache MINA SSHD 2.12.0 (sshd-core, sshd-sftp), порт 2222.

- Компаньон: `/Users/restart/Documents/GitHub/MacDroidCommander/AndroidCompanion`, Kotlin, minSdk 26, targetSdk 34, версия 2.1.19.
- Сервер живёт в foreground-службе `FileDaemonService` с `foregroundServiceType="dataSync"`, `START_STICKY`. Есть автозапуск по `BOOT_COMPLETED` и `MY_PACKAGE_REPLACED`.
- WakeLock (PARTIAL) и WifiLock (`WIFI_MODE_FULL_HIGH_PERF`) берутся только на время активной передачи.
- Для приложения отключена оптимизация батареи. В журнале системы приложение есть в списке `AurogonImmobulusMode mNoRestrictAppSet`.
- Обнаружение: NSD (Bonjour) `_macphone_sftp._tcp`.

Телефон, на котором проблема: Xiaomi 24030PN60G (Xiaomi 14 Ultra), HyperOS 3.0 (OS3.0), Android 16. На Redmi 2409BRN2CY с тем же компаньоном таких сбоев заметно меньше (не измерено точно).

## Привязка сервера к адресу

Сервер слушает только адрес Wi-Fi (`wlan*`) плюс loopback (через loopback идёт `adb forward` при подключении кабелем). Если Wi-Fi-адрес не найден — все интерфейсы.

```kotlin
// AndroidCompanion/app/src/main/kotlin/com/macandroid/filemanager/server/EmbeddedServer.kt
val server = SshServer.setUpDefaultServer().apply {
    this.port = this@EmbeddedServer.port
    // MINA SSHD принимает список адресов через запятую.
    bindHost?.let { this.host = "$it,127.0.0.1" }
    keyPairProvider = SimpleGeneratorHostKeyProvider(hostKeyFile.toPath())
    passwordAuthenticator = null
    publickeyAuthenticator = ... // TOFU: см. отдельный вопрос
    val serverProps = this.properties
    serverProps["nio2-read-buf-size"] = (256 * 1024).toString()
    serverProps["window-size"] = (8L * 1024 * 1024).toString()
    serverProps["packet-size"] = (64 * 1024).toString()
    serverProps["max-open-handles-per-session"] = "32"
    ...
}
try { server.start() } catch (e: Exception) { server.stop(true); throw e }

fun findWifiIpv4Address(): String? =
    Collections.list(NetworkInterface.getNetworkInterfaces())
        .filter { it.isUp && !it.isLoopback && it.name.startsWith("wlan", ignoreCase = true) }
        .flatMap { Collections.list(it.inetAddresses) }
        .firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
        ?.hostAddress
```

## Жизненный цикл в службе (версия 2.1.19)

```kotlin
// AndroidCompanion/app/src/main/kotlin/com/macandroid/filemanager/runtime/FileDaemonService.kt
// Все переходы сервера — под lifecycleLock, в serviceScope (Dispatchers.IO).

private fun ensureServerLocked(refreshDiscovery: Boolean, restartReason: String? = null) {
    if (stopped) return
    val wanted = EmbeddedServer.findWifiIpv4Address()
    if (server != null) {
        if (restartReason != null) {
            DaemonLog.write(this, "Перезапуск сервера: $restartReason")
        } else if (wanted == boundHost) {
            if (refreshDiscovery) registerDiscoveryLocked()
            return
        } else {
            DaemonLog.write(this, "Адрес сервера изменился: ${addressLabel(boundHost)} → ${addressLabel(wanted)}")
        }
    }
    stopServerLocked()            // NSD unregister + server.stop(true): рвёт все активные сессии
    try {
        val newServer = EmbeddedServer(this, port = 2222, bindHost = wanted)
        newServer.start()
        server = newServer; boundHost = wanted; isServerListening = true
        DaemonLog.write(this, "SFTP-сервер запущен (адрес ${addressLabel(wanted)}, порт 2222)")
        retryAttempt = 0; cancelRetryLocked(); registerDiscoveryLocked()
    } catch (e: Exception) {
        stopServerLocked(); scheduleRetryLocked(e.message ?: "")   // повторы 5, 10, 20, 40, 60 с
    }
}

// Сетевые события: подписка только на TRANSPORT_WIFI.
// onAvailable / onLost / onLinkPropertiesChanged → ensureServerLocked(...)

// Самопроверка: раз в 30 с (без wakelock) и при открытии приложения.
private fun checkServerHealth(fromApp: Boolean = false) {
    val host: String?; val probed: EmbeddedServer
    synchronized(lifecycleLock) {
        if (stopped) return
        if (retryJob != null) { if (fromApp) ensureServerLocked(false); return }
        val current = server
        if (current == null || EmbeddedServer.findWifiIpv4Address() != boundHost) {
            ensureServerLocked(refreshDiscovery = false); return
        }
        host = boundHost; probed = current
    }
    // Проба вне lock: TCP connect к (boundHost ?: 127.0.0.1):2222, сначала 1 с, затем 3 с
    val failure = probeSftpPort(host, 1_000)?.let { probeSftpPort(host, 3_000) } ?: return
    synchronized(lifecycleLock) {
        if (stopped || server !== probed) return
        ensureServerLocked(false, restartReason = "проба порта ${addressLabel(host)} не прошла: $failure")
    }
}

private fun probeSftpPort(host: String?, timeoutMs: Int): String? =
    try {
        Socket().use { it.connect(InetSocketAddress(host ?: "127.0.0.1", 2222), timeoutMs) }
        null
    } catch (e: Exception) { "${e.javaClass.simpleName}: ${e.message}" }
```

# Факты

## До версии 2.1.19 (31.10.2026)
- 21:15 и 21:19: телефон отвечает на ping по 192.168.1.16 (RTT 190–300 мс). На порт 2222 — мгновенный `Connection refused`. Bonjour `_macphone_sftp._tcp` пуст.
- 21:17: экран компаньона показывает «Статус сервера: Запущен», IP 192.168.1.16. Флаг статуса статический и в новом процессе был бы false, значит процесс был прежний, а sshd в нём не слушал.
- IP на экране вычисляется заново при каждом обновлении, а не берётся из `boundHost`. Поэтому возможна и привязка к старому адресу.
- Последняя сессия с Mac оборвалась в 18:06 UTC: «Timeout, server not responding» (keepalive 10 с × 2).
- Журнал `ApplicationExitInfo` компаньона: смерти процесса до 29.10 — `OTHER KILLS BY SYSTEM`, description `OneKeyClean`; одна — `USER REQUESTED / FORCE STOP / LockScreenClean`. Новых записей после 29.10 нет, хотя сервер не слушал.
- Включение «Отладки по USB» на HyperOS 3 перезагрузило телефон в отдельный профиль «Режим отладки» (user 110). Компаньон там не установлен, журнал logcat до перезагрузки потерян. Поэтому снять `ss -ltn` и logcat на живой проблеме не удалось.

## Журнал событий сервера 2.1.19 (`Android/data/com.macandroid.filemanager/files/daemon.log`, 1–9.11.2026)
Выдержка, время локальное (+0100):
```
2026-11-01T16:21:05 Адрес сервера изменился: 192.168.1.16 → все интерфейсы
2026-11-01T16:21:21 Адрес сервера изменился: все интерфейсы → 10.7.22.37
2026-11-01T16:21:45 Адрес сервера изменился: 10.7.22.37 → все интерфейсы
2026-11-02T15:45:01 Перезапуск сервера: проба порта 192.168.1.16 не прошла: ConnectException: failed to connect to /192.168.1.16 (port 2222) from /192.168.1.16 (port 47642) after …
2026-11-05T10:34:23 Перезапуск сервера: проба порта 172.27.196.95 не прошла: ConnectException: failed to connect to /172.27.196.95 (port 2222) from /172.27.196.95 (port 40016) …
2026-11-05T11:14:19 Перезапуск сервера: проба порта 172.27.196.95 не прошла: ConnectException …
2026-11-05T14:43:44 Перезапуск сервера: проба порта 172.27.196.95 не прошла: ConnectException …
2026-11-06T19:25:37 Перезапуск сервера: проба порта 192.168.1.16 не прошла: ConnectException …
2026-11-06T20:03:46 Перезапуск сервера: проба порта 192.168.1.16 не прошла: ConnectException …
2026-11-07T12:25:53 Перезапуск сервера: проба порта 192.168.1.16 не прошла: ConnectException …
2026-11-07T16:33:53 Перезапуск сервера: проба порта 192.168.1.16 не прошла: ConnectException …
2026-11-09T13:06:54 Адрес сервера изменился: 192.168.1.16 → все интерфейсы
2026-11-09T13:06:56 Адрес сервера изменился: все интерфейсы → 192.168.68.64
2026-11-09T16:28:39 Адрес сервера изменился: 192.168.1.16 → все интерфейсы
2026-11-09T16:28:42 Адрес сервера изменился: все интерфейсы → 10.59.179.150
2026-11-09T16:28:48 Адрес сервера изменился: 10.59.179.150 → все интерфейсы
2026-11-09T18:30:21 Адрес сервера изменился: все интерфейсы → 192.168.1.16
```
После каждого перезапуска сервер сразу успешно стартовал на том же адресе. Обе пробы (1 с и 3 с) не прошли, то есть порт не принимал подключения дольше 4 с подряд. Сообщение «… after …» обрезано при выводе.

Адреса 10.x и 172.x — другие сети Wi-Fi (телефон носят с собой). Между ними сервер на минуты переходит на «все интерфейсы», потому что Wi-Fi-адреса нет.

## 9.11.2026, после 2.1.19
- 19:16:01 Mac подключился. 19:16:11 пользователь начал отправку файла 6,6 МБ на телефон.
- 19:18:45 сессия оборвалась на стороне Mac: `client_loop: ssh_packet_write_poll: Connection to 192.168.1.16 port 2222: Broken pipe`. Совпало ли это с перезапуском сервера на телефоне, не проверено: записи в daemon.log за это время ещё не прочитаны.
- Сейчас порт 2222 открыт: проверял раз в секунду 70 с подряд, закрывался ни разу. Bonjour объявление видно.

# Что уже исключено
- Не убийство процесса: `ApplicationExitInfo` новых смертей не показывает, экран приложения был открыт и показывал состояние живого процесса.
- Не отказ старта: перезапуск после провала пробы каждый раз стартует сразу.
- Не Mac-сторона для случая 31.10: `Connection refused` приходил и на `nc` из Терминала Mac.

# Вопросы
1. Какие механизмы Android 16 / HyperOS 3 могут закрыть или сделать недоступным слушающий TCP-сокет живого процесса так, чтобы приходил RST (`Connection refused`)? Разбери: `SOCK_DESTROY` / `destroyLiveTcpSockets` при смене firewall-цепочек (Doze, App Standby, background restriction, low power standby), «заморозку» процесса (cached apps freezer), особенности Xiaomi (OneKeyClean, Immobulus, «Защита от сетевых атак», Greeze). Что из этого применимо к слушающему сокету, а что только к установленным соединениям?
2. Почему проба `connect()` к собственному Wi-Fi-адресу с того же устройства получает `ConnectException`? Может ли это быть ложным срабатыванием (фаервол Android для uid приложения в фоне, маршрут через `lo`), а не смертью сокета? Как отличить одно от другого изнутри приложения без root?
3. Как Apache MINA SSHD 2.12.0 (Nio2Acceptor) ведёт себя, если система уничтожила слушающий сокет или пропал адрес, к которому он привязан (смена Wi-Fi, DHCP)? Замечает ли `SshServer.isOpen()`? Есть ли штатный способ узнать, что приёмник умер?
4. Правильно ли привязываться к конкретному адресу `wlan*` + `127.0.0.1`, или лучше слушать `0.0.0.0` и фильтровать входящие по интерфейсу/подсети? Какие риски у каждого варианта на Android (сотовая сеть, VPN, точка доступа, Wi-Fi Direct)? `findWifiIpv4Address()` берёт первый IPv4 среди всех `wlan*`: что будет на устройстве с wlan0 + wlan1/wlan2 (точка доступа, двойной Wi-Fi Xiaomi)?
5. Надёжна ли наша самопроверка? Перезапуск рвёт активные передачи: оценить риск ложных перезапусков (обрыв 19:18:45 во время передачи). Как сделать проверку, которая не перезапускает сервер, если он фактически обслуживает сессии (например, по счётчику активных сессий MINA или по времени последнего принятого подключения)?
6. Что ещё в конфигурации службы стоит поменять для HyperOS: тип foreground-службы (`dataSync` имеет 6-часовой лимит на Android 14+; подходят ли `connectedDevice`, `specialUse`?), постоянный WifiLock/WakeLock, исключения Xiaomi «Автозапуск», «Без ограничений», «Закрепить в недавних»? Что из этого можно проверить или запросить программно?
7. Какие данные нужно писать в daemon.log, чтобы следующий такой случай однозначно показал причину (например, `/proc/net/tcp` своего uid, состояние сокета MINA, `ActivityManager.getRunningAppProcesses` importance, `PowerManager.isDeviceIdleMode`, `ConnectivityManager.getRestrictBackgroundStatus`, `UsageStatsManager.getAppStandbyBucket`)? Какие из этих вызовов доступны без особых разрешений?

# Формат ответа
- По каждому вопросу: короткий вывод, затем обоснование со ссылками на исходники AOSP/MINA или документацию, где возможно.
- Явно разделяй: «проверенный факт / документировано», «вероятно», «предположение».
- Гипотезы о причине — списком по убыванию вероятности, к каждой: как подтвердить или опровергнуть на устройстве без root (команды adb или код), и что изменить в коде.
- В конце — рекомендуемая архитектура сервера и самопроверки в виде конкретных изменений к приведённому коду (Kotlin), минимальных и достаточных.
