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

        // Отступ 10, а не 14: девять промежутков по 14 съедали 126 точек —
        // каждый пятый пиксель панели был пустым. Линии-разделители стоят
        // только там, где меняется голос: после пары главных цифр и перед
        // рядом кнопок. Между «сегодня» и «за месяц» линия не нужна — это
        // одна мысль в двух масштабах.
        VStack(alignment: .leading, spacing: 10) {
            statusRow(s)
            // Первым и крупным идёт то, что выбрано для меню-бара: на цифру
            // нажали затем, чтобы посмотреть её подробнее, и искать её глазами
            // в середине панели человек не должен. Второй итог остаётся тут же,
            // компактной строкой, — он всегда нужен следующим вопросом.
            //
            // Высота панели от порядка не зависит: крупный блок всегда ровно
            // один и компактный ровно один, меняются они только местами.
            hero(model.settings.menuBarTotal == .day ? today(s) : month(s))
            compact(model.settings.menuBarTotal == .day ? month(s) : today(s))
            Divider()
            statsBlock(s)
            if model.settings.moodEnabled {
                MoodBlock(model: model, log: model.mood)
            }
            Divider()
            buttons
        }
        .padding(14)
        // 340, а не 300: десятая плашка опроса не помещалась в три строки,
        // а четвёртая строка — это лишние 26 точек высоты и разъехавшееся
        // облако. Заодно перестали жаться строки с суммами.
        .frame(width: 340)
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

    // MARK: Итоги дня и месяца

    /// Всё, что нужно нарисовать про один итог. Оба итога описываются одинаково,
    /// поэтому крупный и компактный вид — это две функции, а не два блока:
    /// иначе четыре сочетания пришлось бы держать в согласии руками.
    private struct Totals {
        var heroCaption: String
        var caption: String
        var earned: Double
        var full: Double
        var progress: Double
        var hint: String
        var tint: Color
    }

    private func today(_ s: Snapshot) -> Totals {
        Totals(heroCaption: "Заработано сегодня",
               caption: "Сегодня",
               earned: s.todayEarned,
               full: s.todayFull,
               progress: s.dayProgress,
               hint: dayHint(s),
               // Зелёная, пока день идёт, и приглушённая, когда кончился:
               // цвет теперь отвечает за «капает или нет», а не за то,
               // день это или месяц.
               tint: s.state == .working ? .green : .secondary)
    }

    private func month(_ s: Snapshot) -> Totals {
        let name = Fmt.monthName(s.now, timeZone: model.settings.timeZone)
        return Totals(heroCaption: "Заработано за \(name)",
                      caption: "За \(name)",
                      earned: s.monthEarned,
                      full: s.monthProjected,
                      progress: s.monthProgress,
                      // Не «43% месяца»: непонятно, процент времени это или
                      // денег. Дни отвечают на тот же вопрос без двусмысленности.
                      hint: "Оплачено дней: \(s.paidDaysDone) из \(s.paidDaysTotal)",
                      // Тот же цвет, что и у дневной полосы. Разные цвета
                      // у двух одинаковых по смыслу индикаторов — обещание
                      // разницы, которой нет: это одна мысль в двух масштабах.
                      tint: .green)
    }

    /// Крупный вид: то, зачем панель открыли.
    private func hero(_ t: Totals) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.heroCaption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)

            // Цветом текста, а не зелёным (жалоба владельца 2026-08-17: «нечитаемо»).
            // Подложка панели полупрозрачная, и системный зелёный на светлых
            // обоях теряет контраст ровно там, где его нужно больше всего —
            // на 28 точках полужирного. Это была самая плохо читаемая строка
            // в приложении, и зелёной она стояла с первой версии.
            //
            // Цвет из цифры никуда не делся, он переехал на полосу под ней:
            // на сплошной заливке контраст не важен, а «деньги идут» читается
            // с той же секунды.
            Text(model.amountsHidden ? "••• •••" : money.string(t.earned))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())

            ProgressBar(value: t.progress, tint: t.tint)

            HStack {
                Text(t.hint)
                Spacer()
                Text("из \(model.amountsHidden ? "•••" : moneyRounded.string(t.full))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    /// Компактный вид: второй итог, который всё равно спросят следующим.
    private func compact(_ t: Totals) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t.caption).font(.system(size: 11)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Text(model.amountsHidden ? "•••" : "\(money.string(t.earned)) / \(moneyRounded.string(t.full))")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            ProgressBar(value: t.progress, tint: t.tint)
            HStack {
                Text(t.hint)
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
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

    /// Было пять одинаковых серых строк без всякой иерархии — самый плохо
    /// читаемый кусок панели, а в приватном режиме ещё и пять одинаковых
    /// «•••» подряд, похожих на сбой отрисовки.
    ///
    /// «В минуту» убрано: производная от «в час», не меняется за день, а два
    /// знака после запятой делают её похожей на живую. «Норма месяца» уехала
    /// в «Деньги → Что получается»: это вход расчёта, по нему в панели ничего
    /// не решают. «Оплачено дней» переехало под цифру месяца, где отвечает
    /// на вопрос «сколько ещё». Осталось то, что нельзя посчитать в уме.
    private func statsBlock(_ s: Snapshot) -> some View {
        statRow("Ставка", "\(moneyRounded.string(s.dailyRate)) в день · \(moneyRounded.string(s.perHour)) в час")
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            // В мелких строках прочерк, а не точки: «•••» должно быть жестом
            // («тут спрятана сумма»), и работает он только на крупной цифре.
            Text(model.amountsHidden ? "—" : value).monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: Кнопки

    private var buttons: some View {
        HStack(spacing: 8) {
            Button {
                openSettings()
            } label: {
                Label("Настройки", systemImage: "gearshape")
            }

            // Ссылка «Посмотреть статистику» переехала сюда из середины блока
            // опроса: там она весила целую строку и перетягивала внимание
            // синим цветом с плашек — единственного места в панели, где от
            // человека ждут действия.
            if model.settings.moodEnabled {
                Button {
                    openSettings(.mood)
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                }
                .help("Статистика настроения")
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
            // Скрытие — это режим, а не действие: одной сменой глифа его
            // не заметить. Оранжевый — тот же, которым подсвечена причина
            // в строке состояния.
            .tint(model.amountsHidden ? Color.orange : nil)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Выйти")
            // Отступ от кнопки-глаза: промах во время видеозвонка не должен
            // выключать приложение.
            .padding(.leading, 10)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Открыть окно настроек, при необходимости сразу на нужном разделе.
    /// Без раздела окно остаётся там, где его закрыли.
    private func openSettings(_ section: SettingsSection? = nil) {
        activateApp()
        if let section { model.settingsSection = section }
        openWindow(id: WindowID.settings)
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
