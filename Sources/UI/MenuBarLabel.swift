import SwiftUI

/// То, что видно в строке меню: капля и сумма — за сегодня или за месяц,
/// смотря что выбрано в настройках. Вне рабочего дня сумма по умолчанию
/// убирается и остаётся одна капля.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let s = model.snapshot

        HStack(spacing: 4) {
            if model.settings.showIcon {
                Image(systemName: model.amountsHidden ? "drop"
                      : (s.state == .working ? "drop.fill" : "drop"))
            }
            // Пока панель открыта, ширина значка не должна меняться: она задаёт
            // точку, к которой панель прицеплена, и от скачка ширины панель
            // уезжает вбок. Поэтому на время открытой панели держим место
            // под самое длинное значение — невидимый образец задаёт ширину.
            ZStack(alignment: .trailing) {
                if model.panelIsOpen {
                    Text(widestText(snapshot: s))
                        .monospacedDigit()
                        .hidden()
                }
                if let text = labelText(snapshot: s) {
                    Text(text).monospacedDigit()
                }
            }
        }
    }

    /// Самая длинная строка, которую значок покажет сегодня: по ней и меряем.
    private func widestText(snapshot s: Snapshot) -> String {
        let money = MoneyFormatter(settings: model.settings)
        switch model.settings.menuBarTotal {
        case .month: return money.string(max(s.monthEarned, s.monthProjected))
        case .day: return money.string(max(s.todayEarned, s.todayFull))
        }
    }

    private func labelText(snapshot s: Snapshot) -> String? {
        // В приватном режиме цифр нет вообще: «•••» на видеозвонке само по себе
        // привлекает внимание, а пустая капля выглядит как любой другой значок.
        if model.amountsHidden { return placeholder }
        // Вне рабочего дня сумма замирает, поэтому по умолчанию убирается.
        guard s.state == .working || model.settings.idleShowsAmount else { return placeholder }

        let money = MoneyFormatter(settings: model.settings)
        switch model.settings.menuBarTotal {
        case .day: return money.string(s.todayEarned)
        case .month: return money.string(s.monthEarned)
        }
    }

    /// Когда цифры нет, а значок выключен, пункт меню-бара стал бы пустым
    /// и по нему нечем было бы попасть — оставляем прочерк.
    private var placeholder: String? {
        model.settings.showIcon ? nil : "—"
    }
}
