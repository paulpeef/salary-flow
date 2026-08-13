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

/// Отметки настроения для превью. Без них раздел статистики пустой, а проверить
/// надо именно графики и выводы. Данные детерминированные: превью не должно
/// меняться от прогона к прогону, иначе по нему нельзя сравнивать правки.
func demoMoodEntries(reference: Date) -> [MoodEntry] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!

    var seed: UInt64 = 20_260_812
    func random(_ bound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 33) % UInt64(bound))
    }

    var entries: [MoodEntry] = []
    for daysBack in stride(from: 70, through: 0, by: -1) {
        guard let day = calendar.date(byAdding: .day, value: -daysBack, to: reference) else { continue }
        let weekday = calendar.component(.weekday, from: day)
        guard (2...6).contains(weekday) else { continue }
        guard random(10) < 6 else { continue }               // отмечают не каждый день

        let stamp = DayStamp(day, in: calendar)
        // Понедельник тяжелее, пятница легче, последние недели тяжелее всех.
        var pool: [MoodKind] = [.good, .good, .tired, .hard, .bored]
        if weekday == 2 { pool += [.tired, .nervous, .quit] }
        if weekday == 6 { pool += [.good, .flow] }
        if stamp.day >= 21 { pool += [.hard, .bored] }
        if daysBack < 21 { pool += [.tired, .nervous] }

        let kind = pool[random(pool.count)]
        let hour = kind.isPositive ? 11 + random(3) : 15 + random(4)
        let minute = random(60)
        guard let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
              at <= reference else { continue }   // «сегодня» кончается на моменте превью
        let minuteOfDay = hour * 60 + minute
        let fraction = min(1, max(0, Double(minuteOfDay - 600) / 540))

        entries.append(MoodEntry(at: at, kind: kind, day: stamp, minuteOfDay: minuteOfDay,
                                 weekday: weekday, phase: .working, shiftFraction: fraction))
        // Иногда рядом идёт вторая отметка того же захода.
        if !kind.isPositive, random(10) < 4 {
            let second: MoodKind = [.tired, .bored, .nervous, .hard][random(4)]
            if second != kind, let also = calendar.date(byAdding: .minute, value: 3, to: at) {
                entries.append(MoodEntry(at: also, kind: second, day: stamp,
                                         minuteOfDay: minuteOfDay + 3, weekday: weekday,
                                         phase: .working, shiftFraction: fraction))
            }
        }
    }

    // Отметка минуту назад: на панели «14:37» она попадает в окно исправления
    // и видна выделенной, а на вечерней панели того же дня подсветка уже снята,
    // но «отмечено в» осталось — обе половины правила видно в рендере.
    let recent = reference.addingTimeInterval(-60)
    let parts = calendar.dateComponents([.hour, .minute, .weekday], from: recent)
    entries.append(MoodEntry(at: recent, kind: .tired, day: DayStamp(recent, in: calendar),
                             minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0),
                             weekday: parts.weekday ?? 1, phase: .working, shiftFraction: 0.5))
    return entries
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    // Журнал настроения пишем до создания моделей: MoodLog читает файл в init.
    try? FileManager.default.createDirectory(at: MoodLog.fileURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    if let data = try? MoodLog.encode(demoMoodEntries(reference: moment(2026, 8, 12, 14, 37))) {
        try? data.write(to: MoodLog.fileURL)
    }

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
        (.mood, "mood"), (.appearance, "look"), (.privacy, "privacy")
    ]
    for (section, name) in sections {
        let sectionModel = makeModel { $0.ranges = settingsModel.settings.ranges }
        sectionModel.settingsSection = section
        sectionModel.overrideNow(moment(2026, 8, 12, 14, 37))
        renderWindow(SettingsView(model: sectionModel),
                     size: settingsSize,
                     to: "\(outDir)/settings-\(name).png")
    }

    // Статистика настроения не влезает в окно целиком: страница прокручивается,
    // а проверить надо все графики и выводы сразу. Поэтому второй снимок —
    // сам раздел без окна, во всю высоту (ширина как у правой колонки: 700−190).
    let tallMood = makeModel { _ in }
    tallMood.overrideNow(moment(2026, 8, 12, 14, 37))
    renderWindow(MoodStatsView(model: tallMood, log: tallMood.mood)
                    .environment(\.locale, Locale(identifier: "ru_RU")),
                 size: CGSize(width: 510, height: 2150),
                 to: "\(outDir)/settings-mood-full.png")
}

func moment(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Moscow")!
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
