import Foundation

// MARK: - Файл копии

/// Копия для переезда: всё состояние приложения одним файлом.
///
/// Внутри лежат ровно те два документа, что и в `Application Support` —
/// `settings.json` и `mood.json` целиком, каждый со своим номером формата.
/// Новый формат данных здесь не изобретается намеренно: импорт тогда даром
/// получает всю уже написанную машинерию — терпимый разбор, где испорченное
/// поле откатывается к умолчанию, и дописывание старой схемы до текущей.
/// Копия, снятая версией 1.6, встанет в сегодняшнюю сборку сама.
///
/// Остальное в папке — производное: резервная копия настроек, кэш праздников,
/// карта переносов. На новой машине оно появится само, и в копии ему делать
/// нечего.
///
/// Файл уезжает туда, куда его сохранил человек, — значит содержимое видно
/// всякому, у кого он есть. Ничего сверх того, что и так лежит на диске,
/// в него не добавляется: ни имени пользователя, ни путей, ни журнала.
struct BackupFile: Codable {
    static let currentFormat = 1

    /// Метка «это наш файл». Без неё чужой JSON молча превратился бы
    /// в настройки по умолчанию, стерев настоящие.
    static let marker = "SalaryFlow"

    var format: Int
    var app: String
    /// Версия приложения, снявшего копию, — её видно в подтверждении импорта.
    var appVersion: String
    var exportedAt: Date
    /// Имя машины: когда копий несколько, оно отвечает на вопрос «эта откуда».
    var machine: String?

    /// Обе секции необязательные, и это не небрежность. Файл можно править
    /// руками, и копия, в которой оставили только историю настроения, должна
    /// ввозиться, а не отвергаться целиком.
    var settings: AppSettings?
    var mood: MoodFile?

    init(format: Int = BackupFile.currentFormat,
         app: String = BackupFile.marker,
         appVersion: String,
         exportedAt: Date,
         machine: String?,
         settings: AppSettings?,
         mood: MoodFile?) {
        self.format = format
        self.app = app
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.machine = machine
        self.settings = settings
        self.mood = mood
    }

    enum CodingKeys: String, CodingKey {
        case format, app, appVersion, exportedAt, machine, settings, mood
    }

    /// Разбор такой же терпимый, как у настроек: испорченная секция теряет
    /// себя, а не весь файл. Решение, годится ли то, что осталось, принимает
    /// `Backup.decode` — здесь только чтение.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Нет номера формата — считаем текущим: поле могли срезать при правке
        // руками, и отказывать из-за этого файлу с настоящими данными глупо.
        format = c.value(.format, or: BackupFile.currentFormat)
        app = c.value(.app, or: "")
        appVersion = c.value(.appVersion, or: "")
        exportedAt = c.value(.exportedAt, or: Date(timeIntervalSince1970: 0))
        machine = try? c.decodeIfPresent(String.self, forKey: .machine)
        settings = try? c.decodeIfPresent(AppSettings.self, forKey: .settings)
        mood = try? c.decodeIfPresent(MoodFile.self, forKey: .mood)
    }
}

// MARK: - Что внутри

/// Опись копии для окна подтверждения: человек должен увидеть, что именно
/// сейчас въедет поверх его данных, до того как это случится, а не после.
struct BackupSummary: Equatable {
    var exportedAt: Date
    var appVersion: String
    var machine: String?
    var hasSettings: Bool
    var entryCount: Int
    /// Сколько записей разбор выбросил как испорченные.
    var skipped: Int
    var firstDay: DayStamp?
    var lastDay: DayStamp?
    /// Пустую историю называем только тогда, когда секция в файле есть:
    /// «история пустая» и «истории в файле нет» — разные новости.
    var mentionsEmptyHistory = false

    /// Описание в две-три строки — заголовок подтверждения.
    ///
    /// Суммы здесь не показываются намеренно. Файл опознаётся по дате, машине
    /// и объёму истории; оклад для этого не нужен, а окно настроек открывают
    /// в том числе при включённом приватном режиме.
    var text: String {
        var lines = ["Копия от \(BackupSummary.stamp(exportedAt))"]

        // «?» приходит из сборки, запущенной вне бандла: номер версии живёт
        // в Info.plist, и вне его Sparkle отвечать нечем.
        let version = appVersion.trimmingCharacters(in: .whitespaces)
        var origin = "Снята версией \(version.isEmpty || version == "?" ? "неизвестной" : version)"
        if let machine, !machine.isEmpty { origin += ", машина «\(machine)»" }
        lines.append(origin)

        var parts: [String] = []
        if hasSettings { parts.append("настройки") }
        if entryCount > 0 {
            var marks = Fmt.marks(entryCount)
            if let first = firstDay, let last = lastDay {
                marks += first == last
                    ? " за \(Fmt.day(first))"
                    : " с \(Fmt.day(first)) по \(Fmt.day(last))"
            }
            parts.append(marks)
        } else if mentionsEmptyHistory {
            parts.append("история настроения пустая")
        }
        lines.append("Внутри: " + (parts.isEmpty ? "ничего" : Fmt.list(parts)))

        if skipped > 0 {
            lines.append("Испорченных записей, которые не поедут: \(skipped)")
        }
        return lines.joined(separator: "\n")
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy, HH:mm"
        return f.string(from: date)
    }
}

extension BackupFile {
    var summary: BackupSummary {
        let entries = mood?.entries ?? []
        var s = BackupSummary(
            exportedAt: exportedAt,
            appVersion: appVersion,
            machine: machine,
            hasSettings: settings != nil,
            entryCount: entries.count,
            skipped: mood?.skipped ?? 0,
            firstDay: entries.first?.day,
            lastDay: entries.last?.day
        )
        s.mentionsEmptyHistory = mood != nil
        return s
    }
}

// MARK: - Ошибки

/// Почему файл не годится. Текст сразу человеческий: это единственное, что
/// человек увидит, и «не удалось разобрать JSON» ему ничего не объясняет.
enum BackupError: Error, Equatable {
    /// Не JSON вообще: не тот файл, битая загрузка, архив вместо копии.
    case unreadable
    /// JSON, но чужой — не наша копия.
    case foreign
    /// Копия из будущего: формат новее, чем эта сборка умеет читать.
    case tooNew(Int)
    /// Наш файл, но внутри пусто — ни настроек, ни отметок.
    case empty

    var message: String {
        switch self {
        case .unreadable:
            return "Файл не читается: похоже, это не копия Salary Flow или он повреждён."
        case .foreign:
            return "Это не копия Salary Flow. Нужен файл, сохранённый кнопкой «Сохранить копию…»."
        case .tooNew(let format):
            return "Копия сделана более новой версией программы (формат \(format)). Обновите Salary Flow и попробуйте снова."
        case .empty:
            return "В копии нет ни настроек, ни отметок — переносить нечего."
        }
    }
}

// MARK: - Сборка и разбор

enum Backup {
    /// Что делает импорт с историей настроения.
    ///
    /// Настройки в обоих случаях заменяются целиком: смешивать два оклада
    /// бессмысленно, «половина графика оттуда» — не состояние, которое кто-то
    /// хотел бы получить.
    enum Mode: Equatable {
        /// Переезд: было — стало. Обычный случай.
        case replace
        /// Обе машины вели дневник: истории объединяются, дубли схлопываются.
        case mergeMarks
    }

    /// Что случилось со страховкой — копией прежнего состояния, которую
    /// импорт делает до того, как что-то трогать.
    enum SafetyCopy: Equatable {
        case written(URL)
        /// Свежая установка: терять было нечего, и класть в папку файл
        /// «до импорта» с пустотой внутри незачем.
        case notNeeded
        case failed
    }

    /// Итог импорта — из него собирается сообщение «готово».
    struct Result: Equatable {
        var mode: Mode
        var settingsReplaced: Bool
        var marksBefore: Int
        var marksAfter: Int
        /// Сколько отметок реально прибавилось при объединении.
        var added: Int
        var safetyCopy: SafetyCopy
    }

    static func make(settings: AppSettings,
                     entries: [MoodEntry],
                     appVersion: String,
                     machine: String?,
                     at date: Date = Date()) -> BackupFile {
        BackupFile(appVersion: appVersion,
                   exportedAt: date,
                   machine: machine,
                   settings: settings,
                   mood: MoodFile(entries: entries))
    }

    static func encode(_ file: BackupFile) throws -> Data {
        let encoder = JSONEncoder()
        // Читаемо и с устойчивым порядком ключей: копию можно открыть глазами
        // и сравнить две штуки обычным diff.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    static func decode(_ data: Data) throws -> BackupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(BackupFile.self, from: data) else {
            throw BackupError.unreadable
        }
        guard file.app == BackupFile.marker else { throw BackupError.foreign }
        guard file.format <= BackupFile.currentFormat else {
            throw BackupError.tooNew(file.format)
        }
        guard file.settings != nil || file.mood != nil else { throw BackupError.empty }
        return file
    }

    /// Имя по умолчанию в окне сохранения: `salaryflow-2026-08-17.json`.
    /// Дата в имени, потому что копий со временем становится несколько,
    /// и различать их по «копия (3)» — мучение.
    static func suggestedFileName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "salaryflow-\(f.string(from: date)).json"
    }

    // MARK: Объединение

    /// Склейка двух историй.
    ///
    /// Дубли ловятся дважды. По `id` — обычный случай: одна и та же отметка,
    /// уехавшая в копию и вернувшаяся обратно. И по паре «момент + состояние» —
    /// случай, когда файл правили руками или пересобирали, и `id` у одной
    /// и той же отметки разошлись. Момент округляется до секунды: в файле он
    /// и лежит с точностью до секунды, а после разбора ISO-строки в `Double`
    /// остаётся хвост, из-за которого равные моменты перестали бы совпадать.
    static func merged(existing: [MoodEntry],
                       incoming: [MoodEntry]) -> (entries: [MoodEntry], added: Int) {
        var ids = Set(existing.map(\.id))
        var moments = Set(existing.map(fingerprint))
        var result = existing
        var added = 0

        for entry in incoming {
            let mark = fingerprint(entry)
            guard !ids.contains(entry.id), !moments.contains(mark) else { continue }
            ids.insert(entry.id)
            moments.insert(mark)
            result.append(entry)
            added += 1
        }

        // Порядок и предел — там же, где и у обычной записи в журнал:
        // объединение двух полных историй как раз и есть тот единственный
        // способ перевалить за предел разом.
        return (MoodRules.normalized(result), added)
    }

    private static func fingerprint(_ entry: MoodEntry) -> String {
        "\(Int(entry.at.timeIntervalSince1970.rounded()))|\(entry.kind.rawValue)"
    }
}
