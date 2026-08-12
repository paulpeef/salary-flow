import SwiftUI

/// День, выбранный кликом, — чтобы показать по нему подсказку.
private struct PickedDay: Identifiable {
    let day: DayStamp
    var id: String { "\(day.year)-\(day.month)-\(day.day)" }
}

/// Лента месяцев: видно сразу, какие дни рабочие, какие выпали и почему.
/// Списком из полусотни дат это не читается — календарь показывает форму месяца.
///
/// Месяцы идут одной строкой с прокруткой вправо: в несколько рядов они
/// разъезжались по высоте и мешали читать. Плашки одинакового размера,
/// потому что сетка всегда в шесть недель — короткий месяц просто
/// добирается пустыми клетками.
struct CalendarGrid: View {
    @ObservedObject var model: AppModel
    @State private var picked: PickedDay?

    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 2), count: 7)
    private let weekdayTitles = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
    private let weeksShown = 6

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(months, id: \.self) { month in
                    monthBlock(month)
                }
            }
            .padding(.bottom, 6)
        }
        .popover(item: $picked) { picked in
            dayDetails(picked.day)
                .padding(12)
                .frame(width: 260)
        }
    }

    // MARK: Какие месяцы показываем

    private var calendar: Calendar { model.settings.calendar }

    /// От текущего месяца до конца последнего года, про который вообще
    /// есть данные. Показывать дальше нечего — там пустой календарь.
    private var months: [DayStamp] {
        let today = DayStamp(Date(), in: calendar)
        let lastYear = model.holidays.years.max() ?? today.year
        let total = max(1, min(24, (lastYear - today.year) * 12 + (12 - today.month) + 1))

        return (0..<total).compactMap { offset in
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
                Spacer(minLength: 4)
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
                        .frame(width: 26)
                }
            }

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<(weeksShown * 7), id: \.self) { index in
                    if let day = day(at: index, in: month) {
                        dayCell(day)
                    } else {
                        // Пустая клетка держит размер: все месяцы одной высоты.
                        Color.clear.frame(width: 26, height: 22)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .fixedSize()
    }

    private func monthTitle(_ month: DayStamp) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = calendar.timeZone
        let sameYear = month.year == DayStamp(Date(), in: calendar).year
        formatter.dateFormat = sameYear ? "LLLL" : "LLLL yyyy"
        return formatter.string(from: month.startOfDay(in: calendar)).capitalizedFirst
    }

    private func daysCount(in month: DayStamp) -> Int {
        calendar.range(of: .day, in: .month, for: month.startOfDay(in: calendar))?.count ?? 30
    }

    /// Неделя начинается с понедельника независимо от системных настроек:
    /// подписи столбцов заданы жёстко, и сетка должна им соответствовать.
    private func leadingBlanks(_ month: DayStamp) -> Int {
        let first = DayStamp(year: month.year, month: month.month, day: 1)
        let weekday = calendar.component(.weekday, from: first.startOfDay(in: calendar))
        return (weekday + 5) % 7
    }

    private func day(at index: Int, in month: DayStamp) -> DayStamp? {
        let number = index - leadingBlanks(month) + 1
        guard number >= 1, number <= daysCount(in: month) else { return nil }
        return DayStamp(year: month.year, month: month.month, day: number)
    }

    private func workingDays(_ month: DayStamp) -> Int {
        (1...daysCount(in: month))
            .map { DayStamp(year: month.year, month: month.month, day: $0) }
            .filter { model.engineSnapshotState(for: $0).isWorkday }
            .count
    }

    // MARK: Клетка дня

    private func dayCell(_ day: DayStamp) -> some View {
        let state = model.engineSnapshotState(for: day)
        let isToday = day == DayStamp(Date(), in: calendar)

        return Button {
            picked = PickedDay(day: day)
        } label: {
            Text("\(day.day)")
                .font(.system(size: 11, weight: isToday ? .bold : .regular))
                .monospacedDigit()
                .frame(width: 26, height: 22)
                .background(background(for: state), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(foreground(for: state))
                .overlay {
                    if isToday {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(shortHint(day, state))
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

    // MARK: Подсказка

    private func shortHint(_ day: DayStamp, _ state: DayState) -> String {
        var parts = [Fmt.day(day), stateTitle(state)]
        if let name = model.holidays.nationalDays[day] { parts.insert(name, at: 1) }
        return parts.joined(separator: " · ")
    }

    private func stateTitle(_ state: DayState) -> String {
        switch state {
        case .working, .beforeShift, .afterShift: return "рабочий день"
        case .holiday: return "нерабочий праздник"
        case .weekend: return "выходной"
        case .paidLeave(let kind): return kind.title.lowercased()
        case .unpaid: return "за свой счёт"
        case .notEmployed: return "вне периода работы"
        }
    }

    /// Подсказка по клику объясняет не только «что», но и «почему»:
    /// праздник назван, перенос назван переносом.
    @ViewBuilder
    private func dayDetails(_ day: DayStamp) -> some View {
        let state = model.engineSnapshotState(for: day)
        let weekday = calendar.component(.weekday, from: day.startOfDay(in: calendar))
        let isWeekendByWeek = !model.settings.workWeekdays.contains(weekday)

        VStack(alignment: .leading, spacing: 8) {
            Text(fullDate(day))
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(background(for: state))
                    .frame(width: 14, height: 14)
                Text(stateTitle(state).capitalizedFirst)
                    .font(.system(size: 12))
            }

            if let name = model.holidays.nationalDays[day] {
                Label(name, systemImage: "party.popper")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            // Переносы — то, ради чего календарь и подтягивается.
            if model.holidays.officialWorkdays.contains(day) {
                explanation("Рабочий день по переносу: выходной сделан рабочим производственным календарём.",
                            systemImage: "arrow.left.arrow.right")
            } else if model.holidays.officialDaysOff.contains(day),
                      model.holidays.nationalDays[day] == nil,
                      !isWeekendByWeek {
                explanation("Нерабочий по переносу: будний день объявлен выходным.",
                            systemImage: "arrow.left.arrow.right")
            }

            if let range = model.settings.ranges.last(where: { $0.contains(day) }) {
                explanation(range.note.isEmpty
                            ? "Ваша запись: \(range.kind.title.lowercased())"
                            : "Ваша запись: \(range.kind.title.lowercased()) · \(range.note)",
                            systemImage: range.kind.symbol)
            }

            if state.isWorkday {
                let money = MoneyFormatter(settings: model.settings, decimals: 0)
                Text("Начисление за день: \(money.string(model.snapshot.dailyRate))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func explanation(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fullDate(_ day: DayStamp) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter.string(from: day.startOfDay(in: calendar)).capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
