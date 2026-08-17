import AppKit
import SwiftUI

// Зонд раскрытия панели из кода.
//
// Отвечает на вопрос, который иначе видит только владелец за экраном: что
// происходит, когда панель просят раскрыться не мышью, а из кода — как при
// нажатии на уведомление. Условия те же: зонд запускают из терминала, поэтому
// активное приложение — Терминал, а зонд неактивен, ровно как приложение
// в момент прихода уведомления.
//
// Меряется два способа подряд: нажатие на пункт меню-бара без активации
// и с активацией. Про каждый печатается, появилось ли окно панели.
// Запуск: ./Tools/panelprobe.sh

@MainActor
final class Probe {
    /// Панель живёт отдельным окном рядом с окном самого пункта меню-бара.
    /// Узнаём её по ширине: пункт — узкий значок, панель — 340pt.
    private func panelWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.frame.width > 200 && $0.frame.height > 200 }
    }

    private func describe(_ moment: String) {
        let windows = NSApp.windows.filter(\.isVisible)
        print("  \(moment): активно=\(NSApp.isActive), видимых окон \(windows.count)")
        for window in windows {
            print("    \(window.className) \(Int(window.frame.width))×\(Int(window.frame.height))"
                  + " ключевое=\(window.isKeyWindow)")
        }
    }

    /// Приводим экран в исходное состояние: панель закрыта, приложение остыло.
    /// Без паузы после закрытия следующее нажатие срабатывает через раз —
    /// на этом первая версия зонда сама себя и обманула.
    private func settle() async {
        if MenuBarPanel.isOpen { MenuBarPanel.statusButton()?.performClick(nil) }
        try? await Task.sleep(for: .milliseconds(1200))
    }

    /// Одно нажатие — так делало приложение до правки.
    private func singleClick(activating: Bool) async -> Bool {
        MenuBarPanel.open(activating: activating)
        try? await Task.sleep(for: .milliseconds(800))
        return MenuBarPanel.isOpen
    }

    /// То, что делает приложение теперь: нажать, проверить, при неудаче повторить.
    private func withRetry(activating: Bool) async -> Bool {
        MenuBarPanel.open(activating: activating)
        try? await Task.sleep(for: .milliseconds(500))
        if !MenuBarPanel.isOpen {
            MenuBarPanel.open(activating: activating)
            try? await Task.sleep(for: .milliseconds(500))
        }
        return MenuBarPanel.isOpen
    }

    func run() async {
        print("== Зонд раскрытия панели ==")
        print("политика активации: \(NSApp.activationPolicy().rawValue) (0 = regular, 1 = accessory)")

        guard MenuBarPanel.statusButton() != nil else {
            print("ПРОВАЛ: кнопка пункта меню-бара не найдена среди окон приложения")
            exit(1)
        }
        print("кнопка пункта меню-бара найдена, приложение неактивно: \(!NSApp.isActive)")

        // Признак, по которому приложение решает, нажимать ли второй раз,
        // обязан совпадать со списком окон: иначе повтор закроет уже открытую.
        await settle()
        _ = await singleClick(activating: false)
        let byWindows = panelWindow() != nil
        print("признак isOpen=\(MenuBarPanel.isOpen), по списку окон=\(byWindows)"
              + (MenuBarPanel.isOpen == byWindows ? " — сходится" : " — РАСХОЖДЕНИЕ"))
        describe("панель раскрыта")

        let attempts = 4
        print("\nпо \(attempts) попытки на способ:")
        for activating in [false, true] {
            for retry in [false, true] {
                var opened = 0
                for _ in 0..<attempts {
                    await settle()
                    let ok = retry ? await withRetry(activating: activating)
                                   : await singleClick(activating: activating)
                    if ok { opened += 1 }
                }
                let name = (retry ? "нажатие с повтором" : "одно нажатие")
                    + (activating ? ", с активацией" : ", без активации")
                print("  \(name): раскрылась \(opened) из \(attempts)")
            }
        }
        await settle()
        exit(0)
    }
}

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Как у приложения: LSUIElement, то есть accessory.
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            // Даём SwiftUI поставить пункт в меню-бар.
            try? await Task.sleep(for: .milliseconds(1500))
            await Probe().run()
        }
    }
}

@main
struct PanelProbeApp: App {
    @NSApplicationDelegateAdaptor(ProbeDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
