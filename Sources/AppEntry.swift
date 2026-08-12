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
            MenuBarLabel(model: model)
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
