# Peer review 2026-10-22 — сводка находок

Источник: 5 независимых ревью (Haiku 5.5), только статический анализ кода. Кабель/USB-соединение вне области.
Пути относительно `MacHost/Sources/MacHostCore/` (Swift) и `AndroidCompanion/app/src/main/kotlin/com/macandroid/filemanager/` (Kotlin, `A:`). Каталог `mac_android_filemanager_v2/` — устаревшая копия, не трогать.
Каждую находку перед правкой проверить по коду (ревью могло ошибаться); если не подтверждается — пропустить и записать в отчёт.

## P0 — потеря данных / безопасность

### Потеря и порча данных
- D1. Core/JobOrchestrator.swift:230-261, 426-441, 698-713; Core/TransferJournal.swift:249-279 — журнал не получает статус «completed»; `findResumableTransfer` ищет только по source, не по target; при возобновлении проверяется только 4 КБ префикса. Итог: коммит файла с дырами. Исправить: ключ по target-пути, статус completed при успехе, проверка длины temp-файла ≥ frontier.
- D2. Core/TransferJournal.swift:134-289, Core/IntentLedger.swift:119-157 — `sqlite3_bind_text` с `(x as NSString).utf8String` и destructor nil (UB). Исправить: SQLITE_TRANSIENT.
- D3. Core/JobOrchestrator.swift:404-411 + Transport/PhoneConnectionManager.swift:194-204 — fallback `rm -f` через adb без привязки к устройству SFTP-сессии (может удалить файл на другом телефоне). Привязать serial или отказаться от fallback. То же в Core/SearchService.swift:61-101.
- D4. Core/JobOrchestrator.swift:507, 526, 650-653 — проверка существования цели через `try?` читает сетевую ошибку как «файла нет» → posix-rename затирает файл. Различать noSuchFile и прочие ошибки.
- D5. Core/JobOrchestrator.swift:871-884 — Mac→Mac move при совпадении источника и цели удаляет единственную копию. UI/DualPaneViewModel.swift:4238-4263, 3668-3692, 3582-3628 — нет guard «та же папка». Добавить guard в оркестраторе и в UI-путях (drop из Finder тоже).
- D6. UI/DualPaneViewModel.swift:3748 (`?? .overwrite`) + UI/Views/MainContentView.swift:44-50 — диалог конфликтов мёртвый (`showConflictDialog`/`activeConflict` не назначаются), всё молча перезаписывается. Подключить детект конфликтов, по умолчанию skip.
- D7. UI/DualPaneViewModel.swift:2111-2200 + Drivers/LocalFSDriver.swift:78-101 — rename поверх существующего файла уничтожает его. Проверка существования, ошибка «уже существует».
- D8. UI/Views/BatchRenameModalView.swift:176-195, DualPaneViewModel.swift:2721-2741 — конфликты с существующими файлами и циклы (A→B, B→A) не детектятся. Проверять цели по листингу; циклы через временные имена.
- D9. UI/DualPaneViewModel.swift:3901-3920, Transport/PhoneConnectionManager.swift:233-238, Transport/TransportMultiplexer.swift:529-537 — phone→phone copy/move игнорирует стратегию конфликтов (`cp -p`, posix-rename); результат `executeDelete` игнорируется (`_ = try?`). Проверять цель; `cp -n`/не-перезаписывающий rename; учитывать результат удаления.
- D10. UI/DualPaneViewModel.swift:2909-2912 + Services/ArchiveService.swift:103-105 — существующий архив удаляется до создания нового (и destURL может быть папкой/источником). Создавать во временное имя и заменять атомарно; отказ если dest не обычный файл или совпадает с источником.
- D11. UI/DualPaneViewModel.swift:3434, 3525-3526; UI/Views/FileGridPaneView.swift:706-709, 868-870; PaneView.swift:2146-2148 — устаревший drag-payload перехватывает внешние drop из Finder. Сбрасывать по окончании drag.
- D12. UI/DualPaneViewModel.swift:2464, 2542, 2923, 3016, 3061 + Core/TransferQueueManager.swift:99-109 — операции только ставятся в очередь, исполнителя нет, при этом рапортуют успех и удаляют temp-вывод. Исполнять через оркестратор либо честно сообщать об ошибке; не удалять temp до завершения.
- D13. Core/JobOrchestrator.swift:415-421 — после неудачного удаления ошибка prepareRead трактуется как «удалено». Только noSuchFile = удалено, иначе transferredWithoutSourceDeletion. 360-364 — неудачный stat = indeterminate, не коммитить.
- D14. Core/JobOrchestrator.swift:159 + Drivers/LocalFSDriver.swift:110-116 — checkFreeSpace возвращает 0 при ошибке/переполнении и проверка пропускается. Вернуть optional.
- D15. Core/JobOrchestrator.swift:304-308, TransportMultiplexer.swift:285, 322 — чекпоинты без fsync. fsync перед чекпоинтом или перепроверка при resume.
- D16. Services/ArchiveService.swift:126-155 — мультиисточники из разных папок архивируются по lastPathComponent относительно первой папки. Отказ или staging.
- D17. UI/Views/ImageViewerModalView.swift:12, 153-200 — preloadedImages без вытеснения (OOM). Окно ±2 или NSCache.

### Безопасность Wi-Fi (см. раздел ниже)

## P1 — Wi-Fi соединение (отдельный блок)

- W1 (High). A:server/EmbeddedServer.kt:31-53 — SSHD слушает все интерфейсы; 60-секундное окно сопряжения принимает первый попавшийся ключ без подтверждения. Привязать к адресу Wi-Fi-интерфейса; показывать на телефоне отпечаток/код и требовать подтверждения; окно одноразовое.
- W2 (High). Transport/HostKeyStore.swift:42-52, Transport/ConnectionController.swift:207-214, 267-279 — пин ключа хоста привязан к `host:port` и не сверяется с pinnedFingerprint устройства; смена IP (DHCP) ведёт к принятию чужого ключа и записи его как доверенного. Привязать пин к device id; при несовпадении отказ.
- W3 (High). UI/Views/PairingModalView.swift:251, ConnectionController.swift:256-264 — ключ телефона берётся ssh-keyscan по сети и пинится по клику, без сверки; Android не показывает отпечаток. Показать отпечаток хост-ключа в MainActivity и в Mac-диалоге, подтверждение сопоставлением.
- W4 (High). ConnectionController.swift:267-271, 300-348; SessionCoordinator.swift:222-226; DeviceRegistry.swift:75-79, 186-201 — личный `~/.ssh/id_ed25519` предлагается любому хосту, совпавшему с legacy-записью по IP (пустой pinnedFingerprint). Legacy-fallback только после проверки непустого отпечатка; доверие по одному host не выводить.
- W5 (High). PairingModalView.swift:219-224 — «Сбросить старый ключ и доверять текущему» без сравнения. Показывать оба отпечатка и требовать подтверждения.
- W6 (High). PairingModalView.swift:173-191, DualPaneViewModel.swift:1404-1410 — auto-connect для произвольного IP сохраняет непроверенный отпечаток. Сохранять только после верифицированного сопряжения.
- W7. DualPaneViewModel.swift:1379-1430, 1485-1501; PhoneConnectionManager.swift:181-190, 644-682; ConnectionController.swift:231-238 — нет backoff: каждые 2,5 с adb devices + nc-пробы + connect; authFailed не подавляется. Экспоненциальный backoff по endpoint, подавление после authFailed.
- W8. SessionCoordinator.swift:137-139, 292-293, 461-462, 113-126 — переподключение не завершает старые masterProcess/каналы (утечка ssh-процессов). Вызывать cleanupMasterProcess() и закрывать оба канала перед новым; CancellationError в health probe не должен рвать здоровую сессию.
- W9. ConnectionController.swift:174-187, 256-258 — нет проверки isAttemptValid перед updateRemoteEndpoint; отменённые попытки продолжают keyscan/nc.
- W10. A:runtime/FileDaemonService.kt:84-90, 119-130 — гонка start/stop (sshd стартует после onDestroy), нет try/catch вокруг `start()` (BindException → крэш + START_STICKY loop). @Volatile/мьютекс, флаг stopped, отмена scope в onDestroy, обработка ошибок, отображение состояния отказа.
- W11. A:runtime/NsdDiscoveryHelper.kt, FileDaemonService.kt:73-77 — NSD регистрируется один раз; нет NetworkCallback (смена сети/IP), onRegistrationFailed пуст. Добавить NetworkCallback с перерегистрацией и retry, логирование.
- W12. A:ui/MainActivity.kt:83-85 — onResume перезапускает демона после ручной остановки. Флаг user-stopped в prefs. MainActivity.kt:326-331 — IP не обновляется при смене сети.
- W13. A:runtime/FileDaemonService.kt:79-81, 99-107; MainActivity.kt:312-314 — WifiLock держится всё время; Doze. Брать на первую сессию, отпускать на последней; предупреждение при отсутствии исключения из батарейной оптимизации.
- W14. Transport/DiscoveryService.swift:176-180, 278-294, PhoneConnectionManager.swift:33-40 — устаревшие IP после DHCP-смены (resolvedServiceIds, discoveredIps копятся); дедуп по name склеивает два телефона одной модели (PairingModalView.swift:415-417). Перерезолвить при изменении, чистить stale, ключ = instance name + host.
- W15. DiscoveryService.swift:335 — getaddrinfo без таймаута. PairingModalView.swift:311-316, 377-397 — fingerprint fetch на каждый символ без отмены. Отменять предыдущий Task.
- W16. SessionCoordinator.swift:113-127, 233-234; DualPaneViewModel.swift:425-435 — дохлая связь детектится ~20-25 с, нет обработки sleep/wake. Подписаться на NSWorkspace.willSleep/didWake → health check; probe timeout 1-2 с.
- W17. ConnectionController.swift:359-368, 375-376; SessionCoordinator.swift:216, 251; PhoneConnectionManager.swift:755-758 — sshUser без валидации и без `--`; `nc` без `--`; pushDedicatedPublicKey: readDataToEndOfFile до waitUntilExit без таймаута. Валидация `[a-z_][a-z0-9_-]*`, `--`, дедлайн.
- W18. A:server/EmbeddedServer.kt:118-142, 201-208 — `authorize_key` без окна сопряжения/валидации/lock (многострочный ввод даёт несколько ключей); resetPairing не закрывает живые сессии. Валидировать через AuthorizedKeyEntry, общий lock, закрывать сессии при сбросе.
- W19. A:AndroidManifest.xml:17 — allowBackup=true раскрывает hostkey.ser и authorized_keys. allowBackup=false; убрать неиспользуемый CHANGE_WIFI_MULTICAST_STATE.
- W20. A:EmbeddedServer.kt:82-83 — корень VirtualFileSystem `/storage` целиком. Ограничить allowlist пользовательских папок (если это не ломает функционал — иначе зафиксировать как принятый риск в документации).
- W21. A:ui/MainActivity.kt:537-543, build.gradle.kts minSdk=26 — на API 26-29 legacy storage permissions не запрашиваются. Объявить и запросить для API<30.
- W22. Transport/ClientKeyManager.swift:25-35 — приватный ключ в UserDefaults; при нечитаемом значении молча генерируется новый (ломает сопряжение). Keychain; не перезаписывать молча.
- W23. Transport/HostKeyStore.swift:135-166, 204-226 — pinned_hosts.json пишется неатомарно, с правами по умолчанию; повреждённый файл = пустое хранилище (fail-open). Атомарная запись 0600, fail-closed, resetHostKey одной транзакцией.

## P2 — надёжность Transport и UI

- T1. Transport/TransportMultiplexer.swift:160-162, 316-319, 507-510 + SFTPChannel.swift:149 — при отмене не отправляется SSH_FXP_CLOSE (утечка handle). Закрывать через не-отменяемый путь.
- T2. SessionCoordinator.swift:142-146 — отмена вызывающего не прерывает connect (withTaskCancellationHandler).
- T3. TransportMultiplexer.swift:243, 416, 496, 530, 578 — гонка по serverExtensions/serverLimits (читаются без замка); SessionCoordinator.swift:428-438 serverLimits не сбрасывается между сессиями.
- T4. SessionBudget.swift:135-147 + SessionCoordinator.swift:167 — budget.reset() при активных передачах.
- T5. SFTPPacketEngine.swift:201-203, 383 — одно не-UTF-8 имя валит весь листинг; нужен lossy-декод на уровне записи.
- T6. FileModel.swift:49-50, SFTPPacketEngine.swift:56, SessionCoordinator.swift:576 — NFC-нормализация удалённых путей ломает NFD-имена; хранить исходные байты, NFC только для отображения.
- T7. TransportMultiplexer.swift:267-299 + SSHTransportLog.swift — построчный лог на каждый 256 КиБ чанк под глобальным замком; убрать/буферизовать. Лог: права до записи, один ISO8601DateFormatter.
- T8. SessionCoordinator.swift:61-65 — общий канал bulk/interactive в fallback.
- T9. Мелочи Transport: SFTPChannel.swift:285-287, 326 loadUnaligned; TransportMultiplexer.swift:420, 591-592 overflow-safe арифметика; 387-388 ошибка размера; 74, 128, 227, 555, 569 `try?` глотает CancellationError; SessionCoordinator.swift:357-361 лог причины fallback.
- T10. Drivers/RemoteSFTPDriver.swift:12-13, TransportMultiplexer.swift:22-23 — инициализатор мутирует SessionCoordinator.shared; :76-81 hasPrefix("/emulated/0") без границы компонента; :193-199, 304-309 нестатусный ответ = успех.
- C1. Core/TransferQueueManager.swift:111-125, 190-193 — нет guard'ов переходов статусов.
- C2. Core/TransferJournal.swift:25-31, DualPaneViewModel.swift:294-295 — `try!`/`.first!` → крэш; fallback на in-memory.
- C3. Core/IntentLedger.swift:63-88, 136-140 — транзакции без блокировки, ошибки BEGIN игнорируются.
- C4. Core/JobOrchestrator.swift:85-93 cleanAllActivePartFiles удаляет temp живых передач; :790-798, 871-875, 961-1032 отмена не проверяется в пакетных циклах.
- C5. Drivers/LocalFSDriver.swift:91-107 — перезапись удаляет старый файл мимо корзины; `.bak.*` не чистятся. Core/FileModel.swift:16-23 неизвестный source → .localMac (fail-closed).
- C6. Services/ArchiveService.swift:65-71, 165-171 — waitUntilExit до чтения stderr (дедлок при >64 КБ).
- U1. Media/QuickLookCacheManager.swift:77-102 — загрузка не отменяется при отмене вызывающего; :33-40 длинные имена. Views/QuickViewPaneView.swift:205-257 — нет проверки устаревания, фиксированное temp-имя, декод на main; :198, 214, 246 ключ кэша по path.
- U2. UI/DualPaneViewModel.swift:4106-4194, 2487-2549 — синхронный скан/copyItem на MainActor; Finder paste считает успех при ошибках; 3583-3616 гонка по localPaths при drop.
- U3. UI/DualPaneViewModel.swift:1174-1222 swapPanes не отменяет refresh-задачи; 1816-1836 спиннер гаснет рано (generation counter); 4014-4019, 4197-4198 мелочи.
- U4. Media/ThumbnailCacheManager.swift:88-89, 356-387 — cleanupDiskIfNeeded O(N) на каждое сохранение; длинные ключи (хэшировать).
- U5. MacHost/Sources/MacHost/App.swift:68/254 (Cmd+D), 110/244 (Cmd+L) дубли; UI/KeyCommandMonitor.swift:110-127 приоритет keyCode над символом.

## P3 — Android гигиена
- A:server/CustomSftpEventListener.kt:27, 42-55 — гонка счётчика сессий, lastWakeLockPing не volatile, scope без отмены; :98-118 actionId из имени файла + REPLACE.
- A:server/EmbeddedServer.kt:100-109 фиктивный `df`; :143-155 LIKE без экранирования, управляющие символы в записях.
- A: нет логирования (проглоченные исключения) — добавить Log.w/e; MainActivity.kt:551-557 ActivityNotFoundException; gradle wrapper без distributionSha256Sum.
- A:runtime/FileDaemonService.kt:132-139 — onTimeout без уведомления.

## Не исправлять
- Transport/SSHProtocolHandler.swift, SSHProcessHolder.swift — используются только тестами (можно оставить как есть).
