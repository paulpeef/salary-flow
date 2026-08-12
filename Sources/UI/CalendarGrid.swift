import SwiftUI

/// Сетка месяцев: видно сразу, какие дни рабочие, какие выпали и почему.
/// Списком из полусотни дат это не читается — календарь показывает форму месяца.
struct CalendarGrid: View {
    @ObservedObject var model: AppModel
    /// Сколько месяцев показывать, начиная с текущего.
    var monthCount: Int = 4

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private let weekdayTitles = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
            ForEach(months, id: \.self) { month in
                monthBlock(month)
            }
        }
    }

    // MARK: Месяцы

    private var calendar: Calendar { model.settings.calendar }

    private var months: [DayStamp] {
        let today = DayStamp(Date(), in: calendar)
        return (0..<monthCount).compactMap { offset in
            var components = DateComponents()
            components.year = today.year
            components.month = today.month + offset
            components.day = 1
            guard let date = calendar.date(from: components) else { return nil }
            return DayStamp(date, in: calendar)
        }
    }

    private func monthBlock(_ month: DayStamp) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(monthTitle(month))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(workingDays(month)) раб.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 2) {
                ForEach(weekdayTitles, id: \.self) { title in
                    Text(title)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 2) {
                // Пустые клетки до первого числа: месяц должен начинаться
                // со своего дня недели, иначе сетка врёт.
                ForEach(0..<leadingBlanks(month), id: \.self) { _ in
                    Color.clear.frame(height: 22)
                }
                ForEach(days(in: month), id: \.self) { day in
                    dayCell(day)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func monthTitle(_ month: DayStamp) -> String {
        let date = month.startOfDay(in: calendar)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = month.year == DayStamp(Date(), in: calendar).year ? "LLLL" : "LLLL yyyy"
        return formatter.string(from: date).capitalizedFirst
    }

    private func days(in month: DayStamp) -> [DayStamp] {
        let date = month.startOfDay(in: calendar)
        guard let range = calendar.range(of: .day, in: .month, for: date) else { return [] }
        return range.map { DayStamp(year: month.year, month: month.month, day: $0) }
    }

    /// Неделя начинается с понедельника независимо от системных настроек:
    /// подписи столбцов заданы жёстко, и сетка должна им соответствовать.
    private func leadingBlanks(_ month: DayStamp) -> Int {
        let first = DayStamp(year: month.year, month: month.month, day: 1)
        let weekday = calendar.component(.weekday, from: first.startOfDay(in: calendar))
        return (weekday + 5) % 7
    }

    private func workingDays(_ month: DayStamp) -> Int {
        days(in: month).filter { model.engineSnapshotState(for: $0).isWorkday }.count
    }

    // MARK: Клетка дня

    private func dayCell(_ day: DayStamp) -> some View {
        let state = model.engineSnapshotState(for: day)
        let today = DayStamp(Date(), in: calendar)
        let isToday = day == today

        return Text("\(day.day)")
            .font(.system(size: 11, weight: isToday ? .bold : .regular))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(background(for: state), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(foreground(for: state))
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .help(tooltip(day, state))
    }

    private func background(for state: DayState) -> Color {
        switch state {
        case .working, .beforeShift, .afterShift: return Color.green.opacity(0.16)
        case .holiday: return Color.orange.opacity(0.20)
        case .paidLeave(.sickLeave): return Color.blue.opacity(0.18)
        case .paidLeave: return Color.teal.opacity(0.20)
        case .unpaid: return Color.red.opacity(0.14)
        case .weekend, .notEmployed: return Color.primary.opacity(0.05)
        }
    }

    private func foreground(for state: DayState) -> Color {
        switch state {
        case .working, .beforeShift, .afterShift: return .primary
        case .notEmployed: return .secondary.opacity(0.5)
        default: return .secondary
        }
    }

    /// Подсказка объясняет не только «что», но и «почему»: праздник назван,
    /// перенос назван переносом, рабочая суббота — рабочей субботой.
    private func tooltip(_ day: DayStamp, _ state: DayState) -> String {
        var parts = ["\(Fmt.day(day))"]

        if let name = model.holidays.nationalDays[day] {
            parts.append(name)
        } else if let note = model.settings.ranges.last(where: { $0.contains(day) })?.note,
                  !note.isEmpty {
            parts.append(note)
        }

        switch state {
        case .working, .beforeShift, .afterShift:
            let weekday = calendar.component(.weekday, from: day.startOfDay(in: calendar))
            parts.append(weekday == 1 || weekday == 7 ? "рабочий выходной по переносу" : "рабочий день")
        case .holiday: parts.append("нерабочий праздник")
        case .weekend: parts.append(model.holidays.officialDaysOff.contains(day)
                                    ? "нерабочий по производственному календарю" : "выходной")
        case .paidLeave(let kind): parts.append(kind.title.lowercased())
        case .unpaid: parts.append("за свой счёт")
        case .notEmployed: parts.append("вне периода работы")
        }

        return parts.joined(separator: " · ")
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
