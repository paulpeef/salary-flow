import AppKit
import SwiftUI

/// Панель, которая раскрывается по клику на значок в меню-баре.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var money: MoneyFormatter { MoneyFormatter(settings: model.settings) }
    private var moneyRounded: MoneyFormatter { MoneyFormatter(settings: model.settings, decimals: 0) }

    var body: some View {
        let s = model.snapshot

        VStack(alignment: .leading, spacing: 14) {
            statusRow(s)
            monthBlock(s)
            Divider()
            todayBlock(s)
            Divider()
            statsBlock(s)
            Divider()
            buttons
        }
        .padding(14)
        .frame(width: 300)
        // Высота панели теперь постоянна, но подстраховка остаётся: любое
        // изменение размера должно происходить одним шагом, иначе окно
        // меню-бара перерисовывает подложку не в такт с содержимым.
        .transaction { $0.animation = nil }
        .environment(\.locale, Locale(identifier: "ru_RU"))
        // Плавное перекатывание цифр — ради него всё и затевалось.
        .animation(.snappy(duration: 0.25), value: s.monthEarned)
        .onAppear { model.panelIsOpen = true }
        .onDisappear { model.panelIsOpen = false }
    }

    // MARK: Состояние

    /// Высота панели должна быть постоянной. Отдельный баннер приватности её
    /// менял, а окно меню-бара оставляет подложку прежнего размера — отсюда
    /// светлый прямоугольник позади панели. Поэтому причина живёт в строке
    /// состояния, которая есть всегда, а действие — на кнопке-глазе внизу.
    private func statusRow(_ s: Snapshot) -> some View {
        let privacy = model.privacyReason

        return HStack(spacing: 6) {
            Image(systemName: privacy != nil ? "eye.slash" : s.state.symbol)
                .foregroundStyle(privacy != nil ? Color.orange
                                 : (s.state == .working ? Color.green : .secondary))
            Text(privacy.map(shortPrivacyTitle) ?? s.state.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(privacy != nil ? Color.orange : .primary)
                .lineLimit(1)
            if privacy == nil, let note = activeNote(s), !note.isEmpty {
                Text("· \(note)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if privacy == nil, s.state.isWorkday, let start = s.shiftStart, let end = s.shiftEnd {
                Text("\(Fmt.clock(start, timeZone: model.settings.timeZone))–\(Fmt.clock(end, timeZone: model.settings.timeZone))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// Заметка особого дня («Отпуск · Турция») — если сегодня попало в диапазон.
    private func activeNote(_ s: Snapshot) -> String? {
        let today = DayStamp(s.now, in: model.settings.calendar)
        return model.settings.ranges.last(where: { $0.contains(today) })?.note
    }

    // MARK: Приватность

    /// Подпись к кнопке-глазу зависит от того, кто спрятал суммы.
    private var eyeHint: String {
        if model.settings.hideAmount { return "Показать суммы" }
        if model.detectedPrivacy != nil {
            return model.temporaryReveal ? "Спрятать снова" : "Показать до конца звонка"
        }
        return "Скрыть суммы (для демонстрации экрана)"
    }

    private func shortPrivacyTitle(_ reason: PrivacyReason) -> String {
        switch reason {
        case .manual: return "Суммы скрыты"
        case .camera: return "Скрыто: включена камера"
        case .capture: return "Скрыто: идёт захват экрана"
        }
    }

    // MARK: Месяц — главный блок

    private func monthBlock(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Заработано за \(Fmt.monthName(s.now, timeZone: model.settings.timeZone))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(model.amountsHidden ? "••• •••" : money.string(s.monthEarned))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Color.green)
                .contentTransition(.numericText())

            ProgressBar(value: s.monthProgress, tint: .green)

            HStack {
                Text("\(Fmt.percent(s.monthProgress)) месяца")
                Spacer()
                Text("из \(model.amountsHidden ? "•••" : moneyRounded.string(s.monthProjected))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    // MARK: Сегодня

    private func todayBlock(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Сегодня").font(.system(size: 11)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Text(model.amountsHidden ? "•••" : "\(money.string(s.todayEarned)) / \(moneyRounded.string(s.todayFull))")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            ProgressBar(value: s.dayProgress, tint: s.state == .working ? .accentColor : .secondary)
            HStack {
                Text(dayHint(s))
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private func dayHint(_ s: Snapshot) -> String {
        switch s.state {
        case .working:
            return "До конца дня \(Fmt.duration(s.secondsLeftToday))"
        case .beforeShift:
            if let start = s.shiftStart {
                return "Старт в \(Fmt.clock(start, timeZone: model.settings.timeZone)), через \(Fmt.duration(start.timeIntervalSince(s.now)))"
            }
            return "Смена ещё не началась"
        case .afterShift:
            return "День закрыт полностью"
        case .paidLeave(let kind):
            return "\(kind.title) — день оплачен целиком"
        case .weekend:
            return "Сегодня не рабочий день по графику"
        case .holiday:
            return "Нерабочий праздник, на оклад не влияет"
        case .unpaid:
            return "День не оплачивается"
        case .notEmployed:
            return "Дата вне периода работы в компании"
        }
    }

    // MARK: Мелкая статистика

    private func statsBlock(_ s: Snapshot) -> some View {
        VStack(spacing: 4) {
            statRow("В час", money.string(s.perHour))
            statRow("В минуту", MoneyFormatter(settings: model.settings, decimals: 2).string(s.perSecond * 60))
            statRow("Дневная ставка", moneyRounded.string(s.dailyRate))
            statRow("Оплачено дней", "\(s.paidDaysDone) из \(s.paidDaysTotal)")
            statRow("Норма месяца", Fmt.days(s.normDays))
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(model.amountsHidden ? "•••" : value).monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: Кнопки

    private var buttons: some View {
        HStack(spacing: 8) {
            Button {
                activateApp()
                openWindow(id: WindowID.settings)
            } label: {
                Label("Настройки", systemImage: "gearshape")
            }

            Spacer()

            Button {
                // Ручное скрытие снимаем настройкой, автоматическое — временным
                // показом до конца звонка: настройка тут ни при чём.
                if model.settings.hideAmount {
                    model.settings.hideAmount = false
                } else if model.detectedPrivacy != nil {
                    model.temporaryReveal.toggle()
                } else {
                    model.settings.hideAmount = true
                }
            } label: {
                Image(systemName: model.amountsHidden ? "eye.slash" : "eye")
            }
            .help(eyeHint)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Выйти")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// Тонкая полоса прогресса — стандартная ProgressView на macOS
/// выглядит здесь слишком тяжеловесно.
struct ProgressBar: View {
    var value: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}
