import Foundation

// MARK: - Окно наблюдения

enum MoodWindow: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90
    case all = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: return "7 дней"
        case .month: return "30 дней"
        case .quarter: return "3 месяца"
        case .all: return "всё время"
        }
    }

    /// Сколько дней захватывает окно; nil — всё время.
    var days: Int? { self == .all ? nil : rawValue }
}

// MARK: - Заход

/// Отметки, сделанные подряд, — это один заход, а не несколько наблюдений.
/// Иначе человек, нажавший «устал» и «скучно» разом, весит в статистике вдвое
/// больше того, кто нажал что-то одно.
struct MoodCheckIn: Equatable {
    var at: Date
    var day: DayStamp
    var minuteOfDay: Int
    var weekday: Int
    var phase: MoodPhase
    var shiftFraction: Double?
    var kinds: [MoodKind]

    /// Индекс захода: среднее по его отметкам, 0…100.
    var index: Double {
        guard !kinds.isEmpty else { return 50 }
        return kinds.reduce(0) { $0 + $1.index } / Double(kinds.count)
    }

    var hasNegative: Bool { kinds.contains { !$0.isPositive } }
}

// MARK: - Статистика

/// Всё, что можно посчитать по отметкам. Чистая структура без интерфейса
/// и без обращений к системному времени: момент передаётся снаружи, поэтому
/// её можно гонять тестами по любым датам.
struct MoodStats {
    /// Точка графика. Индекс может отсутствовать — в этот день или час
    /// отметок не было, и рисовать там ноль было бы ложью.
    struct Point: Identifiable {
        var id: String
        var label: String
        var index: Double?
        var count: Int
    }

    struct Slice: Identifiable {
        var kind: MoodKind
        var count: Int
        var share: Double          // 0…1 от всех отметок окна
        var previousCount: Int
        var id: String { kind.rawValue }
        var delta: Int { count - previousCount }
    }

    var window: MoodWindow
    var now: Date

    var checkIns: [MoodCheckIn] = []
    var marks: Int = 0
    var counts: [MoodKind: Int] = [:]
    var previousCounts: [MoodKind: Int] = [:]
    var previousMarks: Int = 0

    /// Средний индекс за окно и за предыдущее такое же окно, 0…100.
    var index: Double?
    var previousIndex: Double?

    var distribution: [Slice] = []
    var byWeekday: [Point] = []
    var byTimeOfDay: [Point] = []
    var byWeek: [Point] = []
    var byMonthThird: [Point] = []

    /// Индекс и число отметок по дням — из этого рисуется теплокарта.
    var dayIndex: [DayStamp: Double] = [:]
    var dayMarks: [DayStamp: Int] = [:]

    var daysWithMarks: Int = 0
    var daysInWindow: Int = 0
    /// Рабочих дней в окне и сколько из них с отметками. Нужно, чтобы
    /// честно сказать, на какой доле дней вообще строятся выводы.
    var workdaysInWindow: Int?
    var workdaysWithMarks: Int?

    /// Сколько отметок пришло в нерабочее время — по фазам дня.
    var phaseCounts: [MoodPhase: Int] = [:]

    /// Худшая и текущая серия подряд идущих дней с отметками, где индекс дня
    /// ниже 40. Считается по дням с отметками, а не по календарным: про день
    /// без отметок мы ничего не знаем и достраивать его нечем.
    var worstStreak: Int = 0
    var currentStreak: Int = 0

    var firstDay: DayStamp?
    var lastDay: DayStamp?

    // MARK: Производные

    var isEmpty: Bool { marks == 0 }

    /// Достаточно ли данных, чтобы выводы вообще что-то значили.
    var isConclusive: Bool { marks >= 5 && daysWithMarks >= 3 }

    func count(_ kind: MoodKind) -> Int { counts[kind] ?? 0 }

    func share(_ kind: MoodKind) -> Double {
        marks > 0 ? Double(count(kind)) / Double(marks) : 0
    }

    /// Сколько отметок этого вида пришлось на вторую половину смены.
    func lateShiftShare(_ kind: MoodKind) -> (late: Int, total: Int) {
        let withFraction = checkIns.flatMap { checkIn -> [Double] in
            guard checkIn.kinds.contains(kind), let f = checkIn.shiftFraction else { return [] }
            return [f]
        }
        return (withFraction.filter { $0 >= 0.5 }.count, withFraction.count)
    }

    /// Негативные отметки, разложенные по тому, о чём они: силы, интерес,
    /// нагрузка, нервы, деньги, отношение к работе.
    var negativeByAxis: [(axis: MoodAxis, count: Int)] {
        var totals: [MoodAxis: Int] = [:]
        for (kind, count) in counts where !kind.isPositive {
            totals[kind.axis, default: 0] += count
        }
        return totals.sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
            .map { (axis: $0.key, count: $0.value) }
    }

    // MARK: Сборка

    static func build(entries: [MoodEntry],
                     now: Date,
                     window: MoodWindow,
                     calendar: Calendar,
                     isWorkday: ((DayStamp) -> Bool)? = nil) -> MoodStats {
        var stats = MoodStats(window: window, now: now)

        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2          // неделя с понедельника, как в календаре приложения

        let sorted = entries.sorted { $0.at < $1.at }
        let (from, previousFrom) = bounds(now: now, window: window, calendar: calendar, entries: sorted)

        let inWindow = sorted.filter { $0.at >= from && $0.at <= now }
        let inPrevious = sorted.filter { $0.at >= previousFrom && $0.at < from }

        stats.checkIns = groupIntoCheckIns(inWindow)
        stats.marks = inWindow.count
        stats.previousMarks = inPrevious.count
        stats.counts = tally(inWindow)
        stats.previousCounts = tally(inPrevious)
        stats.index = averageIndex(of: stats.checkIns)
        stats.previousIndex = averageIndex(of: groupIntoCheckIns(inPrevious))
        stats.firstDay = inWindow.first?.day
        stats.lastDay = inWindow.last?.day

        for entry in inWindow {
            stats.phaseCounts[entry.phase, default: 0] += 1
        }

        stats.distribution = MoodKind.allCases.compactMap { kind in
            let count = stats.counts[kind] ?? 0
            guard count > 0 else { return nil }
            return Slice(kind: kind, count: count,
                         share: stats.marks > 0 ? Double(count) / Double(stats.marks) : 0,
                         previousCount: stats.previousCounts[kind] ?? 0)
        }
        .sorted { ($0.count, $0.kind.valence) > ($1.count, $1.kind.valence) }

        // По дням: индекс дня — среднее по его заходам.
        let byDay = Dictionary(grouping: stats.checkIns, by: \.day)
        for (day, checkIns) in byDay {
            stats.dayIndex[day] = averageIndex(of: checkIns)
            stats.dayMarks[day] = checkIns.reduce(0) { $0 + $1.kinds.count }
        }
        stats.daysWithMarks = byDay.count
        stats.daysInWindow = window.days ?? max(1, daySpan(from: from, to: now, calendar: calendar))

        if let isWorkday {
            let days = calendarDays(from: from, to: now, calendar: calendar)
            let workdays = days.filter(isWorkday)
            stats.workdaysInWindow = workdays.count
            stats.workdaysWithMarks = workdays.filter { byDay[$0] != nil }.count
        }

        // По дню недели: порядок Пн…Вс, как в графике работы.
        let weekdayOrder: [(Int, String)] = [
            (2, "Пн"), (3, "Вт"), (4, "Ср"), (5, "Чт"), (6, "Пт"), (7, "Сб"), (1, "Вс")
        ]
        stats.byWeekday = weekdayOrder.map { number, title in
            let group = stats.checkIns.filter { $0.weekday == number }
            return Point(id: "wd\(number)", label: title,
                         index: averageIndex(of: group),
                         count: group.reduce(0) { $0 + $1.kinds.count })
        }

        // По времени суток. Границы выбраны по рабочему дню, а не по астрономии:
        // до начала, два куска до обеда, два после, вечер.
        let buckets: [(String, Range<Int>)] = [
            ("до 10", 0..<600), ("10–12", 600..<720), ("12–14", 720..<840),
            ("14–16", 840..<960), ("16–18", 960..<1080), ("после 18", 1080..<1440)
        ]
        stats.byTimeOfDay = buckets.compactMap { title, range in
            let group = stats.checkIns.filter { range.contains($0.minuteOfDay) }
            guard !group.isEmpty else { return nil }
            return Point(id: "tod\(range.lowerBound)", label: title,
                         index: averageIndex(of: group),
                         count: group.reduce(0) { $0 + $1.kinds.count })
        }

        // По неделям — тренд. Больше двенадцати точек на 300pt не читается.
        let weekGroups = Dictionary(grouping: stats.checkIns) { checkIn -> Date in
            let date = checkIn.day.startOfDay(in: weekCalendar)
            return weekCalendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        }
        stats.byWeek = weekGroups.keys.sorted().suffix(12).map { start in
            let group = weekGroups[start] ?? []
            return Point(id: "w\(Int(start.timeIntervalSince1970))",
                         label: Fmt.dayMonth(start, calendar: weekCalendar),
                         index: averageIndex(of: group),
                         count: group.reduce(0) { $0 + $1.kinds.count })
        }

        // По трети месяца: у зарплатного счётчика это не праздное деление —
        // к концу месяца деньги кончаются, и настроение это чувствует.
        let thirds: [(String, ClosedRange<Int>)] = [
            ("начало", 1...10), ("середина", 11...20), ("конец", 21...31)
        ]
        stats.byMonthThird = thirds.compactMap { title, range in
            let group = stats.checkIns.filter { range.contains($0.day.day) }
            guard !group.isEmpty else { return nil }
            return Point(id: "third\(range.lowerBound)", label: title,
                         index: averageIndex(of: group),
                         count: group.reduce(0) { $0 + $1.kinds.count })
        }

        let (worst, current) = streaks(dayIndex: stats.dayIndex)
        stats.worstStreak = worst
        stats.currentStreak = current

        return stats
    }

    // MARK: Кухня

    private static func bounds(now: Date, window: MoodWindow, calendar: Calendar,
                               entries: [MoodEntry]) -> (from: Date, previousFrom: Date) {
        guard let days = window.days else {
            let first = entries.first?.at ?? now
            return (first, first)
        }
        let from = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        let previousFrom = calendar.date(byAdding: .day, value: -2 * days, to: now) ?? from
        return (from, previousFrom)
    }

    static func groupIntoCheckIns(_ entries: [MoodEntry]) -> [MoodCheckIn] {
        var result: [MoodCheckIn] = []
        for entry in entries.sorted(by: { $0.at < $1.at }) {
            if var last = result.last,
               entry.at.timeIntervalSince(last.at) <= MoodRules.checkInWindow,
               last.day == entry.day {
                if !last.kinds.contains(entry.kind) { last.kinds.append(entry.kind) }
                result[result.count - 1] = last
            } else {
                result.append(MoodCheckIn(at: entry.at, day: entry.day,
                                          minuteOfDay: entry.minuteOfDay, weekday: entry.weekday,
                                          phase: entry.phase, shiftFraction: entry.shiftFraction,
                                          kinds: [entry.kind]))
            }
        }
        return result
    }

    private static func tally(_ entries: [MoodEntry]) -> [MoodKind: Int] {
        var counts: [MoodKind: Int] = [:]
        for entry in entries { counts[entry.kind, default: 0] += 1 }
        return counts
    }

    private static func averageIndex(of checkIns: [MoodCheckIn]) -> Double? {
        guard !checkIns.isEmpty else { return nil }
        return checkIns.reduce(0) { $0 + $1.index } / Double(checkIns.count)
    }

    private static func daySpan(from: Date, to: Date, calendar: Calendar) -> Int {
        let a = calendar.startOfDay(for: from)
        let b = calendar.startOfDay(for: to)
        return (calendar.dateComponents([.day], from: a, to: b).day ?? 0) + 1
    }

    private static func calendarDays(from: Date, to: Date, calendar: Calendar) -> [DayStamp] {
        var result: [DayStamp] = []
        var cursor = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        while cursor <= end, result.count < 1000 {
            result.append(DayStamp(cursor, in: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// Серии тяжёлых дней. День тяжёлый, если индекс ниже 40 — это уровень
    /// «устал» и хуже. Серия считается по дням с отметками подряд: день без
    /// отметок серию не продолжает и не рвёт, про него просто ничего не известно.
    private static func streaks(dayIndex: [DayStamp: Double]) -> (worst: Int, current: Int) {
        let days = dayIndex.keys.sorted()
        var worst = 0
        var running = 0
        for day in days {
            if (dayIndex[day] ?? 50) < 40 {
                running += 1
                worst = max(worst, running)
            } else {
                running = 0
            }
        }
        return (worst, running)
    }
}

// MARK: - Выводы

struct MoodInsight: Identifiable {
    enum Level: Int {
        case good, info, attention, alarm
    }

    var id = UUID()
    var level: Level
    var text: String
}

/// Выводы по статистике.
///
/// Правило здесь одно и оно важнее остальных: не говорить уверенно там, где
/// данных нет. Три отметки за месяц — это не «тенденция к выгоранию», а три
/// отметки, и приложение должно так и сказать.
enum MoodInsights {
    static func build(_ s: MoodStats) -> [MoodInsight] {
        guard !s.isEmpty else {
            return [MoodInsight(level: .info,
                                text: "Отметок за этот период нет. Отмечайте состояние в панели — через пару недель здесь появятся закономерности.")]
        }

        guard s.isConclusive else {
            return [MoodInsight(level: .info,
                                text: "Пока мало данных: \(Fmt.marks(s.marks)) за \(Fmt.days(s.daysWithMarks)). Выводы начнут что-то значить примерно с пяти отметок в трёх разных днях.")]
        }

        var result: [MoodInsight] = []
        background(s, into: &result)
        dynamics(s, into: &result)
        dominant(s, into: &result)
        timeOfDay(s, into: &result)
        weekdays(s, into: &result)
        monthThirds(s, into: &result)
        quitting(s, into: &result)
        streaks(s, into: &result)
        coverage(s, into: &result)
        return result
    }

    // MARK: Общий фон

    private static func background(_ s: MoodStats, into result: inout [MoodInsight]) {
        guard let index = s.index else { return }
        let word: String
        let level: MoodInsight.Level
        switch index {
        case 70...: (word, level) = ("в целом хорошее", .good)
        case 55..<70: (word, level) = ("скорее хорошее", .good)
        case 45..<55: (word, level) = ("ровное", .info)
        case 30..<45: (word, level) = ("скорее тяжёлое", .attention)
        default: (word, level) = ("тяжёлое", .alarm)
        }
        result.append(MoodInsight(level: level,
                                  text: "Настроение \(word): индекс \(Fmt.index(index)) из 100 по \(Fmt.marks(s.marks)) за \(Fmt.days(s.daysWithMarks))."))
    }

    private static func dynamics(_ s: MoodStats, into result: inout [MoodInsight]) {
        guard let index = s.index, let previous = s.previousIndex, s.previousMarks >= 3 else { return }
        let delta = index - previous
        let label = s.window == .all
            ? "с прошлым таким же отрезком"
            : "с предыдущими \(Fmt.daysInstrumental(s.window.days ?? 0))"
        if delta >= 7 {
            result.append(MoodInsight(level: .good,
                                      text: "Стало лучше: индекс \(Fmt.index(previous)) → \(Fmt.index(index)) в сравнении \(label)."))
        } else if delta <= -7 {
            result.append(MoodInsight(level: .attention,
                                      text: "Стало хуже: индекс \(Fmt.index(previous)) → \(Fmt.index(index)) в сравнении \(label)."))
        } else {
            result.append(MoodInsight(level: .info,
                                      text: "Держится ровно: индекс почти не изменился в сравнении \(label) (\(Fmt.index(previous)) → \(Fmt.index(index)))."))
        }
    }

    // MARK: Что именно чаще всего

    private static func dominant(_ s: MoodStats, into result: inout [MoodInsight]) {
        guard let top = s.distribution.first, top.count >= 3, s.share(top.kind) >= 0.3 else { return }
        let count = "\(top.count) из \(s.marks)"
        let text: String
        let level: MoodInsight.Level
        switch top.kind {
        case .good:
            (text, level) = ("Чаще всего всё в порядке — \(count) отметок. Остальное на этом фоне единичные случаи.", .good)
        case .flow:
            (text, level) = ("Чаще всего вы в потоке — \(count) отметок. Это редкая картина, и стоит заметить, при каких условиях так выходит.", .good)
        case .tired:
            (text, level) = ("Усталость — самое частое состояние (\(count) отметок). Это похоже на постоянную нехватку сил, а не на пару тяжёлых дней.", .attention)
        case .hard:
            (text, level) = ("Чаще всего работа идёт тяжело (\(count) отметок). Тяжело — это про сложность и сопротивление, а не про нехватку сил: посмотрите на задачи, а не на режим сна.", .attention)
        case .bored:
            (text, level) = ("Чаще всего скучно (\(count) отметок). Скука на работе изнашивает не меньше перегрузки, только медленнее и незаметнее.", .attention)
        case .nervous:
            (text, level) = ("Чаще всего нервно (\(count) отметок). Нервы — самое дорогое из всего списка: они не восстанавливаются выходными так, как силы.", .alarm)
        case .quit:
            (text, level) = ("Чаще всего — желание не работать здесь (\(count) отметок). Это не настроение дня, а вывод о работе целиком.", .alarm)
        }
        result.append(MoodInsight(level: level, text: text))

        // Вторая ось: если рядом с главной идёт другая по природе жалоба,
        // это меняет диагноз. Усталость плюс скука — не то же, что усталость плюс нагрузка.
        let axes = s.negativeByAxis
        if axes.count >= 2, axes[0].count >= 3, axes[1].count >= 3 {
            result.append(MoodInsight(level: .info,
                                      text: "Проседает не одно: \(axes[0].axis.title) (\(axes[0].count)) и \(axes[1].axis.title) (\(axes[1].count)). Это разные вещи, и починить их одним отдыхом не выйдет."))
        }
    }

    // MARK: Время дня

    private static func timeOfDay(_ s: MoodStats, into result: inout [MoodInsight]) {
        let (late, total) = s.lateShiftShare(.tired)
        if total >= 4 {
            if Double(late) / Double(total) >= 0.7 {
                result.append(MoodInsight(level: .info,
                                          text: "Усталость приходит ко второй половине дня — \(late) из \(total) отметок после середины смены. Это нормальный ход дня, а не тревожный признак."))
            } else if Double(total - late) / Double(total) >= 0.6 {
                result.append(MoodInsight(level: .attention,
                                          text: "Усталость начинается ещё до середины дня — \(total - late) из \(total) отметок в первой половине смены. Так выглядит либо недосып, либо работа, которая тяжела с самого утра."))
            }
        }

        // Проседающий кусок дня — только если в нём набралось на что смотреть.
        let solid = s.byTimeOfDay.filter { $0.count >= 3 && $0.index != nil }
        if solid.count >= 2, let overall = s.index,
           let worst = solid.min(by: { ($0.index ?? 100) < ($1.index ?? 100) }),
           let worstIndex = worst.index, overall - worstIndex >= 12 {
            result.append(MoodInsight(level: .info,
                                      text: "Самое тяжёлое время дня — \(worst.label): индекс \(Fmt.index(worstIndex)) против \(Fmt.index(overall)) в среднем."))
        }
    }

    // MARK: Дни недели

    private static func weekdays(_ s: MoodStats, into result: inout [MoodInsight]) {
        guard let overall = s.index else { return }
        let solid = s.byWeekday.filter { $0.count >= 3 && $0.index != nil }
        guard solid.count >= 3 else { return }

        if let worst = solid.min(by: { ($0.index ?? 100) < ($1.index ?? 100) }),
           let worstIndex = worst.index, overall - worstIndex >= 12 {
            result.append(MoodInsight(level: .attention,
                                      text: "Тяжелее всего \(dayInCase(worst.label)): индекс \(Fmt.index(worstIndex)) против \(Fmt.index(overall)) в среднем по неделе."))
        }
        if let best = solid.max(by: { ($0.index ?? 0) < ($1.index ?? 0) }),
           let bestIndex = best.index, bestIndex - overall >= 12 {
            result.append(MoodInsight(level: .good,
                                      text: "Лучший день недели — \(dayFull(best.label)): индекс \(Fmt.index(bestIndex))."))
        }
    }

    private static func dayInCase(_ short: String) -> String {
        switch short {
        case "Пн": return "по понедельникам"
        case "Вт": return "по вторникам"
        case "Ср": return "по средам"
        case "Чт": return "по четвергам"
        case "Пт": return "по пятницам"
        case "Сб": return "по субботам"
        default: return "по воскресеньям"
        }
    }

    private static func dayFull(_ short: String) -> String {
        switch short {
        case "Пн": return "понедельник"
        case "Вт": return "вторник"
        case "Ср": return "среда"
        case "Чт": return "четверг"
        case "Пт": return "пятница"
        case "Сб": return "суббота"
        default: return "воскресенье"
        }
    }

    // MARK: Внутри месяца

    private static func monthThirds(_ s: MoodStats, into result: inout [MoodInsight]) {
        let solid = s.byMonthThird.filter { $0.count >= 3 && $0.index != nil }
        guard solid.count >= 2, let overall = s.index else { return }
        if let worst = solid.min(by: { ($0.index ?? 100) < ($1.index ?? 100) }),
           let worstIndex = worst.index, overall - worstIndex >= 10 {
            result.append(MoodInsight(level: .info,
                                      text: "В месяце просаживается \(worst.label): индекс \(Fmt.index(worstIndex)) против \(Fmt.index(overall)) в среднем."))
        }
    }

    // MARK: Желание уйти

    private static func quitting(_ s: MoodStats, into result: inout [MoodInsight]) {
        let count = s.count(.quit)
        guard count > 0 else { return }
        let previous = s.previousCounts[.quit] ?? 0
        let days = Set(s.checkIns.filter { $0.kinds.contains(.quit) }.map(\.day)).count

        if count >= 6 || (count >= 3 && count > previous * 2) {
            result.append(MoodInsight(level: .alarm,
                                      text: "«Не хочу здесь работать» — \(Fmt.times(count)) за период, в \(Fmt.days(days))\(previous > 0 ? ", в предыдущем периоде \(previous)" : ""). Столько раз это не настроение: стоит решать вопрос с работой, а не пережидать."))
        } else if count >= 3 {
            result.append(MoodInsight(level: .attention,
                                      text: "«Не хочу здесь работать» — \(Fmt.times(count)) за период. Пока это не серия, но и не случайность: посмотрите, что было в эти дни."))
        } else {
            result.append(MoodInsight(level: .info,
                                      text: "«Не хочу здесь работать» — \(Fmt.times(count)) за период. На таком фоне это, скорее, плохой день."))
        }
    }

    private static func streaks(_ s: MoodStats, into result: inout [MoodInsight]) {
        if s.currentStreak >= 3 {
            result.append(MoodInsight(level: .alarm,
                                      text: "Прямо сейчас идёт серия: \(Fmt.days(s.currentStreak)) с отметками подряд, и каждый тяжёлый."))
        } else if s.worstStreak >= 3 {
            result.append(MoodInsight(level: .info,
                                      text: "Худшая серия за период — \(Fmt.days(s.worstStreak)) подряд с тяжёлыми отметками. Сейчас серия прервана."))
        }
    }

    // MARK: Честность выборки

    private static func coverage(_ s: MoodStats, into result: inout [MoodInsight]) {
        guard let workdays = s.workdaysInWindow, let covered = s.workdaysWithMarks, workdays >= 5 else { return }
        let share = Double(covered) / Double(workdays)
        if share < 0.34 {
            result.append(MoodInsight(level: .info,
                                      text: "Отметки есть в \(covered) из \(Fmt.days(workdays)) рабочих. Выводы выше построены на этой части — в плохой день о таких кнопках вспоминают чаще, чем в обычный, и картина может быть темнее настоящей."))
        }
    }
}
