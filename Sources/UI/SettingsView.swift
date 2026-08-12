import AppKit
import SwiftUI

enum SettingsSection: Int, CaseIterable, Identifiable, Hashable {
    case money, schedule, specialDays, appearance, privacy

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .money: return "Деньги"
        case .schedule: return "График"
        case .specialDays: return "Особые дни"
        case .appearance: return "Вид"
        case .privacy: return "Приватность"
        }
    }

    var symbol: String {
        switch self {
        case .money: return "banknote"
        case .schedule: return "calendar"
        case .specialDays: return "beach.umbrella"
        case .appearance: return "slider.horizontal.3"
        case .privacy: return "eye.slash"
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
    @State private var section: SettingsSection

    init(model: AppModel, initialSection: SettingsSection = .money) {
        self.model = model
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $section) {
                ForEach(SettingsSection.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .padding(.vertical, 2)
                        .tag(item)
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
        case .appearance: AppearanceTab(model: model)
        case .privacy: PrivacyTab(model: model)
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
                LabeledContent("Дневная ставка", value: money.string(s.dailyRate))
                LabeledContent("В час", value: money.string(s.perHour))
                LabeledContent("В минуту", value: money.string(s.perSecond * 60))
                LabeledContent("В секунду", value: MoneyFormatter(settings: model.settings, decimals: 4).string(s.perSecond))
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
                HStack(spacing: 6) {
                    ForEach(weekdayOrder, id: \.0) { day, title in
                        let on = model.settings.workWeekdays.contains(day)
                        Button(title) {
                            if on { model.settings.workWeekdays.remove(day) }
                            else { model.settings.workWeekdays.insert(day) }
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .secondary)
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
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

            Section {
                TimeZonePicker(selection: $model.settings.timeZoneID)
            } header: {
                Text("Часовой пояс")
            } footer: {
                Text("Рабочий день считается по этому поясу, даже если ноутбук уехал в другой.")
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
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($model.settings.ranges) { $range in
                            RangeRow(range: $range, summary: summary(for: range)) {
                                model.settings.ranges.removeAll { $0.id == range.id }
                            }
                        }
                    }
                    .padding(12)
                }
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

// MARK: - Вид

private struct AppearanceTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("В меню-баре") {
                Toggle("Показывать значок капли", isOn: $model.settings.showIcon)
                Picker("Копейки", selection: $model.settings.decimals) {
                    Text("Не показывать").tag(0)
                    Text("Показывать").tag(2)
                }
                .help("По умолчанию выключены: младшие разряды мельтешат и мешают читать сумму")
                Picker("Вне рабочего дня показывать", selection: $model.settings.idleDisplay) {
                    ForEach(IdleDisplay.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Toggle("Запускать при входе в систему", isOn: $model.settings.launchAtLogin)
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
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.amountsHidden ? Color.orange : Color.green)
                            .frame(width: 7, height: 7)
                        Text(model.privacyReason?.title ?? "Ничего не обнаружено, суммы видны")
                            .foregroundStyle(.secondary)
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
                    Text("Камера — самый широкий признак: она включается на любом видеозвонке, в Zoom, Meet, Teams, Telegram. Захват экрана определяется по процессам — их список ниже.")
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

            Section {
                Text(AppSettings.defaultCaptureProcesses.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

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
            } header: {
                Text("Процессы, означающие захват экрана")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Совпадение по части имени, регистр не важен. Имя работающего процесса видно в Мониторинге системы.")
                    Text("Не добавляйте сюда программы удалённого доступа целиком (AnyDesk, TeamViewer, RuDesktop): их агенты работают в фоне постоянно, а не только во время сеанса. Процессы, уже работавшие в момент запуска Salary Flow, игнорируются — демонстрация экрана всегда начинается позже.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
