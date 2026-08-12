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
        engine = Engine(settings: loaded)
        snapshot = engine.snapshot()

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Log.info("пробуждение из сна — пересчёт")
            Task { @MainActor in self?.refresh() }
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
        refresh()
    }

    /// Остановить время на заданном моменте — используется рендером превью.
    func overrideNow(_ date: Date?) {
        frozenNow = date
        timer?.invalidate()
        timer = nil
        currentInterval = 0
        engine = Engine(settings: settings)
        snapshot = engine.snapshot(now: date ?? Date())
        if date == nil { rescheduleTimer() }
    }

    func refresh() {
        engine = Engine(settings: settings)
        snapshot = engine.snapshot(now: frozenNow ?? Date())
        if frozenNow == nil { rescheduleTimer() }
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
