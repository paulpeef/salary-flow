import Foundation

// MARK: - Что можно отметить

/// Состояния для опроса в панели.
///
/// Набор осознанно маленький и закрытый. Свободное поле здесь было бы хуже
/// по обеим причинам сразу: писать в него никто не станет, а сравнивать
/// записи между собой стало бы нечем — вся статистика держится на том, что
/// вариантов конечное число и у каждого есть числовой вес.
///
/// Порядок объявления — это и порядок плашек в панели: сначала хорошее,
/// потом всё остальное. «Всё хорошо» идёт первым сознательно: если человеку
/// нормально, он не должен пробираться к своему ответу через список жалоб.
/// Названия состояний менялись и ещё будут меняться, а `rawValue` — нет:
/// это ключ, которым отметка лежит в файле. Переименование подписи историю
/// не трогает, переименование `case` стёрло бы её молча.
enum MoodKind: String, Codable, CaseIterable, Identifiable {
    /// Ровный фон: ничего особенного, всё в порядке.
    case good
    /// Не просто нормально, а хорошо.
    case great
    /// Работа идёт, увлекает, время летит.
    case flow
    /// Кончились силы.
    case tired
    /// Работа даётся тяжело — не «сил нет», а именно тяжело.
    case hard
    /// Скучно: делать нечего или дело не занимает.
    case bored
    /// Тревожно, на пределе.
    case nervous
    /// Злость и раздражение — на людей, задачи или порядки.
    case angry
    /// Считает часы до конца дня: работа не невыносима, но хочется, чтобы
    /// она уже кончилась.
    case homeSoon
    /// «Хочу уволиться» — отметка про отношение к работе целиком.
    case quit

    var id: String { rawValue }

    /// Короткая подпись на плашке.
    ///
    /// Ширина панели 300pt, а высота её должна быть постоянной: длинная фраза
    /// переносит облако плашек на лишнюю строку и меняет высоту. Поэтому на
    /// плашке одно-два слова, а полная формулировка живёт в `title` и в подсказке.
    var short: String {
        switch self {
        case .good: return "Всё хорошо"
        case .great: return "Прекрасно"
        case .flow: return "В потоке"
        case .tired: return "Устал"
        case .hard: return "Тяжело"
        case .bored: return "Скучно"
        case .nervous: return "Тревожно"
        case .angry: return "Злюсь"
        case .homeSoon: return "Скорее бы домой"
        case .quit: return "Хочу уволиться"
        }
    }

    /// Полная формулировка — в статистике и выводах, где место есть.
    var title: String {
        switch self {
        case .good: return "всё хорошо"
        case .great: return "прекрасно"
        case .flow: return "в потоке"
        case .tired: return "устал"
        case .hard: return "тяжело работается"
        case .bored: return "скучно"
        case .nervous: return "тревожно"
        case .angry: return "злюсь"
        case .homeSoon: return "скорее бы домой"
        case .quit: return "хочу уволиться"
        }
    }

    var emoji: String {
        switch self {
        case .good: return "🙂"
        case .great: return "😄"
        // Волна, а не огонь: поток — это когда несёт, а не когда горит.
        case .flow: return "🌊"
        case .tired: return "😴"
        // Составные эмодзи (вроде «😮‍💨») в панели рисуются как попало —
        // берём простые односимвольные.
        case .hard: return "😓"
        case .bored: return "🥱"
        case .nervous: return "😬"
        case .angry: return "😠"
        case .homeSoon: return "🏠"
        case .quit: return "🚪"
        }
    }

    /// Подсказка при наведении: раскрывает короткую подпись до нормальной фразы.
    var hint: String {
        switch self {
        case .good: return "Ничего особенного, всё в порядке"
        case .great: return "Не просто нормально, а хорошо — редкое и ценное состояние"
        case .flow: return "Работа идёт, увлекает, время летит"
        case .tired: return "Кончились силы"
        case .hard: return "Тяжело работается — не в смысле «нет сил», а именно тяжело"
        case .bored: return "Скучно: делать нечего или дело не занимает"
        case .nervous: return "Тревожно, на пределе"
        case .angry: return "Злит и раздражает — люди, задачи или порядки"
        case .homeSoon: return "Считаю часы до конца дня"
        case .quit: return "Хочу уволиться — это не про сегодняшний день, а про работу целиком"
        }
    }

    /// От −2 (совсем плохо) до +2 (хорошо).
    ///
    /// Веса не выдуманы поровну: «тяжело», «тревожно» и «злюсь» тяжелее простой
    /// усталости, а «хочу уволиться» — предел шкалы, потому что это уже не про
    /// сегодняшний день. Из этих весов считается индекс настроения, и от них
    /// зависят все выводы — менять их значит менять историю задним числом.
    var valence: Double {
        switch self {
        // Верх шкалы занимают двое, и это не дубли: «прекрасно» — про общий
        // фон, «в потоке» — про работу. Бывает и одно без другого.
        case .great: return 2
        case .flow: return 2
        case .good: return 1
        case .tired: return -1
        case .bored: return -1
        // Ждать вечера — обычное человеческое состояние, а не беда: вес такой
        // же, как у скуки и усталости. Тяжесть тут не в самом чувстве, а в том,
        // когда оно приходит, — за это отвечает отдельный вывод про первую
        // половину дня.
        case .homeSoon: return -1
        case .hard: return -1.5
        case .nervous: return -1.5
        // Злость весит как тревога: обе про то, что изнашивается быстрее сил
        // и выходными не восстанавливается.
        case .angry: return -1.5
        case .quit: return -2
        }
    }

    /// Индекс отдельной отметки: 0…100, где 50 — ровно посередине.
    var index: Double { 50 + 25 * valence }

    var isPositive: Bool { valence > 0 }

    /// О чём именно эта отметка. Нужна, чтобы вывод говорил «просели силы»
    /// или «просел интерес», а не «просело настроение вообще» — это разные
    /// беды с разными решениями.
    var axis: MoodAxis {
        switch self {
        case .good, .great: return .mood
        // «Скорее бы домой» — про то же, что и скука: работа не занимает.
        case .flow, .bored, .homeSoon: return .interest
        case .tired: return .energy
        case .hard: return .load
        case .nervous: return .nerves
        // Злость и тревога разведены намеренно: тревога — про неопределённость
        // и давление, злость — про столкновение с людьми и порядками. Лечатся
        // они разным, и складывать их в одну ось значит потерять разницу.
        case .angry: return .anger
        case .quit: return .loyalty
        }
    }
}

/// По чему именно проседает настроение.
enum MoodAxis: String, Codable, CaseIterable, Identifiable {
    case mood, energy, interest, load, nerves, anger, loyalty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mood: return "общий фон"
        case .energy: return "силы"
        case .interest: return "интерес"
        case .load: return "нагрузка"
        case .nerves: return "нервы"
        case .anger: return "злость"
        case .loyalty: return "отношение к работе"
        }
    }
}

/// Где в рабочем дне человека застала отметка.
///
/// Считается в момент записи, а не при разборе статистики: график работы
/// со временем меняется, и восстанавливать по старой отметке, шла ли тогда
/// смена, было бы гаданием.
enum MoodPhase: String, Codable, CaseIterable {
    case beforeShift
    case working
    case afterShift
    /// Выходной, праздник, день за свой счёт, вне периода работы.
    case dayOff
    /// Отпуск или больничный.
    case leave
    /// Запись пришла из файла без этого поля.
    case unknown

    var title: String {
        switch self {
        case .beforeShift: return "до начала дня"
        case .working: return "в рабочее время"
        case .afterShift: return "после работы"
        case .dayOff: return "в выходной"
        case .leave: return "в отпуске или на больничном"
        case .unknown: return "неизвестно"
        }
    }

    init(_ state: DayState) {
        switch state {
        case .beforeShift: self = .beforeShift
        case .working: self = .working
        case .afterShift: self = .afterShift
        case .paidLeave: self = .leave
        case .weekend, .holiday, .unpaid, .notEmployed: self = .dayOff
        }
    }
}

// MARK: - Отметка

/// Одна отметка: что отметили и когда.
///
/// Производные поля (локальная дата, минута суток, день недели, фаза дня)
/// пишутся сразу, а не выводятся потом из `at`. Причина простая: пояс, график
/// и границы смены — это настройки, они меняются, а отметка сделана однажды
/// и в тех условиях, которые были тогда. Если считать «во сколько это было»
/// заново по новым настройкам, история поедет.
struct MoodEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Абсолютный момент.
    var at: Date
    var kind: MoodKind
    /// Локальная дата по поясу из настроек.
    var day: DayStamp
    /// Минуты от полуночи по тому же поясу.
    var minuteOfDay: Int
    /// День недели по нумерации Calendar: 1 = воскресенье … 7 = суббота.
    var weekday: Int
    var phase: MoodPhase
    /// Насколько прошла смена, 0…1 — только для отметок в рабочее время.
    /// По нему видно, приходит усталость к вечеру или уже к обеду.
    var shiftFraction: Double?

    init(id: UUID = UUID(), at: Date, kind: MoodKind, day: DayStamp,
         minuteOfDay: Int, weekday: Int, phase: MoodPhase, shiftFraction: Double? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.day = day
        self.minuteOfDay = minuteOfDay
        self.weekday = weekday
        self.phase = phase
        self.shiftFraction = shiftFraction
    }

    /// Момент и состояние обязательны — без них запись бессмысленна.
    /// Остальное восстанавливается из момента: файл можно править руками,
    /// и урезанная запись не должна ронять разбор.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Date.self, forKey: .at)
        kind = try c.decode(MoodKind.self, forKey: .kind)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: at)

        id = c.value(.id, or: UUID())
        day = c.value(.day, or: DayStamp(at, in: calendar))
        minuteOfDay = c.value(.minuteOfDay, or: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        weekday = c.value(.weekday, or: parts.weekday ?? 1)
        phase = c.value(.phase, or: .unknown)
        shiftFraction = try? c.decodeIfPresent(Double.self, forKey: .shiftFraction)
    }
}

/// Что делает нажатие на плашку.
///
/// Правило одно и без исключений: если отметка ещё выделена — нажатие её
/// снимает, иначе добавляет новую. Что видно выделенным, то и снимется.
///
/// Сочетания не запрещены никакие — «в потоке, но устал» это нормальная жизнь,
/// а не противоречие, и индекс захода как среднее по отметкам даёт ровно
/// середину. Запрет тут был (хорошее снимало плохое) и оказался вредным:
/// плашка гасла молча, и выглядело это как «не даёт выбрать несколько»
/// (наблюдение владельца, 2026-08-13).
enum MoodTap: Equatable {
    case add
    case remove(UUID)

    /// `open` — отметки, которые ещё можно снять (`MoodRules.openForUndo`).
    static func decide(kind: MoodKind, open: [MoodEntry]) -> MoodTap {
        if let existing = open.first(where: { $0.kind == kind }) { return .remove(existing.id) }
        return .add
    }
}

/// Правила, по которым отметки складываются в наблюдения.
enum MoodRules {
    /// Отметки, сделанные подряд в пределах этого окна, считаются одним
    /// заходом: человек может нажать «устал» и «скучно» вместе, и это одно
    /// состояние, а не два разных момента.
    ///
    /// На индекс это влияет, на число отметок — нет. Повтор «устал» через
    /// двадцать минут не делает день вдвое хуже (состояние-то одно), но в
    /// «сколько раз отмечали» он попадает: как часто человек об этом
    /// вспоминает — самостоятельный сигнал.
    static let checkInWindow: TimeInterval = 30 * 60

    /// Сколько времени плашка остаётся выделенной и снимается повторным
    /// нажатием.
    ///
    /// Окно короткое и намеренно отвязано от окна захода. «Ой, не то» замечают
    /// сразу — плашка загорелась не та, вот она перед глазами. А через двадцать
    /// минут человек уже не исправляет, он отмечает заново: «всё ещё устал».
    /// Пока эти два окна были одним, повтор был невозможен — выделенная плашка
    /// на нажатие только гасла (замечание владельца, 2026-08-13).
    static let undoWindow: TimeInterval = 3 * 60

    /// Отметки, которые ещё можно снять нажатием, — они же выделены в панели.
    /// Чистая функция: правило проверяется тестами, а не только глазами.
    static func openForUndo(_ entries: [MoodEntry], now: Date) -> [MoodEntry] {
        var result: [MoodEntry] = []
        // Записи лежат по возрастанию времени, поэтому идём с конца и
        // останавливаемся на первой старой: панель спрашивает это на каждый тик.
        for entry in entries.reversed() {
            let age = now.timeIntervalSince(entry.at)
            // Отметка из будущего — переведённые назад часы или правка файла
            // руками. Снимать её нечем: пользователь её не делал «только что».
            if age < 0 { continue }
            guard age <= undoWindow else { break }
            result.append(entry)
        }
        return result.reversed()
    }

    /// Больше этого числа отметок в файле не держим. При тройке отметок
    /// в день это больше двадцати лет — предел стоит не ради экономии,
    /// а чтобы испорченный или размноженный файл не рос без границ.
    static let maxEntries = 20_000

    /// Приводит историю к виду, в котором её ждёт всё остальное: по возрастанию
    /// времени и не длиннее предела.
    ///
    /// Порядок здесь не косметика. `openForUndo` и `lastMark` идут с конца
    /// и останавливаются на первой подходящей записи — на перемешанном списке
    /// они молча врут. Пока история росла только через `append`, порядок
    /// держался сам собой; с приходом импорта и объединения он стал тем,
    /// что нужно восстанавливать явно.
    static func normalized(_ entries: [MoodEntry]) -> [MoodEntry] {
        var sorted = entries.sorted { $0.at < $1.at }
        if sorted.count > maxEntries {
            sorted.removeFirst(sorted.count - maxEntries)
        }
        return sorted
    }
}

// MARK: - Хранилище

/// Журнал отметок: свой файл рядом с настройками.
///
/// Отдельный файл, а не поле в настройках, по двум причинам. Настройки
/// целиком перезаписываются на каждое нажатие клавиши в поле оклада —
/// подмешивать туда растущую историю незачем. И удалить историю, не сбросив
/// заодно все настройки, должно быть можно одним движением.
///
/// Данные не уходят в сеть ни при каких условиях: это самое чувствительное,
/// что приложение о человеке знает.
@MainActor
final class MoodLog: ObservableObject {
    @Published private(set) var entries: [MoodEntry] = []

    /// Путь переопределяется переменной окружения — этим пользуются превью
    /// и тесты, чтобы не трогать живую историю.
    static let fileURL: URL = {
        if let custom = ProcessInfo.processInfo.environment["SALARYFLOW_MOOD"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SalaryFlow/mood.json")
    }()

    init() {
        entries = MoodLog.loadFromDisk()
    }

    // MARK: Изменение

    func append(_ entry: MoodEntry) {
        entries.append(entry)
        if entries.count > MoodRules.maxEntries {
            let extra = entries.count - MoodRules.maxEntries
            entries.removeFirst(extra)
            Log.warn("журнал настроения подрезан: убрано \(extra) самых старых отметок")
        }
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        Log.info("история настроения удалена по кнопке в настройках (\(entries.count) отметок)")
        entries = []
        save()
    }

    /// Заменить журнал целиком — этим пользуется импорт копии.
    /// Порядок восстанавливается здесь, а не доверяется файлу: копию могли
    /// править руками.
    func replace(with newEntries: [MoodEntry]) {
        let normalized = MoodRules.normalized(newEntries)
        // Сколько отметок стало — не тайна, а вот какие они, в журнал не идёт.
        Log.info("журнал настроения заменён: было \(entries.count) отметок, стало \(normalized.count)")
        entries = normalized
        save()
    }

    /// Отметки, которые панель показывает выделенными и снимает нажатием.
    func marksOpenForUndo(now: Date) -> [MoodEntry] {
        MoodRules.openForUndo(entries, now: now)
    }

    /// Последняя отметка этого дня — панель показывает её время как
    /// «отмечено в 15:04». Держится до конца суток, а не пару минут:
    /// это память о том, что сегодня уже отмечались, и она не мешает
    /// отметиться снова.
    ///
    /// Отметки с временем позже `now` пропускаются: подпись «отмечено в 16:38»
    /// в половине третьего выглядит как ошибка, потому что ею и является.
    func lastMark(on day: DayStamp, notAfter now: Date) -> MoodEntry? {
        for entry in entries.reversed() where entry.at <= now {
            return entry.day == day ? entry : nil
        }
        return nil
    }

    // MARK: Файл

    /// Разбор терпимый на двух уровнях: непонятная запись выбрасывается
    /// по одной, а не роняет файл целиком. Файл этот живёт годами, и одна
    /// битая строка не должна стоить всей истории.
    nonisolated static func decode(_ data: Data) -> (entries: [MoodEntry], skipped: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(MoodFile.self, from: data) else { return ([], 0) }
        return (file.entries.sorted { $0.at < $1.at }, file.skipped)
    }

    nonisolated static func encode(_ entries: [MoodEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(MoodFile(entries: entries))
    }

    private static func loadFromDisk() -> [MoodEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else {
            Log.error("журнал настроения не читается: \(fileURL.path)")
            return []
        }
        let result = decode(data)
        if result.entries.isEmpty, data.count > 2 {
            // Файл есть, а записей нет — значит он испорчен. Откладываем в сторону,
            // а не перезаписываем: вдруг из него ещё что-то вытащат руками.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let quarantine = fileURL.deletingLastPathComponent()
                .appendingPathComponent("mood-broken-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            Log.error("журнал настроения испорчен, отложен в \(quarantine.lastPathComponent)")
            return []
        }
        if result.skipped > 0 {
            Log.warn("в журнале настроения пропущено записей: \(result.skipped)")
        }
        Log.info("журнал настроения прочитан: отметок \(result.entries.count)")
        return result.entries
    }

    private func save() {
        let dir = MoodLog.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            // Запись атомарная: файл либо старый целиком, либо новый целиком.
            try MoodLog.encode(entries).write(to: MoodLog.fileURL, options: .atomic)
        } catch {
            Log.error("не удалось сохранить журнал настроения: \(error)")
        }
    }
}

/// Обёртка файла. Разбирает массив поэлементно, чтобы одна испорченная
/// запись не уносила с собой все остальные.
///
/// Не приватная, потому что ровно эта обёртка вкладывается в копию для
/// переезда (`BackupFile`): формат истории там один и тот же, и второго
/// описания того же самого быть не должно.
struct MoodFile: Codable {
    var version = 1
    var entries: [MoodEntry]
    var skipped = 0

    init(entries: [MoodEntry]) {
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey { case version, entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, or: 1)
        // Разбор идёт через обёртку, которая не умеет падать: испорченный
        // элемент превращается в nil, а не в ошибку всего массива. Вручную
        // шагать по элементам нельзя — на брошенном элементе счётчик
        // JSONDecoder не двигается, и цикл встаёт насмерть.
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
        let entry: MoodEntry?
        init(from decoder: Decoder) throws {
            entry = try? MoodEntry(from: decoder)
        }
    }
}
