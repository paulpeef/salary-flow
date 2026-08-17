import AppKit
import UserNotifications

/// Напоминания отметить настроение.
///
/// Опрос, о котором не вспоминают, данных не даёт: за первый день эксплуатации
/// человек нажимает плашку, пока помнит, а потом панель открывается ради цифр
/// и вопрос проходит мимо. Поэтому три раза за смену приложение спрашивает само.
///
/// Нажатие на уведомление раскрывает панель — так же, как если бы человек сам
/// щёлкнул по капле в меню-баре. Отдельный экран с вопросом не заводится:
/// отвечать надо там же, где потом смотреть статистику.
///
/// Сам напоминатель ничего не знает ни про панель, ни про журнал отметок:
/// что делать по нажатию, ему говорит модель через два замыкания.
@MainActor
final class MoodReminder: NSObject, ObservableObject {
    /// Вердикт и правило его вывода живут в модели: там их достают тесты.
    typealias Access = ReminderAccess

    @Published private(set) var access: Access = .notAsked

    /// Последний отказ системы принять запрос разрешения.
    ///
    /// Держится отдельно от `access` намеренно. «Система не приняла запрос» —
    /// это не «человек запретил»: код 1 приходит, например, сразу после подмены
    /// бандла новой сборкой, когда служба уведомлений ещё не подхватила
    /// приложение. Один раз спутав эти два случая, приложение трое суток
    /// показывало предупреждение о запрете при выданном разрешении.
    @Published private(set) var systemRefusal: String?

    /// Итог последней проверки уведомления и признак того, что она идёт.
    @Published private(set) var test: ReminderTest?
    @Published private(set) var isTesting = false

    /// Хранит ли система доставленные уведомления. Нужно только затем, чтобы
    /// проверка не объявила потерей выключенный Центр уведомлений.
    private var keptInCenter = true

    var onOpenPanel: (() -> Void)?
    var onMark: ((MoodKind) -> Void)?

    private static let categoryID = "mood.checkIn"
    private static let requestPrefix = "mood.reminder."
    private static let openAction = "mood.open"
    private static let markPrefix = "mood.mark."
    private static let testPrefix = "mood.test."

    /// Уведомление прошлой проверки — чтобы убрать его перед следующей.
    private var lastTestID: String?

    /// Попал ли ответ системы в журнал хоть раз за сеанс.
    private var didReportAccess = false

    /// Номер проверки: по нему сторож отличает свою проверку от следующей.
    private var testRun = 0

    /// Быстрый ответ прямо из уведомления, без открытия панели. Двое, а не все
    /// десять: в списке уведомления помещается немного, а это два самых частых
    /// ответа — «всё в порядке» и «устал». За остальным открывается панель.
    private static let quickMarks: [MoodKind] = [.good, .tired]

    /// Пусто у вспомогательных инструментов: `UNUserNotificationCenter` требует
    /// настоящего бандла и валит процесс, если его нет. Ровно та же причина,
    /// по которой в превью не поднимается Sparkle.
    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        guard let center else {
            access = .unavailable
            return
        }
        center.delegate = self
        center.setNotificationCategories([MoodReminder.category])
        refreshAccess()
    }

    var isAvailable: Bool { center != nil }

    // MARK: Разрешение

    /// Спросить у системы, как дела сейчас.
    ///
    /// Зовётся не только при запуске, и это главное: разрешение выдают руками
    /// в системных настройках, и заметить это приложение обязано само —
    /// иначе предупреждение живёт до перезапуска, хотя уведомления уже разрешены.
    func refreshAccess(then next: (@MainActor (Access) -> Void)? = nil) {
        guard let center else {
            next?(.unavailable)
            return
        }
        center.getNotificationSettings { [weak self] settings in
            // Сами настройки за границу потока не тащим, они для этого
            // не предназначены: наружу уходят три простых значения.
            let facts = ReminderSettingsFacts(settings)
            Task { @MainActor in
                let verdict = ReminderAccessRules.verdict(facts)
                guard let self else {
                    next?(verdict)
                    return
                }
                // Пишем первый ответ и каждую смену: перечитываем при каждой
                // активации, и повторять в журнале одно и то же незачем.
                if verdict != self.access || !self.didReportAccess {
                    self.didReportAccess = true
                    Log.info("напоминания: система отвечает — \(verdict.title)")
                }
                self.keptInCenter = facts.keptInNotificationCenter
                self.access = verdict
                // Система ответила по существу — прошлый отказ принять запрос
                // больше ничего не значит.
                if verdict != .notAsked { self.systemRefusal = nil }
                next?(verdict)
            }
        }
    }

    /// Спросить разрешение, если его ещё не спрашивали.
    ///
    /// Сначала выясняем у системы, а не смотрим в собственную память: между
    /// запуском и этим вызовом разрешение могли выдать или отозвать руками.
    /// Отказ человека не переспрашиваем — повторный запрос система всё равно
    /// проглатывает молча, а вернуть разрешение можно только в её настройках.
    func requestAccessIfNeeded() {
        guard let center else { return }
        refreshAccess { [weak self] access in
            guard access == .notAsked else { return }
            self?.ask(center)
        }
    }

    /// Системный вопрос.
    ///
    /// Ответ запроса вердиктом не считается: `granted == false` приходит и когда
    /// человек нажал «Не разрешать», и когда система вообще не приняла запрос.
    /// Различить их по этому флагу нельзя, поэтому итог всегда перечитывается
    /// у системы — она одна знает, чем дело кончилось.
    private func ask(_ center: UNUserNotificationCenter, then next: (@MainActor () -> Void)? = nil) {
        // Звук не просим намеренно: три раза в день со звуком — это уже
        // не напоминание, а помеха, и выключают такое вместе с опросом.
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            let refusal = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let refusal {
                    self.systemRefusal = refusal
                    Log.error("напоминания: система не приняла запрос разрешения (\(refusal))")
                } else {
                    Log.info("напоминания: разрешение \(granted ? "выдано" : "не выдано")")
                }
                self.refreshAccess { _ in next?() }
            }
        }
    }

    /// Открыть системные настройки уведомлений — единственный способ вернуть
    /// разрешение после отказа.
    ///
    /// Сразу на строке приложения, а не на общем списке: искать себя среди сотни
    /// программ человек не должен. Если система идентификатор не поймёт,
    /// откроется тот же общий раздел, что и раньше, — хуже не станет.
    func openSystemSettings() {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        let target = Bundle.main.bundleIdentifier.map { "\(pane)?id=\($0)" } ?? pane
        guard let url = URL(string: target) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Только для оффскрин-рендера: показать раздел так, будто система ответила
    /// именно так. В настоящем приложении не делает ничего — там вердикт
    /// приходит только от системы, и подменить его нечем.
    func overrideForPreview(access: Access, refusal: String? = nil, test: ReminderTest? = nil) {
        guard center == nil else { return }
        self.access = access
        systemRefusal = refusal
        self.test = test
    }

    // MARK: Проверка

    /// Проверить уведомления прямо сейчас.
    ///
    /// Нужна потому, что доверия к настройкам нет ни у человека, ни у самого
    /// приложения: разрешение выдаётся в одном месте, баннеры выключаются
    /// в другом, а «Не беспокоить» перебивает и то и другое. Одно нажатие
    /// показывает результат целиком — дошло или нет и почему, — вместо того
    /// чтобы ждать напоминания по расписанию и гадать.
    func sendTest() {
        guard let center else {
            finishTest(.rejected("в этой сборке уведомления недоступны"))
            return
        }
        isTesting = true
        test = nil
        startTestWatchdog()
        refreshAccess { [weak self] access in
            guard let self else { return }
            switch access {
            case .unavailable:
                self.finishTest(.rejected("уведомления недоступны"))
            case .denied:
                self.finishTest(.rejected("система запрещает уведомления этому приложению"))
            case .notAsked:
                // Нажали «проверить», не успев дать разрешение, — заодно
                // и спросим: более понятного момента для системного вопроса
                // не будет.
                self.ask(center) { [weak self] in self?.continueTest(center) }
            case .granted, .silenced:
                self.deliverTest(center)
            }
        }
    }

    /// Продолжение после системного вопроса: спрашивали только что, поэтому
    /// перечитывать вердикт заново не нужно — `ask` это уже сделал.
    private func continueTest(_ center: UNUserNotificationCenter) {
        switch access {
        case .granted, .silenced: deliverTest(center)
        case .denied: finishTest(.rejected("разрешение не выдано"))
        case .notAsked: finishTest(.rejected(systemRefusal ?? "система не ответила на запрос разрешения"))
        case .unavailable: finishTest(.rejected("уведомления недоступны"))
        }
    }

    private func deliverTest(_ center: UNUserNotificationCenter) {
        // Прошлую проверку из Центра убираем: копящиеся «проверка прошла» —
        // мусор, а не история.
        if let lastTestID { center.removeDeliveredNotifications(withIdentifiers: [lastTestID]) }

        let id = MoodReminder.testPrefix + UUID().uuidString
        lastTestID = id
        let content = UNMutableNotificationContent()
        content.title = "Проверка напоминаний"
        content.body = "Видите это — значит напоминания о настроении дойдут."
        // Категорию не ставим намеренно: у проверки не должно быть кнопок
        // ответа, иначе нажатие запишет отметку настроения, которой не было.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            let refusal = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let refusal {
                    self.finishTest(.rejected(refusal))
                    return
                }
                // «Отдали системе» и «человек увидел» — разные вещи, поэтому
                // ищем уведомление в Центре. Пауза обязательна: доставка
                // не мгновенная, и без неё проверка объявит потерю раньше,
                // чем уведомление успеет появиться.
                try? await Task.sleep(for: .milliseconds(900))
                self.checkDelivered(id: id)
            }
        }
    }

    /// Центр берём у себя, а не тащим параметром через ожидание: сам
    /// `UNUserNotificationCenter` для переноса между потоками не предназначен.
    private func checkDelivered(id: String) {
        guard let center else { return }
        center.getDeliveredNotifications { [weak self] delivered in
            // Наружу — только да/нет: сами уведомления за границу потока
            // не тащим по той же причине, что и настройки.
            let found = delivered.contains { $0.request.identifier == id }
            Task { @MainActor in
                guard let self else { return }
                self.finishTest(ReminderAccessRules.testVerdict(
                    access: self.access,
                    keptInCenter: self.keptInCenter,
                    rejection: nil,
                    foundInCenter: found
                ))
            }
        }
    }

    /// Страховка от неотвеченного вызова: вся эта правка — про состояние,
    /// залипшее навсегда, и заводить ещё одно такое же было бы смешно.
    /// Не дождавшись ответа системы, проверка честно говорит, что не дождалась,
    /// и отпускает кнопку.
    private func startTestWatchdog() {
        testRun += 1
        let run = testRun
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.isTesting, self.testRun == run else { return }
            self.finishTest(.rejected("система не ответила"))
        }
    }

    private func finishTest(_ result: ReminderTest) {
        // Нажали ещё раз, пока шла прошлая проверка, — её итог уже не наш.
        testRun += 1
        test = result
        isTesting = false
        Log.info("напоминания: проверка — \(result.message)")
    }

    // MARK: Расписание

    /// Заменить весь список запланированных напоминаний.
    ///
    /// Именно заменить, а не дополнить: план пересчитывается целиком при каждой
    /// правке настроек, поэтому проще снести старое, чем сводить два списка.
    /// Чужих уведомлений у приложения нет — снимать можно все.
    func schedule(_ moments: [Date], calendar: Calendar) {
        guard let center else { return }
        center.removeAllPendingNotificationRequests()
        guard !moments.isEmpty else {
            Log.info("напоминания: сроки сняты")
            return
        }

        for (number, moment) in moments.enumerated() {
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moment)
            // Пояс прикреплён к сроку: рабочий день задан в поясе из настроек,
            // и уехавший в отпуск ноутбук не должен сдвигать напоминания.
            parts.timeZone = calendar.timeZone
            let request = UNNotificationRequest(
                identifier: "\(MoodReminder.requestPrefix)\(number)",
                content: MoodReminder.content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            )
            center.add(request) { error in
                if let error { Log.error("напоминания: не удалось поставить срок (\(error))") }
            }
        }
        Log.info("напоминания: запланировано \(moments.count) на ближайшие \(MoodReminderRules.horizonDays) суток")
    }

    // MARK: Содержимое

    private static var content: UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Как вы себя чувствуете?"
        content.body = "Отметьте настроение — это одно нажатие."
        content.categoryIdentifier = categoryID
        return content
    }

    private static var category: UNNotificationCategory {
        var actions = quickMarks.map {
            UNNotificationAction(identifier: markPrefix + $0.rawValue,
                                 title: "\($0.emoji) \($0.short)",
                                 options: [])
        }
        actions.append(UNNotificationAction(identifier: openAction,
                                            title: "Открыть панель",
                                            options: [.foreground]))
        return UNNotificationCategory(identifier: categoryID, actions: actions,
                                      intentIdentifiers: [], options: [])
    }

    private func handle(action: String) {
        if action == UNNotificationDefaultActionIdentifier || action == MoodReminder.openAction {
            onOpenPanel?()
            return
        }
        guard action.hasPrefix(MoodReminder.markPrefix) else { return }   // «закрыть» — тоже ответ
        let raw = String(action.dropFirst(MoodReminder.markPrefix.count))
        guard let kind = MoodKind(rawValue: raw) else { return }
        onMark?(kind)
    }
}

// MARK: - Системные настройки → факты

extension ReminderSettingsFacts {
    /// Снимается прямо в обработчике, где `UNNotificationSettings` ещё живёт
    /// в своём потоке. Дальше решение принимается уже по этим значениям.
    init(_ settings: UNNotificationSettings) {
        let authorization: Authorization
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        // Временное и провизорное разрешение — тоже разрешение: уведомление дойдёт.
        default: authorization = .authorized
        }
        // Сравниваем с `.disabled`, а не с `.enabled`: `.notSupported` означает
        // «система про это не спрашивает», и трактовать его как «выключено»
        // нельзя — иначе на месте появится предупреждение из ничего.
        self.init(authorization: authorization,
                  alertsShown: settings.alertSetting != .disabled,
                  keptInNotificationCenter: settings.notificationCenterSetting != .disabled)
    }
}

// MARK: - Ответ на уведомление

extension MoodReminder: UNUserNotificationCenterDelegate {
    /// Приложение живёт в меню-баре и в момент срабатывания вполне может быть
    /// активным — без этого баннер бы не показался.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        Task { @MainActor in self.handle(action: action) }
        completionHandler()
    }
}

// MARK: - Как раскрыть панель из кода

/// Публичного способа открыть `MenuBarExtra` программно нет, поэтому нажимаем
/// на сам пункт меню-бара: он живёт в отдельном окне, и его кнопка — обычный
/// `NSStatusBarButton`, открытый класс AppKit. Приватных ключей и селекторов
/// здесь нет намеренно: если однажды кнопка перестанет находиться, приложение
/// не упадёт — уведомление просто останется уведомлением.
enum MenuBarPanel {
    @MainActor
    @discardableResult
    static func open() -> Bool {
        for window in NSApp.windows {
            guard let button = statusButton(in: window.contentView) else { continue }
            button.performClick(nil)
            return true
        }
        return false
    }

    @MainActor
    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = statusButton(in: subview) { return found }
        }
        return nil
    }
}
