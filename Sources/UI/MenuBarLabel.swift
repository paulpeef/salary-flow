import SwiftUI

/// То, что видно в строке меню: капля и сумма.
/// Вне рабочего дня превращается в заглушку — по настройке либо просто значок,
/// либо итог дня, либо итог месяца.
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
        switch model.settings.idleDisplay {
        case .monthTotal: return money.string(max(s.monthEarned, s.monthProjected))
        default: return money.string(max(s.todayEarned, s.todayFull))
        }
    }

    private func labelText(snapshot s: Snapshot) -> String? {
        // В приватном режиме цифр нет вообще: «•••» на видеозвонке само по себе
        // привлекает внимание, а пустая капля выглядит как любой другой значок.
        if model.amountsHidden { return model.settings.showIcon ? nil : "—" }
        let money = MoneyFormatter(settings: model.settings)
        if s.state == .working { return money.string(s.todayEarned) }
        switch model.settings.idleDisplay {
        case .icon: return model.settings.showIcon ? nil : "—"
        case .dayTotal: return money.string(s.todayEarned)
        case .monthTotal: return money.string(s.monthEarned)
        }
    }
}
