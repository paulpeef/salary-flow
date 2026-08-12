import AppKit
import SwiftUI

/// Нужен ради двух вещей, которых у SwiftUI-приложения иначе нет:
/// поднять журнал раньше всего остального и поймать штатное завершение.
final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        AppDelegate.exitIfAlreadyRunning()
        _ = Migration.performed
        Log.installCrashHandlers()
        Log.bootstrap()
        Migration.notes.forEach { Log.info("переезд: \($0)") }
    }

    /// Второй экземпляр — это вторая капля в меню-баре и два счётчика,
    /// спорящих за один файл настроек. Появляется он буднично: регистрация
    /// агента автозапуска с `RunAtLoad` поднимает копию поверх уже работающей,
    /// да и запустить приложение дважды никто не мешает.
    ///
    /// Уходим через `exit`, а не `terminate`: делегат не должен успеть снять
    /// метку сеанса — она принадлежит работающему экземпляру, и её пропажа
    /// выглядела бы как его аварийное завершение.
    private static func exitIfAlreadyRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mine && !$0.isTerminated }
        guard !others.isEmpty else { return }
        exit(0)
    }

    /// Приложение живёт в меню-баре, а не в окне. Без этого AppKit гасит его,
    /// как только закрыто последнее окно, — то есть выход из настроек убивал
    /// весь счётчик. В журнале это выглядело штатным завершением, потому им
    /// и было: решение принимал AppKit, а не пользователь.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.endSession(reason: "выход из приложения")
    }
}
