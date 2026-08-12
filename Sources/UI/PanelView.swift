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
            if let reason = model.privacyReason {
                privacyBanner(reason)
            }
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
        .environment(\.locale, Locale(identifier: "ru_RU"))
        // Плавное перекатывание цифр — ради него всё и затевалось.
        .animation(.snappy(duration: 0.25), value: s.monthEarned)
        .onAppear { model.panelIsOpen = true }
        .onDisappear { model.panelIsOpen = false }
    }

    // MARK: Состояние

    private func statusRow(_ s: Snapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: s.state.symbol)
                .foregroundStyle(s.state == .working ? Color.green : .secondary)
            Text(s.state.title)
                .font(.system(size: 12, weight: .medium))
            if let note = activeNote(s), !note.isEmpty {
                Text("· \(note)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if s.state.isWorkday, let start = s.shiftStart, let end = s.shiftEnd {
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

    private func privacyBanner(_ reason: PrivacyReason) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Приватный режим")
                    .font(.system(size: 11, weight: .medium))
                Text(reason.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if reason == .manual {
                Button("Показать") { model.settings.hideAmount = false }
                    .controlSize(.small)
            } else {
                Button("Показать") { model.temporaryReveal = true }
                    .controlSize(.small)
                    .help("До конца звонка — потом спрячется снова")
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
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
                model.settings.hideAmount.toggle()
            } label: {
                Image(systemName: model.amountsHidden ? "eye.slash" : "eye")
            }
            .help(model.amountsHidden ? "Показать суммы" : "Скрыть суммы (для демонстрации экрана)")

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
