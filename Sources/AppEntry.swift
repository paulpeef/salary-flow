import AppKit
import SwiftUI

@main
struct SalaryFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // isInserted позволяет убрать пункт из меню-бара целиком —
        // это и есть «исчезнуть на время демонстрации экрана».
        MenuBarExtra(isInserted: Binding(
            get: { model.menuBarItemVisible },
            set: { _ in }
        )) {
            PanelView(model: model)
        } label: {
            AccessibleMenuBarLabel(model: model, delegate: delegate)
        }
        .menuBarExtraStyle(.window)

        Window("Настройки Salary Flow", id: WindowID.settings) {
            SettingsView(model: model)
        }
        // Заголовок окна убран: он рисуется поверх содержимого и при боковом
        // списке налезал на него — начинался после светофора и переваливал
        // за границу сайдбара на центральный блок. Разделы и так подписаны.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Открытие из Finder должно давать видимое окно даже при скрытом пункте
/// меню-бара. OpenWindowAction берём из окружения сцены, а ранний запрос
/// делегат сохраняет до её появления.
private struct AccessibleMenuBarLabel: View {
    @ObservedObject var model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarLabel(model: model)
            .onAppear {
                delegate.showSettings = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: WindowID.settings)
                }
            }
    }
}
