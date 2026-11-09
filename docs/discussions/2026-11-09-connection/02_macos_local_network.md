Ты — инженер macOS с глубоким знанием Local Network Privacy (macOS 15 Sequoia), подписи кода (codesign, designated requirement), Network.framework и BSD-сокетов. Тебе нужно объяснить, почему приложение периодически теряет доступ к устройствам в локальной сети, хотя разрешение «Локальная сеть» включено, и предложить надёжное решение. Отвечай по-русски.

# Система

MacDroid Commander — SwiftUI-приложение для macOS (Apple Silicon, macOS 15.7.3). Код: `/Users/restart/Documents/GitHub/MacDroidCommander/MacHost`. Подключается к Android-телефону в домашней Wi-Fi сети (192.168.1.0/24) по SSH/SFTP.

- Bundle id `com.macandroid.MacDroidCommander`. Info.plist содержит `NSLocalNetworkUsageDescription` и `NSBonjourServices = [_macphone_sftp._tcp]`.
- Приложение собирается скриптом `/Users/restart/Documents/GitHub/MacDroidCommander/scripts/build_macos_app.sh` (swift build → бандл). До 9.11.2026 подпись была ad-hoc: `codesign --force --deep --sign -`. Сборок много: несколько в день, из разных папок (основной чекаут, git worktree агентов, временные копии в `/private/tmp`, копия в `~/Downloads/MacDroidCommander_Gemini`).
- Сетевые пути в приложении:
  1. Bonjour: `NWBrowser(for: .bonjour(type: "_macphone_sftp._tcp", domain: "local."), using: NWParameters())`, `includePeerToPeer = true`.
  2. Проба порта: BSD `socket(AF_INET, SOCK_STREAM)` + неблокирующий `connect()` + `poll(POLLOUT, timeout)` + `SO_ERROR` (код ниже). Таймауты: 2000 мс при явном подключении, 250 мс при групповой проверке адресов, 1000 мс перед запуском SSH.
  3. SSH/SFTP: дочерние процессы `/usr/bin/ssh` (ControlMaster + 2 канала `-s sftp`), запускаются через `Process`.
  4. Дочерние `ssh-keyscan`, `nc`, `adb`.

```swift
// MacHost/Sources/MacHostCore/Transport/NetworkPortReachability.swift
public static func isPortOpen(host: String, port: UInt16 = 2222, timeoutMs: Int = 200) -> Bool {
    var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let addr = res else { return false }
    defer { freeaddrinfo(res) }
    let sock = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
    guard sock >= 0 else { return false }
    defer { close(sock) }
    let flags = fcntl(sock, F_GETFL, 0); _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
    let ret = connect(sock, addr.pointee.ai_addr, addr.pointee.ai_addrlen)
    if ret == 0 { return true }
    guard errno == EINPROGRESS else { return false }        // errno не логируется
    var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
    if poll(&pfd, 1, Int32(timeoutMs)) > 0 {
        var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len) == 0 { return err == 0 }
    }
    return false
}
```
При провале пробы пользователь видит: «TCP probe failed for Wi-Fi (192.168.1.16:2222) at 192.168.1.16:2222. Verify that the companion service is listening and that the route/ADB forward is active.»

# Факты (9.11.2026, время локальное)

- Телефон 192.168.1.16:2222 всё время доступен с этого же Mac: `nc -z` из Терминала проходит каждый раз (70 проверок подряд), `ssh-keyscan` отвечает, `dns-sd -B _macphone_sftp._tcp` из Терминала видит телефон.
- В те же минуты приложение пишет «TCP probe failed» и «Нет доступных телефонов в сети» (Bonjour ничего не находит).
- `lsof -p <app> -iTCP` каждые 0,5 с в течение 5 минут: приложение открывает и держит в `SYN_SENT` соединения к старым адресам телефона из истории вне подсети (192.168.68.64:2222, 10.171.79.23:2222 — идут через шлюз). Соединение к 192.168.1.16 (в своей подсети) ни разу не появилось даже на долю секунды: значит, `connect()` завершается сразу, без ожидания.
- В «Настройки → Конфиденциальность и безопасность → Локальная сеть» пять записей «MacDroid Commander» и две «MacHost», все включены. В `/Library/Preferences/com.apple.networkextension.plist` записи с путями разных копий бандла (основной чекаут, worktree, `/private/tmp/*.app`, `~/Downloads/...`), у всех `DenyMulticast = 0`, `MulticastPreferenceSet = 1`, у всех `SigningIdentifier = com.macandroid.MacDroidCommander`, `DesignatedRequirement` пустой, `AllowEmptyDesignatedRequirement = 1`.
- Хронология:
  - 8.11 21:59 — сессия с телефоном работала;
  - 9.11 днём — несколько пересборок ad-hoc, приложение перестало подключаться;
  - 19:03 — пользователь выключил и включил переключатели «Локальная сеть» и перезапустил приложение; файл `com.apple.networkextension.plist` изменён в 19:03:12;
  - 19:05 — приложение подключилось к обоим телефонам (Redmi 192.168.1.11 и Xiaomi 192.168.1.16);
  - к 19:08 снова «TCP probe failed» и пустой Bonjour. При этом ControlMaster `/usr/bin/ssh`, запущенный приложением в 19:05, оставался в `ESTABLISHED` с 192.168.1.16 до ручного закрытия: на уже открытое соединение дочернего процесса запрет не действовал.
  - Записи о разрешениях после 19:03 не менялись. В системном журнале (`log show`, nehelper, networkd) упоминаний решений Local Network для приложения найти не удалось.
- 19:14 бандл переподписан самоподписанным сертификатом (см. ниже). 19:15:59 запуск → 19:16:01 подключение к Xiaomi без ручных действий. 19:18:45 сессия оборвалась с `Broken pipe` (возможно, на стороне телефона, это отдельный вопрос). После этого за 20 с наблюдения приложение не открыло ни одного TCP-соединения (возможно, пауза автоподключения до 60 с — не проверено), следующая проба ещё не наблюдалась.

## Что сделано
В скрипте сборки вместо ad-hoc: самоподписанный сертификат с EKU codeSigning (`CN = MacDroid Commander Local Signing`, RSA 2048, 10 лет) в отдельной связке `~/Library/Keychains/macdroid-codesign.keychain-db` без пароля. Связка временно добавляется в `security list-keychains -d user` на время `codesign --force --deep --sign <SHA1>`, затем список восстанавливается. Сертификат не доверен системой (`CSSMERR_TP_NOT_TRUSTED`), но codesign подписывает. Результат:
```
designated => identifier "com.macandroid.MacDroidCommander" and certificate leaf = H"71fa3aa6cf50f37518e3f3822680d9afaef83ff2"
codesign --verify --deep --strict → valid on disk, satisfies its Designated Requirement
```
Нового запроса «Разрешить доступ к локальной сети» после переподписи не появилось.

# Вопросы
1. Как macOS 15 сопоставляет запущенный процесс с записью Local Network Privacy: по пути, по signing identifier, по cdhash, по designated requirement, по «responsible process»? Что происходит при ad-hoc подписи, когда у нескольких копий с разными путями один signing identifier, а cdhash меняется с каждой сборкой? Может ли это давать «разрешено — через несколько минут запрещено» без изменения переключателей?
2. Объясни наблюдаемое: запрет действует на BSD `connect()` и `NWBrowser` процесса приложения, но не на уже установленное соединение дочернего `/usr/bin/ssh`. Какой errno возвращает `connect()` при запрете Local Network (EHOSTUNREACH? EPERM?)? Как это достоверно определить из кода приложения?
3. Достаточно ли самоподписанного сертификата (designated requirement = identifier + certificate leaf), чтобы разрешение сохранялось между пересборками? Нужен ли сертификат, которому доверяет система, или Apple Development / Developer ID? Нужно ли удалить старые записи (как, если `tccutil` Local Network не сбрасывает)? Что с записями `AllowEmptyDesignatedRequirement = 1`?
4. Связан ли запрет с «responsible process»: приложение иногда запускается агентами из Терминала (`open` или напрямую бинарник). Как macOS решает, чьё разрешение применять в этих случаях?
5. Может ли влиять проба с таймаутом 250 мс / 1–2 с на телефон в режиме энергосбережения Wi-Fi (RTT 100–300 мс, первый пакет после сна до секунд), и как отличить такой таймаут от запрета macOS? Какие таймауты и повторы разумны?
6. Как диагностировать Local Network Privacy на macOS 15 без догадок: какие подсистемы unified log включить (`log config`, private data), какие ключи смотреть в `com.apple.networkextension.plist`, есть ли `nehelper`/`networkd` события «denied local network»?
7. Как правильно встроить в приложение раннее обнаружение запрета: проверка «я вижу шлюз / свою подсеть», `NWPathMonitor`, `NWConnection` со state `.waiting` и `NWError` с причиной локальной сети (`kDNSServiceErr_PolicyDenied`, `-65570`?), и что показать пользователю?

# Формат ответа
- По каждому вопросу: короткий вывод, затем обоснование. Ссылайся на документацию Apple (TN3179 «Understanding local network privacy», WWDC-сессии, форумы разработчиков Apple), где возможно.
- Разделяй: «документировано», «наблюдалось сообществом», «предположение».
- Гипотезы о причине — по убыванию вероятности, к каждой: как подтвердить на этом Mac (команды) и что изменить.
- В конце — рекомендуемая схема подписи и сборки для локальной разработки без платного аккаунта разработчика, плюс изменения кода пробы (Swift), чтобы ошибка «запрещено macOS» отличалась от «телефон не отвечает».
