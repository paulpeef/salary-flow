import AppKit
import Foundation

// Зонд таймера: гоняет настоящую модель по настоящим часам.
//
// Отвечает на то, чего не видят ни тесты, ни оффскрин-рендер. Тесты проверяют
// правила на подставленном моменте, рендер — как это выглядит на одном кадре.
// А здесь работает живой `AppModel` со своим тиком: заводится таймер на
// несколько секунд, и зонд смотрит, действительно ли модель проходит все фазы
// сама, засчитывает ли заход в итог дня и правда ли напоминание о настроении
// уезжает на конец сессии.
//
// Боевые настройки, журнал и отметки не трогает — пути подменены окружением.
// Запуск: ./Tools/timerprobe.sh

var failures: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "✓" : "✗") \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
    if !ok { failures.append(name) }
}

/// Крутим настоящий RunLoop: тик модели живёт именно в нём, и подменять его
/// сном потока нельзя — таймер просто не сработает.
@MainActor
func wait(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func describe(_ phase: TimerPhase?) -> String {
    switch phase {
    case .none: return "нет"
    case .running(let left): return "идёт \(TimerRules.clock(left))"
    case .paused(let left): return "пауза \(TimerRules.clock(left))"
    case .done: return "готово"
    case .gone: return "снят"
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    let model = AppModel()

    // MARK: Жизнь таймера от запуска до исчезновения

    print("== Зонд таймера ==")
    print("\nЖизнь короткого таймера (6 секунд)")

    var settings = model.settings
    settings.timerEnabled = true
    settings.timerPresets = [TimerPreset(name: "Зонд", seconds: 6)]
    model.settings = settings

    guard let preset = model.timerPresets.first else {
        print("  ✗ пресет не подхватился")
        exit(1)
    }

    let started = Date()
    model.startTimer(preset)
    check("таймер занял строку меню", model.timerOnMenuBar)
    check("пункт меню-бара виден", model.menuBarItemVisible)

    var seen: [String] = []
    var blinked = false
    var sawDone = false
    while Date().timeIntervalSince(started) < 11 {
        wait(0.25)
        let phase = model.timerPhase
        let line = describe(phase)
        if seen.last != line {
            seen.append(line)
            print("    \(String(format: "%4.1f", Date().timeIntervalSince(started))) с: \(line)")
        }
        if let run = model.timerRun, TimerRules.blinking(run, now: Date()) { blinked = true }
        if phase == .done { sawDone = true }
        // Ждём, пока таймер снимет сам себя, а не пока перестанет
        // показываться: показ гаснет в ту же секунду, когда истекает «Готово»,
        // а заход в счёт записывает ближайший тик модели — на полсекунды
        // позже. Первая версия зонда ловила ровно этот зазор и обвиняла
        // модель в потере захода.
        if model.timerRun == nil && seen.count > 1 { break }
    }

    check("таймер шёл и отсчитывал", seen.contains { $0.hasPrefix("идёт") })
    check("последние секунды мигал", blinked)
    check("показал «Готово»", sawDone)
    check("сам снялся со строки меню", !model.timerOnMenuBar)
    check("заход попал в счёт своего таймера", model.timerLaunchesToday(preset) == 1,
          "\(model.timerLaunchesToday(preset))")

    // Счёт лежит в файле, а не в памяти: другой экземпляр журнала на том же
    // пути должен увидеть тот же заход — это и есть «переживает перезапуск».
    check("счёт запусков лежит на диске",
          TimerLog().launches(preset: preset.id, on: DayStamp(Date(), in: model.settings.calendar)) == 1)

    // MARK: Пауза

    print("\nПауза держит остаток")
    model.startTimer(preset)
    wait(1.2)
    model.pauseTimer()
    let frozen = model.timerPhase
    wait(2.0)
    check("на паузе остаток не убывает", model.timerPhase == frozen, describe(model.timerPhase))
    model.resumeTimer()
    wait(0.4)
    check("после паузы таймер снова идёт",
          { if case .running = model.timerPhase { return true } else { return false } }(),
          describe(model.timerPhase))
    model.stopTimer()
    check("остановленный вручную заход в счёт не идёт",
          model.timerLaunchesToday(preset) == 1, "\(model.timerLaunchesToday(preset))")
    check("после остановки строка меню свободна", !model.timerOnMenuBar)

    // MARK: Удаление таймера уносит его счёт

    print("\nУдалённый таймер уносит свой счёт")
    var withoutPreset = model.settings
    withoutPreset.timerPresets = []
    model.settings = withoutPreset
    check("записи удалённого таймера убраны", model.timers.entries.isEmpty,
          "осталось \(model.timers.entries.count)")

    var backAgain = model.settings
    backAgain.timerPresets = [TimerPreset(name: "Зонд", seconds: 6)]
    model.settings = backAgain

    // MARK: Горячие клавиши

    // Само нажатие отсюда не проверить: посылать события за другие программы
    // умеет только процесс с доступом к мониторингу, а у терминала его нет
    // (замерено: `AXIsProcessTrusted() == false`, синтетическое нажатие
    // до горячей клавиши не доходит). Зато проверяется главное, ради чего
    // выбран Carbon: система принимает регистрацию без единого разрешения.
    print("\nГорячие клавиши")
    let center = HotKeyCenter()
    let combo = TimerHotkey(keyCode: 25, command: true, option: true)   // ⌥⌘9
    let good = TimerPreset(name: "Годный", seconds: 60, hotkey: combo)
    let weak = TimerPreset(name: "Негодный", seconds: 60,
                           hotkey: TimerHotkey(keyCode: 26, shift: true))
    let twin = TimerPreset(name: "Дубль", seconds: 60, hotkey: combo)

    center.apply([good, weak, twin], enabled: true)
    check("система приняла сочетание без разрешений", center.registeredCount == 1,
          "повешено \(center.registeredCount)")

    center.apply([good], enabled: false)
    check("с выключенным блоком клавиш не остаётся", center.registeredCount == 0)
    center.unregisterAll()

    // MARK: Напоминание о настроении уезжает на конец сессии

    print("\nНапоминание внутри сессии")

    // Смену подгоняем под текущий момент, чтобы ближайшее напоминание пришлось
    // на ближайшие минуты: расписание считается из границ рабочего дня.
    let now = Date()
    let calendar = Calendar.current
    let from = calendar.dateComponents([.hour, .minute], from: now.addingTimeInterval(-10 * 60))
    let to = calendar.dateComponents([.hour, .minute], from: now.addingTimeInterval(20 * 60))

    var shifted = model.settings
    shifted.moodEnabled = true
    shifted.moodRemindersEnabled = true
    // Панелью, а не уведомлением: система уведомлений в зонде ни при чём,
    // и просить у неё разрешение из терминала незачем.
    shifted.moodReminderStyle = .panel
    shifted.workWeekdays = Set(1...7)
    shifted.dayStart = TimeOfDay(hour: from.hour ?? 0, minute: from.minute ?? 0)
    shifted.dayEnd = TimeOfDay(hour: to.hour ?? 0, minute: to.minute ?? 0)
    shifted.timeZoneID = TimeZone.current.identifier
    shifted.employmentStart = DayStamp(year: 2020, month: 1, day: 1)
    shifted.timerPresets = [TimerPreset(name: "Долгий", seconds: 6 * 60)]
    model.settings = shifted

    let before = model.plannedReminders.first
    if let before, before.timeIntervalSince(now) < 20 * 60 {
        print("    ближайшее напоминание: \(Fmt.clock(before, timeZone: model.settings.timeZone))")
        guard let long = model.timerPresets.first else { exit(1) }
        model.startTimer(long)
        let expected = model.timerRun.map { $0.deadline.addingTimeInterval(TimerRules.quietAfterFinish) }
        let after = model.plannedReminders.first
        check("напоминание уехало на конец сессии",
              after.map { abs($0.timeIntervalSince(expected ?? now)) < 1 } ?? false,
              after.map { Fmt.clock($0, timeZone: model.settings.timeZone) } ?? "нет")
        check("напоминание не пропало совсем", after != nil)

        model.stopTimer()
        // Заход бросили — напоминание возвращается на своё место. Тишина
        // после остановки длится всего минуту, и попавшее в неё напоминание
        // сдвинулось бы ровно на неё, а не на бывший конец сессии.
        let afterStop = model.plannedReminders.first
        let backInPlace = afterStop == before
        let insideQuiet = afterStop.map { $0.timeIntervalSince(Date()) < 70 } ?? false
        check("после остановки напоминание вернулось на своё место",
              backInPlace || insideQuiet,
              afterStop.map { Fmt.clock($0, timeZone: model.settings.timeZone) } ?? "нет")
    } else {
        print("    окно подобрать не удалось (смена пересекла полночь) — проверка пропущена")
    }

    print("")
    if failures.isEmpty {
        print("✅ Зонд прошёл")
        exit(0)
    } else {
        print("❌ Провалено: \(failures.joined(separator: ", "))")
        exit(1)
    }
}
