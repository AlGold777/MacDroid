# Техническое задание: AndroidCompanion v2.2 — финальная редакция

**Статус:** финальная редакция, заменяет черновик от 16.11.2026. Готова к передаче разработчику / coding-агенту.
**Куда положить:** `docs/ТЗ_AndroidCompanion_v2.2.md` в репозитории (не полагаться на временные S3-ссылки).
**База:** `main @ 419dcd7` (проверенный HEAD), AndroidCompanion 2.1.20 (versionCode 22). Целевой релиз: **2.2.0 (versionCode 23)**, minSdk 26, targetSdk 34, compileSdk 34 — без изменений в этом релизе.

---

## 0. Проверенные факты (предпосылки, на которые опирается ТЗ)

Все пункты ниже верифицированы по исходникам `main@419dcd7`, Apache MINA SSHD `sshd-2.12.0` и публичным advisory. Агент должен считать их истинными и не «переоткрывать» их.

| # | Факт | Источник |
|---|---|---|
| F1 | MacHost **не вызывает** `mediastore_query` (0 упоминаний в `MacHost/`) | grep по дереву репозитория |
| F2 | MacHost **не читает** `action_receipts`/квитанции (0 упоминаний); БД лежит вне SFTP-корня `/storage` | grep + `EmbeddedServer.kt` |
| F3 | MacHost шлёт по SSH-exec только `authorize_key` (`ConnectionController.swift:505`); `df`/`ls` идут через `adb shell` | grep |
| F4 | На OpenSSH-пути MacHost уже задан `ServerAliveInterval=15` (`SessionCoordinator.swift:361`) | код MacHost |
| F5 | Swift-клиент MacHost декларирует окно 2 МБ / max packet 32 КБ (`SSHProtocolHandler.swift:140–141`); SFTP-каналы также идут через `/usr/bin/ssh` (дефолты OpenSSH 32 КБ/2 МБ) | код MacHost |
| F6 | **MINA вызывает `PublickeyAuthenticator.authenticate()` ДО проверки подписи**, в т.ч. в query-фазе (`hasSig=false`) — текущий код пишет первый ключ именно там → регистрация без доказательства владения | `UserAuthPublicKey.doAuth`, sshd-2.12.0 |
| F7 | **В MINA ЕСТЬ серверный heartbeat**: `CoreModuleProperties.HEARTBEAT_INTERVAL` (`"heartbeat-interval"`, default 0=off), `HEARTBEAT_REQUEST`, `HEARTBEAT_REPLY_WAIT`; `IDLE_TIMEOUT` default 10 мин | `CoreModuleProperties.java`, sshd-2.12.0 |
| F8 | API MINA подтверждены: `org.apache.sshd.server.forward.RejectAllForwardingFilter.INSTANCE`, `ChannelSessionFactory`, `SessionListener.Event.Authenticated` («session fully authenticated»), `AbstractGeneratorHostKeyProvider.setOverwriteAllowed` (default **true**), `setAlgorithm` (default **EC**, не Ed25519) | исходники sshd-2.12.0 |
| F9 | CVE-2026-94029 — memory exhaustion в SFTP v6 check-file расширениях, версии 1.0.0–2.19.0, исправлено в 2.20.0 (authenticated DoS) | cve.org / advisory Apache |
| F10 | CVE-2026-77185 — обход проверки подписи в **асинхронной** аутентификации, 2.0.0–2.19.0, исправлено в 2.20.0; компаньон использует синхронный authenticator → напрямую не применим | cve.org / advisory Apache |
| F11 | В `main` **нет** `PairingConfirmationReceiver`, `RejectAllForwardingFilter`, loopback-fallback — это предстоящие фиксы, а не текущее состояние | код `main` |
| F12 | `net.i2p.crypto:eddsa 0.3.0` — последняя версия библиотеки; необходима для Ed25519 на Android (у MINA нет Ed25519 без внешнего провайдера) | Maven / исходники MINA |
| F13 | Решение 2.1.20 «wake-локи на всю сессию» — осознанное: 30-минутный таймаут previously рвал простаивающие сессии при засыпании | комментарий `FileDaemonService.kt:376–380`, commit 317aff1 |

**Сильные части, не трогать без необходимости:** `lifecycleLock`-дисциплина, retry-backoff с проверкой идентичности job, двойная проба порта, NSD-generation + main-confinement, транспортные буферы/окна/лимиты (имена свойств сверены с MINA 2.12.0).

---

## 1. Цель и границы

**Цель:** production-ready по безопасности, устойчивости сети, ресурсам и качеству кода без поломки совместимости с MacHost.

**В границах:** `AndroidCompanion/` (Kotlin, MINA SSHD, NSD, FGS; Room — удаляется, см. 5.1).
**Вне границ:** MacHost (Swift). Протоколовые зависимости от MacHost зафиксированы в разделе 8.3 как D1–D5; без их выполнения соответствующие UX-критерии на Android-стороне считаются достигнутыми частично.

**Правило для агента:** каждый PR — атомарный, собирается, проходит тесты; рискованные изменения политики (7.2-эксперимент, targetSdk 35) — за флагами/в отдельных майлстоунах. Не менять транспортные настройки буферов без замеров.

---

## 2. Безопасность и TOFU

### 2.1. Fail-closed привязка к loopback (P0)

**Требование:** при отсутствии Wi-Fi (`wifiIpv4 == null`) сервер слушает **только** `127.0.0.1:2222`.

- `EmbeddedServer.start()`: `bindHost == null` → `host = "127.0.0.1"` (не `null`/все интерфейсы).
- Запрещена привязка к `rmnet*`, `tun*`, hotspot/AP-интерфейсам без явной пользовательской настройки (opt-in toggle, **по умолчанию выключен**, каждое включение и каждый fallback логируются в `daemon.log`).
- **NSD не регистрируется**, когда сервер слушает только loopback (сервис недостижим по Wi-Fi); при появлении Wi-Fi — регистрация вместе с ребайндом.
- Уведомление демона: «Wi-Fi недоступен — доступ только по кабелю (USB)».
- USB через `adb forward tcp:2222 tcp:2222` продолжает работать.

**Приёмка:** при выключенном Wi-Fi в `/proc/net/tcp` (или `adb shell ss -ltn`, если toybox-`ss` доступен) listener только на `127.0.0.1:2222`; NSD-сервис не виден в сети; USB-подключение работает.

### 2.2. TOFU: подтверждение пользователем + доказательство владения ключом (P0)

**Требование A (исправление F6):** первый ключ записывается в `authorized_keys` **только после успешной аутентификации с проверенной подписью** — в колбэке `SessionListener.sessionEvent(session, Event.Authenticated)`. Запись внутри `PublickeyAuthenticator.authenticate()` (query-фаза) **запрещена**.

**Требование B:** неизвестный ключ не принимается автоматически — нужно явное подтверждение на телефоне.

**Механика (рекомендуемая, неблокирующая):**

1. Состояния (companion-объект `EmbeddedServer`, под `pairingLock`): `WINDOW_OPEN` → `PENDING(key, fingerprint, sourceIp, createdAt)` → `APPROVED(key, expiresAt = конец окна)` → `ENROLLED`.
2. `authenticate()` для неизвестного ключа: **всегда `false`**. Если окно открыто и слот pending свободен — сохранить pending-ключ, показать prompt, залогироватьoffer. Повторные offer’ы при занятом слоте игнорируются и логируются (защита от флуда и подмены отпечатка после показа prompt).
3. Prompt: уведомление с SHA256-отпечатком ключа и кнопками «Принять»/«Отклонить» → `PairingConfirmationReceiver` (**`exported=false`**, explicit Intent, `PendingIntent.FLAG_IMMUTABLE`, уникальный `requestCode` на pending-id). Уведомление отменяется при resolve/таймауте/закрытии окна/сбросе сопряжения.
4. «Принять» → состояние `APPROVED` для **конкретных байтов ключа** (не «следующего подключившегося»); ключ ещё **не записан**. «Отклонить»/таймаут → очистка слота, лог.
5. MacHost повторяет подключение (зависимость **D1**). При retry authenticator видит `APPROVED`-ключ → `true` → MINA проверяет подпись → `Event.Authenticated` → **атомарная запись** (2.4) в OpenSSH-формате → закрытие окна → аудит-лог.
6. Окно: 60 с; закрывается после первого enrolled-ключа или по таймауту. `APPROVED` истекает вместе с окном.

**Fallback без `POST_NOTIFICATIONS` (Android 13+):**
- `MainActivity` на переднем плане → AlertDialog с тем же отпечатком и кнопками.
- Приложение в фоне → **fail-closed**: ключ не принимается, событие логируется; Mac получает отказ аутентификации (Mac-сторона показывает подсказку «откройте приложение на телефоне», D1). **Не пытаться стартовать Activity из фона** (ограничения Android 10+).

**Аудит (#18):** каждое событие (offer / prompt / approve / reject / enroll / timeout / отказ вне окна) → `daemon.log`: время, IP источника, SHA256-отпечаток, результат.

**Известные ключи:** путь аутентификации сохранённым ключом не меняется. `authorize_key` остаётся доступным для enrolled-сессий (миграция ключа MacHost, F3), но каждое добавление логируется и видно в UI ключей (2.5). Ужесточение `authorize_key` (только в окно/с подтверждением) — P2-опция, согласовать с MacHost, не ломать миграцию.

**Приёмка:**
- без тапа «Принять» ключ не сохраняется;
- **query-only offer (без подписи) никогда не приводит к записи ключа** (инструментальный тест);
- enroll происходит только после `Authenticated`;
- при отказе `POST_NOTIFICATIONS` и foreground — диалог; background — явный отказ, не молчание;
- флуд offer’ов → один prompt, остальные логируются;
- существующее сопряжение продолжает работать без изменений.

### 2.3. Ограничение возможностей SSH (P1)

- `forwardingFilter = RejectAllForwardingFilter.INSTANCE` (`org.apache.sshd.server.forward`).
- `channelFactories = listOf(ChannelSessionFactory.INSTANCE)` — только session-channel.
- `keyboardInteractiveAuthenticator = null` явно; `passwordAuthenticator = null` (уже так).
- Shell не исполняется (CommandFactory-whitelist сохраняется).

**Приёмка:** `ssh -L`/`-R`/`-D` отклоняются; direct-tcpip канал не открывается; пароль/keyboard-interactive недоступны.

### 2.4. Host-key и authorized_keys (P1)

- `SimpleGeneratorHostKeyProvider`: `setAlgorithm("Ed25519")` — **только для генерации нового ключа**. Существующий `hostkey.ser` читается как есть (алгоритм влияет лишь на генерацию) — **регенерация при обновлении запрещена**.
- `setOverwriteAllowed(false)`: повреждённый/нечитаемый файл → диагностируемая ошибка (alert-уведомление + `daemon.log` + статус в UI), **не тихая перегенерация**.
- README привести в соответствие: новые установки — Ed25519; существующие сохраняют ранее выданный ключ (EC).
- Запись `authorized_keys` — атомарная: temp-файл в том же каталоге + `Files.move(ATOMIC_MOVE)`; при `AtomicMoveNotSupportedException` — fallback `renameTo` с логированием.
- Формат: новые записи — OpenSSH (`ssh-ed25519 AAAA… macdroid-<дата>`); **чтение legacy raw-Base64 сохраняется** (обратная совместимость); опционально разовая миграция формата при старте.
- `isPaired()` — по наличию **корректно разобранного** доверенного ключа, а не по длине файла (#22).

**Приёмка:** обновление поверх существующей установки не меняет отпечаток хост-ключа (тест); повреждение файла → ошибка, не новый ключ; kill процесса во время записи → файл цел (тест); legacy-ключ продолжает аутентифицировать.

### 2.5. Управление доверенными ключами (P2)

- Метаданные ключей (дата добавления, источник, метка), список SHA256-отпечатков в UI, **выборочный отзыв** без полного сброса (#19).
- «Сбросить сопряжение» — только с confirm-диалогом; кнопка скрыта/заблокирована при отсутствии ключей (см. 9.2).

---

## 3. Сеть и ребайндинг

### 3.1. Pending-rebind вместо жёсткого рестарта (P0)

**Требование:** смена/потеря Wi-Fi-адреса не убивает сервер при активных сессиях.

- Источник счётчика — единый in-process `SessionStateTracker` (4.1), **не интенты**.
- Смена адреса при `activeSftpSessions > 0`: сохранить `pendingRebind = новый адрес` (**последний выигрывает**), `stopServerLocked()` не вызывать.
- Закрытие последней сессии → под `lifecycleLock` **перепроверить счётчик**: если 0 и есть pending → ребайнд; если открылась новая сессия → снова отложить.
- USB/loopback-сессии защищаются equally: сетевой флап не рвёт их.
- «Залипание» на старом IP при вечно живых idle-сессиях исключается idle-timeout (4.3): idle-сессия закрывается → счётчик 0 → ребайнд.
- При ребайнде: NSD unregister/register согласно 2.1 (loopback-only → без NSD).

**Приёмка:** активная USB-передача через `adb forward` не обрывается при кратковременной потере/восстановлении Wi-Fi (инструментальный тест); после закрытия последней сессии сервер привязан к актуальному адресу; idle-сессия после idle-timeout триггерит отложенный ребайнд.

### 3.2. Дебаунс сетевых событий 2 с с OR-аккумуляцией (P1)

**Требование:** флаг `refreshDiscovery` не теряется при быстрых последовательных событиях; вход дебаунса **не берёт `lifecycleLock` на main-потоке** (callback ConnectivityManager по умолчанию на main).

```kotlin
private var pendingRefreshDiscovery = false   // доступ только под lifecycleLock
private var networkDebounceJob: Job? = null   // доступ только под lifecycleLock

private fun onNetworkChanged(refreshDiscovery: Boolean) {
    // НЕ synchronized здесь: callback может быть на main
    serviceScope.launch {
        synchronized(lifecycleLock) {
            if (stopped) return@launch
            pendingRefreshDiscovery = pendingRefreshDiscovery || refreshDiscovery
            networkDebounceJob?.cancel()
            networkDebounceJob = serviceScope.launch {
                delay(2_000)
                synchronized(lifecycleLock) {
                    if (stopped) return@launch
                    val refresh = pendingRefreshDiscovery
                    pendingRefreshDiscovery = false
                    networkDebounceJob = null
                    ensureServerLocked(refreshDiscovery = refresh)
                }
            }
        }
    }
}
```

**Приёмка:** `onAvailable(true)` + `onLinkPropertiesChanged(false)` с разницей 100 мс → NSD перерегистрируется; старт сервера при boot не задерживается дебаунсом (прямой путь `onCreate` сохраняется).

### 3.3. Health-check: guard активных сессий (P1)

Сохранить: двойную пробу (1 с + 3 с), проверку `server === probed`, backoff. **Добавить:** если `activeSftpSessions > 0` или был файловый I/O за последние N секунд (по `elapsedRealtime`, N = 30) — probe-triggered рестарт **пропускается** с записью в лог (живая передача доказывает работоспособность; проба под нагрузкой может дать ложный отказ). Адресный ребайнд регулируется 3.1, не этим путём.

**Приёмка:** имитация отказа пробы во время активной передачи → сервер не перезапускается, сессии живы.

### 3.4. Единый источник Wi-Fi IPv4 и UI-адрес (#5, #12) (P1)

- Один `WifiAddressProvider` для bind-решений сервера, UI и NSD. Предпочтительный источник: `LinkProperties` Wi-Fi-сети (`TRANSPORT_WIFI`, не default — VPN не влияет), IPv4; fallback —枚举 интерфейсов с явной политикой (STA `wlan*`, исключая AP/p2p по мере определимости).
- UI: копируемая команда `sftp -P 2222 <ip>` **только при валидном Wi-Fi-адресе**; иначе — отдельная USB-инструкция: `adb forward tcp:2222 tcp:2222` + `sftp -P 2222 127.0.0.1`.
- P2: показать фактическое NSD-имя из `onServiceRegistered` (включая суффикс конфликта) (#11).

**Приёмка:** UI и сервер всегда показывают/используют один адрес; при отсутствии Wi-Fi нет误导性 команды с `127.0.0.1` как «Wi-Fi».

---

## 4. Сессии, lifecycle, энергия

### 4.1. Единое in-process состояние сессий (P0, фундамент для 3.1/3.3/4.2) (#47)

- Удалить интенты `ACTION_ACTIVE_SYNC_START/STOP` как механизм управления локами.
- `SessionStateTracker` (process singleton): `AtomicInteger sftpSessions` (инкремент в `initialized`, декремент в `destroying` с clamp ≥ 0), `@Volatile lastIoElapsedRealtime`,generation для устаревших событий.
- Listener вызывает трекер напрямую; сервис читает трекер под `lifecycleLock`; переходы 0→1 / 1→0 запускают acquire/release локов **на одном выделенном Handler** (4.2).
- Различать `CONNECTED` и `TRANSFERRING` (по `lastIoElapsedRealtime`) для UI/уведомления.

**Приёмка:** одновременное закрытие последней и открытие новой сессии не приводит к потере wake-лока (тест); никаких `startService` из NIO-потоков.

### 4.2. WakeLock/WifiLock: потокобезопасность (P0) (#43)

- Все acquire/release — **на одном Handler** (main) либо под единой блокировкой; никакого check-then-act с двух потоков.
- `wakeLock.setReferenceCounted(false)` (у wifiLock уже так).
- **Политика удержания по умолчанию — session-long (решение 2.1.20, F13), не менять.**
- P2-эксперимент за флагом: locks только вокруг I/O + grace ≥ 60 с; допускать только после замеров Doze/screen-off; критерий отката — любой обрыв長 передачи при выключенном экране.
- Redundant 30-секундный ping-IPC из `writing/reading` удалить **после** 4.1 (сейчас он страховка от гонки); все throttle-интервалы — на `SystemClock.elapsedRealtime` (#48).
- Задокументировать: `WIFI_MODE_FULL_HIGH_PERF` deprecated с API 34 → автозамена на LOW_LATENCY (неактивен при выключенном экране); реальную работу делают PARTIAL_WAKE_LOCK + исключение из оптимизации батареи (#49).

**Приёмка:** гонка acquire/release воспроизводится тестом до фикса и не воспроизводится после; двойной release не бросает исключений.

### 4.3. Idle-timeout и heartbeat (P1)

- Сервер: `idle-timeout = 3–5 мин` (явно), **`heartbeat-interval = 20 с`** (свойство существует, F7), `heartbeat-reply-wait` — подобрать (например 60 с). Heartbeat совместимость с OpenSSH-клиентом проверить в регрессе.
- MacHost: OpenSSH-путь уже имеет `ServerAliveInterval=15` (F4); для Swift-клиента — keepalive как зависимость **D4** (опционально).
- Эффект: мёртвые сессии закрываются своевременно → локи освобождаются → pending-rebind срабатывает.

**Приёмка:** оборванный кабель/усыплённый клиент → сессия закрывается в пределах idle/heartbeat-таймаута, локи освобождены.

### 4.4. `onDestroy` без блокировки main (P1)

- Все lifecycle-операции (start/stop/rebind) — на выделенном последовательном executor.
- `onDestroy`: выставить `stopped`, `stopForeground` немедленно, очистку post’ить на executor с watchdog ~2 с, **не ждать `lifecycleLock` на main**; очистка best-effort (смерть процесса всё равно освобождает порт). Executor очистки не должен отменяться вместе с `serviceScope` до завершения.

**Приёмка:** `onDestroy` при занятом lifecycleLock (имитация долгого start) не блокирует main > 100 мс.

### 4.5. dataSync: таймаут и восстановление (P2)

- `onTimeout` уже корректен — сохранить; при targetSdk 35 — двухаргументный `onTimeout(startId, fgsType)` (майстоун 6.3).
- **Сторож:** WorkManager periodic (15–30 мин) проверяет `shouldAutostart && !isRunning`. **Не вызывать `startForegroundService` из воркера** (запрещено из фона на 12+). Вместо этого — notification «Сервер остановлен — нажмите для запуска»; тап → foreground → легальный старт.
- Автозапуск после BOOT_COMPLETED/MY_PACKAGE_REPLACED сохраняется (exemptions, targetSdk 34). При targetSdk 35 dataSync-from-boot запрещён → сценарий заменяется на notification-prompt (майлстоун 6.3).
- `CompanionDeviceManager` presence — легальная альтернатива для фонового старта; оформить как отдельное исследование, **не внедрять по умолчанию** в v2.2.
- Явный пользовательский контроль автозапуска (#38): toggle в UI «Автозапуск после перезагрузки», текущая семантика `user_stopped` сохраняется.

### 4.6. Ошибки запуска FGS (P0) (#32, #33, #34)

- `try/catch` (`ForegroundServiceStartNotAllowedException` и др.) вокруг **всех** UI-точек `startForegroundService` (`onCreate`, `onResume`, кнопка) → причина в карточке статуса + счётчик отказов.
- `stopDaemonService()` при мёртвом сервисе: только флаг `user_stopped` / `stopService()`, **без** `startService(ACTION_STOP)` ради остановки.
- При отказе `POST_NOTIFICATIONS` критические ошибки (сбой старта, лимит, перезапуски) видны в UI, не только в уведомлении.

**Приёмка:** имитация запрета FGS → приложение не падает, причина видна в UI.

---

## 5. Журнал, MediaStore, контракт коммита

### 5.1. Удаление write-only журнала с сохранением Media-хуков (P1)

Подтверждено F2: MacHost квитанции не использует. **Вариант A — удалить.**

**Порядок обязателен:**
1. **Сначала** вынести из `recordCommit`/`recordDeletion` полезную media-логику в отдельный лёгкий компонент (`MediaSyncHelper`): scan конечного файла при коммите `.part`; удаление записи MediaStore по `DATA` + scan при удалении. Сохранить debounce/батчинг (чанки по 100) для массовых операций. Вызов — асинхронно через `ioScope` listener’а (как сейчас).
2. Затем удалить: `ActionJournalDb`, `ActionReceipt`, DAO, `recordCommit`/`recordDeletion` (journal-части), `commitFileAtomic`, `deleteFileVerified`, `getReceipt`, `updateStatus`.
3. Убрать зависимости Room (`room-runtime`, `room-ktx`, `room-compiler`/KSP), если больше не используются.

**Вариант B (future, вне v2.2):** только если появится recovery-протокол: `PREPARED → FILE_APPLIED → COMMITTED`, стабильный `actionId` + `requestHash` от MacHost, reconciliation, TTL 30 дней, exec-команда чтения квитанции. Не реализовывать «на всякий случай».

**Приёмка:** галерея корректна после SFTP-удаления/коммита на тестовом API 26–29 (и 30+); Room отсутствует в зависимостях; APK собирается.

### 5.2. Удаление `mediastore_query` (P1)

Подтверждено F1. Удалить exec-команду, `queryMediaFolder`, `escapeLikePattern`, `sanitizeField` целиком. Если понадобится в будущем — только с `LIMIT`, пагинацией и потоковой выдачей, вне сетевого обработчика.

**Приёмка:** команда отвечает `UNKNOWN COMMAND` / exit 1 (6.1); MacHost не регрессировал.

### 5.3. Строгий контракт `.part` / `.mcdpart` / `.mcdedit` (P2, зависимость D3)

- Зафиксировать с MacHost точный формат временных имён (например скрытый `.<name>.mcdpart` или `.part.<actionId>.<name>` — выбрать один), парсить **anchored regex с группами**, не `contains`.
- Переходный период: один релиз принимать старый формат с deprecation-логом.
- Включить в контракт имена снапшотов внешних правок (`.mcdedit-*`).

**Приёмка:** rename пользовательского файла `my.part.notes.txt` не триггерит commit-хук; ложные срабатывания исключены тестами.

---

## 6. Сборка, зависимости, платформа

### 6.1. R8/ProGuard и чистка зависимостей (P1)

- Release: `isMinifyEnabled = true` + `shrinkResources = true`.
- Keep-правила: `org.apache.sshd.**`, **`net.i2p.crypto.eddsa.**`** (заменить балластные BouncyCastle-правила), `javax.management`-заглушки (документировать их назначение в шапке файлов). Room-правила удалить вместе с Room.
- Убрать неиспользуемые `appcompat`, `material`; проверить и убрать `coroutines-android`, если `Dispatchers.Main` не используется.
- **Smoke-тест release APK:** Ed25519-аутентификация, генерация host-key, SFTP-передача, NSD, перезапуск после kill.
- P2: signingConfig для release (документировать keystore).

### 6.2. Обновление MINA SSHD 2.12.0 → 2.20.1 (P1, отдельный PR)

- Мотивация: CVE-2026-94029 (F9, authenticated DoS через SFTP v6 check-file расширения — проверить, какие расширения реально экспонируются) и CVE-2026-77185 (F10, напрямую не применим к синхронному authenticator, но класс уязвимости — аутентификация).
- **Регресс обязателен:** имена транспортных свойств, SFTP-лимиты, поведение host-key provider, heartbeat, совместимость с OpenSSH-клиентом и Swift-клиентом MacHost, eddsa-провайдер.
- **`net.i2p.crypto:eddsa 0.3.0` оставить** (F12): это последняя версия, она нужна для Ed25519. Замена на BouncyCastle — опционально, не требование v2.2.

### 6.3. Майлстоун targetSdk 35 (P2, отдельный релиз, не смешивать с P0/P1)

- compileSdk 35; edge-to-edge + insets для программного UI; двухаргументный `onTimeout`; квота dataSync 6 ч/24 ч; **запрет dataSync из BOOT_COMPLETED** → автозапуск через notification-prompt (4.5) или CDM-исследование.
- Обновить AGP/Kotlin/Gradle согласованно; проверить матрицу устройств (HyperOS).

### 6.4. Gradle-гигиена (P2)

- Заменить самописный `gradlew` официальным wrapper (`gradle wrapper`); добавить `distributionSha256Sum`.
- `user.home` для MINA выставлять **только в `CompanionApp`** (убрать дубли в сервисе/сервере) (#83).
- P2-мелочи: `df` по всем реальным томам (SD/OTG) (#70); `daemon.log` — минимизировать чувствительные пути в содержимом, принять остаточный риск чтения на API ≤29 (#29).

---

## 7. UI (MainActivity)

### 7.1. Recreate и первый запуск (P1)
- `checkInitialPermissions()` и `startDaemonService()` в `onCreate` — только при `savedInstanceState == null` (поворот не переоткрывает настройки/диалоги).
- **Настройки батареи никогда не открывать автоматически** (в т.ч. при первом запуске) — только по кнопке (#42). Сохранить OEM-переходы PowerKeeper/автозапуск/энергосбережение (#41).

### 7.2. Confirm-диалоги (P2)
- «Сбросить сопряжение» — AlertDialog с подтверждением; скрыть/заблокировать при отсутствии доверенных ключей.

### 7.3. StatusSnapshot вне UI-потока (P2) (#51, #52)
- `isPaired()`, `StatFs`, IP, состояние ключей/сервиса — вычислять в IO, публиковать кэшированный снапшот, обновлять по событиям; убрать `getRunningServices` → in-process `isRunning`/binder.

### 7.4. POST_NOTIFICATIONS (P2) (#76)
- Запрос один раз; учитывать `shouldShowRequestPermissionRationale`; повтор — по явному действию пользователя.

### 7.5. Видимость (P2)
- Активные SSH/SFTP-сессии и состояние подключений (#77); фактическое NSD-имя (#11); список отпечатков доверенных ключей (2.5); причины отказов/сбоев (4.6).

### 7.6. Ресурсы и нейминг (P2) (#74)
- Строки/цвета/порт/имя — в ресурсы/константы; устранить расхождение Commander/Companion; явный `statusHandler` вместо `View.postDelayed` внутри `apply` (#78).
- P2-рефакторинг: разнести MainActivity по контроллерам (permissions/pairing/status) (#73) — не блокирует релиз.

---

## 8. Протокол с MacHost

### 8.1. Неизвестные exec-команды (P1)
- `exit 1` + `"UNKNOWN COMMAND"` вместо `OK`/exit 0. **Совместимость подтверждена F3:** MacHost шлёт только `authorize_key`.

### 8.2. Лимиты канала (P3, информационно — не блокирует релиз)
- 32 КБ/2 МБ — дефолты OpenSSH и значения Swift-клиента (F5); это **не баг**: пайплайнинг достаточен для Wi-Fi/USB (малый BDP).
- Серверные 64 КБ packet-size **не снижать** (они выгодны для upload-направления).
- Поднятие max packet Swift-клиента до 64 КБ — только если замеры покажут выигрыш; OpenSSH-путь не конфигурируется.

### 8.3. Зависимости от MacHost (зафиксировать, вне скоупа)
| ID | Зависимость | Нужно для |
|---|---|---|
| D1 | Retry подключения в окне сопряжения (авто каждые 3–5 с до успеха/закрытия окна) + подсказка «откройте приложение на телефоне» при отказе | 2.2 UX |
| D2 | Показ SHA256-отпечатка клиентского pubkey на экране Mac для сверки | 2.2 |
| D3 | Согласование строгого формата `.part`/`.mcdpart`/`.mcdedit` | 5.3 |
| D4 | Keepalive в Swift-SSH-клиенте (OpenSSH-путь уже покрыт) | 4.3, опционально |
| D5 | Существующий UX сброса pinned host-key (для новых Ed25519-установок/переустановок) | 2.4 |

---

## 9. Тесты и CI (P1)

**Unit (JVM/Robolectric):**
- парсинг `authorized_keys` (OpenSSH + legacy Base64);
- state-машина сопряжения: window/pending/approved/enrolled, таймауты, флуд, **query-only offer не enroll’ит**;
- regex `.part`/`.mcdpart` (включая ложные имена);
- retry-backoff, NSD-generation, OR-дебаунс, условия автозапуска, ротация `daemon.log`.

**Instrumented:**
- старт sshd, pubkey-auth, enroll только после подписанного auth;
- loopback-only bind при выключенном Wi-Fi;
- USB-передача + Wi-Fi-флап (pending-rebind);
- health-guard под нагрузкой;
- rename `.part` → MediaScanner; удаление → очистка MediaStore;
- kill процесса во время записи `authorized_keys` (атомарность);
- восстановление после process kill.

**Ручная матрица:** API 26–29 (legacy storage), 30+ (MANAGE_EXTERNAL_STORAGE), 13 (отказ уведомлений), 14 (dataSync timeout), HyperOS (screen-off/Doze, автозапуск), Android 15-устройство с targetSdk 34.

**Замеры (#89):** 1000 коротких файлов, параллелизм 6, большой файл при выключенном экране, расход батареи idle-подключения, рестарты.

**CI (корректные команды; корневого Gradle-проекта нет):**
```bash
cd AndroidCompanion
./gradlew :app:testDebugUnitTest :app:lintDebug
./gradlew :app:assembleRelease   # smoke R8
```
На каждый PR; instrumented — на устройстве/эмуляторе перед релизом. P2: скан уязвимостей зависимостей.

---

## 10. Приоритеты и порядок работ

| Приоритет | Задачи |
|---|---|
| **P0** | 2.1 loopback fail-closed; 2.2 TOFU+proof-of-possession; 3.1 pending-rebind; 4.1 SessionStateTracker; 4.2 потокобезопасность локов; 4.6 ошибки запуска FGS |
| **P1** | 2.3, 2.4 (atomic write, overwriteAllowed, isPaired); 3.2, 3.3, 3.4; 5.1, 5.2; 6.1, 6.2; 4.3, 4.4; 8.1; 7.1; 9 |
| **P2** | 2.5; 4.5; 5.3; 6.3 (отдельный майлстоун), 6.4; 7.2–7.6; 4.2-эксперимент |
| **P3** | 8.2 |

**Последовательность PR (каждый самостоятельно собирается и тестируется):**
1. **PR-1 фундамент:** SessionStateTracker + потокобезопасность локов + elapsedRealtime (4.1, 4.2, часть 4.6).
2. **PR-2 сеть:** loopback fail-closed + pending-rebind + OR-дебаунс + health-guard + единый IP-провайдер (2.1, 3.1–3.4).
3. **PR-3 сопряжение:** proof-of-possession + confirmation + аудит + atomic write + host-key policy + isPaired (2.2, 2.4). Параллельно — D1/D2 с Mac-стороной.
4. **PR-4 журнал:** вынос media-хуков → удаление журнала/Room → удаление `mediastore_query` (5.1, 5.2).
5. **PR-5 протокол/сборка:** unknown-exec exit 1; R8 + keep + чистка зависимостей; MINA 2.20.1 отдельным коммитом с регрессом (8.1, 6.1, 6.2).
6. **PR-6 lifecycle:** idle/heartbeat, onDestroy-executor, сторож-notification, FGS-ошибки UI (4.3–4.6).
7. **PR-7 UI:** recreate/first-launch, confirm, snapshot, notifications, видимость (7.x).
8. **PR-8 тесты/CI:** покрывать каждый PR по мере поступления; финальный прогон матрицы и замеров.

---

## 12. Definition of Done

- [ ] Все P0 закрыты и покрыты тестами; P1 закрыты или явно перенесены с обоснованием.
- [ ] При выключенном Wi-Fi listener только `127.0.0.1:2222` (`/proc/net/tcp`), NSD не регистрируется; USB работает.
- [ ] Активная USB-передача не рвётся при Wi-Fi-флапе; ребайнд после закрытия последней сессии.
- [ ] Первый ключ требует тапа «Принять» **и** enroll только после проверенной подписи; query-only offer не enroll’ит (тест).
- [ ] Обновление поверх существующей установки не меняет host-key отпечаток; повреждённый файл → диагностируемая ошибка, не регенерация.
- [ ] `authorized_keys` атомарен (kill-тест); legacy-формат читается.
- [ ] Журнал и Room удалены; **MediaScanner/MediaStore-хуки сохранены** (галерея-тест на 26–29 и 30+).
- [ ] `mediastore_query` удалён; unknown exec → exit 1; MacHost не регрессировал.
- [ ] R8 включён; release APK проходит Ed25519/SFTP/NSD smoke; eddsa не вырезан.
- [ ] MINA 2.20.1: регресс пройден (свойства, лимиты, host-key, heartbeat, OpenSSH/Swift-клиенты).
- [ ] CI зелёный: `cd AndroidCompanion && ./gradlew :app:testDebugUnitTest :app:lintDebug` + release-сборка.
- [ ] Длинная передача при выключенном экране (Doze/HyperOS) стабильна; расход батареи idle-подключения измерен и приемлем.
- [ ] README/AGENTS.md обновлены (алгоритм host-key, протокол, автозапуск); ТЗ лежит в `docs/`.
- [ ] Зависимости D1–D5 переданы Mac-стороне; D1/D2 выполнены или UX-критерий 2.2 отмечен как частично достигнутый.

---

## 13. Антирегрессионная проверка локальной сборки (по аудиту от 17.11)

Локальная рабочая копия содержит частичную реализацию v2.2, не запушенную в main (419dcd7). Перед приёмкой прогнать по локальной копии:
1. **Журнал:** убедиться, что запись квитанций не синхронная в потоке сокета (insertReceiptSync/recordCommitSync недопустимы); выполнить ТЗ 5.1 (вынос media-хуков → удаление журнала/Room).
2. **Сопряжение (P0, F6):** подтвердить, что enroll происходит только в `SessionListener.Event.Authenticated`; тест «query-only offer не записывает ключ». Проверить fallback без `POST_NOTIFICATIONS`, привязку approve к байтам ключа, единственный pending-слот, отмену prompt при закрытии окна (ТЗ 2.2).
3. **Сеть:** pending-rebind в `onNetworkChanged` (не только guard в health-check) — ТЗ 3.1; дебаунс с OR-аккумуляцией и без `lifecycleLock` на main — ТЗ 3.2; тест «`onAvailable(true)`+`onLinkPropertiesChanged(false)` через 100 мс → NSD перерегистрируется».
4. **idle-timeout:** 3–5 мин (не 15) + серверный heartbeat-interval — ТЗ 4.3.
5. **Локи:** политика по умолчанию session-long (2.1.20); acquire/release на одном Handler, `setReferenceCounted(false)` — ТЗ 4.2. I/O-only — только за флагом с замерами.
6. **Host-key:** существующий `hostkey.ser` не перегенерируется при обновлении; `setOverwriteAllowed(false)`; атомарная запись `authorized_keys` — ТЗ 2.4.
7. **Сборка:** R8 + keep `net.i2p.crypto.eddsa.**`; smoke release (Ed25519/SFTP/NSD) — ТЗ 6.1.
8. **Микро-правки (новые):** `DaemonLog` — статический `DateTimeFormatter` вместо per-call `SimpleDateFormat` (P2, 6.4); зафиксировать JDK 17 (toolchain / `org.gradle.java.home`), CI на JDK 17 (6.4/9).
9. **Единый источник правил:** implementation вести только по этому ТЗ; сторонние rulebook’и (метки «H3», «D1» из аудита) не использовать как источник требований.
10. Локальную ветку запушить в GitHub для независимой верификации; до этого пункты 1–7 — обязательные к ручному/инструментальному прогону.
