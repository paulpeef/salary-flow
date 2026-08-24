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
            // Разрешение спрашиваем в момент, когда человек сам попросил
            // напоминать уведомлением, а не при запуске: системный вопрос
            // понятен только сразу после такой просьбы. Смена способа
            // на «уведомлением» — такая же просьба, как и включение тумблера.
            let wasByNotification = oldValue.moodEnabled && oldValue.moodRemindersEnabled
                && oldValue.moodReminderStyle == .notification
            if remindByNotification, !wasByNotification {
                reminders.requestAccessIfNeeded()
            }
            // Блок включили только что: список браузеров нужен раньше,
            // чем панель откроется, — иначе в ней на секунду пусто.
            if settings.browserPickerEnabled, !oldValue.browserPickerEnabled {
                browsers.refresh()
            }
            refresh()
        }
    }

    /// Панель открыта — тикаем чаще, чтобы цифры шли плавно.
    var panelIsOpen = false {
        didSet {
            rescheduleTimer()
            // Браузер по умолчанию меняют и мимо приложения — в системных
            // настройках или самим браузером при запуске. Спрашиваем систему
            // в момент раскрытия, а не показываем ответ недельной давности.
            if panelIsOpen, settings.browserPickerEnabled { browsers.refresh() }
        }
    }

    /// Что нашёл монитор приватности: камера, захват экрана или ничего.
    @Published private(set) var detectedPrivacy: PrivacyReason?
    /// Кандидаты на захват экрана, которые работают, но экран не показывают.
    @Published private(set) var quietPrivacyCandidates: [String] = []
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

    /// Кто открывает ссылки и переключение этого из панели.
    let browsers = BrowserSwitcher()

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

    /// Подставить кандидатов для оффскрин-рендера: живой Zoom в превью
    /// не поднимешь, а увидеть строку надо. Работает только там, где нет
    /// бандла, — в самом приложении вызов ничего не делает.
    func overridePrivacyCandidatesForPreview(_ names: [String]) {
        guard Bundle.main.bundleIdentifier == nil else { return }
        quietPrivacyCandidates = names
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
            Task { @MainActor in
                self?.reminders.refreshAccess()
                // Тот же случай, что и с разрешением: браузер по умолчанию
                // могли сменить в системных настройках, пока нас не было.
                guard let self, self.settings.browserPickerEnabled else { return }
                self.browsers.refresh()
            }
        }

        privacy.settings = loaded
        privacy.onChange = { [weak self] reason in
            guard let self else { return }
            self.detectedPrivacy = reason
            Log.info(reason.map { "приватный режим включён: \($0.title)" } ?? "приватный режим снят")
            // Звонок кончился — временное «показать всё равно» тоже сбрасываем.
            if reason == nil { self.temporaryReveal = false }
        }
        privacy.onQuietChange = { [weak self] names in
            self?.quietPrivacyCandidates = names
        }
        detectedPrivacy = privacy.reason
        quietPrivacyCandidates = privacy.quietCandidates
        // Первый опрос проходит до того, как повешен обработчик смены, — иначе
        // приложение, запущенное посреди демонстрации экрана, прячет суммы
        // молча, и в журнале об этом нет ни строки.
        if let reason = detectedPrivacy {
            Log.info("приватный режим включён уже при запуске: \(reason.title)")
        }

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

        if loaded.browserPickerEnabled { browsers.refresh() }

        reminders.onOpenPanel = { [weak self] in self?.openPanel() }
        reminders.onMark = { [weak self] kind in self?.toggleMood(kind) }
        if remindByNotification { reminders.requestAccessIfNeeded() }

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

    /// Напоминать уведомлением. Иначе приложение раскрывает панель само,
    /// и системе уведомлений в этом деле нечего делать вовсе: ни разрешения,
    /// ни сроков у неё не остаётся.
    var remindByNotification: Bool {
        remindersWanted && settings.moodReminderStyle == .notification
    }

    /// Сроки, в последний раз отданные системе уведомлений. `nil` — за этот
    /// сеанс не отдавали ещё ничего.
    private var scheduledMoments: [Date]?

    /// Ближайший срок, которого ждёт режим «раскрывать панель».
    ///
    /// Держится отдельно от плана, потому что план хранит только будущее:
    /// наступивший срок из него исчезает, и по нему уже не понять, что момент
    /// пришёл. Живёт в памяти — при перезапуске потеряется, но опоздание всё
    /// равно ограничено пятью минутами.
    private var pendingPanelReminder: Date?

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

        if plan != plannedReminders {
            plannedReminders = plan
            // Будущий срок пропал из плана — например, человек только что
            // отметился, и ближайшее напоминание стало лишним. Ждать его
            // больше незачем. Наступившие сроки при этом не трогаем: их
            // в плане нет никогда, и отменёнными их считать нельзя.
            if let pending = pendingPanelReminder, pending > now, !plan.contains(pending) {
                pendingPanelReminder = nil
            }
        }

        // В режиме «раскрывать панель» системе сроков не отдаём вовсе: иначе
        // к раскрытой панели прилетал бы ещё и баннер про то же самое.
        //
        // Сравниваем с тем, что отдано системе, а не с планом. Способ
        // напоминания меняется при неизменном плане — и на сравнении планов
        // переключение на панель оставило бы уже поставленные сроки в силе:
        // человек просил не присылать пуши, а они продолжали бы приходить.
        // Первый раз за сеанс отдаём всегда: сроки могли остаться от прошлого.
        let forSystem = remindByNotification ? plan : []
        guard forSystem != scheduledMoments else { return }
        scheduledMoments = forSystem
        reminders.schedule(forSystem, calendar: settings.calendar)
    }

    /// Ход времени в режиме «раскрывать панель»: зовётся с каждым тиком.
    ///
    /// Отдельного таймера нет намеренно — модель и так тикает раз в секунду-две
    /// внутри смены, а напоминания стоят как раз внутри неё. Второй таймер
    /// пришлось бы отдельно заводить, гасить и переставлять при каждой правке
    /// настроек, и он был бы ещё одним местом, где расписание может разойтись
    /// с планом.
    private func advancePanelReminder() {
        guard remindersWanted, settings.moodReminderStyle == .panel else {
            pendingPanelReminder = nil
            return
        }
        let now = frozenNow ?? Date()

        switch PanelReminderRules.verdict(now: now, due: pendingPanelReminder) {
        case .wait:
            break
        case .open:
            pendingPanelReminder = nil
            if amountsHidden {
                // Идёт звонок или запись экрана. Панель, выскочившая посреди
                // демонстрации, — ровно то, от чего защищает приватный режим,
                // и «хочу уволиться» на общем экране дороже пропущенного
                // напоминания.
                Log.info("напоминание: суммы скрыты — панель не раскрываю")
            } else {
                Log.info("напоминание: время подошло — раскрываю панель")
                openPanel()
            }
        case .skip:
            // Компьютер спал, или человек был в другом приложении во весь
            // экран. Догонять поздно: вопрос про «сейчас», а «сейчас» уже другое.
            Log.info("напоминание: срок пропущен, панель не раскрываю")
            pendingPanelReminder = nil
        }

        if pendingPanelReminder == nil {
            pendingPanelReminder = PanelReminderRules.next(after: now, in: plannedReminders)
        }
    }

    /// Раскрыть панель — по нажатию на напоминание или вместо него.
    ///
    /// Нажатие может прийти не с баннера, а из Центра уведомлений — из списка,
    /// куда напоминание легло, пока человека не было. Тогда в момент вызова
    /// Центр ещё на экране и держит фокус: панель раскрывается под ним и
    /// схлопывается вместе с его закрытием, а со стороны это выглядит как
    /// «нажал, и ничего не произошло» (замечено владельцем 2026-08-17:
    /// с баннера панель раскрывалась, из списка — нет). Поэтому ждём, пока
    /// Центр уедет, и проверяем результат, а не надеемся на него.
    private func openPanel() {
        guard !MenuBarPanel.isOpen else {
            Log.info("напоминание: панель уже открыта")
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard MenuBarPanel.open() else {
                // Пункт меню-бара мог быть спрятан приватным режимом: идёт
                // звонок, и раскрывать панель с суммами поверх демонстрации
                // экрана — ровно то, от чего этот режим и защищает.
                Log.warn("напоминание: панель раскрыть не удалось — пункт меню-бара недоступен")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))

            if !MenuBarPanel.isOpen {
                // Центр уведомлений мог закрываться дольше обычного. Второе
                // нажатие безопасно ровно потому, что мы спросили AppKit,
                // а не модель: по уже открытой панели оно бы её закрыло.
                Log.info("напоминание: панель не раскрылась с первого раза, повторяю")
                MenuBarPanel.open()
                try? await Task.sleep(for: .milliseconds(500))
            }
            Log.info(MenuBarPanel.isOpen
                     ? "напоминание: панель раскрыта"
                     : "напоминание: панель раскрыть не удалось, нажатие прошло впустую")
        }
    }

    // MARK: Копия для переезда

    /// Всё состояние одним файлом: настройки и история отметок.
    func backupData(at date: Date = Date()) throws -> Data {
        let file = Backup.make(settings: settings,
                               entries: mood.entries,
                               appVersion: updater.currentVersion,
                               machine: Host.current().localizedName,
                               at: date)
        return try Backup.encode(file)
    }

    func writeBackup(to url: URL) throws {
        try backupData().write(to: url, options: .atomic)
        // Куда именно человек её сохранил — его дело, в журнал идёт только имя.
        Log.info("копия сохранена в \(url.lastPathComponent): отметок \(mood.entries.count)")
    }

    /// Прежнее состояние, сложенное рядом с настройками перед импортом.
    ///
    /// Промах кнопкой не должен быть необратимым: у человека может не быть
    /// копии того, что он сейчас затрёт, — а после этого шага она есть всегда
    /// и ввозится обратно тем же импортом.
    private func writeSafetyCopy(at date: Date = Date()) -> Backup.SafetyCopy {
        // Главный случай этой кнопки — свежая установка на новой машине.
        // Там терять нечего, и файл «до импорта» с пустотой внутри был бы
        // ровно тем мусором в папке, от которого вся затея и избавляет.
        guard !mood.entries.isEmpty || settings != AppSettings() else {
            Log.info("страховка перед импортом не понадобилась: настройки нетронуты, отметок нет")
            return .notNeeded
        }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let url = SettingsStore.fileURL.deletingLastPathComponent()
            .appendingPathComponent("salaryflow-before-import-\(f.string(from: date)).json")
        do {
            try backupData(at: date).write(to: url, options: .atomic)
            return .written(url)
        } catch {
            Log.error("не удалось сложить прежнее состояние перед импортом: \(error)")
            return .failed
        }
    }

    /// Ввозит копию и отдаёт итог для сообщения «готово».
    ///
    /// Порядок не случаен: сначала страховка, потом история, потом настройки.
    /// Настройки идут последними, потому что их присвоение тянет за собой
    /// пересчёт всего — включая план напоминаний, который считается по свежим
    /// отметкам и должен видеть уже ввезённую историю.
    @discardableResult
    func importBackup(_ file: BackupFile, mode: Backup.Mode) -> Backup.Result {
        let before = mood.entries.count
        let safety = writeSafetyCopy()

        var added = 0
        if let incoming = file.mood?.entries {
            switch mode {
            case .replace:
                // Заменили целиком — «прибавилось» тут ничего не значит,
                // итог виден по числу отметок.
                mood.replace(with: incoming)
            case .mergeMarks:
                let merged = Backup.merged(existing: mood.entries, incoming: incoming)
                added = merged.added
                mood.replace(with: merged.entries)
            }
        }

        var settingsReplaced = false
        if let incoming = file.settings {
            // Тем же путём, что и файл с диска: копию могла снять сборка
            // прежнего формата, и её надо дописать до текущего.
            settings = SettingsStore.upgraded(incoming)
            settingsReplaced = true
        }
        // Настройки могли и не измениться — например, копия с этой же машины.
        // Тогда `didSet` промолчит, а план напоминаний пересобрать всё равно
        // нужно: отметки стали другими.
        rescheduleReminders()

        Log.info("копия ввезена: настройки \(settingsReplaced ? "заменены" : "не менялись"), отметок было \(before), стало \(mood.entries.count)")
        return Backup.Result(mode: mode,
                             settingsReplaced: settingsReplaced,
                             marksBefore: before,
                             marksAfter: mood.entries.count,
                             added: added,
                             safetyCopy: safety)
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
        advancePanelReminder()
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
