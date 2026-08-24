import Combine
import Foundation

// MARK: - Примитивы

/// Дата без времени и часового пояса. Храним именно так, чтобы перевод часов,
/// переезд между таймзонами и смена системного календаря не сдвигали
/// «дату выхода на работу» и границы отпуска.
struct DayStamp: Codable, Equatable, Comparable, Hashable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, in calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Начало этих суток в заданном календаре.
    func startOfDay(in calendar: Calendar) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        return calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    static func < (lhs: DayStamp, rhs: DayStamp) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Первое число текущего месяца — разумное «когда я вышел на работу»
    /// по умолчанию для того, кто работает давно.
    static var firstDayOfCurrentMonth: DayStamp {
        let now = DayStamp(Date(), in: Calendar(identifier: .gregorian))
        return DayStamp(year: now.year, month: now.month, day: 1)
    }

    static var lastDayOfCurrentYear: DayStamp {
        DayStamp(year: DayStamp(Date(), in: Calendar(identifier: .gregorian)).year,
                 month: 12, day: 31)
    }
}

/// Время суток без даты — начало/конец рабочего дня, начало перерыва.
struct TimeOfDay: Codable, Equatable, Hashable {
    var hour: Int
    var minute: Int

    var minutesFromMidnight: Int { hour * 60 + minute }

    init(hour: Int, minute: Int) {
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
    }
}

// MARK: - Особые дни

enum DayKind: String, Codable, CaseIterable, Identifiable {
    /// Отпуск: оплачивается по дневной ставке, работать не надо.
    case vacation
    /// Больничный: здесь считаем как оплачиваемый по дневной ставке.
    case sickLeave
    /// Отгул за свой счёт: день из нормы не выпадает, но и не оплачивается.
    case unpaid
    /// Нерабочий праздник: выпадает из нормы месяца, оклад не уменьшает.
    case holiday
    /// Рабочая суббота: обычный оплачиваемый рабочий день вне графика недели.
    case extraWorkday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vacation: return "Отпуск"
        case .sickLeave: return "Больничный"
        case .unpaid: return "За свой счёт"
        case .holiday: return "Праздник"
        case .extraWorkday: return "Рабочий выходной"
        }
    }

    var hint: String {
        switch self {
        case .vacation: return "Оплачивается по дневной ставке, работать не нужно"
        case .sickLeave: return "Оплачивается по дневной ставке, работать не нужно"
        case .unpaid: return "Не оплачивается, месячная сумма уменьшается"
        case .holiday: return "Выходной для всех, на сумму оклада не влияет"
        case .extraWorkday: return "Обычный рабочий день, даже если это выходной"
        }
    }

    var symbol: String {
        switch self {
        case .vacation: return "beach.umbrella"
        case .sickLeave: return "cross.case"
        case .unpaid: return "minus.circle"
        case .holiday: return "party.popper"
        case .extraWorkday: return "hammer"
        }
    }
}

/// Диапазон особых дней (включительно с обеих сторон).
struct DayRange: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var from: DayStamp
    var to: DayStamp
    var kind: DayKind
    var note: String = ""

    func contains(_ day: DayStamp) -> Bool {
        let lo = min(from, to)
        let hi = max(from, to)
        return day >= lo && day <= hi
    }

    init(id: UUID = UUID(), from: DayStamp, to: DayStamp, kind: DayKind, note: String = "") {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Даты обязательны — без них запись бессмысленна; остальное восстановимо.
        from = try c.decode(DayStamp.self, forKey: .from)
        to = try c.decode(DayStamp.self, forKey: .to)
        id = c.value(.id, or: UUID())
        kind = c.value(.kind, or: .vacation)
        note = c.value(.note, or: "")
    }
}

/// Читает поле, а если его нет или оно испорчено — подставляет значение по умолчанию.
///
/// Синтезированный Swift'ом `Decodable` не умеет использовать значения по умолчанию:
/// отсутствие ключа — это ошибка, роняющая разбор всего файла целиком. Из-за этого
/// добавление любого нового поля обнуляло пользователю все настройки разом.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        // try? схлопывает T?? в T?: отсутствие ключа и ошибка разбора
        // приводят к одному и тому же — берём значение по умолчанию.
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

// MARK: - Режимы расчёта

enum SalaryMode: String, Codable, CaseIterable, Identifiable {
    case monthly
    case hourly
    var id: String { rawValue }
    var title: String { self == .monthly ? "Оклад в месяц" : "Ставка в час" }
}

enum RateBasis: String, Codable, CaseIterable, Identifiable {
    /// Дневная ставка = оклад / норма рабочих дней конкретного месяца.
    case workingDaysInMonth
    /// Дневная ставка = оклад / фиксированное число дней (например, 21).
    case fixedDays
    var id: String { rawValue }
    var title: String {
        switch self {
        case .workingDaysInMonth: return "Норма рабочих дней месяца"
        case .fixedDays: return "Фиксированное число дней"
        }
    }
}

/// Что делать со счётчиком, когда экран могут видеть посторонние.
enum PrivacyAction: String, Codable, CaseIterable, Identifiable {
    /// Значок остаётся, цифры исчезают.
    case mask
    /// Пункт меню-бара пропадает целиком.
    case hide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mask: return "Убрать цифры, оставить значок"
        case .hide: return "Убрать из меню-бара совсем"
        }
    }
}

/// Чем присутствие процесса отличается от настоящего захвата экрана.
enum CaptureEvidence: Equatable {
    /// Процесс живёт ровно столько, сколько идёт захват: `screencapture`
    /// поднимается на снимок и тут же исчезает. Достаточно самого факта.
    case presence

    /// Процесс висит всё время звонка, показывают экран или нет, — значит,
    /// сам по себе он ничего не доказывает. Нужен живой признак: окно
    /// на экране. Zoom поднимает `CptHost` при входе в конференцию и держит
    /// до её конца (замерено 24.08.2026: 25 минут, 0% процессора, ни одного
    /// окна), а рамку вокруг показываемого экрана рисует только на время
    /// демонстрации — вот она и есть окно.
    case sharingFrame
}

/// Процесс, за которым следит монитор приватности, и признак, по которому
/// его засчитывают.
struct CaptureSuspect: Equatable {
    /// Совпадение по части имени, регистр не важен.
    let needle: String
    let evidence: CaptureEvidence

    init(_ needle: String, _ evidence: CaptureEvidence) {
        self.needle = needle
        self.evidence = evidence
    }
}

/// Какую сумму показывает счётчик: за сегодня или за месяц.
///
/// Выбор один на всё приложение: он же задаёт, какой блок в панели идёт первым
/// и крупным. Держать в меню-баре одно, а в панели другое было бы враньём —
/// человек нажимает на цифру именно затем, чтобы посмотреть её подробнее.
enum MenuBarTotal: String, Codable, CaseIterable, Identifiable {
    case day
    case month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "За текущий день"
        case .month: return "За текущий месяц"
        }
    }

    /// Короткая подпись — заголовок компактного блока в панели.
    var short: String {
        switch self {
        case .day: return "Сегодня"
        case .month: return "За месяц"
        }
    }
}

/// Настройка предыдущего формата: одно поле отвечало и за то, показывать ли
/// сумму вне рабочего дня, и за то, какую именно. Теперь это два вопроса,
/// потому что второй перестал быть вопросом только про вечер. Тип оставлен,
/// чтобы прочитать файл, записанный до этой правки, и перевести его.
enum IdleDisplay: String, Codable {
    case icon
    case dayTotal
    case monthTotal
}

// MARK: - Настройки

struct AppSettings: Codable, Equatable {
    /// Версия формата файла. Растёт, когда меняется смысл существующих полей;
    /// добавление новых полей версию не меняет — их подхватывает терпимый разбор.
    var schemaVersion: Int = AppSettings.currentSchemaVersion
    static let currentSchemaVersion = 3

    // Деньги
    var mode: SalaryMode = .monthly
    var monthlyAmount: Double = 150_000
    var hourlyAmount: Double = 1_500
    var currencyCode: String = "RUB"
    /// Производственный календарь: чьи государственные праздники считать нерабочими.
    var country: Country = .russia
    var customCurrencySymbol: String = ""

    // График
    /// Дни недели по нумерации Calendar: 1 = воскресенье … 7 = суббота.
    var workWeekdays: Set<Int> = [2, 3, 4, 5, 6]
    var dayStart = TimeOfDay(hour: 10, minute: 0)
    var dayEnd = TimeOfDay(hour: 19, minute: 0)
    var timeZoneID: String = TimeZone.current.identifier

    // Трудоустройство
    //
    // Даты вычисляются при первом запуске, а не зашиты в код: конкретное число
    // в значении по умолчанию — это чья-то чужая дата выхода на работу, и новому
    // пользователю она не подходит. Начало месяца выбрано потому, что большинство
    // работает в компании давно: итог за текущий месяц сойдётся сразу, без правок.
    var employmentStart: DayStamp = .firstDayOfCurrentMonth
    var hasEmploymentEnd: Bool = false
    var employmentEnd: DayStamp = .lastDayOfCurrentYear

    // База расчёта
    var rateBasis: RateBasis = .workingDaysInMonth
    var fixedDaysPerMonth: Int = 21

    // Особые дни
    var ranges: [DayRange] = []

    // Отображение
    /// Копейки по умолчанию выключены: на счётчике в меню-баре они дают
    /// мельтешение младших разрядов и мешают читать сумму. Кому нужно —
    /// включает на вкладке «Вид».
    var decimals: Int = 0
    /// Что считает счётчик: сегодняшний день или весь месяц.
    /// По умолчанию день — с ним приложение жило до появления выбора.
    var menuBarTotal: MenuBarTotal = .day
    /// Показывать ли сумму, когда рабочий день кончился.
    /// По умолчанию нет: вечером цифра замирает и превращается в шум,
    /// от которого глаз всё равно отучается.
    var idleShowsAmount: Bool = false
    var hideAmount: Bool = false
    var showIcon: Bool = true
    var launchAtLogin: Bool = false

    /// Спрашивать в панели, как человек себя чувствует.
    /// Выключается там же, где смотрится статистика: опрос — не обязательная
    /// часть счётчика, и панель без него просто короче.
    var moodEnabled: Bool = true

    /// Напоминать отметить настроение три раза за смену.
    /// По умолчанию включено: опрос, о котором не вспоминают, не даёт данных,
    /// а выключается он одним тумблером там же, где включается опрос.
    var moodRemindersEnabled: Bool = true

    /// Чем напоминать: уведомлением или раскрытой панелью.
    /// По умолчанию уведомлением — так напоминание догонит и того, кто сидит
    /// в другом приложении во весь экран.
    var moodReminderStyle: MoodReminderStyle = .notification

    // Браузер по умолчанию

    /// Показывать в панели выбор браузера по умолчанию.
    /// По умолчанию выключено: у большинства браузер один, и блок, который
    /// нечего переключать, был бы лишней строкой в панели у всех ради тех,
    /// кто держит рабочий и личный отдельно.
    var browserPickerEnabled: Bool = false

    /// Браузеры, снятые из панели. Хранится именно спрятанное, а не выбранное:
    /// так только что установленный браузер появляется в панели сам, а не
    /// пропадает молча, пока про него не вспомнят в настройках.
    var browserPickerHidden: [String] = []

    // Таймер

    /// Показывать в панели таймер.
    /// По умолчанию выключен, как и выбор браузера: панель нужна прежде всего
    /// ради денег, и необязательные блоки в ней включает тот, кому они нужны.
    var timerEnabled: Bool = false

    /// Настроенные таймеры, до трёх. Хранятся списком, а не тремя полями:
    /// одного человеку хватает, а пустые строки в настройках выглядели бы
    /// как незаполненная анкета.
    var timerPresets: [TimerPreset] = TimerPreset.defaults

    /// Что рисовать в строке меню, пока таймер идёт.
    var timerDial: TimerDial = .ring

    // Приватность
    var privacyOnCamera: Bool = true
    var privacyOnCapture: Bool = true
    var privacyAction: PrivacyAction = .mask
    /// Дополнительные имена процессов, добавленные пользователем.
    var privacyExtraProcesses: [String] = []

    /// Процессы, за которыми стоит следить, и чем каждый выдаёт настоящий захват.
    ///
    /// Здесь только те, что появляются на время сеанса. Программы удалённого
    /// доступа (AnyDesk, TeamViewer, RuDesktop) сюда сознательно не входят:
    /// их агенты висят в фоне круглосуточно, и счётчик спрятался бы навсегда.
    /// Проверено на этой машине — `rudesktop_agent` работает всё время,
    /// хотя никто никуда не подключён.
    static let defaultCaptureSuspects: [CaptureSuspect] = [
        CaptureSuspect("CptHost", .sharingFrame),   // Zoom: и демонстрация, и просто звонок
        CaptureSuspect("zcscpthost", .sharingFrame), // Zoom: он же в новых сборках
        CaptureSuspect("screencapture", .presence),  // встроенные скриншоты и запись экрана
        CaptureSuspect("screencaptureui", .presence),
        CaptureSuspect("screensharingd", .presence)  // «Общий экран» macOS, поднимается на время сеанса
    ]

    /// Полный список подозреваемых: встроенные плюс добавленные вручную.
    ///
    /// Свои процессы считаются по присутствию: человек добавляет их, посмотрев
    /// в Мониторинг системы, что процесс появляется именно на время показа, —
    /// требовать от них ещё и рамку значило бы молча не сработать.
    var captureSuspects: [CaptureSuspect] {
        AppSettings.defaultCaptureSuspects + privacyExtraProcesses
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { CaptureSuspect($0, .presence) }
    }

    init() {}

    /// Поля, которых в структуре уже нет, но которые могут лежать в файле.
    /// Синтезированные `CodingKeys` про них не знают — читаем отдельным ключом.
    private enum LegacyKeys: String, CodingKey {
        case idleDisplay
    }

    /// Разбор, переживающий любые изменения формата: каждое поле читается
    /// отдельно и при отсутствии или порче откатывается к значению по умолчанию.
    /// Настройки пользователя не должны теряться из-за того, что в программе
    /// появилась новая галочка.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()

        schemaVersion = c.value(.schemaVersion, or: 0)

        mode = c.value(.mode, or: d.mode)
        monthlyAmount = c.value(.monthlyAmount, or: d.monthlyAmount)
        hourlyAmount = c.value(.hourlyAmount, or: d.hourlyAmount)
        currencyCode = c.value(.currencyCode, or: d.currencyCode)
        country = c.value(.country, or: d.country)
        customCurrencySymbol = c.value(.customCurrencySymbol, or: d.customCurrencySymbol)

        workWeekdays = c.value(.workWeekdays, or: d.workWeekdays)
        dayStart = c.value(.dayStart, or: d.dayStart)
        dayEnd = c.value(.dayEnd, or: d.dayEnd)
        timeZoneID = c.value(.timeZoneID, or: d.timeZoneID)

        employmentStart = c.value(.employmentStart, or: d.employmentStart)
        hasEmploymentEnd = c.value(.hasEmploymentEnd, or: d.hasEmploymentEnd)
        employmentEnd = c.value(.employmentEnd, or: d.employmentEnd)

        rateBasis = c.value(.rateBasis, or: d.rateBasis)
        fixedDaysPerMonth = c.value(.fixedDaysPerMonth, or: d.fixedDaysPerMonth)
        ranges = c.value(.ranges, or: d.ranges)

        decimals = c.value(.decimals, or: d.decimals)
        menuBarTotal = c.value(.menuBarTotal, or: d.menuBarTotal)
        idleShowsAmount = c.value(.idleShowsAmount, or: d.idleShowsAmount)
        hideAmount = c.value(.hideAmount, or: d.hideAmount)
        showIcon = c.value(.showIcon, or: d.showIcon)
        launchAtLogin = c.value(.launchAtLogin, or: d.launchAtLogin)
        moodEnabled = c.value(.moodEnabled, or: d.moodEnabled)
        moodRemindersEnabled = c.value(.moodRemindersEnabled, or: d.moodRemindersEnabled)
        moodReminderStyle = c.value(.moodReminderStyle, or: d.moodReminderStyle)
        browserPickerEnabled = c.value(.browserPickerEnabled, or: d.browserPickerEnabled)
        browserPickerHidden = c.value(.browserPickerHidden, or: d.browserPickerHidden)
        timerEnabled = c.value(.timerEnabled, or: d.timerEnabled)
        timerPresets = c.value(.timerPresets, or: d.timerPresets)
        timerDial = c.value(.timerDial, or: d.timerDial)

        // Файл до третьей версии формата: поле «вне рабочего дня показывать»
        // разошлось на два — что показывать вообще и показывать ли вечером.
        // Перевод делается здесь, а не в хранилище, чтобы старый файл читался
        // правильно везде, включая тесты и инструменты.
        if schemaVersion < 3,
           let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
           let idle = try? legacy.decodeIfPresent(IdleDisplay.self, forKey: .idleDisplay) {
            switch idle {
            case .icon:
                idleShowsAmount = false
            case .dayTotal:
                menuBarTotal = .day
                idleShowsAmount = true
            case .monthTotal:
                menuBarTotal = .month
                idleShowsAmount = true
            }
        }

        privacyOnCamera = c.value(.privacyOnCamera, or: d.privacyOnCamera)
        privacyOnCapture = c.value(.privacyOnCapture, or: d.privacyOnCapture)
        privacyAction = c.value(.privacyAction, or: d.privacyAction)
        privacyExtraProcesses = c.value(.privacyExtraProcesses, or: d.privacyExtraProcesses)
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Длительность рабочего дня в секундах.
    /// Если конец раньше начала — смена считается ночной и переходит через полночь.
    ///
    /// Перерыва в расчёте нет намеренно: он каждый день в разное время, а на сумму
    /// за день и за месяц всё равно не влияет — дневная ставка берётся из оклада
    /// и нормы дней. Перерыв менял лишь форму кривой внутри дня и цифру «в час».
    var paidSecondsPerDay: TimeInterval {
        var span = TimeInterval(dayEnd.minutesFromMidnight - dayStart.minutesFromMidnight) * 60
        if span <= 0 { span += 24 * 3600 }
        return max(60, span)
    }
}

// MARK: - Хранилище

/// Настройки лежат обычным JSON-файлом — их можно править руками
/// и складывать в бэкап, не выковыривая из UserDefaults.
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { if settings != oldValue { save() } }
    }

    /// Путь можно переопределить переменной окружения — этим пользуются
    /// инструменты предпросмотра, чтобы не трогать боевые настройки.
    static let fileURL: URL = {
        if let custom = ProcessInfo.processInfo.environment["SALARYFLOW_SETTINGS"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SalaryFlow/settings.json")
    }()

    /// Копия последнего успешно прочитанного файла — страховка на случай,
    /// если основной окажется испорчен.
    static var backupURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("settings.backup.json")
    }

    init() {
        // Настройки могли остаться от прежнего имени приложения — сначала переезд.
        _ = Migration.performed
        settings = SettingsStore.loadFromDisk()
        if !FileManager.default.fileExists(atPath: SettingsStore.fileURL.path) {
            save()   // первый запуск: файл должно быть видно и можно править руками
        } else {
            SettingsStore.refreshBackup()
            settings = SettingsStore.upgraded(settings)
        }
    }

    /// Дописывает настройки прежней версии формата до текущей, сохранив всё,
    /// что в них было.
    ///
    /// Отдельная чистая функция, а не кусок `init`, потому что тем же путём
    /// должна проходить копия, приехавшая с другой машины: она могла быть
    /// снята сборкой полугодовой давности, и без этого шага её поля остались
    /// бы в старом смысле — молча, без единого признака.
    static func upgraded(_ settings: AppSettings) -> AppSettings {
        guard settings.schemaVersion != AppSettings.currentSchemaVersion else { return settings }
        Log.info("настройки дописаны с версии формата \(settings.schemaVersion) до \(AppSettings.currentSchemaVersion)")
        var upgraded = settings
        if upgraded.schemaVersion < 2, upgraded.decimals != 0 {
            // Копейки стали выключены по умолчанию — переводим и тех,
            // у кого они остались от прежней версии.
            upgraded.decimals = 0
            Log.info("копейки на счётчике выключены (их можно вернуть в разделе «Счётчик»)")
        }
        if upgraded.schemaVersion < 3 {
            // Сам перевод сделан при разборе — здесь только след в журнале,
            // чтобы по нему было видно, откуда взялось новое значение.
            Log.info("счётчик в меню-баре: показывает \(upgraded.menuBarTotal.title.lowercased()), вне рабочего дня сумма \(upgraded.idleShowsAmount ? "остаётся" : "убирается")")
        }
        upgraded.schemaVersion = AppSettings.currentSchemaVersion
        return upgraded
    }

    private static func decode(_ url: URL) throws -> AppSettings {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppSettings.self, from: data)
    }

    /// Настройки не должны теряться молча: испорченный файл откладывается в сторону,
    /// в дело идёт резервная копия, и всё это попадает в журнал.
    private static func loadFromDisk() -> AppSettings {
        let exists = FileManager.default.fileExists(atPath: fileURL.path)

        if exists {
            do {
                let loaded = try decode(fileURL)
                Log.info("настройки прочитаны: \(fileURL.path), версия формата \(loaded.schemaVersion)")
                return loaded
            } catch {
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let quarantine = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("settings-broken-\(stamp).json")
                try? FileManager.default.moveItem(at: fileURL, to: quarantine)
                Log.error("не удалось прочитать настройки (\(error)); файл отложен в \(quarantine.lastPathComponent)")
            }
        }

        if FileManager.default.fileExists(atPath: backupURL.path), let restored = try? decode(backupURL) {
            Log.warn("настройки восстановлены из резервной копии")
            return restored
        }

        if exists {
            Log.error("резервной копии тоже нет — настройки сброшены на значения по умолчанию")
        } else {
            Log.info("файла настроек нет, это первый запуск")
        }
        return AppSettings()
    }

    private static func refreshBackup() {
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    private func save() {
        let dir = SettingsStore.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(settings)
            try data.write(to: SettingsStore.fileURL, options: .atomic)
        } catch {
            Log.error("не удалось сохранить настройки: \(error)")
        }
    }
}
