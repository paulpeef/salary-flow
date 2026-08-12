import AppKit
import SwiftUI

// Оффскрин-рендер интерфейса в PNG: даёт посмотреть на панель и настройки
// в разных состояниях, не запуская приложение и не занимая экран.
// Запуск: ./Tools/preview.sh

@MainActor
func render<V: View>(_ view: V, to path: String, scale: CGFloat = 2) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.cgImage else {
        FileHandle.standardError.write(Data("не удалось отрендерить \(path)\n".utf8))
        return
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
    print("✓ \(path)  \(image.width)×\(image.height)")
}

/// Рендер через настоящее окно: ImageRenderer не умеет AppKit-контролы
/// (TabView, Picker, DatePicker) и подсовывает вместо них знак «нельзя».
/// Окно живёт за пределами экрана, поэтому ничего не мигает пользователю.
@MainActor
func renderWindow<V: View>(_ view: V, size: CGSize, to path: String, title: String = "Настройки Salary Flow") {
    let window = NSWindow(
        contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false
    )
    window.title = title
    window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    window.orderFront(nil)

    // Даём SwiftUI разложить контролы.
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))

    // Снимаем не contentView, а рамку окна целиком: заголовок и светофор
    // рисуются именно там, и без них не видно, как заголовок накладывается
    // на содержимое. Раньше это было слепым пятном.
    guard let content = window.contentView?.superview ?? window.contentView,
          let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
        FileHandle.standardError.write(Data("не удалось подготовить буфер для \(path)\n".utf8))
        return
    }
    content.cacheDisplay(in: content.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
    print("✓ \(path)  \(rep.pixelsWide)×\(rep.pixelsHigh)")
    window.orderOut(nil)
}

@MainActor
func makeModel(_ mutate: (inout AppSettings) -> Void) -> AppModel {
    let model = AppModel()
    var s = AppSettings()
    s.monthlyAmount = 210_000
    s.currencyCode = "RUB"
    s.timeZoneID = "Europe/Moscow"
    s.employmentStart = DayStamp(year: 2026, month: 8, day: 12)
    mutate(&s)
    model.settings = s
    return model
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    // Панель в разных состояниях дня.
    let working = makeModel { _ in }
    working.overrideNow(moment(2026, 8, 12, 14, 37))
    render(PanelView(model: working).frame(width: 300), to: "\(outDir)/panel-working.png")

    let evening = makeModel { _ in }
    evening.overrideNow(moment(2026, 8, 12, 21, 5))
    render(PanelView(model: evening).frame(width: 300), to: "\(outDir)/panel-evening.png")

    let weekend = makeModel { _ in }
    weekend.overrideNow(moment(2026, 8, 15, 12, 0))
    render(PanelView(model: weekend).frame(width: 300), to: "\(outDir)/panel-weekend.png")

    let vacation = makeModel {
        $0.ranges = [DayRange(from: DayStamp(year: 2026, month: 8, day: 10),
                              to: DayStamp(year: 2026, month: 8, day: 21),
                              kind: .vacation, note: "Турция")]
    }
    vacation.overrideNow(moment(2026, 8, 12, 14, 37))
    render(PanelView(model: vacation).frame(width: 300), to: "\(outDir)/panel-vacation.png")

    let hidden = makeModel { $0.hideAmount = true }
    hidden.overrideNow(moment(2026, 8, 12, 14, 37))
    render(PanelView(model: hidden).frame(width: 300), to: "\(outDir)/panel-private.png")

    // Настройки.
    let settingsModel = makeModel {
        $0.ranges = [
            DayRange(from: DayStamp(year: 2026, month: 8, day: 24),
                     to: DayStamp(year: 2026, month: 9, day: 6), kind: .vacation, note: "Отпуск"),
            DayRange(from: DayStamp(year: 2026, month: 11, day: 4),
                     to: DayStamp(year: 2026, month: 11, day: 4), kind: .holiday, note: "День народного единства")
        ]
    }
    let settingsSize = CGSize(width: 700, height: 500)
    let sections: [(SettingsSection, String)] = [
        (.money, "money"), (.schedule, "schedule"), (.specialDays, "days"),
        (.appearance, "look"), (.privacy, "privacy")
    ]
    for (section, name) in sections {
        let sectionModel = makeModel { $0.ranges = settingsModel.settings.ranges }
        renderWindow(SettingsView(model: sectionModel, initialSection: section),
                     size: settingsSize,
                     to: "\(outDir)/settings-\(name).png")
    }
}

func moment(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
