import Foundation

/// Таймер в панели и в строке меню: помидор для работы и короткие подходы
/// вроде «держать эспандер тридцать секунд» на созвоне.
///
/// Здесь только правила, без обращения к системному времени: момент передаётся
/// параметром. Поэтому таймер проверяется тестами целиком — вместе со сном
/// компьютера, паузой и границами мигания, которые иначе пришлось бы ловить
/// секундомером у экрана.

// MARK: - Пресет

/// Настроенный таймер: имя и длительность. Их до трёх — столько помещается
/// в одну строку панели, а строка должна быть одна: раскладка блока задаёт
/// высоту панели, и переносить плашки на вторую строку нельзя.
struct TimerPreset: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Длительность в секундах. Хранится числом, а не парой «сколько + единица»:
    /// единица — это только способ ввода, и в файле ей делать нечего.
    var seconds: Int
    /// Сочетание клавиш, запускающее таймер откуда угодно. `nil` — не назначено.
    var hotkey: TimerHotkey?

    init(id: UUID = UUID(), name: String, seconds: Int, hotkey: TimerHotkey? = nil) {
        self.id = id
        self.name = name
        self.seconds = seconds
        self.hotkey = hotkey
    }

    /// Длительность, приведённая к допустимым границам.
    ///
    /// Приведение здесь, а не в `init`: разбор `Codable` синтезирован и мимо
    /// `init` проходит, так что правленный руками файл настроек иначе
    /// протащил бы в таймер ноль или сутки.
    var duration: TimeInterval {
        TimeInterval(min(TimerRules.maxSeconds, max(TimerRules.minSeconds, seconds)))
    }

    /// Три заготовки: рабочий помидор, короткий подход и перерыв.
    /// Имена короткие намеренно — плашки стоят в один ряд на ширине панели.
    static let defaults: [TimerPreset] = [
        TimerPreset(name: "Фокус", seconds: 25 * 60),
        TimerPreset(name: "Эспандер", seconds: 30),
        TimerPreset(name: "Перерыв", seconds: 5 * 60),
    ]
}

/// Сочетание клавиш, запускающее таймер.
///
/// В файле лежит читаемо — код клавиши и четыре признака, а не битовая маска:
/// настройки правят руками, и `1048840` в них ничего не объясняет. Маску
/// для системы собирает тот, кто вешает клавишу.
struct TimerHotkey: Codable, Equatable, Hashable {
    /// Виртуальный код клавиши: у горячих клавиш считается физическая клавиша,
    /// а не буква на ней. Поэтому раскладка на сочетание не влияет — и русская
    /// раскладка не отменяет ⌥⌘F.
    var keyCode: Int
    var command = false
    var option = false
    var control = false
    var shift = false

    /// Годится ли сочетание. Одного Shift мало: ⇧1 — это «!», и таймер
    /// запускался бы посреди набранного текста.
    var isValid: Bool { command || option || control }
}

/// Что рисовать в строке меню, пока таймер идёт.
///
/// Два варианта, потому что на тринадцати точках это решается только глазами:
/// кольцо показывает, сколько осталось, стрелка — что время идёт.
enum TimerDial: String, Codable, CaseIterable, Identifiable {
    /// Кольцо, которое убывает вместе с остатком.
    case ring
    /// Стрелка, обходящая круг за минуту, как секундная на часах.
    case hand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ring: return "Кольцо"
        case .hand: return "Стрелка"
        }
    }

    var hint: String {
        switch self {
        case .ring: return "Дуга убывает вместе с остатком — видно, сколько ещё"
        case .hand: return "Стрелка обходит круг за минуту — видно, что время идёт"
        }
    }
}

// MARK: - Запущенный таймер

/// Идущий таймер.
///
/// Держим срок, а не остаток: остаток, уменьшаемый на каждом тике, разъезжается
/// от каждого пропущенного тика и от сна компьютера — по той же причине, по
/// которой `Engine` считает срез заново, а не копит его.
struct TimerRun: Equatable {
    /// Каким пресетом заведён — по нему заход попадает в счёт этого таймера.
    var presetID: UUID
    /// Имя пресета копией: пресет могут переименовать или удалить, пока таймер
    /// идёт, а карточка в панели должна остаться подписанной.
    var name: String
    var total: TimeInterval
    var startedAt: Date
    var deadline: Date
    /// Сколько оставалось в момент паузы. `nil` — таймер идёт.
    var pausedRemaining: TimeInterval?

    var isPaused: Bool { pausedRemaining != nil }
}

/// Что происходит с таймером прямо сейчас.
enum TimerPhase: Equatable {
    case running(remaining: TimeInterval)
    case paused(remaining: TimeInterval)
    /// Отработал. Несколько секунд на месте таймера держится «Готово».
    case done
    /// Показывать больше нечего — пора возвращаться к обычному виду.
    case gone
}

/// Досчитанный до конца заход.
///
/// Считается по таймерам поодиночке, а не общей суммой: шесть подходов
/// с эспандером по полминуты и один помидор на двадцать пять минут в сумме
/// дают «28 минут», и это число не значит ничего. «Сегодня запускали 6 раз»
/// про конкретный таймер — значит.
struct TimerDone: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Какой таймер. Именно идентификатор, а не имя: таймер могут
    /// переименовать, и счёт при этом теряться не должен.
    var preset: UUID
    var at: Date
    /// Локальная дата по поясу из настроек — по ней и считается «сегодня».
    var day: DayStamp
    /// Имя на момент захода: по нему запись читается глазами в файле,
    /// и по нему же однажды можно будет показать историю переименованного.
    var name: String
    var seconds: Int

    init(id: UUID = UUID(), preset: UUID, at: Date, day: DayStamp, name: String, seconds: Int) {
        self.id = id
        self.preset = preset
        self.at = at
        self.day = day
        self.name = name
        self.seconds = seconds
    }

    /// Момент и таймер обязательны — без них запись бессмысленна. Остальное
    /// восстановимо: файл можно править руками, и урезанная запись не должна
    /// ронять разбор.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Date.self, forKey: .at)
        preset = try c.decode(UUID.self, forKey: .preset)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        id = c.value(.id, or: UUID())
        day = c.value(.day, or: DayStamp(at, in: calendar))
        name = c.value(.name, or: "Таймер")
        seconds = c.value(.seconds, or: 0)
    }
}

// MARK: - Правила

enum TimerRules {
    /// Больше трёх плашек в строку панели не помещается.
    static let maxPresets = 3

    /// Меньше пяти секунд — не таймер, а нажатие. Больше трёх часов не бывает
    /// ни у помидора, ни у подхода, а промах в поле ввода на порядок
    /// («250» вместо «25») заметить нечем.
    static let minSeconds = 5
    static let maxSeconds = 3 * 3600

    /// Предел журнала запусков. Записи мелкие, но файл живёт годами:
    /// шесть подходов в день — это тысяча записей за полгода.
    static let maxEntries = 20_000

    /// Сколько секунд таймер мигает перед концом.
    static let blinkSeconds: TimeInterval = 3

    /// Сколько держится «Готово» после конца.
    static let doneSeconds: TimeInterval = 3

    /// Тишина после таймера: напоминание о настроении, попавшее в фокус-сессию,
    /// сдвигается на её конец плюс эта минута. Ровно на конец — значит в ту же
    /// секунду, когда таймер мигает «Готово»; минута отделяет одно от другого.
    static let quietAfterFinish: TimeInterval = 60

    static func phase(_ run: TimerRun, now: Date) -> TimerPhase {
        if let paused = run.pausedRemaining { return .paused(remaining: max(0, paused)) }
        let left = run.deadline.timeIntervalSince(now)
        if left > 0 { return .running(remaining: left) }
        // Компьютер мог спать: проснулись, а срок прошёл полчаса назад.
        // Мигать и показывать «Готово» задним числом незачем — таймер просто
        // исчезает, как если бы его досмотрели.
        return -left < doneSeconds ? .done : .gone
    }

    /// Идут последние секунды — то самое зелёное мигание.
    static func blinking(_ run: TimerRun, now: Date) -> Bool {
        guard case .running(let remaining) = phase(run, now: now) else { return false }
        return remaining <= blinkSeconds
    }

    /// Фаза мигания: полсекунды горит, полсекунды нет.
    ///
    /// Считается от абсолютного времени, а не от остатка: тики приходят
    /// с допуском, и привязка к ним давала бы неровное мерцание.
    static func blinkOn(_ now: Date) -> Bool {
        Int(floor(now.timeIntervalSince1970 * 2)) % 2 == 0
    }

    /// Сколько таймера уже прошло, 0…1.
    static func progress(_ run: TimerRun, now: Date) -> Double {
        guard run.total > 0 else { return 1 }
        let remaining: TimeInterval
        switch phase(run, now: now) {
        case .running(let left), .paused(let left): remaining = left
        case .done, .gone: remaining = 0
        }
        return min(1, max(0, (run.total - remaining) / run.total))
    }

    /// Угол стрелки в градусах: полный круг за минуту, как у секундной.
    /// Считается от пройденного, а не от часов на стене, — чтобы на паузе
    /// стрелка замирала вместе с цифрами.
    static func handAngle(_ run: TimerRun, now: Date) -> Double {
        let remaining: TimeInterval
        switch phase(run, now: now) {
        case .running(let left), .paused(let left): remaining = left
        case .done, .gone: remaining = 0
        }
        let elapsed = max(0, run.total - remaining)
        return elapsed.truncatingRemainder(dividingBy: 60) * 6
    }

    /// «25:00», «0:29», «1:05:00» — то, что показывают в строке меню.
    /// Остаток округляется вверх: пока идёт последняя секунда, на счётчике
    /// должна стоять единица, а не ноль.
    static func clock(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Подпись на месте таймера в последние секунды.
    /// Не «Стоп таймер»: это читалось бы как кнопка, а не как сообщение.
    static let doneLabel = "Готово"

    /// «30 с», «25 мин», «1 ч», «1 ч 5 мин» — длительность на плашке.
    /// `Fmt.duration` здесь не годится: ровный час он называет «1 ч 0 мин».
    static func length(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) ч") }
        if m > 0 { parts.append("\(m) мин") }
        if s > 0 && h == 0 { parts.append("\(s) с") }
        return parts.isEmpty ? "0 с" : parts.joined(separator: " ")
    }

    /// Сколько раз этот таймер досчитали до конца в этот день.
    static func launches(_ entries: [TimerDone], preset: UUID, on day: DayStamp) -> Int {
        entries.reduce(0) { $0 + (($1.preset == preset && $1.day == day) ? 1 : 0) }
    }

    /// Хвост подсказки на плашке. Отдельной строкой в панели это не показано
    /// намеренно: место в ряду занято, а число запусков — не то, ради чего
    /// панель открывают.
    static func launchNote(_ count: Int) -> String {
        count == 0 ? "Сегодня ещё не запускали" : "Сегодня запускали \(Fmt.times(count))"
    }

    /// Подпись сочетания: «⌃⌥⌘9». Модификаторы в том же порядке, в каком
    /// их пишет система, — иначе одно и то же сочетание в разных местах
    /// выглядело бы по-разному.
    static func hotkeyName(_ hotkey: TimerHotkey) -> String {
        var text = ""
        if hotkey.control { text += "⌃" }
        if hotkey.option { text += "⌥" }
        if hotkey.shift { text += "⇧" }
        if hotkey.command { text += "⌘" }
        return text + keyName(hotkey.keyCode)
    }

    /// Имя клавиши по её коду. Латиницей и по физической клавише: именно так
    /// сочетание и работает, в любой раскладке.
    static func keyName(_ code: Int) -> String {
        if let named = specialKeyNames[code] { return named }
        if let letter = letterKeyNames[code] { return letter }
        return "клавиша \(code)"
    }

    /// Назначить сочетание одному таймеру, сняв его со всех остальных.
    ///
    /// Отказывать было бы хуже: человек уже решил, какой таймер он хочет
    /// на этих клавишах, и разбираться, у кого они заняты, — не его работа.
    /// Пропажу видно сразу: у прежнего владельца поле становится пустым.
    static func assigning(_ hotkey: TimerHotkey?, to preset: UUID,
                          in presets: [TimerPreset]) -> [TimerPreset] {
        presets.map { item in
            var updated = item
            if item.id == preset {
                updated.hotkey = (hotkey?.isValid ?? false) ? hotkey : nil
            } else if let hotkey, item.hotkey == hotkey {
                updated.hotkey = nil
            }
            return updated
        }
    }

    /// Записи удалённых таймеров выбрасываются: счёт живёт ровно столько,
    /// сколько сам таймер. Иначе файл копил бы историю того, чего в панели
    /// давно нет, и по идентификаторам её было бы уже не опознать.
    static func pruned(_ entries: [TimerDone], keeping presets: Set<UUID>) -> [TimerDone] {
        entries.filter { presets.contains($0.preset) }
    }

    // MARK: Действия

    static func start(_ preset: TimerPreset, now: Date) -> TimerRun {
        TimerRun(presetID: preset.id,
                 name: preset.name,
                 total: preset.duration,
                 startedAt: now,
                 deadline: now + preset.duration)
    }

    /// Пауза запоминает остаток, а не момент: продолжить нужно ровно с той
    /// секунды, на которой остановились, сколько бы ни длилась пауза.
    static func paused(_ run: TimerRun, now: Date) -> TimerRun {
        guard run.pausedRemaining == nil else { return run }
        var paused = run
        paused.pausedRemaining = max(0, run.deadline.timeIntervalSince(now))
        return paused
    }

    static func resumed(_ run: TimerRun, now: Date) -> TimerRun {
        guard let remaining = run.pausedRemaining else { return run }
        var resumed = run
        resumed.pausedRemaining = nil
        resumed.deadline = now + remaining
        return resumed
    }

    /// Длительность в допустимых границах.
    static func clamp(_ seconds: Int) -> Int {
        min(maxSeconds, max(minSeconds, seconds))
    }

    /// Клавиши, у которых есть собственное имя или знак.
    private static let specialKeyNames: [Int: String] = [
        49: "Пробел", 36: "↩", 48: "⇥", 51: "⌫", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 50: "`", 42: "\\",
    ]

    /// Буквы и цифры основного блока клавиатуры.
    private static let letterKeyNames: [Int: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4",
        23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]

    /// Пресеты, приведённые к правилам: не больше трёх, без пустых имён.
    static func normalized(_ presets: [TimerPreset]) -> [TimerPreset] {
        presets.prefix(maxPresets).map { preset in
            var fixed = preset
            let trimmed = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            fixed.name = trimmed.isEmpty ? "Таймер" : trimmed
            fixed.seconds = min(maxSeconds, max(minSeconds, preset.seconds))
            return fixed
        }
    }
}

// MARK: - Журнал запусков

/// Сколько раз какой таймер досчитали до конца.
///
/// Отдельным файлом рядом с настройками и отметками настроения — по тем же
/// причинам, что и у настроения: настройки целиком перезаписываются на каждое
/// нажатие клавиши в поле оклада, а истории там не место. Запись атомарная,
/// разбор терпимый поэлементно, испорченный файл откладывается в сторону.
///
/// В копию для переезда журнал не едет намеренно. Копия везёт настройки
/// и дневник настроения — то, что человек копил месяцами; счёт запусков
/// привязан к идентификаторам таймеров, обнуляется каждые сутки и на новой
/// машине наберётся за день. Сами таймеры при этом переезжают: они в настройках.
@MainActor
final class TimerLog: ObservableObject {
    @Published private(set) var entries: [TimerDone] = []

    /// Путь переопределяется переменной окружения — этим пользуются превью,
    /// зонды и тесты, чтобы не трогать живой журнал.
    static let fileURL: URL = {
        if let custom = ProcessInfo.processInfo.environment["SALARYFLOW_TIMERS"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SalaryFlow/timers.json")
    }()

    init() {
        entries = TimerLog.loadFromDisk()
    }

    func append(_ done: TimerDone) {
        entries.append(done)
        if entries.count > TimerRules.maxEntries {
            entries.removeFirst(entries.count - TimerRules.maxEntries)
        }
        save()
    }

    /// Оставить только записи живых таймеров. Зовётся, когда таймер удалили
    /// из настроек: его счёт уходит вместе с ним.
    func keepOnly(presets: Set<UUID>) {
        let kept = TimerRules.pruned(entries, keeping: presets)
        guard kept.count != entries.count else { return }
        Log.info("журнал запусков подчищен: убрано записей удалённых таймеров \(entries.count - kept.count)")
        entries = kept
        save()
    }

    /// Сколько раз этот таймер сегодня досчитали до конца.
    func launches(preset: UUID, on day: DayStamp) -> Int {
        TimerRules.launches(entries, preset: preset, on: day)
    }

    // MARK: Файл

    nonisolated static func decode(_ data: Data) -> (entries: [TimerDone], skipped: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(TimerFile.self, from: data) else { return ([], 0) }
        return (file.entries.sorted { $0.at < $1.at }, file.skipped)
    }

    nonisolated static func encode(_ entries: [TimerDone]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(TimerFile(entries: entries))
    }

    private static func loadFromDisk() -> [TimerDone] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else {
            Log.error("журнал запусков не читается: \(fileURL.path)")
            return []
        }
        let result = decode(data)
        if result.entries.isEmpty, data.count > 2 {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let quarantine = fileURL.deletingLastPathComponent()
                .appendingPathComponent("timers-broken-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            Log.error("журнал запусков испорчен, отложен в \(quarantine.lastPathComponent)")
            return []
        }
        if result.skipped > 0 {
            Log.warn("в журнале запусков пропущено записей: \(result.skipped)")
        }
        return result.entries
    }

    private func save() {
        let dir = TimerLog.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try TimerLog.encode(entries).write(to: TimerLog.fileURL, options: .atomic)
        } catch {
            Log.error("не удалось сохранить журнал запусков: \(error)")
        }
    }
}

/// Обёртка файла: разбирает массив поэлементно, чтобы одна испорченная запись
/// не уносила с собой все остальные.
struct TimerFile: Codable {
    var version = 1
    var entries: [TimerDone]
    var skipped = 0

    init(entries: [TimerDone]) {
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey { case version, entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, or: 1)
        let raw = c.value(.entries, or: [Lenient]())
        entries = raw.compactMap(\.entry)
        skipped = raw.count - entries.count
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(entries, forKey: .entries)
    }

    private struct Lenient: Decodable {
        let entry: TimerDone?
        init(from decoder: Decoder) throws {
            entry = try? TimerDone(from: decoder)
        }
    }
}
