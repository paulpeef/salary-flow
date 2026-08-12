import Foundation

// MARK: - Как классифицируется день

enum DayState: Equatable {
    /// Ещё не устроен / уже уволен.
    case notEmployed
    /// Выходной по графику недели.
    case weekend
    /// Нерабочий праздник.
    case holiday
    /// Отпуск или больничный — день оплачен целиком.
    case paidLeave(DayKind)
    /// За свой счёт — день не оплачен.
    case unpaid
    /// Рабочий день, смена ещё не началась.
    case beforeShift
    /// Рабочий день, идёт смена.
    case working
    /// Рабочий день, смена окончена.
    case afterShift

    var isWorkday: Bool {
        switch self {
        case .beforeShift, .working, .afterShift: return true
        default: return false
        }
    }
}

/// Мгновенный срез: всё, что показывает виджет, считается заново на каждый тик,
/// поэтому смена месяца, полуночи или таймзоны не требует отдельной обработки.
struct Snapshot {
    var now: Date
    var state: DayState

    var todayEarned: Double
    var todayFull: Double
    var dayProgress: Double        // 0…1
    var shiftStart: Date?
    var shiftEnd: Date?
    var secondsLeftToday: TimeInterval

    var monthEarned: Double
    var monthProjected: Double     // сколько выйдет, если доработать месяц по графику
    var monthProgress: Double      // 0…1 от прогноза

    var dailyRate: Double
    var perHour: Double
    var perSecond: Double

    var normDays: Int              // норма рабочих дней в месяце
    var paidDaysDone: Int          // сколько оплачиваемых дней уже закрыто
    var paidDaysTotal: Int         // сколько их будет к концу месяца
}

// MARK: - Расчёт

struct Engine {
    var settings: AppSettings

    private var calendar: Calendar { settings.calendar }

    // MARK: Классификация дней

    private func override(for day: DayStamp) -> DayKind? {
        // Более поздний диапазон в списке перекрывает более ранний —
        // так «рабочая суббота» посреди отпуска отрабатывает предсказуемо.
        settings.ranges.last(where: { $0.contains(day) })?.kind
    }

    private func isEmployed(_ day: DayStamp) -> Bool {
        if day < settings.employmentStart { return false }
        if settings.hasEmploymentEnd && day > settings.employmentEnd { return false }
        return true
    }

    /// Входит ли день в норму рабочих дней месяца.
    /// Норма не зависит от даты трудоустройства и от отпусков — это календарь компании.
    func isNormDay(_ day: DayStamp) -> Bool {
        switch override(for: day) {
        case .holiday: return false
        case .extraWorkday: return true
        default: break
        }
        let date = day.startOfDay(in: calendar)
        let weekday = calendar.component(.weekday, from: date)
        return settings.workWeekdays.contains(weekday)
    }

    func state(of day: DayStamp, now: Date) -> DayState {
        guard isEmployed(day) else { return .notEmployed }
        let kind = override(for: day)
        if kind == .holiday { return .holiday }
        guard isNormDay(day) else { return .weekend }
        switch kind {
        case .vacation: return .paidLeave(.vacation)
        case .sickLeave: return .paidLeave(.sickLeave)
        case .unpaid: return .unpaid
        default: break
        }
        guard let shift = shift(for: day) else { return .afterShift }
        if now < shift.start { return .beforeShift }
        if now >= shift.end { return .afterShift }
        return .working
    }

    // MARK: Смена

    /// Границы смены конкретного дня. Для ночного графика конец уезжает на следующие сутки.
    func shift(for day: DayStamp) -> (start: Date, end: Date)? {
        let midnight = day.startOfDay(in: calendar)
        guard let start = calendar.date(byAdding: .minute, value: settings.dayStart.minutesFromMidnight, to: midnight) else { return nil }
        var endMinutes = settings.dayEnd.minutesFromMidnight
        if endMinutes <= settings.dayStart.minutesFromMidnight { endMinutes += 24 * 60 }
        guard let end = calendar.date(byAdding: .minute, value: endMinutes, to: midnight) else { return nil }
        return (start, end)
    }

    /// Сколько секунд рабочего дня прошло к моменту `now`.
    /// Начисление идёт ровно от начала до конца дня: перерыв не вычитается,
    /// потому что он каждый день в разное время, а на итог всё равно не влияет.
    func paidSecondsElapsed(day: DayStamp, now: Date) -> (elapsed: TimeInterval, total: TimeInterval) {
        guard let shift = shift(for: day) else { return (0, settings.paidSecondsPerDay) }
        let total = max(60, shift.end.timeIntervalSince(shift.start))
        let cursor = min(max(now, shift.start), shift.end)
        let elapsed = cursor.timeIntervalSince(shift.start)
        return (min(max(0, elapsed), total), total)
    }

    // MARK: Ставки

    /// Норма рабочих дней месяца, которому принадлежит день.
    func normDays(inMonthOf day: DayStamp) -> Int {
        allDays(inMonthOf: day).filter { isNormDay($0) }.count
    }

    func allDays(inMonthOf day: DayStamp) -> [DayStamp] {
        let date = day.startOfDay(in: calendar)
        guard let range = calendar.range(of: .day, in: .month, for: date) else { return [] }
        return range.map { DayStamp(year: day.year, month: day.month, day: $0) }
    }

    /// Оплата за полный рабочий день.
    func dailyRate(inMonthOf day: DayStamp) -> Double {
        switch settings.mode {
        case .hourly:
            return settings.hourlyAmount * (settings.paidSecondsPerDay / 3600)
        case .monthly:
            switch settings.rateBasis {
            case .fixedDays:
                return settings.monthlyAmount / Double(max(1, settings.fixedDaysPerMonth))
            case .workingDaysInMonth:
                return settings.monthlyAmount / Double(max(1, normDays(inMonthOf: day)))
            }
        }
    }

    /// Сколько начислено за конкретный день к моменту `now`.
    func earned(on day: DayStamp, now: Date, rate: Double) -> Double {
        switch state(of: day, now: now) {
        case .notEmployed, .weekend, .holiday, .unpaid:
            return 0
        case .paidLeave:
            // День оплачен целиком, как только он наступил.
            return day.startOfDay(in: calendar) <= now ? rate : 0
        case .beforeShift:
            return 0
        case .afterShift:
            return rate
        case .working:
            let (elapsed, total) = paidSecondsElapsed(day: day, now: now)
            return rate * (elapsed / total)
        }
    }

    /// Полная оплата дня, если его отработать до конца.
    func fullDayValue(on day: DayStamp, rate: Double) -> Double {
        guard isEmployed(day), isNormDay(day) else { return 0 }
        switch override(for: day) {
        case .unpaid: return 0
        default: return rate
        }
    }

    // MARK: Срез

    func snapshot(now: Date = Date()) -> Snapshot {
        let today = DayStamp(now, in: calendar)

        // При ночном графике смена, начавшаяся вчера, ещё считается «сегодняшней».
        var activeDay = today
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now.startOfDayFallback(calendar)) {
            let prev = DayStamp(yesterday, in: calendar)
            if let shift = shift(for: prev), now < shift.end, now >= shift.start, state(of: prev, now: now).isWorkday {
                activeDay = prev
            }
        }

        let rate = dailyRate(inMonthOf: activeDay)
        let state = state(of: activeDay, now: now)
        let shift = shift(for: activeDay)

        let todayFull = fullDayValue(on: activeDay, rate: rate)
        let todayEarned = earned(on: activeDay, now: now, rate: rate)
        let (elapsed, total) = paidSecondsElapsed(day: activeDay, now: now)
        let dayProgress = state.isWorkday ? min(1, max(0, elapsed / total)) : (todayFull > 0 ? 1 : 0)
        let secondsLeft = state == .working ? max(0, (shift?.end.timeIntervalSince(now) ?? 0)) : 0

        // Ночная смена может начаться в прошлом месяце — сумму за месяц
        // всё равно считаем по ставке текущего календарного месяца.
        let monthRate = dailyRate(inMonthOf: today)
        var monthEarned = 0.0
        var monthProjected = 0.0
        var paidDaysDone = 0
        var paidDaysTotal = 0
        for day in allDays(inMonthOf: today) {
            let full = fullDayValue(on: day, rate: monthRate)
            monthProjected += full
            if full > 0 { paidDaysTotal += 1 }

            let got = earned(on: day, now: now, rate: monthRate)
            monthEarned += got
            if full > 0, got >= full - 0.000_001 { paidDaysDone += 1 }
        }

        let perHour: Double = {
            switch settings.mode {
            case .hourly: return settings.hourlyAmount
            case .monthly: return rate / (settings.paidSecondsPerDay / 3600)
            }
        }()

        return Snapshot(
            now: now,
            state: state,
            todayEarned: todayEarned,
            todayFull: todayFull,
            dayProgress: dayProgress,
            shiftStart: shift?.start,
            shiftEnd: shift?.end,
            secondsLeftToday: secondsLeft,
            monthEarned: monthEarned,
            monthProjected: monthProjected,
            monthProgress: monthProjected > 0 ? min(1, monthEarned / monthProjected) : 0,
            dailyRate: rate,
            perHour: perHour,
            perSecond: perHour / 3600,
            normDays: normDays(inMonthOf: today),
            paidDaysDone: paidDaysDone,
            paidDaysTotal: paidDaysTotal
        )
    }
}

private extension Date {
    func startOfDayFallback(_ calendar: Calendar) -> Date {
        calendar.startOfDay(for: self)
    }
}
