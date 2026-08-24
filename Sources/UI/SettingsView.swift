import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: Int, CaseIterable, Identifiable, Hashable {
    case money, schedule, specialDays, counter, privacy, mood, browser, app

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .money: return "Деньги"
        case .schedule: return "График"
        case .specialDays: return "Особые дни"
        case .counter: return "Счётчик"
        case .privacy: return "Приватность"
        case .mood: return "Настроение"
        case .browser: return "Браузер"
        case .app: return "Приложение"
        }
    }

    var symbol: String {
        switch self {
        case .money: return "banknote"
        case .schedule: return "calendar"
        case .specialDays: return "beach.umbrella"
        case .counter: return "menubar.rectangle"
        case .privacy: return "eye.slash"
        case .mood: return "face.smiling"
        case .browser: return "globe"
        case .app: return "gearshape"
        }
    }
}

/// Разделы, собранные в группы.
///
/// Семь строк подряд читаются как свалка — ровно то, на что жаловался владелец
/// («много всего напихано, непонятно, что где лежит»). Группы разводят то, что
/// настраивают один раз при установке, и то, что трогают время от времени,
/// так что боковой список сам становится картой.
enum SettingsGroup: Int, CaseIterable, Identifiable {
    case calculation, display, rest

    var id: Int { rawValue }

    /// У последней группы заголовка нет намеренно. Прежде их было четыре,
    /// и две последние состояли из одной строки каждая: «Дневник» над одним
    /// «Настроением» и — совсем нелепо — «Программа» над «Приложением», то есть
    /// слово над своим же синонимом. Заголовок, который не отличает одну строку
    /// от другой, ничего не группирует; строки лучше читаются просто стоящими
    /// вместе внизу.
    var title: String? {
        switch self {
        case .calculation: return "Расчёт"
        case .display: return "Показ"
        case .rest: return nil
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .calculation: return [.money, .schedule, .specialDays]
        case .display: return [.counter, .privacy]
        case .rest: return [.mood, .browser, .app]
        }
    }
}

/// Боковой список разделов вместо полосы вкладок.
///
/// На macOS 26 полоса вкладок плавает поверх содержимого и при нехватке ширины
/// схлопывается в меню-шеврон — пятый раздел это и вызвал. Боковой список не
/// переполняется по устройству, растёт вместе с числом разделов и совпадает
/// с тем, как устроены системные Настройки. Побочная польза: он рисуется внутри
/// окна, а значит попадает в оффскрин-рендер и его видно на превью.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    /// Выбранный раздел живёт в модели, а не в `@State` окна: снаружи по нему
    /// прицеливаются («Посмотреть статистику» в панели открывает окно сразу
    /// на «Настроении»), и второго источника истины тут быть не должно —
    /// иначе окно, уже открытое на другом разделе, прыжок пропустит.
    private var section: SettingsSection { model.settingsSection }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $model.settingsSection) {
                ForEach(SettingsGroup.allCases) { group in
                    Section {
                        ForEach(group.sections) { item in
                            Label(item.title, systemImage: item.symbol)
                                .padding(.vertical, 2)
                                .tag(item)
                        }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        }
        .frame(width: 700, height: 520)
        // Интерфейс русский, поэтому время показываем в 24-часовом формате,
        // а даты как 24.08.2026 — независимо от языка системы.
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .onDisappear {
            // Возвращаем приложение в режим «только меню-бар»: иконка в доке
            // нужна была лишь для того, чтобы окно настроек вышло вперёд.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .money: MoneyTab(model: model)
        case .schedule: ScheduleTab(model: model)
        case .specialDays: SpecialDaysTab(model: model)
        case .counter: CounterTab(model: model)
        case .privacy: PrivacyTab(model: model)
        case .mood: MoodStatsView(model: model, log: model.mood, reminders: model.reminders)
        case .browser: BrowserTab(model: model, browsers: model.browsers)
        case .app: AppTab(model: model)
        }
    }
}

// MARK: - Деньги

private struct MoneyTab: View {
    @ObservedObject var model: AppModel

    /// Разделители тысяч как в остальном интерфейсе: 210 000, а не 210,000.
    private var amountFormat: FloatingPointFormatStyle<Double> {
        .number.locale(Locale(identifier: "ru_RU")).precision(.fractionLength(0...2))
    }

    private static let currencies: [(String, String)] = [
        ("RUB", "Рубль ₽"), ("USD", "Доллар $"), ("EUR", "Евро €"),
        ("MYR", "Ринггит RM"), ("AED", "Дирхам"), ("GBP", "Фунт £"),
        ("THB", "Бат ฿")
    ]

    var body: some View {
        Form {
            Section {
                Picker("Считать по", selection: $model.settings.mode) {
                    ForEach(SalaryMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)

                if model.settings.mode == .monthly {
                    TextField("Оклад в месяц", value: $model.settings.monthlyAmount, format: amountFormat)
                        .monospacedDigit()
                } else {
                    TextField("Ставка в час", value: $model.settings.hourlyAmount, format: amountFormat)
                        .monospacedDigit()
                }

                Picker("Валюта", selection: $model.settings.currencyCode) {
                    ForEach(Self.currencies, id: \.0) { Text($0.1).tag($0.0) }
                }

                TextField("Свой символ", text: $model.settings.customCurrencySymbol,
                          prompt: Text("необязательно, например ₽"))
                // Выбор страны переехал в «Особые дни»: он управляет сеткой
                // производственного календаря, а она живёт именно там — держать
                // настройку и её результат в разных разделах значит прятать связь.
            } header: {
                Text("Сколько платят")
            } footer: {
                Text("Указывайте сумму, которую хотите видеть на счётчике: на руки или до налогов — приложение просто делит её на дни и часы.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.settings.mode == .monthly {
                Section {
                    Picker("База дневной ставки", selection: $model.settings.rateBasis) {
                        ForEach(RateBasis.allCases) { Text($0.title).tag($0) }
                    }
                    if model.settings.rateBasis == .fixedDays {
                        Stepper("Дней в месяце: \(model.settings.fixedDaysPerMonth)",
                                value: $model.settings.fixedDaysPerMonth, in: 1...31)
                    }
                } header: {
                    Text("Как делить оклад")
                } footer: {
                    Text(model.settings.rateBasis == .workingDaysInMonth
                         ? "Оклад делится на реальное число рабочих дней конкретного месяца — как в производственном календаре."
                         : "Оклад всегда делится на одно и то же число дней, независимо от месяца.")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Что получается") {
                let s = model.snapshot
                let money = MoneyFormatter(settings: model.settings, decimals: 2)
                LabeledContent("Норма рабочих дней месяца", value: Fmt.days(s.normDays))
                LabeledContent("Дневная ставка", value: money.string(s.dailyRate))
                LabeledContent("В час", value: money.string(s.perHour))
                // «В секунду» отсюда убрано: четыре знака после запятой — цифра
                // для развлечения, а скорость и так видно по «в минуту».
                LabeledContent("В минуту", value: money.string(s.perSecond * 60))
            }
            .monospacedDigit()
        }
        .formStyle(.grouped)
    }
}

// MARK: - График

private struct ScheduleTab: View {
    @ObservedObject var model: AppModel

    private let weekdayOrder: [(Int, String)] = [
        (2, "Пн"), (3, "Вт"), (4, "Ср"), (5, "Чт"), (6, "Пт"), (7, "Сб"), (1, "Вс")
    ]

    var body: some View {
        Form {
            Section("Рабочие дни недели") {
                // Заливку рисуем сами, а не через .tint у .bordered: системная
                // подсветка на macOS 26 перестала отличать выбранное от невыбранного,
                // и по кнопкам было не понять, какие дни рабочие.
                HStack(spacing: 6) {
                    ForEach(weekdayOrder, id: \.0) { day, title in
                        let on = model.settings.workWeekdays.contains(day)
                        Button {
                            if on { model.settings.workWeekdays.remove(day) }
                            else { model.settings.workWeekdays.insert(day) }
                        } label: {
                            Text(title)
                                .font(.system(size: 12, weight: on ? .semibold : .regular))
                                .frame(width: 34, height: 26)
                                .background(on ? Color.accentColor : Color.primary.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(on ? Color.white : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(on ? "\(title) — рабочий, нажмите чтобы сделать выходным"
                                 : "\(title) — выходной, нажмите чтобы сделать рабочим")
                    }
                }
            }

            Section {
                DatePicker("Начало", selection: timeBinding($model.settings.dayStart),
                           displayedComponents: .hourAndMinute)
                DatePicker("Окончание", selection: timeBinding($model.settings.dayEnd),
                           displayedComponents: .hourAndMinute)
                LabeledContent("Длина рабочего дня",
                               value: String(format: "%.1f", model.settings.paidSecondsPerDay / 3600)
                                .replacingOccurrences(of: ".", with: ",") + " ч")
                .monospacedDigit()
            } header: {
                Text("Рабочий день")
            } footer: {
                Text("Счётчик равномерно растёт от начала до окончания дня. Перерыв не задаётся: он каждый день в разное время, а на сумму за день и месяц не влияет — она берётся из оклада и нормы рабочих дней.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Работа в компании") {
                DatePicker("Первый рабочий день",
                           selection: dayBinding($model.settings.employmentStart),
                           displayedComponents: .date)
                Toggle("Есть дата окончания", isOn: $model.settings.hasEmploymentEnd)
                if model.settings.hasEmploymentEnd {
                    DatePicker("Последний рабочий день",
                               selection: dayBinding($model.settings.employmentEnd),
                               displayedComponents: .date)
                }
            }

            // Пояс задаётся один раз и потом не трогается — поэтому внизу,
            // а не над датами, к которым возвращаются.
            Section {
                TimeZonePicker(selection: $model.settings.timeZoneID)
            } header: {
                Text("Часовой пояс")
            } footer: {
                Text("Рабочий день считается по этому поясу, даже если ноутбук уехал в другой. По нему же расставляются напоминания отметить настроение.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Особые дни

private struct SpecialDaysTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.settings.ranges.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "beach.umbrella")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Особых дней пока нет")
                        .foregroundStyle(.secondary)
                    Text("Добавьте отпуск, больничный, праздники или рабочую субботу — счётчик учтёт их в расчёте.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Свои дни идут первыми: их добавляют руками и к ним возвращаются.
                    ForEach($model.settings.ranges) { $range in
                        RangeRow(range: $range, summary: summary(for: range)) {
                            model.settings.ranges.removeAll { $0.id == range.id }
                        }
                    }

                    if !model.settings.ranges.isEmpty {
                        Divider().padding(.vertical, 4)
                    }
                    holidayCalendar
                }
                .padding(12)
            }

            Divider()

            HStack(spacing: 8) {
                Menu {
                    ForEach(DayKind.allCases) { kind in
                        Button {
                            add(kind)
                        } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("Добавить", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Text("При наложении диапазонов побеждает нижний в списке")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    /// Производственный календарь: сетка месяцев вместо списка дат.
    /// Списком полсотни праздников не читаются, а на сетке сразу видно
    /// форму месяца — где каникулы, где перенос, где отпуск.
    @ViewBuilder
    private var holidayCalendar: some View {
        HStack(spacing: 8) {
            Text("Производственный календарь")
                .font(.system(size: 12, weight: .semibold))
            // Выбор страны стоит прямо над сеткой, которой он управляет:
            // раньше он лежал в «Деньгах», и связь была видна только по
            // совпадению слов в двух разных разделах.
            Picker("", selection: $model.settings.country) {
                ForEach(Country.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            if let refreshed = model.holidays.lastRefresh {
                Text("обновлён \(Fmt.shortDate(refreshed))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        CalendarGrid(model: model)

        legend

        let regional = upcomingRegional
        if !regional.isEmpty {
            DisclosureGroup("Региональные праздники · \(Fmt.days(regional.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(regional) { holiday in
                        HStack(spacing: 8) {
                            Text(Fmt.day(holiday.day))
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 78, alignment: .leading)
                            Text(holiday.name).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Button("Добавить") { addHoliday(holiday) }
                                .font(.system(size: 10))
                                .buttonStyle(.borderless)
                        }
                    }
                    Text("Зависят от штата, поэтому сами не применяются — добавьте те, что касаются вас.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("рабочий", .green.opacity(0.16))
            legendItem("выходной", .primary.opacity(0.05))
            legendItem("праздник", .orange.opacity(0.20))
            legendItem("отпуск", .teal.opacity(0.20))
            legendItem("больничный", .blue.opacity(0.18))
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text(title)
        }
    }

    /// Региональные праздники начиная с сегодняшнего дня — прошедшие не нужны.
    private var upcomingRegional: [PublicHoliday] {
        let today = DayStamp(Date(), in: model.settings.calendar)
        return model.holidays.holidays
            .filter { $0.scope == .regional && $0.day >= today }
            .prefix(12)
            .map { $0 }
    }

    private func addHoliday(_ holiday: PublicHoliday) {
        guard !model.settings.ranges.contains(where: {
            $0.kind == .holiday && $0.from == holiday.day && $0.to == holiday.day
        }) else { return }
        model.settings.ranges.append(
            DayRange(from: holiday.day, to: holiday.day, kind: .holiday, note: holiday.name))
    }

    private func add(_ kind: DayKind) {
        let today = DayStamp(Date(), in: model.settings.calendar)
        model.settings.ranges.append(DayRange(from: today, to: today, kind: kind))
    }

    /// «14 дней · 10 рабочих» — сколько дней задето и сколько из них
    /// были бы рабочими по обычному графику недели.
    private func summary(for range: DayRange) -> String {
        let calendar = model.settings.calendar
        let last = max(range.from, range.to)
        var cursor = min(range.from, range.to).startOfDay(in: calendar)
        var total = 0
        var working = 0
        while DayStamp(cursor, in: calendar) <= last, total < 400 {
            total += 1
            if model.settings.workWeekdays.contains(calendar.component(.weekday, from: cursor)) {
                working += 1
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return "\(Fmt.days(total)) · рабочих по графику: \(working)"
    }
}

private struct RangeRow: View {
    @Binding var range: DayRange
    var summary: String
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $range.kind) {
                    ForEach(DayKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .labelsHidden()
                .fixedSize()

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 8) {
                DatePicker("с", selection: dayBinding($range.from), displayedComponents: .date)
                DatePicker("по", selection: dayBinding($range.to), displayedComponents: .date)
            }
            .datePickerStyle(.field)

            TextField("Заметка", text: $range.note, prompt: Text("необязательно"))
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(range.kind.hint)
                Spacer()
                Text(summary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Счётчик

/// Всё, что видно на счётчике и в панели, — и больше ничего.
///
/// Раньше этот раздел назывался «Вид» и собрал в себе четыре несвязанные вещи:
/// счётчик, автозапуск, обновления и пути к файлам. Общего у них было только
/// «больше некуда» — автозапуск в разделе про внешний вид никто не искал.
private struct CounterTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Показывать", selection: $model.settings.menuBarTotal) {
                    ForEach(MenuBarTotal.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)

                Toggle("Показывать сумму и вне рабочего дня", isOn: $model.settings.idleShowsAmount)
                    .help("Вечером и в выходной сумма замирает — по умолчанию она убирается, остаётся одна капля")
                Toggle("Показывать значок капли", isOn: $model.settings.showIcon)
                Toggle("Показывать копейки", isOn: Binding(
                    get: { model.settings.decimals > 0 },
                    set: { model.settings.decimals = $0 ? 2 : 0 }
                ))
                .help("По умолчанию выключены: младшие разряды мельтешат и мешают читать сумму")
            } header: {
                Text("В меню-баре")
            } footer: {
                Text("Выбранное показывается на счётчике и первым, крупным блоком в раскрытой панели. Второй итог остаётся там же компактной строкой — искать его в настройках не придётся.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Приложение

private struct AppTab: View {
    @ObservedObject var model: AppModel

    /// Что показано поверх настроек: подтверждение импорта, итог или отказ.
    ///
    /// Один источник истины вместо трёх независимых `.alert`: два алерта,
    /// висящие на одном представлении, SwiftUI показывает через раз.
    @State private var dialog: BackupDialog?

    var body: some View {
        Form {
            Section {
                Toggle("Запускать при входе в систему", isOn: $model.settings.launchAtLogin)
            } header: {
                Text("Запуск")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Создаёт агент запуска в ~/Library/LaunchAgents и указывает его на текущее расположение программы.")
                    if !LaunchAgent.appIsInstalled {
                        Label("Программа запущена не из папки «Программы», а из \(Bundle.main.bundlePath). Автозапуск сломается, как только эта папка изменится — перенесите Salary Flow в «Программы» и включите тумблер заново.",
                              systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Выше обновлений намеренно: обновления идут сами, а переезд —
            // то, ради чего сюда приходят руками.
            Section {
                LabeledContent("Копия") {
                    HStack {
                        Button("Сохранить копию…") { exportBackup() }
                        Button("Загрузить копию…") { importBackup() }
                    }
                }
            } header: {
                Text("Перенос на другой компьютер")
            } footer: {
                Text("Один файл, в котором лежат все настройки и вся история настроения. Сохраните его перед переездом, поставьте Salary Flow на новой машине и загрузите — счётчик и дневник продолжат с того же места. В папки заходить не придётся. Копия никуда не отправляется и учётной записи не требует: это обычный файл, и он остаётся у вас.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if !model.updater.isAvailable {
                    Text("Проверка обновлений недоступна в этой сборке")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Версия") {
                    Text(model.updater.currentVersion).monospacedDigit()
                }
                Toggle("Проверять обновления автоматически", isOn: Binding(
                    get: { model.updater.checksAutomatically },
                    set: { model.updater.checksAutomatically = $0 }
                ))
                LabeledContent("Обновление") {
                    Button(model.updater.isChecking ? "Проверяю…" : "Проверить сейчас") {
                        model.updater.checkNow()
                    }
                    .disabled(model.updater.isChecking)
                }
            } header: {
                Text("Обновления")
            } footer: {
                Text("Обновления берутся из релизов на GitHub и проверяются подписью: приложение установит только то, что подписано ключом автора. Подпись Apple у сборки самодельная, поэтому при первом запуске скачанной версии система спросит подтверждение.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Файлы") {
                LabeledContent("Настройки") {
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.fileURL])
                    }
                }
                Text(SettingsStore.fileURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                LabeledContent("Журнал") {
                    HStack {
                        Button("Открыть") { NSWorkspace.shared.open(Log.fileURL) }
                        Button("Показать в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                        }
                    }
                }
                Text(Log.fileURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .alert(dialog?.title ?? "", isPresented: Binding(
            get: { dialog != nil },
            set: { if !$0 { dialog = nil } }
        ), presenting: dialog) { dialog in
            buttons(for: dialog)
        } message: { dialog in
            Text(message(for: dialog))
        }
    }

    // MARK: Копия

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.title = "Сохранить копию"
        panel.nameFieldStringValue = Backup.suggestedFileName()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.writeBackup(to: url)
        } catch {
            dialog = .failed(title: "Копия не сохранилась",
                             text: "Не удалось записать файл: \(error.localizedDescription)")
        }
    }

    /// Загрузка идёт в два шага: сначала показываем, что внутри, и только
    /// потом ввозим. Данные, которые копятся месяцами, не должны затираться
    /// одним нажатием на файл, выбранный наугад.
    private func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "Загрузить копию"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            dialog = .confirm(try Backup.decode(try Data(contentsOf: url)))
        } catch let error as BackupError {
            dialog = .failed(title: "Копия не загрузилась", text: error.message)
        } catch {
            dialog = .failed(title: "Копия не загрузилась",
                             text: "Файл не читается: \(error.localizedDescription)")
        }
    }

    private func apply(_ file: BackupFile, _ mode: Backup.Mode) {
        let result = model.importBackup(file, mode: mode)
        // Второй алерт заводится не сразу: пока первый закрывается, SwiftUI
        // сбросит `dialog` в nil своей же рукой и заодно съест новое значение.
        DispatchQueue.main.async { dialog = .done(result) }
    }

    @ViewBuilder
    private func buttons(for dialog: BackupDialog) -> some View {
        switch dialog {
        case .confirm(let file):
            Button("Заменить") { apply(file, .replace) }
            // Объединять есть что только когда истории две.
            if !model.mood.entries.isEmpty, (file.mood?.entries.isEmpty == false) {
                Button("Добавить отметки") { apply(file, .mergeMarks) }
            }
            Button("Отмена", role: .cancel) {}
        case .done(let result):
            if case .written(let copy) = result.safetyCopy {
                Button("Показать прежнее") {
                    NSWorkspace.shared.activateFileViewerSelecting([copy])
                }
            }
            Button("Хорошо", role: .cancel) {}
        case .failed:
            Button("Понятно", role: .cancel) {}
        }
    }

    private func message(for dialog: BackupDialog) -> String {
        switch dialog {
        case .confirm(let file):
            var text = file.summary.text + "\n\n"
            text += "«Заменить» — нынешние настройки и история уступят место копии. "
            text += "Прежнее состояние сложим отдельным файлом рядом с настройками, "
            text += "так что вернуться будет чем."
            if !model.mood.entries.isEmpty, file.mood?.entries.isEmpty == false {
                text += "\n«Добавить отметки» — настройки всё равно заменятся, "
                text += "а две истории настроения сложатся в одну без повторов."
            }
            return text

        case .done(let result):
            var lines: [String] = []
            if result.settingsReplaced { lines.append("Настройки заменены.") }
            switch result.mode {
            case .replace:
                lines.append("Отметок было \(result.marksBefore), стало \(result.marksAfter).")
            case .mergeMarks:
                lines.append(result.added > 0
                    ? "Добавилось \(Fmt.marks(result.added)), всего стало \(result.marksAfter)."
                    : "Новых отметок в копии не нашлось — всё это уже было.")
            }
            switch result.safetyCopy {
            case .written(let copy):
                lines.append("Прежнее состояние лежит в файле \(copy.lastPathComponent) рядом с настройками.")
            case .notNeeded:
                break
            case .failed:
                lines.append("Прежнее состояние сохранить не удалось — подробности в журнале.")
            }
            return lines.joined(separator: "\n")

        case .failed(_, let text):
            return text
        }
    }
}

/// Окно поверх настроек: подтверждение, итог или отказ.
private enum BackupDialog {
    case confirm(BackupFile)
    case done(Backup.Result)
    case failed(title: String, text: String)

    var title: String {
        switch self {
        case .confirm: return "Загрузить копию?"
        case .done: return "Копия загружена"
        case .failed(let title, _): return title
        }
    }
}

// MARK: - Приватность

private struct PrivacyTab: View {
    @ObservedObject var model: AppModel
    @State private var newProcess = ""

    var body: some View {
        Form {
            Section {
                Toggle("Скрыть суммы прямо сейчас", isOn: $model.settings.hideAmount)
                LabeledContent("Сейчас") {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(model.amountsHidden ? Color.orange : Color.green)
                                .frame(width: 7, height: 7)
                            Text(model.privacyReason?.title ?? "Ничего не обнаружено, суммы видны")
                                .foregroundStyle(.secondary)
                        }
                        // Zoom в звонке — самый частый вопрос «почему спрятано»
                        // и «почему не спрятано». Пусть на него отвечает
                        // сама настройка, а не журнал.
                        if !model.quietPrivacyCandidates.isEmpty {
                            Text("\(model.quietPrivacyCandidates.joined(separator: ", ")) работает, но окна демонстрации нет")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Toggle("Когда включена камера", isOn: $model.settings.privacyOnCamera)
                Toggle("Когда идёт захват экрана", isOn: $model.settings.privacyOnCapture)
                Picker("Что делать", selection: $model.settings.privacyAction) {
                    ForEach(PrivacyAction.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Прятать автоматически")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Камера — самый широкий признак: она включается на любом видеозвонке, в Zoom, Meet, Teams, Telegram. Захват экрана ищется по процессам, но одного их присутствия мало: Zoom поднимает своего помощника при входе в конференцию и держит до конца. Поэтому у таких процессов ждут ещё и окно демонстрации — рамку вокруг показываемого экрана.")
                    Text("Спрятать окно от самого захвата macOS не позволяет: свойство sharingType с версии 15.4 игнорируется, публичной замены нет. Поэтому приложение убирает цифры само, заметив звонок или запись.")
                    if model.settings.privacyAction == .hide {
                        Label("Значок пропадёт из меню-бара целиком и вернётся, когда звонок закончится. Вручную скрытые суммы значок не убирают — иначе до настроек было бы не добраться.",
                              systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Список процессов нужен единицам, а место занимал у всех: сносок
            // в нём было больше, чем органов управления, и раздел читался как
            // инструкция, а не как настройки. Тексты хорошие — не выброшены,
            // а спрятаны на один клик.
            Section {
                DisclosureGroup("Процессы, означающие захват экрана") {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("По рамке демонстрации") {
                                Text(suspects(.sharingFrame)).textSelection(.enabled)
                            }
                            LabeledContent("По одному запуску") {
                                Text(suspects(.presence)).textSelection(.enabled)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        ForEach(Array(model.settings.privacyExtraProcesses.enumerated()), id: \.offset) { index, name in
                            HStack {
                                Text(name).monospaced()
                                Spacer()
                                Button(role: .destructive) {
                                    model.settings.privacyExtraProcesses.remove(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        HStack {
                            TextField("Своё имя процесса", text: $newProcess, prompt: Text("например, Webex"))
                                .onSubmit(addProcess)
                            Button("Добавить", action: addProcess)
                                .disabled(newProcess.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Совпадение по части имени, регистр не важен. Имя работающего процесса видно в Мониторинге системы. Свои процессы считаются по одному запуску — добавляйте те, что появляются именно на время показа.")
                            Text("Не добавляйте сюда программы удалённого доступа целиком (AnyDesk, TeamViewer, RuDesktop): их агенты работают в фоне постоянно, а не только во время сеанса. Процессы, уже работавшие в момент запуска Salary Flow, игнорируются — демонстрация экрана всегда начинается позже.")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Встроенные подозреваемые одним признаком — строкой для показа.
    private func suspects(_ evidence: CaptureEvidence) -> String {
        AppSettings.defaultCaptureSuspects
            .filter { $0.evidence == evidence }
            .map(\.needle)
            .joined(separator: ", ")
    }

    private func addProcess() {
        let trimmed = newProcess.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.settings.privacyExtraProcesses.append(trimmed)
        newProcess = ""
    }
}

// MARK: - Часовой пояс

private struct TimeZonePicker: View {
    @Binding var selection: String

    private var groups: [(String, [String])] {
        let ids = TimeZone.knownTimeZoneIdentifiers.sorted()
        let dict = Dictionary(grouping: ids) { $0.split(separator: "/").first.map(String.init) ?? "Прочее" }
        return dict.keys.sorted().map { ($0, dict[$0] ?? []) }
    }

    var body: some View {
        LabeledContent("Пояс") {
            HStack {
                Menu(selection) {
                    Button("Как в системе (\(TimeZone.current.identifier))") {
                        selection = TimeZone.current.identifier
                    }
                    Divider()
                    ForEach(groups, id: \.0) { region, ids in
                        Menu(region) {
                            ForEach(ids, id: \.self) { id in
                                Button(id.replacingOccurrences(of: "\(region)/", with: "")) { selection = id }
                            }
                        }
                    }
                }
                Text(offsetHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var offsetHint: String {
        guard let tz = TimeZone(identifier: selection) else { return "" }
        let hours = Double(tz.secondsFromGMT()) / 3600
        return String(format: "UTC%+.4g", hours)
    }
}

// MARK: - Мосты между моделью и DatePicker

/// DatePicker умеет только Date, а модель хранит дату и время суток отдельно.
/// Оба преобразования идут через системный календарь и потому обратимы.
func dayBinding(_ source: Binding<DayStamp>) -> Binding<Date> {
    Binding(
        get: { source.wrappedValue.startOfDay(in: Calendar(identifier: .gregorian)) },
        set: { newValue in
            source.wrappedValue = DayStamp(newValue, in: Calendar(identifier: .gregorian))
        }
    )
}

func timeBinding(_ source: Binding<TimeOfDay>) -> Binding<Date> {
    Binding(
        get: {
            var c = DateComponents()
            c.year = 2000; c.month = 1; c.day = 1
            c.hour = source.wrappedValue.hour
            c.minute = source.wrappedValue.minute
            return Calendar(identifier: .gregorian).date(from: c) ?? Date()
        },
        set: { newValue in
            let c = Calendar(identifier: .gregorian).dateComponents([.hour, .minute], from: newValue)
            source.wrappedValue = TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
        }
    )
}
