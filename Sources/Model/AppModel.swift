import AppKit
import Combine
import SwiftUI

/// Держит настройки, тикающие часы и текущий срез.
/// Срез пересчитывается целиком на каждый тик — поэтому полночь, смена месяца,
/// перевод часов и правка настроек не требуют отдельной обработки.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            store.settings = settings
            // launchctl дёргаем только на реальном переключении, а не на каждое
            // нажатие клавиши в поле оклада.
            if settings.launchAtLogin != oldValue.launchAtLogin {
                LaunchAgent.setEnabled(settings.launchAtLogin)
            }
            privacy.settings = settings
            if settings.country != oldValue.country {
                holidays.setCountry(settings.country)
            }
            // Разрешение спрашиваем в момент включения тумблера, а не при
            // запуске: системный вопрос понятен только тогда, когда человек
            // сам только что попросил напоминать.
            if remindersWanted, !oldValue.moodEnabled || !oldValue.moodRemindersEnabled {
                reminders.requestAccessIfNeeded()
            }
            refresh()
        }
    }

    /// Панель открыта — тикаем чаще, чтобы цифры шли плавно.
    var panelIsOpen = false { didSet { rescheduleTimer() } }

    /// Что нашёл монитор приватности: камера, захват экрана или ничего.
    @Published private(set) var detectedPrivacy: PrivacyReason?
    /// «Показать всё равно» — временно, до конца звонка.
    @Published var temporaryReveal = false

    private let privacy = PrivacyMonitor()

    /// Обновления через Sparkle — держим здесь, чтобы жил столько же, сколько приложение.
    let updater = Updater()

    /// Производственный календарь выбранной страны.
    let holidays: HolidayStore

    /// Журнал отметок настроения. Живёт столько же, сколько приложение:
    /// его читают и панель, и раздел статистики.
    let mood = MoodLog()

    /// Напоминания отметить настроение. Расписание считает модель — только она
    /// знает, какие дни рабочие и где границы смены.
    let reminders = MoodReminder()

    /// Раздел, открытый в окне настроек. Держится здесь, а не в самом окне,
    /// потому что открывают его снаружи: кнопка «Посмотреть статистику»
    /// в панели должна попасть сразу в нужный раздел, в том числе когда окно
    /// уже открыто на другом.
    @Published var settingsSection: SettingsSection = .money

    /// Итоговая причина, по которой цифры спрятаны.
    var privacyReason: PrivacyReason? {
        if settings.hideAmount { return .manual }
        return temporaryReveal ? nil : detectedPrivacy
    }

    var amountsHidden: Bool { privacyReason != nil }

    /// Ручной режим никогда не убирает значок целиком: иначе до настроек
    /// уже не добраться. Полное исчезновение — только по автоматике,
    /// и она возвращает значок сама.
    var menuBarItemVisible: Bool {
        guard let reason = privacyReason, reason != .manual else { return true }
        return settings.privacyAction == .mask
    }

    /// Замороженное время для предпросмотра и отладки.
    private var frozenNow: Date?

    private let store = SettingsStore()
    private var engine: Engine
    private var timer: Timer?
    private var currentInterval: TimeInterval = 0

    init() {
        let loaded = store.settings
        settings = loaded
        holidays = HolidayStore(country: loaded.country)
        engine = Engine(settings: loaded, publicHolidays: holidays.nationalDays,
                        officialDaysOff: holidays.officialDaysOff,
                        officialWorkdays: holidays.officialWorkdays)
        snapshot = engine.snapshot()

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Log.info("пробуждение из сна — пересчёт")
            Task { @MainActor in self?.refresh() }
        }

        // Разрешение на уведомления живёт не у нас: его выдают и отзывают
        // руками в системных настройках, пока приложение работает. Активация —
        // тот самый момент возвращения оттуда, и без этой строки предупреждение
        // о запрете висело бы до перезапуска.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reminders.refreshAccess() }
        }

        privacy.settings = loaded
        privacy.onChange = { [weak self] reason in
            guard let self else { return }
            self.detectedPrivacy = reason
            Log.info(reason.map { "приватный режим включён: \($0.title)" } ?? "приватный режим снят")
            // Звонок кончился — временное «показать всё равно» тоже сбрасываем.
            if reason == nil { self.temporaryReveal = false }
        }
        detectedPrivacy = privacy.reason

        // Приложение могли перенести или удалить агент запуска руками —
        // приводим систему в соответствие с настройкой.
        if loaded.launchAtLogin != LaunchAgent.isEnabled {
            LaunchAgent.setEnabled(loaded.launchAtLogin)
        }
        // Календарь мог устареть: даты мусульманских праздников уточняют,
        // а переносы выходных в России выходят постановлением на каждый год.
        holidays.refreshIfStale()
        holidayUpdates = holidays.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        reminders.onOpenPanel = { [weak self] in self?.openPanel() }
        reminders.onMark = { [weak self] kind in self?.toggleMood(kind) }
        if remindersWanted { reminders.requestAccessIfNeeded() }

        // Проверка уведомлений из терминала: доставку иначе не проверить ничем,
        // кроме нажатия кнопки руками, — а уведомления держит система, и её
        // ответ не подделывается ни тестом, ни оффскрин-рендером. Итог уходит
        // в журнал тем же путём, что и при нажатии кнопки.
        //   SALARYFLOW_TEST_NOTIFICATION=1 /Applications/SalaryFlow.app/Contents/MacOS/SalaryFlow
        if ProcessInfo.processInfo.environment["SALARYFLOW_TEST_NOTIFICATION"] == "1" {
            reminders.sendTest()
        }

        refresh()
    }

    private var holidayUpdates: AnyCancellable?

    // MARK: Отметки настроения

    /// Отметки, которые панель подсвечивает: только те, что ещё можно снять.
    /// Через несколько минут подсветка гаснет — и то же состояние можно
    /// отметить снова, а не только снять.
    func currentMoodMarks() -> [MoodKind] {
        mood.marksOpenForUndo(now: frozenNow ?? Date()).map(\.kind)
    }

    /// Момент последней сегодняшней отметки — панель показывает его
    /// как «отмечено в 14:32».
    func lastMoodMark() -> Date? {
        let now = frozenNow ?? Date()
        return mood.lastMark(on: DayStamp(now, in: settings.calendar), notAfter: now)?.at
    }

    /// Нажатие на плашку в панели.
    ///
    /// Пока не вышло окно захода, нажатие правит уже сделанную отметку, а не
    /// заводит новую: иначе каждое «ой, не то» оставалось бы в истории навсегда
    /// и портило статистику. Само решение — в `MoodTap`, чтобы правило было
    /// одно и проверялось тестами.
    func toggleMood(_ kind: MoodKind) {
        let now = frozenNow ?? Date()

        switch MoodTap.decide(kind: kind, open: mood.marksOpenForUndo(now: now)) {
        case .remove(let id):
            mood.remove(id: id)
            return
        case .add:
            break
        }

        let calendar = settings.calendar
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        // Что именно отметили, в журнал не пишем: журнал дублируется в системный
        // лог и попадает в отчёты диагностики, а это самое личное, что здесь есть.
        Log.info("отметка настроения записана")
        mood.append(MoodEntry(
            at: now,
            kind: kind,
            day: DayStamp(now, in: calendar),
            minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0),
            weekday: parts.weekday ?? 1,
            phase: MoodPhase(snapshot.state),
            shiftFraction: snapshot.state == .working ? snapshot.dayProgress : nil
        ))
        // Человек только что ответил — ближайшее напоминание становится лишним.
        rescheduleReminders()
    }

    // MARK: Напоминания

    /// Напоминания имеют смысл только вместе с опросом: спрашивать про то,
    /// чего в панели нет, было бы издевательством.
    var remindersWanted: Bool { settings.moodEnabled && settings.moodRemindersEnabled }

    /// Ближайшие напоминания. Публичные и наблюдаемые, потому что их показывают
    /// и в настройках, и в панели: приложение само выбрало время, и это не
    /// должно быть тайной — иначе первое же уведомление станет неожиданностью.
    @Published private(set) var plannedReminders: [Date] = []

    /// День, на который считался последний план.
    private var remindersPlannedFor: DayStamp?

    /// Ближайшее напоминание.
    var nextReminder: Date? {
        let now = frozenNow ?? Date()
        return plannedReminders.first { $0 > now }
    }

    /// Напоминания сегодняшнего дня, которые ещё впереди.
    func remindersLeftToday() -> [Date] {
        let now = frozenNow ?? Date()
        let today = DayStamp(now, in: settings.calendar)
        return plannedReminders.filter { $0 > now && DayStamp($0, in: settings.calendar) == today }
    }

    /// Пересчитать расписание и отдать его системе, если оно изменилось.
    ///
    /// Сравнение с прошлым планом — не микрооптимизация: `refresh()` зовётся
    /// на каждое нажатие клавиши в поле оклада, а перекладывать из-за этого
    /// два десятка системных сроков незачем.
    func rescheduleReminders() {
        let now = frozenNow ?? Date()
        remindersPlannedFor = DayStamp(now, in: settings.calendar)

        var plan: [Date] = []
        if remindersWanted {
            plan = MoodReminderRules.plan(
                now: now,
                calendar: settings.calendar,
                shift: { day in
                    guard self.isExpectedWorkday(day) else { return nil }
                    return self.engine.shift(for: day)
                },
                marks: mood.entries.map(\.at)
            )
        }

        guard plan != plannedReminders else { return }
        plannedReminders = plan
        reminders.schedule(plan, calendar: settings.calendar)
    }

    /// Раскрыть панель — по нажатию на напоминание.
    private func openPanel() {
        guard !panelIsOpen else { return }
        if !MenuBarPanel.open() {
            // Пункт меню-бара мог быть спрятан приватным режимом: идёт звонок,
            // и раскрывать панель с суммами поверх демонстрации экрана — ровно
            // то, от чего этот режим и защищает.
            Log.warn("напоминание: панель раскрыть не удалось — пункт меню-бара недоступен")
        }
    }

    /// Как выглядит конкретный день по текущим настройкам и календарю.
    /// Календарю нужен тот же расчёт, что и счётчику, — чтобы сетка
    /// не разошлась с деньгами.
    func engineSnapshotState(for day: DayStamp) -> DayState {
        engine.state(of: day, now: frozenNow ?? Date())
    }

    /// Должен ли человек был работать в этот день. Статистике настроения нужно
    /// именно это: отпуск и праздник в знаменатель «в каких днях есть отметки»
    /// не идут — в них никто ничего отмечать и не обязан.
    func isExpectedWorkday(_ day: DayStamp) -> Bool {
        engine.state(of: day, now: day.startOfDay(in: settings.calendar)).isWorkday
    }

    /// Остановить время на заданном моменте — используется рендером превью.
    func overrideNow(_ date: Date?) {
        frozenNow = date
        timer?.invalidate()
        timer = nil
        currentInterval = 0
        engine = Engine(settings: settings, publicHolidays: holidays.nationalDays,
                        officialDaysOff: holidays.officialDaysOff,
                        officialWorkdays: holidays.officialWorkdays)
        snapshot = engine.snapshot(now: date ?? Date())
        if date == nil { rescheduleTimer() }
    }

    func refresh() {
        engine = Engine(settings: settings, publicHolidays: holidays.nationalDays,
                        officialDaysOff: holidays.officialDaysOff,
                        officialWorkdays: holidays.officialWorkdays)
        snapshot = engine.snapshot(now: frozenNow ?? Date())
        if frozenNow == nil {
            rescheduleTimer()
            // График работы, отпуска и производственный календарь задают время
            // напоминаний — любая правка расчёта их двигает.
            rescheduleReminders()
        }
    }

    /// Во время смены — раз в секунду, иначе раз в полминуты:
    /// в 8 вечера деньги не капают, будить процесс каждую секунду незачем.
    private func desiredInterval() -> TimeInterval {
        if panelIsOpen { return 1 }
        if snapshot.state == .working { return settings.decimals > 0 ? 1 : 5 }
        return 30
    }

    private func rescheduleTimer() {
        guard frozenNow == nil else { return }
        let interval = desiredInterval()
        guard interval != currentInterval || timer == nil else { return }
        currentInterval = interval
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        snapshot = engine.snapshot()
        // Наступили новые сутки — горизонт напоминаний сдвигается на день вперёд.
        if remindersPlannedFor != DayStamp(snapshot.now, in: settings.calendar) {
            rescheduleReminders()
        }
        if desiredInterval() != currentInterval { rescheduleTimer() }
    }
}

enum WindowID {
    static let settings = "settings"
}

/// Открыть окно настроек так, чтобы оно вышло на передний план:
/// у приложения без иконки в доке этого не происходит само собой.
func activateApp() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
}
