import Foundation

/// Карта года: какие дни официально нерабочие, а какие — рабочие вопреки календарю.
///
/// Нужна ради переносов. В России выходной может стать рабочим (рабочая суббота),
/// а будний день — нерабочим, и решается это постановлением, а не правилом.
/// Выводить такое из дня недели и списка праздников нельзя, поэтому берём готовую
/// карту у сервиса, который её ведёт.
struct YearMap: Equatable {
    var year: Int
    /// Нерабочие дни, включая перенесённые.
    var dayOff: Set<DayStamp> = []
    /// Рабочие дни, выпавшие на выходной по графику недели.
    var workday: Set<DayStamp> = []

    var isEmpty: Bool { dayOff.isEmpty && workday.isEmpty }
}

enum WorkCalendarParser {
    /// Ответ isdayoff.ru — строка из символов по одному на день года:
    /// «0» рабочий, «1» выходной, «2» сокращённый (тоже рабочий), «4» нерабочий.
    ///
    /// Данные будущих лет сервис отдаёт заглушкой из одних нулей — до выхода
    /// постановления о переносах. Принять такую карту нельзя: она объявила бы
    /// рабочими все субботы и воскресенья, и счётчик капал бы без выходных.
    /// Поэтому карта проверяется на правдоподобие: в году не может быть меньше
    /// сотни нерабочих дней.
    static func parse(_ text: String, year: Int, calendar: Calendar) -> YearMap? {
        let symbols = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let expected = daysInYear(year, calendar: calendar)
        guard symbols.count == expected else { return nil }

        var map = YearMap(year: year)
        var start = DateComponents()
        start.year = year
        start.month = 1
        start.day = 1
        guard let firstDay = calendar.date(from: start) else { return nil }

        for (offset, symbol) in symbols.enumerated() {
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
            let stamp = DayStamp(date, in: calendar)
            let weekday = calendar.component(.weekday, from: date)
            let isWeekend = weekday == 1 || weekday == 7

            switch symbol {
            case "1", "4":
                map.dayOff.insert(stamp)
            case "0", "2":
                if isWeekend { map.workday.insert(stamp) }
            default:
                continue
            }
        }

        guard map.dayOff.count >= 100 else { return nil }
        return map
    }

    static func daysInYear(_ year: Int, calendar: Calendar) -> Int {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        guard let date = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .year, for: date) else { return 365 }
        return range.count
    }
}
