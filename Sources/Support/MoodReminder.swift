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
    enum Access: Equatable {
        /// Нет бандла — превью и зонд. Спрашивать не у кого и некому.
        case unavailable
        case notAsked
        case granted
        case denied
    }

    @Published private(set) var access: Access = .notAsked

    var onOpenPanel: (() -> Void)?
    var onMark: ((MoodKind) -> Void)?

    private static let categoryID = "mood.checkIn"
    private static let requestPrefix = "mood.reminder."
    private static let openAction = "mood.open"
    private static let markPrefix = "mood.mark."

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

    func refreshAccess() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            // Статус — простое перечисление; сами настройки за границу потока
            // не тащим, они для этого не предназначены.
            let status = settings.authorizationStatus
            Task { @MainActor in self?.apply(status) }
        }
    }

    /// Спросить разрешение, если его ещё не спрашивали. Отказ не переспрашиваем:
    /// повторный запрос система всё равно проглатывает молча, а вернуть
    /// разрешение можно только в системных настройках.
    func requestAccessIfNeeded() {
        guard let center, access != .granted, access != .denied else { return }
        // Звук не просим намеренно: три раза в день со звуком — это уже
        // не напоминание, а помеха, и выключают такое вместе с опросом.
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            if let error {
                Log.error("напоминания: не удалось спросить разрешение (\(error))")
            }
            Log.info("напоминания: разрешение \(granted ? "выдано" : "не выдано")")
            Task { @MainActor in self?.access = granted ? .granted : .denied }
        }
    }

    /// Открыть системные настройки уведомлений — единственный способ вернуть
    /// разрешение после отказа.
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private func apply(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: access = .notAsked
        case .denied: access = .denied
        default: access = .granted
        }
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
