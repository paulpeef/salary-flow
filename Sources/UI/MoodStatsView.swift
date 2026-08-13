import AppKit
import Charts
import SwiftUI

/// Раздел «Настроение» в окне настроек: что человек отмечал и что из этого следует.
///
/// Порядок разделов на странице — от общего к частному: сначала одна цифра
/// и тренд, потом разрезы, и только потом выводы словами. Выводы стоят после
/// картинок сознательно: сперва видно данные, потом их толкование, а не наоборот.
struct MoodStatsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var log: MoodLog

    @State private var window: MoodWindow = .month
    @State private var confirmWipe = false

    private var calendar: Calendar { model.settings.calendar }

    private var stats: MoodStats {
        MoodStats.build(entries: log.entries,
                        now: model.snapshot.now,
                        window: window,
                        calendar: calendar,
                        isWorkday: { model.isExpectedWorkday($0) })
    }

    var body: some View {
        Form {
            if model.amountsHidden {
                masked
            } else {
                let s = stats
                periodSection(s)
                if !s.isEmpty {
                    trendSection(s)
                    distributionSection(s)
                    profileSection(s)
                    heatmapSection(s)
                }
                insightsSection(s)
            }
            dataSection
        }
        .formStyle(.grouped)
        .confirmationDialog("Удалить всю историю настроения?", isPresented: $confirmWipe) {
            Button("Удалить \(Fmt.marks(log.entries.count))", role: .destructive) {
                log.removeAll()
            }
        } message: {
            Text("Отметки и вся статистика по ним исчезнут без возможности вернуть. Настройки и расчёт зарплаты это не затронет.")
        }
    }

    // MARK: Приватный режим

    /// Здесь лежит самое личное, что приложение знает: «не хочу здесь работать»
    /// на демонстрации экрана стоит дороже, чем открытая сумма оклада.
    private var masked: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Статистика скрыта")
                    Text(model.settings.hideAmount
                         ? "Суммы скрыты вручную. Снимите скрытие в панели, чтобы посмотреть."
                         : "Экран могут видеть посторонние: \(model.privacyReason?.title.lowercased() ?? "идёт захват"). Статистика вернётся сама.")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Период и итог

    private func periodSection(_ s: MoodStats) -> some View {
        Section {
            Picker("Период", selection: $window) {
                ForEach(MoodWindow.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                tile(title: "Индекс настроения",
                     value: s.index.map(Fmt.index) ?? "—",
                     subtitle: deltaText(s),
                     tint: s.index.map(MoodPalette.color) ?? .secondary)
                tile(title: "Отметок",
                     value: "\(s.marks)",
                     subtitle: s.marks > 0 ? "в \(Fmt.days(s.daysWithMarks))" : "пока ничего",
                     tint: .secondary)
                tile(title: "Чаще всего",
                     value: s.distribution.first.map { "\($0.kind.emoji) \($0.kind.short)" } ?? "—",
                     subtitle: s.distribution.first.map { Fmt.times($0.count) } ?? "",
                     tint: s.distribution.first?.kind.tint ?? .secondary,
                     big: false)
            }
        } header: {
            Text("Как дела в целом")
        } footer: {
            Text("Индекс — среднее по отметкам от 0 до 100: 50 — ровно посередине, «всё хорошо» даёт 75, «устал» — 25, «не хочу здесь работать» — 0. Отметки, сделанные подряд, считаются одним заходом, чтобы два клика не весили больше одного.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func deltaText(_ s: MoodStats) -> String {
        guard let index = s.index else { return "нет отметок" }
        guard let previous = s.previousIndex, s.previousMarks >= 3 else { return "сравнивать не с чем" }
        let delta = index - previous
        if abs(delta) < 1 { return "как в прошлый раз" }
        // Подпись в плашке одна строка и места мало: длинное «к прошлому
        // периоду» обрезалось многоточием.
        return (delta > 0 ? "▲ " : "▼ ") + Fmt.index(abs(delta)) + (delta > 0 ? " — лучше" : " — хуже")
    }

    private func tile(title: String, value: String, subtitle: String,
                      tint: Color, big: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
            Text(value)
                .font(.system(size: big ? 24 : 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Тренд

    private func trendSection(_ s: MoodStats) -> some View {
        Section {
            if s.byWeek.count < 2 {
                Text("Тренд появится, когда наберётся вторая неделя с отметками.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(s.byWeek) { point in
                        if let index = point.index {
                            LineMark(x: .value("Неделя", point.label),
                                     y: .value("Индекс", index))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.accentColor)
                            PointMark(x: .value("Неделя", point.label),
                                      y: .value("Индекс", index))
                            .foregroundStyle(MoodPalette.color(index: index))
                            .symbolSize(60)
                        }
                    }
                    RuleMark(y: .value("Середина", 50))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 140)
            }
        } header: {
            Text("Как менялось по неделям")
        } footer: {
            Text("Точка — неделя, подпись — её первый день. Пунктир посередине: выше — скорее хорошее, ниже — скорее тяжёлое.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Распределение

    /// Полосы рисуются руками, а не через Charts: у горизонтальной диаграммы
    /// подписи категорий ложатся на сами полосы, и читать это неудобно.
    /// Здесь же в строке помещается сразу всё — состояние, полоса, доля
    /// и сдвиг к прошлому периоду.
    private func distributionSection(_ s: MoodStats) -> some View {
        let peak = max(1, s.distribution.first?.count ?? 1)
        return Section {
            VStack(spacing: 6) {
                ForEach(s.distribution) { slice in
                    HStack(spacing: 8) {
                        Text("\(slice.kind.emoji) \(slice.kind.short)")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .frame(width: 108, alignment: .leading)

                        ProgressBar(value: Double(slice.count) / Double(peak), tint: slice.kind.tint)

                        Text("\(slice.count) · \(Fmt.percent(slice.share))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 62, alignment: .trailing)

                        Text(deltaMark(slice))
                            .font(.system(size: 10))
                            .foregroundStyle(deltaColor(slice))
                            .monospacedDigit()
                            .frame(width: 26, alignment: .trailing)
                            .help(slice.previousCount == 0 && slice.delta == 0
                                  ? "в прошлом периоде столько же"
                                  : "в прошлом периоде: \(slice.previousCount)")
                    }
                }
            }
        } header: {
            Text("Что отмечали")
        } footer: {
            Text(window == .all
                 ? "Доля считается от всех отметок периода."
                 : "Последняя колонка — насколько чаще или реже это отмечалось в сравнении с предыдущими \(Fmt.daysInstrumental(window.days ?? 0)).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func deltaMark(_ slice: MoodStats.Slice) -> String {
        guard window != .all, slice.delta != 0 else { return "" }
        return slice.delta > 0 ? "+\(slice.delta)" : "\(slice.delta)"
    }

    /// Рост «всё хорошо» — хорошая новость, рост «устал» — плохая.
    /// Цвет здесь про смысл, а не про знак числа.
    private func deltaColor(_ slice: MoodStats.Slice) -> Color {
        let better = slice.kind.isPositive ? slice.delta > 0 : slice.delta < 0
        return better ? .green : .orange
    }

    // MARK: Разрезы

    private func profileSection(_ s: MoodStats) -> some View {
        Section {
            profileChart(title: "По дням недели", points: s.byWeekday, overall: s.index)
            profileChart(title: "По времени дня", points: s.byTimeOfDay, overall: s.index)

            if !s.byMonthThird.isEmpty {
                profileChart(title: "По трети месяца", points: s.byMonthThird, overall: s.index)
            }
        } header: {
            Text("Когда бывает тяжелее")
        } footer: {
            Text("Столбик — средний индекс, число под ним — сколько отметок в него попало. Там, где отметок меньше трёх, разница обычно ничего не значит, и в выводах такие места не участвуют.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func profileChart(title: String, points: [MoodStats.Point], overall: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium))
            Chart {
                ForEach(points) { point in
                    if let index = point.index {
                        BarMark(x: .value("Когда", point.label),
                                y: .value("Индекс", index))
                        .foregroundStyle(MoodPalette.color(index: index))
                        .cornerRadius(3)
                        .opacity(point.count >= 3 ? 1 : 0.45)
                        // Число над столбиком нужно не для красоты: индекс 0
                        // даёт столбик нулевой высоты, и без подписи такой
                        // день выглядел бы как «нет данных».
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text(Fmt.index(index))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                if let overall {
                    RuleMark(y: .value("Среднее", overall))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self),
                           let point = points.first(where: { $0.label == label }) {
                            VStack(spacing: 0) {
                                Text(label)
                                Text("\(point.count)")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 110)
        }
        .padding(.vertical, 2)
    }

    // MARK: Теплокарта

    private func heatmapSection(_ s: MoodStats) -> some View {
        Section {
            // Число колонок подгоняется под окно: за его пределами клетки всё
            // равно пустые, потому что статистика считается только по окну, —
            // и пустота читалась бы как «не отмечал», а не «не показано».
            let heatmapWeeks = min(16, (window.days ?? 112) / 7 + 1)
            MoodHeatmap(stats: s, calendar: calendar, now: model.snapshot.now, weeks: heatmapWeeks)
            Text(heatmapRange(weeks: heatmapWeeks))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                legendCell("тяжело", MoodPalette.color(index: 20))
                legendCell("ниже среднего", MoodPalette.color(index: 35))
                legendCell("ровно", MoodPalette.color(index: 50))
                legendCell("хорошо", MoodPalette.color(index: 80))
                legendCell("нет отметок", Color.primary.opacity(0.06))
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        } header: {
            Text("По дням")
        }
    }

    /// Какой отрезок показан: по клеткам этого не видно, а знать полезно.
    private func heatmapRange(weeks: Int) -> String {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2
        let now = model.snapshot.now
        let thisWeek = weekCalendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? weekCalendar.startOfDay(for: now)
        guard let start = weekCalendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) else { return "" }
        return "Столбик — неделя с понедельника: с \(Fmt.shortDate(start)) по сегодня."
    }

    private func legendCell(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 11, height: 11)
            Text(title)
        }
    }

    // MARK: Выводы

    private func insightsSection(_ s: MoodStats) -> some View {
        Section {
            let insights = MoodInsights.build(s)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(insights) { insight in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: insight.level.symbol)
                            .foregroundStyle(insight.level.tint)
                            .font(.system(size: 11))
                        Text(insight.text)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        } header: {
            Text("Выводы")
        } footer: {
            Text("Выводы считаются по правилам, а не угадываются: каждый требует минимума отметок, иначе не показывается. Это не диагноз и не медицинское заключение — только пересказ того, что вы сами нажимали.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Данные

    private var dataSection: some View {
        Section {
            Toggle("Спрашивать в панели", isOn: $model.settings.moodEnabled)

            LabeledContent("История") {
                HStack {
                    Text(Fmt.marks(log.entries.count))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Выгрузить в CSV") { exportCSV() }
                        .disabled(log.entries.isEmpty)
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([MoodLog.fileURL])
                    }
                    Button("Удалить…", role: .destructive) { confirmWipe = true }
                        .disabled(log.entries.isEmpty)
                }
            }

            Text(MoodLog.fileURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } header: {
            Text("Отметки и файл")
        } footer: {
            Text("Отметки лежат обычным JSON рядом с настройками и не уходят никуда: ни в сеть, ни в журнал приложения — в журнал не пишется даже то, что отметка была такой-то. Это самое личное, что здесь есть, и оно остаётся на этой машине.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Выгрузка для тех, кто хочет посчитать по-своему: в таблице отметки
    /// раскладываются по строкам, а не по нашим правилам группировки.
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "salaryflow-mood.csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines = ["дата;время;состояние;вес;фаза дня;доля смены"]
        for entry in log.entries.sorted(by: { $0.at < $1.at }) {
            let time = String(format: "%02d:%02d", entry.minuteOfDay / 60, entry.minuteOfDay % 60)
            let fraction = entry.shiftFraction.map { String(format: "%.2f", $0) } ?? ""
            lines.append([Fmt.day(entry.day), time, entry.kind.title,
                          String(format: "%.1f", entry.kind.valence),
                          entry.phase.title, fraction].joined(separator: ";"))
        }
        // Windows-строки и BOM: иначе Excel открывает русский текст крякозябрами.
        let text = "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            Log.error("не удалось выгрузить историю настроения: \(error)")
        }
    }
}

// MARK: - Теплокарта

/// Календарь-теплокарта: неделя — колонка, день недели — строка.
///
/// Рисуется руками, а не средствами Charts: клетки должны быть одинаковыми
/// квадратами с понятным пропуском там, где отметок нет, а не столбиками,
/// подогнанными под размер области.
struct MoodHeatmap: View {
    var stats: MoodStats
    var calendar: Calendar
    var now: Date
    var weeks: Int

    private let cell: CGFloat = 13
    private let gap: CGFloat = 3

    var body: some View {
        let columns = buildColumns()
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: gap) {
                ForEach(Array(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"].enumerated()), id: \.offset) { _, title in
                    Text(title)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(height: cell)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(columns, id: \.start) { column in
                        VStack(spacing: gap) {
                            ForEach(column.days, id: \.self) { day in
                                cellView(day)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cellView(_ day: DayStamp) -> some View {
        let index = stats.dayIndex[day]
        let marks = stats.dayMarks[day] ?? 0
        let future = day > DayStamp(now, in: calendar)
        return RoundedRectangle(cornerRadius: 3)
            .fill(index.map(MoodPalette.color) ?? Color.primary.opacity(future ? 0.02 : 0.06))
            .frame(width: cell, height: cell)
            .help(index == nil
                  ? "\(Fmt.day(day)) — отметок нет"
                  : "\(Fmt.day(day)): индекс \(Fmt.index(index ?? 50)), \(Fmt.marks(marks))")
    }

    private struct Column: Hashable {
        var start: Date
        var days: [DayStamp]
    }

    /// Колонки строятся от понедельника: так последняя колонка — текущая неделя,
    /// а строки совпадают с привычным порядком дней.
    private func buildColumns() -> [Column] {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2
        let thisWeek = weekCalendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? weekCalendar.startOfDay(for: now)
        var result: [Column] = []
        for offset in stride(from: -(weeks - 1), through: 0, by: 1) {
            guard let start = weekCalendar.date(byAdding: .weekOfYear, value: offset, to: thisWeek) else { continue }
            var days: [DayStamp] = []
            for shift in 0..<7 {
                guard let date = weekCalendar.date(byAdding: .day, value: shift, to: start) else { continue }
                days.append(DayStamp(date, in: weekCalendar))
            }
            result.append(Column(start: start, days: days))
        }
        return result
    }
}
