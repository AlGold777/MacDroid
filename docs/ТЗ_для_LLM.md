# ТЗ для LLM: MacDroid Commander → Production

---

## 0. Мета-инструкции

Ты работаешь автономно. Пользователь не смотрит в реальном времени и не ответит по ходу задачи. Вопросы «Сделать?» и «Продолжить?» только блокируют работу — **не задавай их**.

**Режим работы**: выполняй задачи последовательно, по фазам. После каждой фазы делай чеклист выполненного. Работай до тех пор, пока все пункты не будут выполнены.

**Язык кода**: Swift 6+ (macOS 14+), Kotlin (Android 14+, API 34). Комментарии в коде на русском.

**Рабочая директория проекта**: путь к проекту будет известен тебе из контекста. Структура описана ниже.

---

## 1. Контекст проекта

### Что это

Двухпанельный файловый менеджер в стиле Total Commander для macOS, управляющий файлами локально (Mac) и удалённо (Android-телефон Xiaomi 14 Ultra) через SSH/SFTP по Wi-Fi. Состоит из двух приложений:

- **MacHost** — нативное macOS-приложение (Swift, SwiftUI, AppKit, SPM).
- **AndroidCompanion** — Android-приложение (Kotlin, Apache MINA SSHD, Room), которое работает как встроенный SFTP-сервер.

### Текущий статус

**Архитектурный прототип (Alpha, ~30% готовности)**. Архитектура и локальная часть реализованы грамотно. Главная проблема: **весь сетевой транспорт между Mac и Android — заглушка (mock)**. APK не собирался ни разу.

### Базовые документы (прочитай перед началом работы)

```
docs/product_spec_v3.md          — полная спецификация продукта (180 строк, Must Have / Сильная / Приемлемая)
docs/architecture_brief.md       — архитектурный бриф (инварианты, сценарии, ограничения)
docs/Анализ платформенных ограничений Mac ↔ Android.md — 72 платформенных ограничения
```

---

## 2. Текущая архитектура

### Слои MacHost

```
┌─────────────────────────────────────────────────┐
│  UI Layer (SwiftUI + AppKit)                    │
│  App.swift → MainContentView → PaneView         │
│  DualPaneViewModel (@MainActor, ObservableObject)│
├─────────────────────────────────────────────────┤
│  Core Layer                                     │
│  JobOrchestrator ←→ IntentLedger (SQLite WAL)   │
│  StateMachine, ConflictResolution               │
│  DirectoryComparator, TransferQueueManager      │
├─────────────────────────────────────────────────┤
│  Driver Layer                                   │
│  FileSystemDriver (protocol)                    │
│    ├── LocalFSDriver   ✅ работает              │
│    └── RemoteSFTPDriver ❌ mock                 │
├─────────────────────────────────────────────────┤
│  Transport Layer                                │
│  TransportMultiplexer  ❌ mock                  │
│  SSHControlClient (actor) ✅ реализован, не подключён │
│  SFTPPacketEngine      ✅ wire protocol готов   │
│  HostKeyStore (TOFU)   ✅ работает              │
│  DiscoveryService      ✅ mDNS                  │
└─────────────────────────────────────────────────┘
```

### Ключевые паттерны (НЕ ЛОМАТЬ)

- **JobUnitStateMachine**: `PLANNED → RUNNING → COMMITTING → COMPLETED`, с ветками `→ INDETERMINATE`, `→ FAILED`
- **IntentLedger**: SQLite WAL + `NSRecursiveLock`, поддерживает `withTransaction {}`
- **JobOrchestrator**: pre-flight check (+5%), повторы при сетевом сбое (паузы 1–15 с, окно ≈60 с, продолжение с подтверждённого frontier; ошибки-ответы сервера не повторяются), `.part` temp files, атомарный rename, верификация после commit
- **TOFU**: Mac хранит fingerprint Android-сервера в `HostKeyStore`; Android хранит public key Mac в `authorized_keys`
- **ConflictResolutionStrategy**: `.skip`, `.skipIfIdentical`, `.overwriteIfNewer`, `.autoRename`, `.overwrite`

---

## 3. Карта файлов

### MacHost (Swift / SPM)

```
MacHost/
├── Package.swift
├── Sources/
│   ├── MacHost/
│   │   └── App.swift                          # @main, горячие клавиши F3-F8
│   └── MacHostCore/
│       ├── Core/
│       │   ├── FileModel.swift                # FileItem, FileSource, PanelTab
│       │   ├── StateMachine.swift             # JobUnitStateMachine, ItemState
│       │   ├── IntentLedger.swift             # SQLite WAL ledger ✅
│       │   ├── JobOrchestrator.swift          # двухфазный commit ✅ (transport mock)
│       │   ├── ConflictResolution.swift       # стратегии конфликтов ✅
│       │   ├── DirectoryComparator.swift      # сравнение каталогов ✅
│       │   └── TransferQueueManager.swift     # очередь передачи
│       ├── Drivers/
│       │   ├── FileSystemDriver.swift         # protocol ✅
│       │   ├── LocalFSDriver.swift            # локальный FS ✅
│       │   └── RemoteSFTPDriver.swift         # ❌ ЗАГЛУШКА — возвращает хардкод
│       ├── Transport/
│       │   ├── SFTPPacketEngine.swift          # SFTP v3 wire protocol ✅
│       │   ├── SSHControlClient.swift          # actor, readExact ✅ НЕ ПОДКЛЮЧЁН
│       │   ├── HostKeyStore.swift              # TOFU Ed25519 ✅
│       │   ├── DiscoveryService.swift          # mDNS/Bonjour ✅
│       │   └── TransportMultiplexer.swift      # ❌ ЗАГЛУШКА — пишет байты 0x5A
│       ├── Media/
│       │   ├── ThumbnailCacheManager.swift     # кэш миниатюр
│       │   └── QuickLookBridge.swift           # QLPreviewPanel
│       └── UI/
│           ├── DualPaneViewModel.swift         # @MainActor ViewModel
│           └── Views/
│               ├── MainContentView.swift       # корневой View
│               ├── PaneView.swift              # панель с Tabs, D&D, comparison
│               ├── BottomToolbarView.swift      # нижняя панель кнопок
│               ├── PairingModalView.swift       # диалог сопряжения
│               ├── ConflictResolutionModalView.swift
│               ├── TransferQueueModalView.swift
│               ├── BatchRenameModalView.swift
│               ├── ImageViewerModalView.swift
│               └── NewFolderModalView.swift
├── Tests/MacHostTests/main.swift              # 8 test suites ✅
└── Resources/Info.plist
```

### AndroidCompanion (Kotlin / Gradle)

```
AndroidCompanion/
├── settings.gradle.kts
├── build.gradle.kts
├── app/
│   ├── build.gradle.kts
│   ├── proguard-rules.pro
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── res/values/strings.xml
│       └── kotlin/com/macandroid/filemanager/
│           ├── data/ActionJournalDb.kt        # Room DB, ActionReceipt
│           ├── storage/StorageGateway.kt      # атомарный commit, scanFilesBatch
│           ├── server/
│           │   ├── EmbeddedServer.kt          # MINA SSHD, TOFU (⚠️ key.toString() баг)
│           │   └── CustomSftpEventListener.kt # события SFTP
│           ├── runtime/
│           │   ├── FileDaemonService.kt       # foreground service, dynamic WakeLock
│           │   └── NsdDiscoveryHelper.kt      # mDNS
│           └── ui/MainActivity.kt             # запуск, разрешения
```

---

## 4. Матрица текущего состояния

| Компонент | Статус | Что нужно |
|---|---|---|
| `RemoteSFTPDriver` | ❌ mock | Подключить к реальному SSH/SFTP через `SSHControlClient` + `SFTPPacketEngine` |
| `TransportMultiplexer` | ❌ mock | Заменить заглушки реальными сетевыми вызовами через `SSHControlClient` |
| `SSHControlClient` | ✅ actor, `readExact` работает | Подключить к `TransportMultiplexer` |
| `SFTPPacketEngine` | ✅ wire protocol | Используется в `RemoteSFTPDriver`, но пакеты не отправляются |
| `EmbeddedServer.kt` | ⚠️ `key.toString()` | Заменить на `Base64.encodeToString(key.encoded, ...)` |
| APK | ❌ не собирался | Собрать `gradlew assembleDebug`, протестировать |
| `startTransfer()` | ❌ только `selected.first` | Цикл по всем `selected` с изоляцией ошибок |
| Session restore | ❌ отсутствует | `UserDefaults` / `@AppStorage` для панелей и вкладок |
| Контекстное меню | ❌ нет `.contextMenu` | `.contextMenu` с полным набором из spec §7 |
| Breadcrumbs | ❌ только label | Кликабельный `HStack` из компонентов пути |
| Избранное / Недавние | ❌ | Sidebar с bookmarks |
| Рекурсивный поиск | ❌ | `FileManager.enumerator` / SFTP recursive readdir |
| Системные уведомления | ❌ | `UNUserNotificationCenter` |
| Android Pairing UI | ❌ | Показать IP:Port, уведомление о сопряжении |
| Offline reconnect | 🟡 только `isStale` | Graceful reconnect с «ожидание подключения» |

---

## 5. ФАЗА 1 — Критические блокеры

> Без этих пунктов приложение нефункционально как продукт.

### ЗАДАЧА 1.1: Реальный SSH/SFTP transport

**Цель**: заменить mock в `RemoteSFTPDriver` и `TransportMultiplexer` реальным SFTP-клиентом.

**Файлы для модификации**:

#### `TransportMultiplexer.swift` — ПОЛНАЯ ПЕРЕРАБОТКА

Текущее состояние: все методы возвращают заглушки. Нужно:

1. Добавить свойство `private let sshClient: SSHControlClient`
2. При `init()` принимать хост/порт или получать из `DiscoveryService`
3. `prepareRead()` → отправить `SSH_FXP_STAT` через `SFTPPacketEngine`, распарсить ответ `SSH_FXP_ATTRS`, вернуть реальные `size` и `mtime`
4. `downloadFileStreaming()` → `SSH_FXP_OPEN` (read) → цикл `SSH_FXP_READ` (chunk 64KB) → запись в файл → `SSH_FXP_CLOSE`. Поддержка `startOffset` для resume
5. `executeDelete()` → `SSH_FXP_REMOVE` через `SFTPPacketEngine`, проверить ответ `SSH_FXP_STATUS`
6. `getRemoteFileDigest()` → вычислить SHA-256 на стороне Mac из скачанного файла (серверная сторона не поддерживает digest в SFTP v3)
7. Добавить метод `connect()` async throws → SSH handshake → SFTP init (`SSH_FXP_INIT` → `SSH_FXP_VERSION`)
8. Добавить `disconnect()`
9. Обработка ошибок: если `readExact` бросает — обернуть в `TransportError` с human-readable описанием

**Важно**: `SSHControlClient` — уже `actor`. Все вызовы к нему — через `await`. `SFTPPacketEngine` thread-safe (`@unchecked Sendable`).

#### `RemoteSFTPDriver.swift` — ПОЛНАЯ ПЕРЕРАБОТКА

1. Заменить хардкод в `listDirectory()` → отправить `SSH_FXP_OPENDIR` → loop `SSH_FXP_READDIR` (до `SSH_FXP_STATUS` с `EOF`) → `SSH_FXP_CLOSE`. Распарсить через `SFTPPacketEngine.parseNameResponse()`
2. `createDirectory()` → отправить `SSH_FXP_MKDIR`, дождаться `SSH_FXP_STATUS`
3. `deleteItem(moveToTrash: true)` → запись метаданных в `.MacDroidTrash/<UUID>/info.json`, затем `SSH_FXP_RENAME` исходника в `payload`. Безвозвратные `SSH_FXP_REMOVE`/`SSH_FXP_RMDIR` применяются только при явном `moveToTrash: false`, в том числе для подтверждённой очистки корзины.
4. `renameItem()` → `SSH_FXP_RENAME`
5. `checkFreeSpace()` → SFTP v3 не поддерживает `statvfs`. Два варианта:
   - Использовать SSH exec `df -B1 /storage/emulated/0` и распарсить вывод
   - Или возвращать `(0, 0)` и показывать «неизвестно» в UI
6. Добавить управление подключением: `connect()`, `disconnect()`, `isConnected`

#### `SSHControlClient.swift` — МИНИМАЛЬНЫЕ ИЗМЕНЕНИЯ

Уже реализован корректно. Нужно:
1. Убедиться, что `connect(host:port:)` создаёт TCP-сокет через `NWConnection` (Network framework) или `CFSocket`
2. Убедиться, что `readExact(count:)` корректно аккумулирует TCP-чанки (уже реализовано)
3. Добавить SSH key exchange (KEX) — **самый сложный блок**. Варианты:
   - Использовать библиотеку [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) — Apple-maintained
   - Использовать [NMSSH](https://github.com/NMSSH/NMSSH)
   - Или реализовать минимальный SSH transport самостоятельно (curve25519-sha256, chacha20-poly1305)

> **Рекомендация**: использовать **SwiftNIO SSH** (`swift-nio-ssh`) — это Apple-maintained пакет, поддерживающий Ed25519, позволяющий запустить SFTP subsystem поверх SSH channel.

**Если используется SwiftNIO SSH**:
- Добавить в `Package.swift`: `.package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.8.0")`
- `SSHControlClient` переписать как обёртку вокруг `NIOSSHClient`
- SFTP channel запустить через `createChannel(type: .session)` → exec `sftp` subsystem
- `SFTPPacketEngine` использовать для формирования/парсинга SFTP-пакетов поверх SSH channel

### ЗАДАЧА 1.2: Исправить `EmbeddedServer.kt` — сравнение ключей

**Файл**: `AndroidCompanion/.../server/EmbeddedServer.kt`

**Проблема**: строка 42 — `key.toString().trim()` — для `PublicKey` возвращает нестабильную строку (зависит от JVM). Два разных объекта с одинаковым ключом могут дать разные `toString()`.

**Исправление**:
```kotlin
import java.util.Base64

// При записи (TOFU — первое сопряжение):
authorizedKeysFile.writeText(Base64.getEncoder().encodeToString(key.encoded))

// При проверке (последующие подключения):
val storedKey = authorizedKeysFile.readText().trim()
val incomingKey = Base64.getEncoder().encodeToString(key.encoded)
storedKey == incomingKey
```

### ЗАДАЧА 1.3: Пакетный transfer

**Файл**: `MacHost/.../UI/DualPaneViewModel.swift`, метод `startTransfer()`

**Проблема**: строка 394 — `guard let firstSelected = selected.first` — обрабатывается только один файл.

**Исправление**:
1. Итерировать по **всем** `selected`
2. Для каждого файла — вызывать `orchestrator.executeCopy/MovePhoneToMac()`
3. Собирать результаты: `succeeded: [String]`, `failed: [(path: String, error: Error)]`, `skipped: [String]`
4. После завершения — показать итоговый отчёт (см. Задачу 2.5)
5. Обновить `transferProgress` на основе `completedCount / totalCount`
6. Ошибка одного файла **не прерывает** обработку остальных (spec §8)

### ЗАДАЧА 1.4: Пауза и отмена в UI

**Файлы**: `TransferQueueModalView.swift`, `DualPaneViewModel.swift`

1. Добавить в `DualPaneViewModel`:
   - `@Published var currentTransferTask: Task<Void, Never>? = nil`
   - Метод `cancelTransfer()` — вызывает `currentTransferTask?.cancel()`
2. В `startTransfer()` — обернуть цикл в `Task {}` и сохранить в `currentTransferTask`
3. Внутри цикла проверять `Task.isCancelled` перед обработкой каждого файла
4. В `TransferQueueModalView` — добавить кнопку «Отменить» / «Приостановить»

---

## 6. ФАЗА 2 — Must Have из спецификации

> Фичи, без которых продукт не соответствует собственному spec.

### ЗАДАЧА 2.1: Session restore

**Файл**: `DualPaneViewModel.swift`

При `init()` — загружать из `UserDefaults`:
```swift
@AppStorage("leftPath") var savedLeftPath: String = ...
@AppStorage("leftSource") var savedLeftSource: String = ...
@AppStorage("rightPath") var savedRightPath: String = ...
@AppStorage("rightSource") var savedRightSource: String = ...
@AppStorage("leftSortField") var savedLeftSortField: String = ...
// аналогично для всех полей из spec §2
```

Для вкладок — сериализовать `[PanelTab]` в JSON и сохранять в `UserDefaults` при каждом изменении.

При выходе из приложения (`NSApplication.willTerminateNotification`) — сохранять всё.

### ЗАДАЧА 2.2: Контекстное меню

**Файл**: `PaneView.swift`

Добавить `.contextMenu` к каждому элементу Table:
```swift
.contextMenu {
    Button("Открыть") { vm.navigateInto(item: item, side: side) }
    Button("Просмотр (F3)") { vm.triggerQuickLook() }
    Divider()
    Button("Копировать (F5)") { vm.triggerCopy() }
    Button("Переместить (F6)") { vm.triggerMove() }
    Button("Переименовать") { /* inline rename */ }
    Button("Удалить (F8)") { vm.triggerDelete() }
    Divider()
    Button("Копировать имя") { NSPasteboard.general.setString(item.name, forType: .string) }
    Button("Копировать путь") { NSPasteboard.general.setString(item.path, forType: .string) }
    if item.source == .localMac {
        Button("Показать в Finder") {
            NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
        }
    }
}
```

### ЗАДАЧА 2.3: Breadcrumbs

**Файл**: `PaneView.swift` — заменить `Text(currentPath)` на кликабельный breadcrumb:

```swift
HStack(spacing: 2) {
    let components = URL(fileURLWithPath: currentPath).pathComponents
    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
        Button(component) {
            let targetPath = "/" + components[1...index].joined(separator: "/")
            if side == .left { vm.leftPath = targetPath }
            else { vm.rightPath = targetPath }
            vm.refreshPane(side: side)
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
        if index < components.count - 1 {
            Text("›").foregroundColor(.secondary)
        }
    }
}
```

### ЗАДАЧА 2.4: Android Pairing UI

**Файл**: `AndroidCompanion/.../ui/MainActivity.kt`

Добавить отображение:
1. Текущий IP-адрес и порт (через `NetworkInterface.getNetworkInterfaces()`)
2. Статус сервера (запущен / остановлен)
3. Статус сопряжения (ожидание первого подключения / сопряжён с [fingerprint])
4. Кнопка «Сбросить сопряжение» — удаляет `authorized_keys`
5. Уведомление при первом сопряжении (TOFU) — показать Toast или AlertDialog с fingerprint подключающегося Mac

### ЗАДАЧА 2.5: Итоговый отчёт операции

**Новый файл**: `MacHost/.../UI/Views/OperationReportView.swift`

После завершения пакетной операции показать `.sheet`:
- Количество скопированных / перемещённых / пропущенных / ошибочных файлов
- Общий объём переданных данных
- Длительность операции
- Список ошибочных файлов с причинами
- Кнопка «Открыть папку назначения»

Добавить в `DualPaneViewModel`:
```swift
@Published var showOperationReport: Bool = false
@Published var operationReport: OperationReport? = nil

struct OperationReport {
    let succeeded: [String]
    let failed: [(path: String, error: String)]
    let skipped: [String]
    let totalBytes: UInt64
    let duration: TimeInterval
}
```

### ЗАДАЧА 2.6: Ручное подключение (fallback для mDNS)

**Файл**: `PairingModalView.swift`

Добавить поля ввода `TextField("IP-адрес", text: $manualHost)` и `TextField("Порт", text: $manualPort)` с кнопкой «Подключиться вручную». При нажатии — создать `RemoteSFTPDriver(host: manualHost, port: UInt16(manualPort)!)` и попробовать `connect()`.

Сохранить последний успешный адрес в `UserDefaults`.

### ЗАДАЧА 2.7: Quick Look для удалённых файлов

**Файл**: `DualPaneViewModel.swift`, метод `triggerQuickLook()`

Если файл из `.remotePhone`:
1. Скачать файл во временную директорию: `FileManager.default.temporaryDirectory.appendingPathComponent(item.name)`
2. Дождаться завершения скачивания
3. Открыть `QuickLookBridge.shared.preview(url: tempURL)`

---

## 7. ФАЗА 3 — Качество и полировка

### ЗАДАЧА 3.1: Виртуализация больших каталогов

Если каталог содержит > 1000 файлов, `Table` может тормозить. Рассмотреть:
- `LazyVStack` с ручной виртуализацией вместо `Table` (при необходимости)
- Порционную загрузку для удалённых каталогов (READDIR пачками)

### ЗАДАЧА 3.2: Рекурсивный поиск

**Новые файлы**: `SearchService.swift`, `SearchResultsView.swift`

Для локального Mac: `FileManager.default.enumerator(at:)`.
Для удалённого: рекурсивный SFTP `OPENDIR` / `READDIR`.
Отмена, порционный вывод результатов, ограничение глубины для удалённого источника.

### ЗАДАЧА 3.3: Системные уведомления macOS

После завершения фоновой передачи длительностью > 30 секунд:
```swift
import UserNotifications
let content = UNMutableNotificationContent()
content.title = "Передача завершена"
content.body = "Скопировано \(count) файлов (\(size))"
// ...
```

### ЗАДАЧА 3.4: Избранное и недавние папки

**Новый файл**: `BookmarksManager.swift`

- Predefined: Downloads, Documents, Desktop, DCIM/Camera, Screenshots, Pictures
- Сохранение пользовательских закладок в `UserDefaults`
- Sidebar или dropdown в `PaneView`

### ЗАДАЧА 3.5: Интеграционные тесты

Минимальный e2e-тест: запустить `EmbeddedServer` локально (можно на localhost), подключиться через `RemoteSFTPDriver`, выполнить `listDirectory`, `createDirectory`, скачать файл, проверить целостность.

---

## 8. Жёсткие ограничения и инварианты

> Эти правила не подлежат обсуждению. Нарушение любого из них — брак.

1. **Никогда не удалять файл пользователя молча.** На Mac — только через `trashItem()`. Если `trashItem` не удалось — бросить `LocalFSDriverError.trashUnavailable`, НЕ fallback на `removeItem`. На Android обычное удаление перемещает объект в собственную `.MacDroidTrash` на том же накопителе с сохранением исходного пути. Ошибка корзины не допускает fallback на безвозвратное удаление. Безвозвратная очистка требует отдельного подтверждения.

2. **Частичный файл НИКОГДА не выглядит как готовый.** Запись идёт в `.{name}.part.{actionId}`, финальное имя — только после `renameItem` и верификации.

3. **Ошибка одного файла не прерывает пакетную операцию.** Каждый файл обрабатывается независимо, результат по каждому — в `OperationReport`.

4. **Offline ≠ Not Found.** Если панель показывает данные не в реальном времени — отображать `isStale` с timestamp. Не показывать «папка пуста», когда на самом деле «недоступна».

5. **Move = Copy → Verify → Delete original.** Оригинал не удаляется до подтверждённого завершения копии.

6. **Нет `force_try`, нет `try?` в критических путях.** Все ошибки передачи файлов должны обрабатываться явно и доводиться до пользователя.

7. **Unicode NFC.** Все имена файлов — через `.precomposedStringWithCanonicalMapping` перед сравнением и записью.

8. **`@MainActor` для UI-состояния.** `DualPaneViewModel` — `@MainActor`. Сетевые вызовы — через `Task {}` с `await`.

---

## 9. Критерии верификации

### Для Фазы 1
- [ ] `swift build -c release` проходит без ошибок
- [ ] `RemoteSFTPDriver.listDirectory()` возвращает реальный список файлов с SFTP-сервера
- [ ] `TransportMultiplexer.downloadFileStreaming()` скачивает реальный файл (содержимое ≠ `0x5A`)
- [ ] При выборе 5 файлов — `startTransfer()` обрабатывает все 5
- [ ] `EmbeddedServer.kt` — `key.encoded` используется для сравнения
- [ ] `gradlew assembleDebug` создаёт APK (если доступен Android SDK)

### Для Фазы 2
- [ ] При перезапуске приложения — панели восстанавливаются в прежнем состоянии
- [ ] Правый клик по файлу → контекстное меню с действиями
- [ ] Клик по компоненту breadcrumb → навигация
- [ ] После пакетной операции → отчёт с количеством файлов

### Для Фазы 3
- [ ] Каталог с 5000+ файлов не блокирует UI
- [ ] Уведомление macOS появляется после длительной передачи
- [ ] Сквозной тест: listDirectory → createDirectory → download file → verify

---

## 10. Порядок выполнения

```
1.1 → 1.2 → 1.3 → 1.4 → верификация Фазы 1
     ↓
2.1 → 2.2 → 2.3 → 2.5 → 2.4 → 2.6 → 2.7 → верификация Фазы 2
     ↓
3.1 → 3.3 → 3.4 → 3.2 → 3.5 → верификация Фазы 3
     ↓
Финальный чеклист
```

**Приоритет**: 1.1 (SFTP transport) — самая важная и самая сложная задача. Если время ограничено — сделать хотя бы её.
