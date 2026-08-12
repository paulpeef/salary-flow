import AppKit
import SwiftUI

// Зонд настоящего окна настроек.
//
// Поднимает окно в том же SwiftUI-сценарии `Window` и с тем же AppDelegate,
// что и приложение, — а значит проверяет реальное поведение, а не его копию.
// Отвечает на два вопроса, которые иначе видит только владелец за экраном:
//
//   1. Какая у окна геометрия и хром — ширина колонок, прозрачность заголовка,
//      растянут ли contentView под заголовок. Именно так нашлось, что заголовок
//      «Настройки Salary Flow» шире колонки и залезает на центральный блок.
//   2. Переживает ли приложение закрытие окна. Оно живёт в меню-баре, и AppKit
//      по умолчанию гасит его после закрытия последнего окна.
//
// Снимок в пикселях зонд не делает: содержимое SwiftUI живёт в слоях, которые
// не отдаются ни через cacheDisplay, ни через CALayer.render, а системный
// захват экрана требует разрешения, которого у терминала нет. Раскладку
// смотрим через Tools/preview.sh, хром — здесь.

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private let real = AppDelegate()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        real.applicationShouldTerminateAfterLastWindowClosed(sender)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            for window in windows {
                print("окно «\(window.title)» \(Int(window.frame.width))×\(Int(window.frame.height))")
                print("   заголовок скрыт: \(window.titleVisibility == .hidden)")
                print("   прозрачный заголовок: \(window.titlebarAppearsTransparent)")
                print("   контент во всю высоту: \(window.styleMask.contains(.fullSizeContentView))")
                self.describeColumns(of: window)
            }

            guard let window = windows.max(by: { $0.frame.width < $1.frame.width }) else {
                print("окно настроек не открылось")
                exit(1)
            }

            print("закрываю окно…")
            window.close()

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                print("ПЕРЕЖИЛО ЗАКРЫТИЕ: приложение работает без окон")
                exit(0)
            }
        }
    }

    /// Ширины колонок берём из дерева представлений: так видно, что боковой
    /// список действительно 190pt, а не расплылся на половину окна.
    private func describeColumns(of window: NSWindow) {
        guard let content = window.contentView else { return }
        var widths: [String] = []
        func walk(_ view: NSView, depth: Int) {
            if view is NSScrollView || view.className.contains("Divider") {
                widths.append("\(view.className) \(Int(view.frame.width))×\(Int(view.frame.height)) @x\(Int(view.frame.minX))")
            }
            guard depth < 6 else { return }
            view.subviews.forEach { walk($0, depth: depth + 1) }
        }
        walk(content, depth: 0)
        for line in widths.prefix(6) { print("   \(line)") }
    }
}

@main
struct WindowProbeApp: App {
    @NSApplicationDelegateAdaptor(ProbeDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Настройки Salary Flow", id: WindowID.settings) {
            SettingsView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
