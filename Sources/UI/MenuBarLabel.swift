import AppKit
import SwiftUI

/// То, что видно в строке меню: капля и сумма — за сегодня или за месяц,
/// смотря что выбрано в настройках. Вне рабочего дня сумма по умолчанию
/// убирается и остаётся одна капля.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    /// Своя капля вместо системного символа.
    ///
    /// Картинка шаблонная: цвета в ней нет, система красит её сама — под тему,
    /// под подсветку открытого меню и под строку меню на цветных обоях.
    /// Путь можно переопределить переменной окружения: у превью и зондов бандла
    /// нет, а посмотреть на значок надо — ровно как с настройками и журналом.
    static let drop: NSImage? = {
        let image: NSImage?
        if let custom = ProcessInfo.processInfo.environment["SALARYFLOW_MENUBAR_ICON"],
           !custom.isEmpty {
            image = NSImage(contentsOfFile: (custom as NSString).expandingTildeInPath)
        } else {
            image = NSImage(named: "MenuBarIcon")
        }
        image?.isTemplate = true
        return image
    }()

    /// Идёт ли начисление прямо сейчас. Полная капля — деньги капают,
    /// приглушённая — нет; в приватном режиме тоже приглушённая, потому что
    /// «сколько накапало» в этот момент не показывается.
    private var dripping: Bool {
        !model.amountsHidden && model.snapshot.state == .working
    }

    var body: some View {
        let s = model.snapshot

        HStack(spacing: 4) {
            if model.settings.showIcon {
                if let drop = MenuBarLabel.drop {
                    Image(nsImage: drop)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        // Высота подогнана к цифрам рядом: своя картинка не
                        // масштабируется вместе со шрифтом, как это делает
                        // системный символ, и без рамки капля вылезала выше строки.
                        .frame(width: 13, height: 13)
                        .opacity(dripping ? 1 : 0.45)
                } else {
                    // Бандла нет — значит это превью или зонд, и картинку
                    // взять неоткуда. Системный символ здесь только затем,
                    // чтобы на месте значка не было пустоты.
                    Image(systemName: dripping ? "drop.fill" : "drop")
                }
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
