import Combine
import Foundation

// MARK: - Страна

/// Производственный календарь, по которому считаются нерабочие дни.
enum Country: String, Codable, CaseIterable, Identifiable {
    case russia
    case malaysia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .russia: return "Россия"
        case .malaysia: return "Малайзия"
        }
    }

    /// Файл снимка в бандле и имя кэша.
    var slug: String { rawValue }

    /// Календарь Google с государственными праздниками страны.
    /// Российский берём на русском — названия праздников идут сразу
    /// по-русски и включают перенесённые выходные.
    var calendarID: String {
        switch self {
        case .russia: return "ru.russian%23holiday%40group.v.calendar.google.com"
        case .malaysia: return "en.malaysia%23holiday%40group.v.calendar.google.com"
        }
    }

    var feedURL: URL? {
        URL(string: "https://calendar.google.com/calendar/ical/\(calendarID)/public/basic.ics")
    }

    /// Код страны для isdayoff.ru — сервиса, который ведёт карту переносов.
    /// У Малайзии переносов в нашем смысле нет: праздник, попавший на воскресенье,
    /// просто получает замещающий день, и он уже размечен в календаре праздников.
    var workCalendarCode: String? {
        switch self {
        case .russia: return "ru"
        case .malaysia: return nil
        }
    }

    func workCalendarURL(year: Int) -> URL? {
        guard let code = workCalendarCode else { return nil }
        return URL(string: "https://isdayoff.ru/api/getdata?year=\(year)&cc=\(code)")
    }
}

// MARK: - Праздник

struct PublicHoliday: Codable, Equatable, Identifiable {
    enum Scope: String, Codable {
        /// Нерабочий по всей стране.
        case national
        /// Нерабочий только в части штатов или регионов.
        case regional
    }

    var day: DayStamp
    var name: String
    var scope: Scope
    /// Для региональных — где именно, как это записано в календаре.
    var regions: String = ""
    /// Дата ещё может сдвинуться: мусульманские праздники объявляют по луне.
    var isTentative: Bool = false

    var id: String { "\(day.year)-\(day.month)-\(day.day)-\(name)" }
}

// MARK: - Разбор ICS

/// Минимальный разбор iCalendar: нужны только дата, название и вид праздника.
enum ICSParser {
    static func parse(_ text: String) -> [PublicHoliday] {
        // Длинные строки в ICS переносятся с ведущим пробелом — сначала склеиваем.
        let unfolded = text
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\n ", with: "")

        var result: [PublicHoliday] = []
        for block in unfolded.components(separatedBy: "BEGIN:VEVENT").dropFirst() {
            let event = block.components(separatedBy: "END:VEVENT").first ?? block
            guard let day = date(in: event), let name = field("SUMMARY", in: event) else { continue }
            let description = field("DESCRIPTION", in: event) ?? ""

            // «Observance» — это отметка в календаре, а не выходной:
            // День святого Валентина или канун Рождества работать не мешают.
            if description.localizedCaseInsensitiveContains("Observance") { continue }

            let isHoliday = description.hasPrefix("Public holiday")
                || description.hasPrefix("Государственный праздник")
            guard isHoliday else { continue }

            let regional = description.contains("Public holiday in ")
            let regions = regional
                ? String(description.dropFirst("Public holiday in ".count))
                    .components(separatedBy: "\\n").first?
                    .replacingOccurrences(of: "\\,", with: ",") ?? ""
                : ""

            result.append(PublicHoliday(
                day: day,
                name: cleanName(name),
                scope: regional ? .regional : .national,
                regions: regions,
                isTentative: name.localizedCaseInsensitiveContains("tentative")
                    || description.localizedCaseInsensitiveContains("Date is tentative")
            ))
        }
        return result.sorted { ($0.day, $0.name) < ($1.day, $1.name) }
    }

    private static func field(_ key: String, in event: String) -> String? {
        for line in event.components(separatedBy: .newlines) where line.hasPrefix("\(key):") {
            return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func date(in event: String) -> DayStamp? {
        for line in event.components(separatedBy: .newlines) where line.hasPrefix("DTSTART") {
            guard let raw = line.components(separatedBy: ":").last else { continue }
            let digits = raw.prefix(8)
            guard digits.count == 8,
                  let year = Int(digits.prefix(4)),
                  let month = Int(digits.dropFirst(4).prefix(2)),
                  let day = Int(digits.dropFirst(6).prefix(2)) else { continue }
            return DayStamp(year: year, month: month, day: day)
        }
        return nil
    }

    /// В календаре пометки идут прямо в названии — в списке они лишние.
    private static func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: " (regional holiday)", with: "")
            .replacingOccurrences(of: " (tentative)", with: "")
            .replacingOccurrences(of: "\\,", with: ",")
            .trimmingCharacters(in: .whitespaces)
    }
}

private func < (lhs: (DayStamp, String), rhs: (DayStamp, String)) -> Bool {
    lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
}

// MARK: - Хранилище

/// Праздники страны: снимок из бандла работает сразу и офлайн, поверх него
/// раз в неделю подтягивается свежий календарь.
///
/// Обновляться нужно не из аккуратности: даты мусульманских праздников
/// объявляют по луне и уточняют, а в России переносы выходных выходят
/// отдельным постановлением на каждый год.
@MainActor
final class HolidayStore: ObservableObject {
    @Published private(set) var holidays: [PublicHoliday] = []
    @Published private(set) var lastRefresh: Date?
    /// Карты годов с переносами. Пусто — значит считаем по дням недели.
    @Published private(set) var yearMaps: [Int: YearMap] = [:]

    private var country: Country
    private static let refreshInterval: TimeInterval = 7 * 24 * 3600

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    init(country: Country) {
        self.country = country
        load()
        loadYearMaps()
    }

    /// Официально нерабочие дни всех известных годов.
    var officialDaysOff: Set<DayStamp> {
        yearMaps.values.reduce(into: Set<DayStamp>()) { $0.formUnion($1.dayOff) }
    }

    /// Рабочие субботы и воскресенья.
    var officialWorkdays: Set<DayStamp> {
        yearMaps.values.reduce(into: Set<DayStamp>()) { $0.formUnion($1.workday) }
    }

    /// Годы, для которых карта переносов известна.
    var mappedYears: [Int] { yearMaps.keys.sorted() }

    func setCountry(_ new: Country) {
        guard new != country else { return }
        country = new
        yearMaps = [:]
        load()
        loadYearMaps()
        refreshIfStale()
    }

    /// Только национальные — их и подставляем в расчёт.
    /// Региональные показываем в списке, но сами не применяем: они зависят
    /// от штата, а штат приложение не знает.
    var nationalDays: [DayStamp: String] {
        Dictionary(holidays.filter { $0.scope == .national }.map { ($0.day, $0.name) },
                   uniquingKeysWith: { first, _ in first })
    }

    func holidays(inYear year: Int) -> [PublicHoliday] {
        holidays.filter { $0.day.year == year }
    }

    var years: [Int] {
        Array(Set(holidays.map(\.day.year))).sorted()
    }

    // MARK: Загрузка

    private static var cacheDirectory: URL {
        SettingsStore.fileURL.deletingLastPathComponent()
    }

    private var cacheURL: URL {
        HolidayStore.cacheDirectory.appendingPathComponent("holidays-\(country.slug).ics")
    }

    private var bundledURL: URL? {
        Bundle.main.url(forResource: "holidays-\(country.slug)", withExtension: "ics")
    }

    private func yearMapCacheURL(_ year: Int) -> URL {
        HolidayStore.cacheDirectory.appendingPathComponent("workdays-\(country.slug)-\(year).txt")
    }

    private func yearMapBundledURL(_ year: Int) -> URL? {
        Bundle.main.url(forResource: "workdays-\(country.slug)-\(year)", withExtension: "txt")
    }

    /// Интересуют текущий год и следующий: дальше данных обычно ещё нет.
    private var relevantYears: [Int] {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        return [year, year + 1]
    }

    private func loadYearMaps() {
        guard country.workCalendarCode != nil else { return }
        for year in relevantYears {
            for url in [yearMapCacheURL(year), yearMapBundledURL(year)].compactMap({ $0 }) {
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let map = WorkCalendarParser.parse(text, year: year, calendar: calendar) else { continue }
                yearMaps[year] = map
                Log.info("календарь переносов \(country.title) \(year): \(map.dayOff.count) нерабочих, \(map.workday.count) рабочих выходных")
                break
            }
        }
    }

    private func refreshYearMaps() async {
        guard country.workCalendarCode != nil else { return }
        for year in relevantYears {
            guard let url = country.workCalendarURL(year: year) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else { continue }
                guard let map = WorkCalendarParser.parse(text, year: year, calendar: calendar) else {
                    // Год ещё не размечен: сервис отдаёт заглушку из нулей.
                    // Молча остаёмся на дне недели плюс праздники.
                    Log.info("календарь переносов \(country.title) \(year): данных пока нет")
                    continue
                }
                try? data.write(to: yearMapCacheURL(year), options: .atomic)
                yearMaps[year] = map
                Log.info("календарь переносов \(country.title) \(year): обновлён, \(map.workday.count) рабочих выходных")
            } catch {
                Log.warn("календарь переносов \(country.title) \(year): \(error.localizedDescription)")
            }
        }
    }

    private func load() {
        // Скачанный календарь свежее вшитого, поэтому он и первый в очереди.
        for url in [cacheURL, bundledURL].compactMap({ $0 }) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let parsed = ICSParser.parse(text)
            guard !parsed.isEmpty else { continue }
            holidays = parsed
            lastRefresh = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            Log.info("праздники \(country.title): \(parsed.count) записей из \(url.lastPathComponent)")
            return
        }
        Log.warn("праздники \(country.title): не нашлось ни снимка, ни кэша")
    }

    /// Обновление молчаливое: не получилось — работаем на том, что есть.
    func refreshIfStale() {
        let age = lastRefresh.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard age > HolidayStore.refreshInterval else { return }
        Task {
            await refresh()
            await refreshYearMaps()
        }
    }

    func refresh() async {
        guard let url = country.feedURL else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else {
                Log.warn("праздники \(country.title): сервер ответил не тем")
                return
            }
            let parsed = ICSParser.parse(text)
            guard !parsed.isEmpty else {
                Log.warn("праздники \(country.title): в ответе нет ни одного праздника, оставляем прежние")
                return
            }
            try? FileManager.default.createDirectory(
                at: HolidayStore.cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            holidays = parsed
            lastRefresh = Date()
            Log.info("праздники \(country.title): обновлены, \(parsed.count) записей")
        } catch {
            Log.warn("праздники \(country.title): обновить не удалось (\(error.localizedDescription))")
        }
    }
}
