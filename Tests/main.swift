import Foundation

// Простой прогон без XCTest: тесты должны запускаться одной командой
// на голых Command Line Tools, без Xcode и без пакета SwiftPM.

var failures: [String] = []
var checks = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !condition() {
        let d = detail()
        failures.append("✗ \(name)" + (d.isEmpty ? "" : " — \(d)"))
    }
}

func nearly(_ a: Double, _ b: Double, eps: Double = 0.01) -> Bool { abs(a - b) < eps }

let moscow = TimeZone(identifier: "Europe/Moscow")!

func moment(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, tz: TimeZone = moscow) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

func baseSettings() -> AppSettings {
    var s = AppSettings()
    s.mode = .monthly
    s.monthlyAmount = 210_000
    s.workWeekdays = [2, 3, 4, 5, 6]          // пн–пт
    s.dayStart = TimeOfDay(hour: 10, minute: 0)
    s.dayEnd = TimeOfDay(hour: 19, minute: 0)
                                               // рабочий день 10:00–19:00 = 9 часов
    s.timeZoneID = "Europe/Moscow"
    s.employmentStart = DayStamp(year: 2020, month: 1, day: 1)
    s.rateBasis = .workingDaysInMonth
    s.ranges = []
    return s
}

// MARK: - Норма и дневная ставка

do {
    let e = Engine(settings: baseSettings())
    check("норма августа 2026 = 21 рабочий день",
          e.normDays(inMonthOf: DayStamp(year: 2026, month: 8, day: 12)) == 21,
          "получено \(e.normDays(inMonthOf: DayStamp(year: 2026, month: 8, day: 12)))")
    check("норма сентября 2026 = 22 рабочих дня",
          e.normDays(inMonthOf: DayStamp(year: 2026, month: 9, day: 1)) == 22)

    let rate = e.dailyRate(inMonthOf: DayStamp(year: 2026, month: 8, day: 12))
    check("дневная ставка = оклад / норму", nearly(rate, 210_000.0 / 21.0), "получено \(rate)")

    var fixed = baseSettings()
    fixed.rateBasis = .fixedDays
    fixed.fixedDaysPerMonth = 20
    let ef = Engine(settings: fixed)
    check("фиксированная база дней", nearly(ef.dailyRate(inMonthOf: DayStamp(year: 2026, month: 8, day: 12)), 10_500))
}

// MARK: - Внутри рабочего дня

do {
    let e = Engine(settings: baseSettings())
    let rate = 210_000.0 / 21.0

    let before = e.snapshot(now: moment(2026, 8, 12, 9, 0))
    check("до начала смены — ноль", nearly(before.todayEarned, 0))
    check("до начала смены — состояние beforeShift", before.state == .beforeShift)

    let atStart = e.snapshot(now: moment(2026, 8, 12, 10, 0))
    check("на старте смены — ноль", nearly(atStart.todayEarned, 0))
    check("на старте смены — состояние working", atStart.state == .working)

    let noon = e.snapshot(now: moment(2026, 8, 12, 12, 0))
    check("через 2 часа — 2/9 дневной ставки", nearly(noon.todayEarned, rate * 2 / 9), "получено \(noon.todayEarned)")

    // Перерыва больше нет: счётчик не замирает в обед, а идёт ровно.
    let lunchTime = e.snapshot(now: moment(2026, 8, 12, 13, 30))
    check("в обеденное время счётчик продолжает идти", nearly(lunchTime.todayEarned, rate * 3.5 / 9),
          "получено \(lunchTime.todayEarned)")

    let afterLunch = e.snapshot(now: moment(2026, 8, 12, 14, 30))
    check("через 4.5 часа — ровно половина дня", nearly(afterLunch.todayEarned, rate * 4.5 / 9),
          "получено \(afterLunch.todayEarned)")

    let atEnd = e.snapshot(now: moment(2026, 8, 12, 19, 0))
    check("в конце смены — полная ставка", nearly(atEnd.todayEarned, rate), "получено \(atEnd.todayEarned)")
    check("в конце смены — состояние afterShift", atEnd.state == .afterShift)

    let night = e.snapshot(now: moment(2026, 8, 12, 23, 30))
    check("вечером сумма дня не растёт", nearly(night.todayEarned, rate))
    check("прогресс дня = 1", nearly(night.dayProgress, 1))

    check("ставка в час считается от длины рабочего дня", nearly(noon.perHour, rate / 9))
    check("ставка в секунду", nearly(noon.perSecond, rate / 9 / 3600, eps: 0.000_001))
}

// MARK: - Выходные

do {
    let e = Engine(settings: baseSettings())
    let sat = e.snapshot(now: moment(2026, 8, 15, 14, 0))
    check("суббота — выходной", sat.state == .weekend)
    check("в субботу не капает", nearly(sat.todayEarned, 0))
}

// MARK: - Неполный месяц: вышел на работу 12 августа

do {
    var s = baseSettings()
    s.employmentStart = DayStamp(year: 2026, month: 8, day: 12)
    let e = Engine(settings: s)
    let rate = 210_000.0 / 21.0

    let firstDay = e.snapshot(now: moment(2026, 8, 12, 19, 0))
    check("первый рабочий день закрыт полностью", nearly(firstDay.todayEarned, rate))
    check("за месяц в первый день — ровно одна ставка", nearly(firstDay.monthEarned, rate), "получено \(firstDay.monthEarned)")

    let endOfMonth = e.snapshot(now: moment(2026, 8, 31, 23, 59))
    check("за неполный август — 14 ставок из 21",
          nearly(endOfMonth.monthEarned, rate * 14), "получено \(endOfMonth.monthEarned)")
    check("прогноз месяца равен факту в конце месяца", nearly(endOfMonth.monthProjected, rate * 14))
    check("закрыто 14 оплачиваемых дней", endOfMonth.paidDaysDone == 14, "получено \(endOfMonth.paidDaysDone)")

    // До выхода на работу вообще ничего.
    let beforeHire = e.snapshot(now: moment(2026, 8, 10, 15, 0))
    check("до трудоустройства — ноль за день", nearly(beforeHire.todayEarned, 0))
    check("до трудоустройства — ноль за месяц", nearly(beforeHire.monthEarned, 0))
    check("до трудоустройства состояние notEmployed", beforeHire.state == .notEmployed)

    // Следующий полный месяц считается как обычно.
    let sept = e.snapshot(now: moment(2026, 9, 30, 23, 59))
    check("сентябрь — полный оклад", nearly(sept.monthEarned, 210_000), "получено \(sept.monthEarned)")
}

// MARK: - Смена месяца

do {
    let e = Engine(settings: baseSettings())
    let justAfterMidnight = e.snapshot(now: moment(2026, 9, 1, 0, 1))
    check("в первую минуту месяца счётчик месяца обнулён", nearly(justAfterMidnight.monthEarned, 0),
          "получено \(justAfterMidnight.monthEarned)")
    check("прогноз на сентябрь = полный оклад", nearly(justAfterMidnight.monthProjected, 210_000))
}

// MARK: - Отпуск

do {
    var s = baseSettings()
    s.ranges = [DayRange(from: DayStamp(year: 2026, month: 8, day: 10),
                         to: DayStamp(year: 2026, month: 8, day: 21),
                         kind: .vacation)]
    let e = Engine(settings: s)
    let rate = 210_000.0 / 21.0

    let onVacation = e.snapshot(now: moment(2026, 8, 12, 11, 0))
    check("в отпуске состояние paidLeave", onVacation.state == .paidLeave(.vacation))
    check("отпускной день начислен целиком сразу", nearly(onVacation.todayEarned, rate))
    check("отпуск не меняет норму месяца", onVacation.normDays == 21)
    check("отпуск не режет месячный оклад", nearly(onVacation.monthProjected, 210_000), "получено \(onVacation.monthProjected)")

    // На 12 августа закрыты 1–7 (5 рабочих дней) плюс 10, 11, 12 отпускных.
    check("месяц с отпуском считается по закрытым дням",
          nearly(onVacation.monthEarned, rate * 8), "получено \(onVacation.monthEarned)")
}

// MARK: - Больничный

do {
    var s = baseSettings()
    s.ranges = [DayRange(from: DayStamp(year: 2026, month: 8, day: 12),
                         to: DayStamp(year: 2026, month: 8, day: 12),
                         kind: .sickLeave)]
    let e = Engine(settings: s)
    check("больничный оплачен как полный день",
          nearly(Engine(settings: s).snapshot(now: moment(2026, 8, 12, 10, 30)).todayEarned, 210_000.0 / 21.0))
    check("больничный не режет оклад", nearly(e.snapshot(now: moment(2026, 8, 12, 10, 30)).monthProjected, 210_000))
}

// MARK: - За свой счёт

do {
    var s = baseSettings()
    s.ranges = [DayRange(from: DayStamp(year: 2026, month: 8, day: 12),
                         to: DayStamp(year: 2026, month: 8, day: 12),
                         kind: .unpaid)]
    let e = Engine(settings: s)
    let rate = 210_000.0 / 21.0
    let snap = e.snapshot(now: moment(2026, 8, 12, 14, 0))
    check("за свой счёт — ноль за день", nearly(snap.todayEarned, 0))
    check("за свой счёт — состояние unpaid", snap.state == .unpaid)
    check("за свой счёт норма месяца не меняется", snap.normDays == 21)
    check("за свой счёт месяц уменьшается на одну ставку",
          nearly(snap.monthProjected, 210_000 - rate), "получено \(snap.monthProjected)")
}

// MARK: - Праздник

do {
    var s = baseSettings()
    s.ranges = [DayRange(from: DayStamp(year: 2026, month: 8, day: 12),
                         to: DayStamp(year: 2026, month: 8, day: 12),
                         kind: .holiday)]
    let e = Engine(settings: s)
    let snap = e.snapshot(now: moment(2026, 8, 12, 14, 0))
    check("праздник выпадает из нормы", snap.normDays == 20, "получено \(snap.normDays)")
    check("праздник — ноль за день", nearly(snap.todayEarned, 0))
    check("праздник не режет оклад", nearly(snap.monthProjected, 210_000), "получено \(snap.monthProjected)")
    check("дневная ставка выросла", nearly(snap.dailyRate, 210_000.0 / 20.0))
}

// MARK: - Рабочая суббота

do {
    var s = baseSettings()
    s.ranges = [DayRange(from: DayStamp(year: 2026, month: 8, day: 15),
                         to: DayStamp(year: 2026, month: 8, day: 15),
                         kind: .extraWorkday)]
    let e = Engine(settings: s)
    let snap = e.snapshot(now: moment(2026, 8, 15, 12, 0))
    check("рабочая суббота попадает в норму", snap.normDays == 22, "получено \(snap.normDays)")
    check("в рабочую субботу капает", snap.state == .working && snap.todayEarned > 0)
}

// MARK: - Приоритет перекрывающихся диапазонов

do {
    var s = baseSettings()
    s.ranges = [
        DayRange(from: DayStamp(year: 2026, month: 8, day: 10), to: DayStamp(year: 2026, month: 8, day: 21), kind: .vacation),
        DayRange(from: DayStamp(year: 2026, month: 8, day: 12), to: DayStamp(year: 2026, month: 8, day: 12), kind: .extraWorkday)
    ]
    let e = Engine(settings: s)
    check("последний диапазон в списке перекрывает предыдущий",
          e.snapshot(now: moment(2026, 8, 12, 12, 0)).state == .working)
}

// MARK: - Почасовая оплата

do {
    var s = baseSettings()
    s.mode = .hourly
    s.hourlyAmount = 1_500
    let e = Engine(settings: s)
    let snap = e.snapshot(now: moment(2026, 8, 12, 19, 0))
    check("почасовая: полный день = 9 × ставку", nearly(snap.todayEarned, 13_500), "получено \(snap.todayEarned)")
    check("почасовая: ставка в час не зависит от месяца", nearly(snap.perHour, 1_500))
    check("почасовая: прогноз августа = 21 × 13500", nearly(snap.monthProjected, 21 * 13_500))
}

// MARK: - Часовой пояс

do {
    var s = baseSettings()
    s.timeZoneID = "Europe/Moscow"
    let e = Engine(settings: s)
    // 09:00 UTC = 12:00 в Москве — два оплаченных часа.
    let utcNoon = moment(2026, 8, 12, 9, 0, tz: TimeZone(identifier: "UTC")!)
    check("расчёт идёт в настроенной таймзоне, а не в системной",
          nearly(e.snapshot(now: utcNoon).todayEarned, (210_000.0 / 21.0) * 2 / 9),
          "получено \(e.snapshot(now: utcNoon).todayEarned)")
}

// MARK: - Ночная смена

do {
    var s = baseSettings()
    s.dayStart = TimeOfDay(hour: 22, minute: 0)
    s.dayEnd = TimeOfDay(hour: 6, minute: 0)
    let e = Engine(settings: s)
    let rate = 210_000.0 / 21.0

    let midShift = e.snapshot(now: moment(2026, 8, 13, 2, 0))   // смена началась 12-го в 22:00
    check("ночная смена продолжается после полуночи", midShift.state == .working)
    check("ночная смена: 4 часа из 8", nearly(midShift.todayEarned, rate * 4 / 8), "получено \(midShift.todayEarned)")
}

// MARK: - Увольнение

do {
    var s = baseSettings()
    s.hasEmploymentEnd = true
    s.employmentEnd = DayStamp(year: 2026, month: 8, day: 14)
    let e = Engine(settings: s)
    let snap = e.snapshot(now: moment(2026, 8, 20, 14, 0))
    check("после увольнения не капает", nearly(snap.todayEarned, 0))
    check("после увольнения состояние notEmployed", snap.state == .notEmployed)
    check("месяц остановился на дате увольнения",
          nearly(snap.monthEarned, (210_000.0 / 21.0) * 10), "получено \(snap.monthEarned)")
}

// MARK: - Приватность: чем захват экрана отличается от работающего процесса

do {
    let all = ProcessList.all()
    check("список процессов не пустой", all.count > 10, "получено \(all.count)")
    check("в списке есть launchd", all.contains { $0.name.lowercased() == "launchd" },
          "первые пять: \(all.prefix(5).map(\.name).joined(separator: ", "))")
    // Номер процесса важнее имени: по нему спрашивают окна. Проверяем на том,
    // что в macOS неизменно, — launchd всегда первый. (Ноль тоже занят,
    // это kernel_task, поэтому «номер больше нуля» проверять нельзя.)
    check("номера процессов настоящие: launchd под номером 1",
          all.contains { $0.name == "launchd" && $0.pid == 1 })

    // Дальше — на выдуманных процессах и окнах, чтобы результат не зависел
    // от того, что реально запущено на машине во время прогона.
    let zoomIdle = [RunningProcess(pid: 10, name: "launchd"),
                    RunningProcess(pid: 20, name: "zoom.us"),
                    RunningProcess(pid: 30, name: "CptHost")]
    let suspects = AppSettings.defaultCaptureSuspects

    // Главный случай, ради которого всё и переписано: Zoom поднимает CptHost
    // при входе в конференцию и держит до конца, показывают экран или нет.
    let idle = CaptureDetector.verdict(suspects: suspects, running: zoomIdle,
                                       windowOwners: [20])
    check("звонок без демонстрации экрана не считается захватом", idle.capture == nil,
          "засчитан \(idle.capture?.process ?? "—")")
    check("молчащий кандидат назван — журналу есть что записать",
          idle.quiet == ["CptHost"], "получено \(idle.quiet)")

    // Во время показа CptHost рисует рамку вокруг показываемого экрана —
    // это его окно, и оно единственное надёжное отличие.
    let sharing = CaptureDetector.verdict(suspects: suspects, running: zoomIdle,
                                          windowOwners: [20, 30])
    check("демонстрация экрана в Zoom ловится по рамке",
          sharing.capture == CaptureHit(process: "CptHost", evidence: .sharingFrame))
    check("во время захвата молчащих кандидатов нет", sharing.quiet.isEmpty)

    // Скриншот — событие мгновенное, ждать от него окна бессмысленно.
    let shot = CaptureDetector.verdict(
        suspects: suspects,
        running: [RunningProcess(pid: 10, name: "launchd"),
                  RunningProcess(pid: 40, name: "screencapture")],
        windowOwners: [])
    check("снимок экрана ловится по одному присутствию процесса",
          shot.capture == CaptureHit(process: "screencapture", evidence: .presence))

    let remote = CaptureDetector.verdict(
        suspects: suspects,
        running: [RunningProcess(pid: 10, name: "launchd"),
                  RunningProcess(pid: 50, name: "rudesktop_agent"),
                  RunningProcess(pid: 51, name: "AnyDesk")],
        windowOwners: [50, 51])
    check("фоновый агент удалёнки не считается захватом экрана", remote.capture == nil,
          "в список по умолчанию попал постоянно работающий демон")

    let atStartup = CaptureDetector.verdict(
        suspects: suspects,
        running: [RunningProcess(pid: 40, name: "screencapture")],
        windowOwners: [], ignoring: ["screencapture"])
    check("процесс-присутствие, работавший ещё до запуска приложения, игнорируется",
          atStartup.capture == nil)

    // А вот к рамке отсечка по старту не применяется: приложение могли
    // перезапустить посреди конференции, и тогда CptHost был бы «старым»,
    // хотя демонстрация ещё впереди.
    let restarted = CaptureDetector.verdict(suspects: suspects, running: zoomIdle,
                                            windowOwners: [30], ignoring: ["CptHost"])
    check("рамку засчитывают даже у процесса, работавшего при старте",
          restarted.capture?.process == "CptHost")

    check("свои процессы добавляются к встроенным и считаются по присутствию",
          CaptureDetector.verdict(
              suspects: suspects + [CaptureSuspect("webex", .presence)],
              running: [RunningProcess(pid: 10, name: "launchd"),
                        RunningProcess(pid: 60, name: "WebexHelper")],
              windowOwners: []).capture == CaptureHit(process: "WebexHelper", evidence: .presence))

    // Опрос идёт каждые три секунды: без запущенного Zoom обходить все окна
    // системы незачем, и монитор этого не делает.
    check("окна не спрашивают, когда по рамке ловить некого",
          !CaptureDetector.needsWindowList(
              suspects: suspects,
              running: [RunningProcess(pid: 10, name: "launchd"),
                        RunningProcess(pid: 40, name: "screencapture")]))
    check("окна спрашивают, когда работает Zoom",
          CaptureDetector.needsWindowList(suspects: suspects, running: zoomIdle))

    check("пустой список подозреваемых ничего не находит",
          CaptureDetector.verdict(suspects: [], running: zoomIdle, windowOwners: [30]).capture == nil)
    check("пустое имя в списке ничего не ловит",
          CaptureDetector.verdict(suspects: [CaptureSuspect("  ", .presence)],
                                  running: zoomIdle, windowOwners: []).capture == nil)

    var withOwn = baseSettings()
    withOwn.privacyExtraProcesses = ["Webex", "  ", "obs"]
    check("свои процессы приходят в список подозреваемых по присутствию",
          withOwn.captureSuspects.suffix(2) == [CaptureSuspect("Webex", .presence),
                                                CaptureSuspect("obs", .presence)],
          "получено \(withOwn.captureSuspects.suffix(2))")

    // Список окон спрашивается у системы без всяких разрешений: нам нужен
    // только владелец окна, а скрыты без права на запись экрана заголовки.
    let owners = WindowCensus.onscreenOwners()
    check("список владельцев окон читается без разрешения на запись экрана",
          !owners.isEmpty, "получено \(owners.count)")

    // Проверяем сам механизм опроса камер: он не должен падать и должен
    // отвечать за разумное время, даже если камер несколько.
    let started = Date()
    _ = CameraWatch.anyCameraIsRunning()
    check("опрос камер отвечает быстрее 200 мс",
          Date().timeIntervalSince(started) < 0.2,
          "заняло \(Int(Date().timeIntervalSince(started) * 1000)) мс")
}

// MARK: - Настройки переживают смену формата

func decodeSettings(_ json: String) -> AppSettings? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(AppSettings.self, from: data)
}

do {
    // Файл, записанный ранней версией: полей приватности и версии формата ещё нет.
    let old = """
    {
      "monthlyAmount": 210000,
      "currencyCode": "KZT",
      "timeZoneID": "Europe/Moscow",
      "decimals": 0,
      "employmentStart": { "year": 2026, "month": 8, "day": 12 },
      "dayStart": { "hour": 9, "minute": 30 },
      "workWeekdays": [2, 3, 4, 5, 6]
    }
    """

    let loaded = decodeSettings(old)
    check("старый файл настроек вообще читается", loaded != nil)
    if let loaded {
        check("оклад пережил появление новых полей", loaded.monthlyAmount == 210_000, "получено \(loaded.monthlyAmount)")
        check("валюта пережила", loaded.currencyCode == "KZT")
        check("часовой пояс пережил", loaded.timeZoneID == "Europe/Moscow")
        check("знаки после запятой пережили", loaded.decimals == 0)
        check("дата выхода на работу пережила",
              loaded.employmentStart == DayStamp(year: 2026, month: 8, day: 12))
        check("начало дня пережило", loaded.dayStart == TimeOfDay(hour: 9, minute: 30))
        check("новые поля взяли значения по умолчанию", loaded.privacyOnCamera == true)
        check("версия формата у старого файла нулевая", loaded.schemaVersion == 0)
    }
}

do {
    // Незнакомые поля из будущей версии не должны ломать разбор.
    let future = """
    { "monthlyAmount": 99000, "somethingFromTheFuture": { "a": [1, 2] }, "schemaVersion": 99 }
    """
    let loaded = decodeSettings(future)
    check("поля из будущего не ломают чтение", loaded?.monthlyAmount == 99_000)
}

do {
    // Испорченное значение отдельного поля не должно уносить весь файл.
    let broken = """
    { "monthlyAmount": 175000, "menuBarTotal": "чтототакое", "decimals": "не число",
      "ranges": [ { "from": {"year":2026,"month":9,"day":1}, "to": {"year":2026,"month":9,"day":5} } ] }
    """
    let loaded = decodeSettings(broken)
    check("испорченное поле не уносит весь файл", loaded?.monthlyAmount == 175_000)
    check("испорченный перечислимый тип откатился к значению по умолчанию",
          loaded?.menuBarTotal == .day)
    check("испорченное число откатилось к значению по умолчанию", loaded?.decimals == 0)
    check("диапазон без типа дня получил значение по умолчанию", loaded?.ranges.first?.kind == .vacation)
}

do {
    // Полный круг: записали — прочитали — получили то же самое.
    var settings = baseSettings()
    settings.ranges = [DayRange(from: DayStamp(year: 2026, month: 8, day: 24),
                                to: DayStamp(year: 2026, month: 9, day: 6),
                                kind: .vacation, note: "Отпуск")]
    settings.privacyExtraProcesses = ["Webex"]
    settings.hasEmploymentEnd = true

    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(settings),
          let restored = try? JSONDecoder().decode(AppSettings.self, from: data) else {
        check("настройки переживают запись и чтение", false, "не удалось закодировать")
        exit(1)
    }
    check("настройки переживают запись и чтение", restored == settings)
    check("особые дни переживают запись и чтение", restored.ranges.first?.note == "Отпуск")
}

// MARK: - Копейки

do {
    check("по умолчанию копеек нет", AppSettings().decimals == 0,
          "получено \(AppSettings().decimals)")
    check("текущая версия формата — третья", AppSettings.currentSchemaVersion == 3)

    var withKopecks = baseSettings()
    withKopecks.decimals = 2
    let money = MoneyFormatter(settings: withKopecks)
    check("включённые копейки показываются", money.string(1234.5).contains("50"),
          "получено \(money.string(1234.5))")

    var without = baseSettings()
    without.decimals = 0
    let rounded = MoneyFormatter(settings: without)
    let text = rounded.string(1234.56)
    check("без копеек дробной части нет", !text.contains(","), "получено \(text)")
    // Разделитель тысяч — неразрывный пробел, поэтому сравниваем без пробелов.
    let digits = text.filter(\.isNumber)
    check("без копеек сумма округляется", digits == "1235", "получено \(text)")

    // Явно выставленное значение из файла обязано пережить чтение:
    // миграцию делает хранилище, а не разбор.
    let kept = decodeSettings(#"{ "decimals": 2, "schemaVersion": 2 }"#)
    check("явно включённые копейки не сбрасываются при чтении", kept?.decimals == 2)
}

// MARK: - Государственные праздники

do {
    // 12 августа 2026 — среда. Делаем её государственным праздником.
    let holidays: [DayStamp: String] = [DayStamp(year: 2026, month: 8, day: 12): "Проверочный день"]
    let e = Engine(settings: baseSettings(), publicHolidays: holidays)
    let snap = e.snapshot(now: moment(2026, 8, 12, 14, 0))

    check("государственный праздник выпадает из нормы", snap.normDays == 20, "получено \(snap.normDays)")
    check("в государственный праздник не капает", nearly(snap.todayEarned, 0))
    check("состояние — праздник", snap.state == .holiday)
    check("оклад от праздника не уменьшается", nearly(snap.monthProjected, 210_000),
          "получено \(snap.monthProjected)")
    check("дневная ставка выросла", nearly(snap.dailyRate, 210_000.0 / 20.0))
}

do {
    // Праздник, попавший на выходной, ничего не меняет: он и так нерабочий.
    let holidays: [DayStamp: String] = [DayStamp(year: 2026, month: 8, day: 15): "Суббота-праздник"]
    let e = Engine(settings: baseSettings(), publicHolidays: holidays)
    check("праздник на выходном норму не трогает",
          e.snapshot(now: moment(2026, 8, 17, 12, 0)).normDays == 21)
}

do {
    // Своя запись перекрывает производственный календарь: в праздник вышли работать.
    var s = baseSettings()
    s.ranges = [DayRange(from: DayStamp(year: 2026, month: 8, day: 12),
                         to: DayStamp(year: 2026, month: 8, day: 12),
                         kind: .extraWorkday)]
    let holidays: [DayStamp: String] = [DayStamp(year: 2026, month: 8, day: 12): "Проверочный день"]
    let e = Engine(settings: s, publicHolidays: holidays)
    let snap = e.snapshot(now: moment(2026, 8, 12, 14, 0))
    check("своя запись перекрывает государственный праздник", snap.state == .working)
    check("норма вернулась к 21", snap.normDays == 21, "получено \(snap.normDays)")
}

// MARK: - Разбор календаря праздников

do {
    let sample = """
    BEGIN:VCALENDAR
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20260831
    SUMMARY:Malaysia's National Day
    DESCRIPTION:Public holiday
    END:VEVENT
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20260214
    SUMMARY:Valentine's Day
    DESCRIPTION:Observance
    END:VEVENT
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20260201
    SUMMARY:Thaipusam (regional holiday)
    DESCRIPTION:Public holiday in Johor\\, Kedah
    END:VEVENT
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20260825
    SUMMARY:The Prophet Muhammad's Birthday (tentative)
    DESCRIPTION:Public holiday\\nDate is tentative and may change
    END:VEVENT
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20260101
    SUMMARY:Новый Год
    DESCRIPTION:Государственный праздник
    END:VEVENT
    END:VCALENDAR
    """

    let parsed = ICSParser.parse(sample)
    check("разобрано четыре праздника, наблюдение отброшено", parsed.count == 4,
          "получено \(parsed.count): \(parsed.map(\.name))")

    let national = parsed.filter { $0.scope == .national }
    check("национальных три", national.count == 3, "получено \(national.count)")

    check("день святого Валентина не считается выходным",
          !parsed.contains { $0.name.contains("Valentine") })

    let regional = parsed.first { $0.scope == .regional }
    check("региональный праздник опознан", regional?.name == "Thaipusam",
          "получено \(regional?.name ?? "нет")")
    check("регионы вытащены", regional?.regions.contains("Johor") == true,
          "получено \(regional?.regions ?? "нет")")

    check("пометка «дата уточняется» подхвачена",
          parsed.contains { $0.isTentative && $0.name.contains("Prophet") })
    check("из названия убрана служебная пометка",
          parsed.contains { $0.name == "The Prophet Muhammad's Birthday" })

    check("русский календарь разбирается тоже",
          parsed.contains { $0.name == "Новый Год" && $0.scope == .national })

    check("дата разобрана верно",
          parsed.contains { $0.day == DayStamp(year: 2026, month: 8, day: 31) })
}

do {
    // Настоящие снимки, вшитые в приложение: они не должны молча испортиться.
    for (name, expected) in [("russia", "Россия"), ("malaysia", "Малайзия")] {
        let path = "Resources/holidays-\(name).ics"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            check("снимок календаря \(expected) читается", false, "нет файла \(path)")
            continue
        }
        let parsed = ICSParser.parse(text)
        let national2026 = parsed.filter { $0.day.year == 2026 && $0.scope == .national }
        check("снимок \(expected): есть праздники на 2026 год", national2026.count >= 8,
              "получено \(national2026.count)")
        let years = Set(parsed.map(\.day.year))
        check("снимок \(expected): есть будущие годы", years.contains { $0 > 2026 },
              "годы: \(years.sorted())")
    }
}

// MARK: - Карта переносов

do {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!

    // Заглушка будущего года: сервис отдаёт одни нули, пока нет постановления.
    // Принять её нельзя — все субботы и воскресенья стали бы рабочими.
    let placeholder = String(repeating: "0", count: 365)
    check("карта из одних нулей отвергается",
          WorkCalendarParser.parse(placeholder, year: 2027, calendar: utc) == nil)

    // Карта неверной длины — тоже мусор.
    check("карта неверной длины отвергается",
          WorkCalendarParser.parse("0101", year: 2026, calendar: utc) == nil)

    // Настоящая карта: выходные по дням недели плюс новогодние каникулы.
    var real = ""
    let start = utc.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    for offset in 0..<365 {
        let date = utc.date(byAdding: .day, value: offset, to: start)!
        let weekday = utc.component(.weekday, from: date)
        let stamp = DayStamp(date, in: utc)
        // 1–9 января нерабочие, 17 января (суббота) — рабочая.
        if stamp.month == 1 && stamp.day <= 9 { real += "1" }
        else if stamp.month == 1 && stamp.day == 17 { real += "0" }
        else if weekday == 1 || weekday == 7 { real += "1" }
        else { real += "0" }
    }

    guard let map = WorkCalendarParser.parse(real, year: 2026, calendar: utc) else {
        check("настоящая карта принимается", false, "разбор вернул nil")
        exit(1)
    }
    check("настоящая карта принимается", true)
    check("новогодние каникулы попали в нерабочие",
          map.dayOff.contains(DayStamp(year: 2026, month: 1, day: 5)))
    check("рабочая суббота опознана",
          map.workday.contains(DayStamp(year: 2026, month: 1, day: 17)),
          "рабочих выходных: \(map.workday.count)")
    check("обычная суббота рабочей не считается",
          !map.workday.contains(DayStamp(year: 2026, month: 1, day: 24)))

    // Движок с этой картой: рабочая суббота входит в норму и в ней капает.
    var s = baseSettings()
    s.employmentStart = DayStamp(year: 2020, month: 1, day: 1)
    let e = Engine(settings: s, officialDaysOff: map.dayOff, officialWorkdays: map.workday)
    let snap = e.snapshot(now: moment(2026, 1, 17, 14, 0))
    check("в рабочую субботу капает", snap.state == .working, "состояние \(snap.state)")
    check("рабочая суббота входит в норму января", e.isNormDay(DayStamp(year: 2026, month: 1, day: 17)))
    check("новогодние каникулы из нормы выпали",
          !e.isNormDay(DayStamp(year: 2026, month: 1, day: 5)))

    // Норма января 2026 по этой карте: будни минус каникулы плюс рабочая суббота.
    let january = e.normDays(inMonthOf: DayStamp(year: 2026, month: 1, day: 15))
    check("норма января посчитана по карте", january == 16, "получено \(january)")

    // Своя запись всё равно главнее производственного календаря.
    var withOverride = s
    withOverride.ranges = [DayRange(from: DayStamp(year: 2026, month: 1, day: 17),
                                    to: DayStamp(year: 2026, month: 1, day: 17),
                                    kind: .vacation)]
    let e2 = Engine(settings: withOverride, officialDaysOff: map.dayOff, officialWorkdays: map.workday)
    check("свой отпуск перекрывает рабочую субботу",
          e2.snapshot(now: moment(2026, 1, 17, 14, 0)).state == .paidLeave(.vacation))
}

// MARK: - Значения по умолчанию для нового пользователя

do {
    let fresh = AppSettings()
    let today = DayStamp(Date(), in: Calendar(identifier: .gregorian))

    // Дата выхода на работу не должна быть зашита в код: однажды туда попала
    // реальная дата владельца, и её увидел бы каждый, кто поставит приложение.
    check("дата выхода на работу вычисляется, а не зашита",
          fresh.employmentStart.year == today.year && fresh.employmentStart.month == today.month,
          "получено \(Fmt.day(fresh.employmentStart))")
    check("дата выхода — первое число месяца", fresh.employmentStart.day == 1)
    check("дата увольнения не в прошлом", fresh.employmentEnd.year >= today.year)

    // Ничего личного в значениях по умолчанию быть не должно.
    check("особых дней по умолчанию нет", fresh.ranges.isEmpty)
    check("свой символ валюты пуст", fresh.customCurrencySymbol.isEmpty)
    check("своих процессов приватности нет", fresh.privacyExtraProcesses.isEmpty)
    check("суммы не скрыты по умолчанию", fresh.hideAmount == false)
    check("автозапуск по умолчанию выключен", fresh.launchAtLogin == false)
    check("выбор браузера по умолчанию выключен", fresh.browserPickerEnabled == false)
    check("спрятанных браузеров по умолчанию нет", fresh.browserPickerHidden.isEmpty)
    check("часовой пояс берётся с машины пользователя",
          fresh.timeZoneID == TimeZone.current.identifier)
}

// MARK: - Настроение: веса и заходы

var moodCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = moscow
    return c
}

func moodEntry(_ kind: MoodKind, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> MoodEntry {
    let at = moment(y, m, d, h, min)
    let weekday = moodCalendar.component(.weekday, from: at)
    let minuteOfDay = h * 60 + min
    return MoodEntry(at: at, kind: kind, day: DayStamp(at, in: moodCalendar),
                     minuteOfDay: minuteOfDay, weekday: weekday, phase: .working,
                     shiftFraction: min0to1(Double(minuteOfDay - 600) / 540))
}

func min0to1(_ v: Double) -> Double { Swift.max(0, Swift.min(1, v)) }

do {
    check("индекс «всё хорошо» = 75", nearly(MoodKind.good.index, 75))
    check("индекс «в потоке» = 100", nearly(MoodKind.flow.index, 100))
    check("индекс «не хочу здесь работать» = 0", nearly(MoodKind.quit.index, 0))
    check("индекс «устал» = 25", nearly(MoodKind.tired.index, 25))
    check("положительных состояний ровно три",
          MoodKind.allCases.filter(\.isPositive).count == 3,
          "получено \(MoodKind.allCases.filter(\.isPositive).map(\.rawValue))")
    check("«скорее бы домой» весит как скука, а не как желание уйти",
          nearly(MoodKind.homeSoon.index, MoodKind.bored.index)
          && MoodKind.homeSoon.index > MoodKind.quit.index)
    check("первым в списке идёт «всё хорошо»", MoodKind.allCases.first == .good,
          "получено \(MoodKind.allCases.first?.rawValue ?? "—")")

    // Отметки подряд — один заход: два клика не должны весить больше одного.
    let together = [moodEntry(.tired, 2026, 8, 12, 15, 0),
                    moodEntry(.bored, 2026, 8, 12, 15, 10)]
    let one = MoodStats.groupIntoCheckIns(together)
    check("две отметки в пределах окна — один заход", one.count == 1, "получено \(one.count)")
    check("индекс захода — среднее по отметкам", nearly(one[0].index, 25))

    let apart = [moodEntry(.tired, 2026, 8, 12, 15, 0),
                 moodEntry(.bored, 2026, 8, 12, 16, 0)]
    check("отметки через час — два захода", MoodStats.groupIntoCheckIns(apart).count == 2)

    // Заход не должен склеиваться через полночь: это разные дни, даже если
    // ночная смена идёт непрерывно.
    let overnight = [moodEntry(.tired, 2026, 8, 12, 23, 50),
                     moodEntry(.bored, 2026, 8, 13, 0, 5)]
    check("через полночь — разные заходы", MoodStats.groupIntoCheckIns(overnight).count == 2)
}

// MARK: - Настроение: что делает нажатие

do {
    let tired = moodEntry(.tired, 2026, 8, 12, 15, 0)
    let good = moodEntry(.good, 2026, 8, 12, 15, 1)

    check("нажатие на пустом месте добавляет отметку",
          MoodTap.decide(kind: .tired, open: []) == .add)
    check("нажатие на выделенной плашке снимает отметку",
          MoodTap.decide(kind: .tired, open: [tired]) == .remove(tired.id))

    // Запрет на смешивание хорошего с плохим убран: он гасил плашку молча,
    // и выглядело это как «не даёт выбрать несколько».
    check("хорошее рядом с плохим разрешено",
          MoodTap.decide(kind: .good, open: [tired]) == .add)
    check("плохое рядом с хорошим разрешено",
          MoodTap.decide(kind: .tired, open: [good]) == .add)
    check("третья жалоба к двум прежним разрешена",
          MoodTap.decide(kind: .nervous, open: [tired, good]) == .add)
    check("снимается именно нажатая отметка, а не первая по списку",
          MoodTap.decide(kind: .good, open: [tired, good]) == .remove(good.id))

    // Смесь считается средним, а не отбрасывается.
    let mixed = MoodStats.groupIntoCheckIns([moodEntry(.flow, 2026, 8, 12, 15, 0),
                                            moodEntry(.tired, 2026, 8, 12, 15, 4)])
    check("«в потоке» и «устал» вместе — один заход", mixed.count == 1)
    check("смесь хорошего и плохого даёт середину", nearly(mixed[0].index, 62.5),
          "получено \(mixed[0].index)")
}

// MARK: - Настроение: окно исправления и повторы

do {
    let entries = [moodEntry(.tired, 2026, 8, 12, 15, 0)]

    check("сразу после отметки её ещё можно снять",
          MoodRules.openForUndo(entries, now: moment(2026, 8, 12, 15, 1)).count == 1)
    check("через двадцать минут снимать уже нечего",
          MoodRules.openForUndo(entries, now: moment(2026, 8, 12, 15, 20)).isEmpty)

    // Главное, ради чего окна разведены: то же состояние можно отметить снова,
    // а не только снять. Иначе выделенная плашка запирала повтор.
    let openLater = MoodRules.openForUndo(entries, now: moment(2026, 8, 12, 15, 20))
    check("через двадцать минут «устал» отмечается заново",
          MoodTap.decide(kind: .tired, open: openLater) == .add)

    check("окно исправления короче окна захода",
          MoodRules.undoWindow < MoodRules.checkInWindow)

    // Часы могли перевести назад, а файл — поправить руками. Отметка из
    // будущего не должна выглядеть как «сделана только что».
    let ahead = [moodEntry(.tired, 2026, 8, 12, 15, 0),
                 moodEntry(.quit, 2026, 8, 12, 18, 0)]
    let openNow = MoodRules.openForUndo(ahead, now: moment(2026, 8, 12, 15, 1))
    check("отметка из будущего не считается выделенной",
          openNow.map(\.kind) == [.tired], "получено \(openNow.map(\.kind.rawValue))")

    // Повтор попадает в число отметок, но не удваивает тяжесть дня:
    // состояние-то одно.
    let repeated = [moodEntry(.tired, 2026, 8, 12, 15, 0),
                    moodEntry(.tired, 2026, 8, 12, 15, 20)]
    let stats = MoodStats.build(entries: repeated, now: moment(2026, 8, 12, 18, 0),
                               window: .week, calendar: moodCalendar)
    check("повтор считается в отметках", stats.marks == 2)
    check("повтор не удваивает вес состояния", stats.checkIns.count == 1)
    check("индекс от повтора не проседает", nearly(stats.index ?? 0, 25),
          "получено \(stats.index ?? -1)")

    // А через полчаса это уже другой заход: человек вернулся и отметился снова.
    let farApart = [moodEntry(.tired, 2026, 8, 12, 12, 0),
                    moodEntry(.tired, 2026, 8, 12, 17, 0)]
    check("отметки через пять часов — два захода",
          MoodStats.groupIntoCheckIns(farApart).count == 2)
}

// MARK: - Настроение: окна и разрезы

do {
    let now = moment(2026, 8, 12, 18, 0)
    let entries = [
        moodEntry(.good, 2026, 6, 1, 12, 0),        // 72 дня назад — вне обоих окон
        moodEntry(.flow, 2026, 7, 1, 12, 0),        // 42 дня назад — предыдущее окно месяца
        moodEntry(.quit, 2026, 7, 20, 16, 0),       // 23 дня назад
        moodEntry(.tired, 2026, 8, 10, 17, 0),      // 2 дня назад
        moodEntry(.good, 2026, 8, 12, 11, 0)
    ]

    let week = MoodStats.build(entries: entries, now: now, window: .week, calendar: moodCalendar)
    check("в окно недели попали две отметки", week.marks == 2, "получено \(week.marks)")
    check("индекс недели — среднее 25 и 75", nearly(week.index ?? 0, 50))

    let month = MoodStats.build(entries: entries, now: now, window: .month, calendar: moodCalendar)
    check("в окно месяца попали три отметки", month.marks == 3, "получено \(month.marks)")
    check("предыдущее окно считается отдельно и берёт только своё",
          month.previousMarks == 1, "получено \(month.previousMarks)")
    check("индекс предыдущего окна считается по его отметкам",
          nearly(month.previousIndex ?? 0, 100), "получено \(month.previousIndex ?? -1)")

    let all = MoodStats.build(entries: entries, now: now, window: .all, calendar: moodCalendar)
    check("«всё время» берёт все отметки", all.marks == 5)
    check("дней с отметками — пять", all.daysWithMarks == 5)
    check("самое частое состояние — «всё хорошо»", all.distribution.first?.kind == .good)
    check("доля «всё хорошо» = 2 из 5", nearly(all.share(.good), 0.4))
}

do {
    // Разрез по дням недели на чистых данных: 10 августа 2026 — понедельник,
    // 11-е — вторник. Дни недели берутся из самой отметки, а не из настроек.
    let entries = [moodEntry(.tired, 2026, 8, 10, 17, 0), moodEntry(.good, 2026, 8, 11, 12, 0)]
    let stats = MoodStats.build(entries: entries, now: moment(2026, 8, 12, 18, 0),
                               window: .month, calendar: moodCalendar)
    let monday = stats.byWeekday.first { $0.label == "Пн" }
    let tuesday = stats.byWeekday.first { $0.label == "Вт" }
    check("понедельник виден в разрезе по дням недели", monday?.count == 1,
          "получено \(monday?.count ?? -1)")
    check("индекс понедельника — «устал»", nearly(monday?.index ?? 0, 25))
    check("индекс вторника — «всё хорошо»", nearly(tuesday?.index ?? 0, 75))
    check("день без отметок остаётся без индекса",
          stats.byWeekday.first { $0.label == "Сб" }?.index == nil)
    check("порядок дней недели начинается с понедельника",
          stats.byWeekday.map(\.label) == ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"])
}

do {
    // Усталость к вечеру: три отметки во второй половине смены из четырёх.
    let entries = [
        moodEntry(.tired, 2026, 8, 3, 17, 0),
        moodEntry(.tired, 2026, 8, 4, 18, 0),
        moodEntry(.tired, 2026, 8, 5, 16, 30),
        moodEntry(.tired, 2026, 8, 6, 10, 30)
    ]
    let stats = MoodStats.build(entries: entries, now: moment(2026, 8, 12, 18, 0),
                               window: .month, calendar: moodCalendar)
    let late = stats.lateShiftShare(.tired)
    check("усталость считается по доле смены", late.total == 4 && late.late == 3,
          "получено \(late.late) из \(late.total)")

    // Рабочие дни в окне приходят снаружи: статистика не должна сама решать,
    // какой день рабочий.
    let withWorkdays = MoodStats.build(entries: entries, now: moment(2026, 8, 12, 18, 0),
                                       window: .week, calendar: moodCalendar,
                                       isWorkday: { $0.day % 2 == 0 })
    check("рабочие дни окна считаются по переданному правилу",
          (withWorkdays.workdaysInWindow ?? 0) > 0)
}

// MARK: - Настроение: выводы

do {
    let now = moment(2026, 8, 12, 18, 0)

    // Пусто — и вывод об этом, а не выдуманная тенденция.
    let empty = MoodStats.build(entries: [], now: now, window: .month, calendar: moodCalendar)
    let emptyInsights = MoodInsights.build(empty)
    check("на пустых данных один вывод", emptyInsights.count == 1)
    check("пустые данные не дают уверенных выводов",
          emptyInsights[0].text.contains("Отметок за этот период нет"))

    // Три отметки — это ещё не закономерность, и приложение так и говорит.
    let thin = MoodStats.build(entries: [moodEntry(.tired, 2026, 8, 10, 17, 0),
                                        moodEntry(.tired, 2026, 8, 11, 17, 0)],
                               now: now, window: .month, calendar: moodCalendar)
    check("двух отметок мало для выводов", thin.isConclusive == false)
    check("о нехватке данных сказано прямо",
          MoodInsights.build(thin).contains { $0.text.contains("мало данных") })

    // Шесть «не хочу здесь работать» за месяц — это уже тревога, а не настроение.
    var quitting: [MoodEntry] = []
    for day in [3, 4, 5, 6, 7, 10] { quitting.append(moodEntry(.quit, 2026, 8, day, 17, 0)) }
    let quitStats = MoodStats.build(entries: quitting, now: now, window: .month, calendar: moodCalendar)
    let quitInsights = MoodInsights.build(quitStats)
    check("серия «хочу уволиться» поднимает тревогу",
          quitInsights.contains { $0.level == .alarm && $0.text.contains("Хочу уволиться") })
    check("тяжёлый фон назван тяжёлым",
          quitInsights.contains { $0.text.contains("Настроение тяжёлое") })
    check("серия тяжёлых дней найдена", quitStats.worstStreak >= 3,
          "получено \(quitStats.worstStreak)")

    // «Скорее бы домой» значит разное утром и вечером — вывод должен различать.
    var morning: [MoodEntry] = []
    for day in [3, 4, 5, 6, 10] { morning.append(moodEntry(.homeSoon, 2026, 8, day, 11, 0)) }
    let morningInsights = MoodInsights.build(
        MoodStats.build(entries: morning, now: now, window: .month, calendar: moodCalendar))
    check("ожидание вечера с утра — повод для внимания",
          morningInsights.contains { $0.level == .attention && $0.text.contains("ждёте с утра") })

    var evening: [MoodEntry] = []
    for day in [3, 4, 5, 6, 10] { evening.append(moodEntry(.homeSoon, 2026, 8, day, 18, 0)) }
    let eveningInsights = MoodInsights.build(
        MoodStats.build(entries: evening, now: now, window: .month, calendar: moodCalendar))
    check("ожидание вечера к вечеру — не беда",
          eveningInsights.contains { $0.text.contains("обычный конец рабочего дня") })
    // Тревога на этих данных всё равно будет — месяц одних жалоб тяжёлый сам
    // по себе. Проверяем ровно то, что проверяем: вывода про утро тут нет.
    check("вечернее ожидание не даёт вывода про утро",
          !eveningInsights.contains { $0.text.contains("ждёте с утра") })

    // Хороший фон не должен превращаться в тревогу.
    var fine: [MoodEntry] = []
    for day in [3, 4, 5, 6, 7, 10] { fine.append(moodEntry(.good, 2026, 8, day, 12, 0)) }
    let fineStats = MoodStats.build(entries: fine, now: now, window: .month, calendar: moodCalendar)
    let fineInsights = MoodInsights.build(fineStats)
    check("на хорошем фоне тревог нет", fineInsights.allSatisfy { $0.level != .alarm })
    check("хороший фон назван хорошим",
          fineInsights.contains { $0.text.contains("в целом хорошее") })
    check("серии тяжёлых дней нет", fineStats.worstStreak == 0)
}

// MARK: - Настроение: файл

do {
    let entries = [moodEntry(.tired, 2026, 8, 10, 17, 0), moodEntry(.good, 2026, 8, 11, 12, 0)]
    let data = try! MoodLog.encode(entries)
    let back = MoodLog.decode(data)
    check("журнал настроения переживает запись и чтение", back.entries.count == 2)
    check("состояния не путаются при чтении",
          back.entries.map(\.kind) == [.tired, .good])
    check("доля смены сохраняется", back.entries[0].shiftFraction != nil)

    // Одна испорченная запись не должна уносить остальные: файл живёт годами.
    let mixed = """
    {"version":1,"entries":[
      {"at":"2026-08-10T14:00:00Z","kind":"tired","day":{"year":2026,"month":8,"day":10},
       "minuteOfDay":1020,"weekday":2,"phase":"working"},
      {"at":"не дата","kind":"tired"},
      {"at":"2026-08-11T09:00:00Z","kind":"такого состояния нет"},
      {"at":"2026-08-11T09:00:00Z","kind":"good"}
    ]}
    """
    let salvaged = MoodLog.decode(Data(mixed.utf8))
    check("испорченные записи пропускаются по одной", salvaged.entries.count == 2,
          "получено \(salvaged.entries.count)")
    check("пропущенные записи посчитаны", salvaged.skipped == 2, "получено \(salvaged.skipped)")
    check("запись без части полей восстанавливается из момента",
          salvaged.entries.last?.phase == .unknown)

    check("мусор вместо файла не роняет разбор", MoodLog.decode(Data("{[nonsense".utf8)).entries.isEmpty)
}

// MARK: - Настроение: настройки

do {
    check("опрос включён по умолчанию", AppSettings().moodEnabled)

    // Файл от версии без опроса не должен выключать его молча.
    let old = """
    {"schemaVersion":2,"monthlyAmount":100000,"currencyCode":"RUB"}
    """
    let decoded = try! JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
    check("старый файл настроек оставляет опрос включённым", decoded.moodEnabled)
    check("старый файл настроек не теряет оклад", nearly(decoded.monthlyAmount, 100_000))
}

// MARK: - Счётчик: что показывать в меню-баре

do {
    check("по умолчанию счётчик показывает день", AppSettings().menuBarTotal == .day)
    check("по умолчанию вне рабочего дня суммы нет", AppSettings().idleShowsAmount == false)

    // Файл предыдущей версии: одно поле «вне рабочего дня показывать» отвечало
    // сразу за два вопроса. Переезд не должен ни потерять выбор, ни сбросить
    // остальные настройки.
    func migrated(_ idle: String) -> AppSettings? {
        decodeSettings("{\"schemaVersion\":2,\"monthlyAmount\":100000,\"idleDisplay\":\"\(idle)\"}")
    }

    check("«только значок» переехал в «вечером суммы нет»",
          migrated("icon")?.idleShowsAmount == false)
    check("«только значок» основной выбор не трогает",
          migrated("icon")?.menuBarTotal == .day)
    check("«итог дня» переехал в «за день» плюс «показывать вечером»",
          migrated("dayTotal")?.menuBarTotal == .day && migrated("dayTotal")?.idleShowsAmount == true)
    check("«итог месяца» переехал в «за месяц»",
          migrated("monthTotal")?.menuBarTotal == .month && migrated("monthTotal")?.idleShowsAmount == true)
    check("оклад при переезде не потерялся",
          nearly(migrated("monthTotal")?.monthlyAmount ?? 0, 100_000))

    // Файл уже нового формата: старое поле в нём не должно перебивать то,
    // что человек выбрал после обновления.
    let modern = decodeSettings("{\"schemaVersion\":3,\"menuBarTotal\":\"month\",\"idleDisplay\":\"dayTotal\"}")
    check("в новом файле старое поле выбор не перебивает", modern?.menuBarTotal == .month)
    check("в новом файле старое поле не включает сумму вечером",
          modern?.idleShowsAmount == false)
}

// MARK: - Настроение: новые состояния

do {
    check("состояний десять", MoodKind.allCases.count == 10,
          "получено \(MoodKind.allCases.count)")
    check("«прекрасно» — верх шкалы", nearly(MoodKind.great.index, 100))
    check("«злюсь» весит как тревога", nearly(MoodKind.angry.index, MoodKind.nervous.index))
    check("злость и тревога разведены по осям", MoodKind.angry.axis != MoodKind.nervous.axis)
    check("«прекрасно» и «всё хорошо» на одной оси", MoodKind.great.axis == MoodKind.good.axis)
    check("«прекрасно» тяжелее «всё хорошо»", MoodKind.great.index > MoodKind.good.index)
    check("эмодзи у всех разные",
          Set(MoodKind.allCases.map(\.emoji)).count == MoodKind.allCases.count)
    check("подписи у всех разные",
          Set(MoodKind.allCases.map(\.short)).count == MoodKind.allCases.count)

    // Ключ в файле — не подпись: переименование не должно стирать историю.
    check("ключ «тревожно» остался прежним", MoodKind.nervous.rawValue == "nervous")
    check("ключ «хочу уволиться» остался прежним", MoodKind.quit.rawValue == "quit")
    check("подпись «тревожно» обновлена", MoodKind.nervous.short == "Тревожно")
    check("подпись «хочу уволиться» обновлена", MoodKind.quit.short == "Хочу уволиться")

    let old = "{\"version\":1,\"entries\":[{\"at\":\"2026-08-10T14:00:00Z\",\"kind\":\"nervous\"}]}"
    check("отметка прежней версии читается и после переименования",
          MoodLog.decode(Data(old.utf8)).entries.first?.kind == .nervous)
}

// MARK: - Напоминания: время внутри смены

do {
    let start = moment(2026, 8, 12, 10, 0)
    let end = moment(2026, 8, 12, 19, 0)
    let times = MoodReminderRules.times(start: start, end: end)

    check("три напоминания за смену", times.count == MoodReminderRules.perDay,
          "получено \(times.map { Fmt.clock($0, timeZone: moscow) })")
    check("первое — через час после начала", times.first == moment(2026, 8, 12, 11, 0),
          "получено \(times.first.map { Fmt.clock($0, timeZone: moscow) } ?? "нет")")
    check("второе — в середине смены", times[1] == moment(2026, 8, 12, 14, 30))
    check("третье — за 45 минут до конца", times[2] == moment(2026, 8, 12, 18, 15))
    check("время круглое, кратное пяти минутам",
          times.allSatisfy { Int($0.timeIntervalSince1970) % 300 == 0 })
    check("напоминания не выходят за границы смены",
          times.allSatisfy { $0 > start && $0 < end })

    // Короткая смена: три точки не должны слипнуться в одну.
    let short = MoodReminderRules.times(start: moment(2026, 8, 12, 10, 0),
                                        end: moment(2026, 8, 12, 12, 0))
    check("на короткой смене напоминания разнесены",
          zip(short, short.dropFirst()).allSatisfy {
              $1.timeIntervalSince($0) >= MoodReminderRules.minimumGap
          },
          "получено \(short.map { Fmt.clock($0, timeZone: moscow) })")
    check("на короткой смене их не больше трёх", short.count <= MoodReminderRules.perDay)

    // Ночная смена переходит через полночь — напоминания едут вместе с ней.
    let night = MoodReminderRules.times(start: moment(2026, 8, 12, 22, 0),
                                        end: moment(2026, 8, 13, 6, 0))
    check("на ночной смене напоминания уезжают за полночь",
          night.contains { $0 > moment(2026, 8, 13, 0, 0) },
          "получено \(night.map { Fmt.clock($0, timeZone: moscow) })")
}

// MARK: - Напоминания: план на неделю

do {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = moscow

    var s = baseSettings()
    s.ranges = [DayRange(from: DayStamp(year: 2026, month: 8, day: 14),
                         to: DayStamp(year: 2026, month: 8, day: 14), kind: .vacation)]
    let e = Engine(settings: s)

    // Ровно то же правило, по которому расписание строит модель.
    func shift(_ day: DayStamp) -> (start: Date, end: Date)? {
        guard e.state(of: day, now: day.startOfDay(in: calendar)).isWorkday else { return nil }
        return e.shift(for: day)
    }

    let now = moment(2026, 8, 12, 9, 0)          // среда, смена ещё не началась
    let plan = MoodReminderRules.plan(now: now, calendar: calendar, shift: shift, marks: [])

    check("план не пустой", !plan.isEmpty)
    check("прошедших моментов в плане нет", plan.allSatisfy { $0 > now })
    check("план отсортирован по времени", plan == plan.sorted())

    let days = Set(plan.map { DayStamp($0, in: calendar) })
    check("на сегодня запланированы все три",
          plan.filter { DayStamp($0, in: calendar) == DayStamp(year: 2026, month: 8, day: 12) }.count == 3)
    check("суббота в план не попала", !days.contains(DayStamp(year: 2026, month: 8, day: 15)))
    check("воскресенье в план не попало", !days.contains(DayStamp(year: 2026, month: 8, day: 16)))
    check("отпускной день пропущен", !days.contains(DayStamp(year: 2026, month: 8, day: 14)),
          "дни плана: \(days.map(Fmt.day).sorted())")

    // Середина смены: то, что уже прошло, в план не попадает.
    let midday = MoodReminderRules.plan(now: moment(2026, 8, 12, 15, 0),
                                        calendar: calendar, shift: shift, marks: [])
    check("на сегодня осталось одно напоминание",
          midday.filter { DayStamp($0, in: calendar) == DayStamp(year: 2026, month: 8, day: 12) }.count == 1,
          "получено \(midday.prefix(3).map { Fmt.clock($0, timeZone: moscow) })")

    // Свежая отметка снимает ближайшее: человек только что ответил на этот вопрос.
    let justMarked = MoodReminderRules.plan(now: now, calendar: calendar, shift: shift,
                                            marks: [moment(2026, 8, 12, 10, 50)])
    check("свежая отметка снимает ближайшее напоминание",
          justMarked.count == plan.count - 1,
          "получено \(justMarked.count) против \(plan.count)")
    check("остальные напоминания остаются",
          justMarked.contains(moment(2026, 8, 12, 14, 30)))

    let old = MoodReminderRules.plan(now: now, calendar: calendar, shift: shift,
                                     marks: [moment(2026, 8, 10, 12, 0)])
    check("старая отметка на план не влияет", old.count == plan.count)

    // Никаких рабочих дней впереди — и напоминать не о чем.
    var fired = baseSettings()
    fired.hasEmploymentEnd = true
    fired.employmentEnd = DayStamp(year: 2026, month: 8, day: 11)
    let afterEnd = Engine(settings: fired)
    let empty = MoodReminderRules.plan(now: now, calendar: calendar, shift: { day in
        guard afterEnd.state(of: day, now: day.startOfDay(in: calendar)).isWorkday else { return nil }
        return afterEnd.shift(for: day)
    }, marks: [])
    check("после увольнения напоминаний нет", empty.isEmpty, "получено \(empty.count)")
}

// MARK: - Напоминания: настройки

do {
    check("напоминания включены по умолчанию", AppSettings().moodRemindersEnabled)

    // Файл от версии без напоминаний не должен выключать их молча.
    let old = decodeSettings("{\"schemaVersion\":2,\"monthlyAmount\":100000}")
    check("старый файл оставляет напоминания включёнными", old?.moodRemindersEnabled == true)
    check("горизонт планирования — неделя", MoodReminderRules.horizonDays == 7)
}

// MARK: - Напоминания: вердикт о разрешении

do {
    func facts(_ authorization: ReminderSettingsFacts.Authorization,
               alerts: Bool = true, center: Bool = true) -> ReminderSettingsFacts {
        ReminderSettingsFacts(authorization: authorization,
                              alertsShown: alerts, keptInNotificationCenter: center)
    }

    check("не спрашивали — так и говорим",
          ReminderAccessRules.verdict(facts(.notDetermined)) == .notAsked)
    check("запрет системы — запрет",
          ReminderAccessRules.verdict(facts(.denied)) == .denied)
    check("разрешено с баннерами — всё хорошо",
          ReminderAccessRules.verdict(facts(.authorized)) == .granted)

    // Тот случай, из-за которого состояний пять: разрешение есть, а увидеть
    // напоминание нельзя. Молчать об этом — обещать то, чего не будет.
    check("разрешено, но баннеры выключены — отдельное состояние",
          ReminderAccessRules.verdict(facts(.authorized, alerts: false)) == .silenced)
    check("выключенный Центр сам по себе разрешения не отменяет",
          ReminderAccessRules.verdict(facts(.authorized, center: false)) == .granted)

    check("разрешение и молчание доставку допускают",
          ReminderAccess.granted.allowsDelivery && ReminderAccess.silenced.allowsDelivery)
    check("запрет, отсутствие бандла и неспрошенное — не допускают",
          !ReminderAccess.denied.allowsDelivery
          && !ReminderAccess.unavailable.allowsDelivery
          && !ReminderAccess.notAsked.allowsDelivery)
}

// MARK: - Напоминания: итог проверки доставки

do {
    func verdict(access: ReminderAccess = .granted, keptInCenter: Bool = true,
                 rejection: String? = nil, found: Bool = true) -> ReminderTest {
        ReminderAccessRules.testVerdict(access: access, keptInCenter: keptInCenter,
                                        rejection: rejection, foundInCenter: found)
    }

    check("нашлось в Центре — доставлено", verdict() == .delivered)
    check("отказ системы важнее всего остального",
          verdict(rejection: "нельзя") == .rejected("нельзя"))
    check("при выключенных баннерах доставка тихая",
          verdict(access: .silenced) == .deliveredQuietly)
    check("приняли, но в Центре нет — потеря", verdict(found: false) == .lost)

    // Выключенный Центр уведомлений не хранит доставленное, и проверять там
    // нечего. Объявлять это потерей нельзя: уведомление как раз всплыло.
    check("выключенный Центр потерей не считается",
          verdict(keptInCenter: false, found: false) == .delivered)
    check("выключенный Центр вместе с баннерами — тихая доставка",
          verdict(access: .silenced, keptInCenter: false, found: false) == .deliveredQuietly)

    check("успехом считается только всплывшее уведомление",
          ReminderTest.delivered.isSuccess
          && !ReminderTest.deliveredQuietly.isSuccess
          && !ReminderTest.lost.isSuccess
          && !ReminderTest.rejected("нельзя").isSuccess)
    check("причина отказа попадает в текст результата",
          ReminderTest.rejected("Notifications are not allowed").message
              .contains("Notifications are not allowed"))
}

// MARK: - Напоминания: раскрытие панели вместо уведомления

do {
    check("по умолчанию напоминают уведомлением",
          AppSettings().moodReminderStyle == .notification)

    // Файл от версии без выбора способа не должен молча переводить человека
    // на раскрытие панели: он этого не просил.
    let old = """
    {"schemaVersion":3,"monthlyAmount":100000,"moodRemindersEnabled":true}
    """
    let decoded = try! JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
    check("старый файл настроек оставляет напоминания уведомлением",
          decoded.moodReminderStyle == .notification)

    let due = moment(2026, 8, 12, 15, 0)

    check("до срока ждём",
          PanelReminderRules.verdict(now: moment(2026, 8, 12, 14, 59), due: due) == .wait)
    check("срок подошёл — раскрываем",
          PanelReminderRules.verdict(now: due, due: due) == .open)
    check("минута опоздания раскрытию не мешает",
          PanelReminderRules.verdict(now: due.addingTimeInterval(60), due: due) == .open)
    check("на границе окна ещё раскрываем",
          PanelReminderRules.verdict(now: due.addingTimeInterval(PanelReminderRules.lateness),
                                     due: due) == .open)
    // Компьютер спал полдня — панель, выскочившая сейчас, спросит про «сейчас»,
    // а это уже совсем другое «сейчас».
    check("опоздание больше окна — срок пропускаем",
          PanelReminderRules.verdict(now: due.addingTimeInterval(PanelReminderRules.lateness + 1),
                                     due: due) == .skip)
    check("ждать нечего, когда срока нет",
          PanelReminderRules.verdict(now: due, due: nil) == .wait)

    let plan = [moment(2026, 8, 12, 11, 0), moment(2026, 8, 12, 15, 0), moment(2026, 8, 12, 18, 30)]
    check("следующий срок берётся ближайший из будущих",
          PanelReminderRules.next(after: moment(2026, 8, 12, 12, 0), in: plan)
              == moment(2026, 8, 12, 15, 0))
    check("наступивший срок следующим не считается",
          PanelReminderRules.next(after: moment(2026, 8, 12, 15, 0), in: plan)
              == moment(2026, 8, 12, 18, 30))
    check("после последнего срока следующего нет",
          PanelReminderRules.next(after: moment(2026, 8, 12, 19, 0), in: plan) == nil)
}

// MARK: - Копия для переезда

do {
    var settings = baseSettings()
    settings.monthlyAmount = 333_000
    settings.currencyCode = "MYR"
    settings.country = .malaysia
    settings.launchAtLogin = true
    settings.ranges = [DayRange(from: DayStamp(year: 2026, month: 7, day: 1),
                                to: DayStamp(year: 2026, month: 7, day: 14),
                                kind: .vacation)]
    let entries = [moodEntry(.tired, 2026, 8, 10, 17, 0),
                   moodEntry(.good, 2026, 8, 11, 12, 0),
                   moodEntry(.flow, 2026, 8, 12, 11, 30)]

    let file = Backup.make(settings: settings, entries: entries,
                           appVersion: "1.10", machine: "MacBook",
                           at: moment(2026, 8, 17, 14, 32))
    let restored = try! Backup.decode(try! Backup.encode(file))

    check("настройки переживают круг «выгрузил — загрузил» целиком",
          restored.settings == settings)
    check("отпуска в копии не теряются", restored.settings?.ranges.count == 1)
    check("история в копии не теряется", restored.mood?.entries.count == 3)
    check("состояния не путаются", restored.mood?.entries.map(\.kind) == [.tired, .good, .flow])
    check("идентификаторы отметок сохраняются — по ним ловятся дубли",
          restored.mood?.entries.map(\.id) == entries.map(\.id))
    check("в копии видно, чем и когда её сняли",
          restored.appVersion == "1.10" && restored.machine == "MacBook"
          && restored.exportedAt == moment(2026, 8, 17, 14, 32))

    let summary = restored.summary
    check("опись копии считает отметки", summary.entryCount == 3)
    check("опись копии знает период",
          summary.firstDay == DayStamp(year: 2026, month: 8, day: 10)
          && summary.lastDay == DayStamp(year: 2026, month: 8, day: 12))
    check("опись копии видит настройки", summary.hasSettings)
    // Окно подтверждения открывают и при включённом приватном режиме —
    // сумм в нём быть не должно.
    check("в описи копии нет сумм", !summary.text.contains("333"))

    // Сборка вне бандла номера версии не знает — в опись это должно попадать
    // словом, а не вопросительным знаком посреди фразы.
    let noVersion = Backup.make(settings: settings, entries: [], appVersion: "?",
                                machine: nil, at: moment(2026, 8, 17, 14, 32))
    check("неизвестная версия в описи названа словом",
          noVersion.summary.text.contains("версией неизвестной")
          && !noVersion.summary.text.contains("?"))
    check("опись пустой истории не выдумывает отметок",
          noVersion.summary.text.contains("история настроения пустая"))

    check("имя файла копии несёт дату",
          Backup.suggestedFileName(at: moment(2026, 8, 17, 14, 32)) == "salaryflow-2026-08-17.json")
}

// MARK: - Копия: что отвергается

func backupError(_ text: String) -> BackupError? {
    do {
        _ = try Backup.decode(Data(text.utf8))
        return nil
    } catch let error as BackupError {
        return error
    } catch {
        return nil
    }
}

do {
    check("не JSON отвергается", backupError("это вообще не файл") == .unreadable)
    check("JSON не той формы отвергается", backupError("[1,2,3]") == .unreadable)
    check("чужой JSON отвергается",
          backupError(#"{"format":1,"app":"SomethingElse","settings":{}}"#) == .foreign)
    check("копия из будущего отвергается с понятной причиной",
          backupError(#"{"format":9,"app":"SalaryFlow","settings":{}}"#) == .tooNew(9))
    check("копия без обеих секций отвергается",
          backupError(#"{"format":1,"app":"SalaryFlow"}"#) == .empty)
    // Срезанный номер формата — не повод отказывать файлу с настоящими данными.
    check("копия без номера формата читается как текущая",
          backupError(#"{"app":"SalaryFlow","settings":{"monthlyAmount":1}}"#) == nil)
    check("причина отказа объясняет, что делать",
          BackupError.tooNew(9).message.contains("Обновите"))

    // Копию можно править руками: испорченная секция должна терять себя,
    // а не уносить с собой вторую.
    let handEdited = """
    {"format":1,"app":"SalaryFlow","appVersion":"1.9","exportedAt":"2026-08-17T10:00:00Z",
     "settings":"тут был мусор",
     "mood":{"version":1,"entries":[{"at":"2026-08-11T09:00:00Z","kind":"good"}]}}
    """
    let salvaged = try! Backup.decode(Data(handEdited.utf8))
    check("испорченные настройки не уносят историю",
          salvaged.settings == nil && salvaged.mood?.entries.count == 1)
    check("опись честно говорит, что настроек в файле нет", !salvaged.summary.hasSettings)
}

// MARK: - Копия: старый формат настроек

do {
    // Копию могли снять сборкой полугодовой давности. Без дописывания её поля
    // приехали бы в прежнем смысле — молча, без единого признака.
    let old = """
    {"format":1,"app":"SalaryFlow","appVersion":"1.5","exportedAt":"2026-02-01T10:00:00Z",
     "settings":{"schemaVersion":1,"monthlyAmount":100000,"decimals":2,"moodEnabled":false}}
    """
    let file = try! Backup.decode(Data(old.utf8))
    let upgraded = SettingsStore.upgraded(file.settings!)
    check("копия прежнего формата дописывается до текущего",
          upgraded.schemaVersion == AppSettings.currentSchemaVersion)
    check("правило перевода применяется и к ввезённой копии", upgraded.decimals == 0)
    check("ввоз старой копии не теряет оклад", nearly(upgraded.monthlyAmount, 100_000))
    check("ввоз старой копии не теряет выключенный опрос", !upgraded.moodEnabled)
    check("настройки текущего формата дописывание не трогает",
          SettingsStore.upgraded(baseSettings()) == baseSettings())
}

// MARK: - Копия: объединение историй

do {
    let mine = [moodEntry(.tired, 2026, 8, 10, 17, 0), moodEntry(.good, 2026, 8, 11, 12, 0)]
    let theirs = [moodEntry(.flow, 2026, 8, 12, 11, 30)]

    let sameAgain = Backup.merged(existing: mine, incoming: mine)
    check("объединение с самим собой ничего не добавляет",
          sameAgain.added == 0 && sameAgain.entries.count == 2)

    let grown = Backup.merged(existing: mine, incoming: theirs + mine)
    check("объединение добавляет только новое", grown.added == 1 && grown.entries.count == 3)
    check("объединённая история лежит по возрастанию времени",
          grown.entries.map(\.at) == grown.entries.map(\.at).sorted())

    // Файл правили руками или пересобирали: id разошлись, а отметка та же.
    var reissued = mine[0]
    reissued.id = UUID()
    check("дубль с другим id ловится по моменту и состоянию",
          Backup.merged(existing: mine, incoming: [reissued]).added == 0)

    // «Устал» и «злюсь» в одну минуту — это два ответа, а не повтор одного.
    var otherKind = mine[0]
    otherKind.id = UUID()
    otherKind.kind = .angry
    check("другое состояние в тот же момент дублем не считается",
          Backup.merged(existing: mine, incoming: [otherKind]).added == 1)

    check("объединение с пустой историей отдаёт вторую целиком",
          Backup.merged(existing: [], incoming: mine).entries.count == 2)

    // Две полные истории — единственный способ перевалить за предел разом.
    let base = moment(2020, 1, 1, 12, 0)
    func bulk(_ count: Int, from start: Int) -> [MoodEntry] {
        (0..<count).map { i in
            let at = base.addingTimeInterval(Double((start + i) * 60))
            return MoodEntry(at: at, kind: .good, day: DayStamp(at, in: moodCalendar),
                             minuteOfDay: 0, weekday: 1, phase: .working)
        }
    }
    let overflow = Backup.merged(existing: bulk(MoodRules.maxEntries, from: 0),
                                 incoming: bulk(10, from: MoodRules.maxEntries))
    check("объединение не выходит за предел журнала",
          overflow.entries.count == MoodRules.maxEntries,
          "получено \(overflow.entries.count)")
    check("при переполнении уходят самые старые отметки",
          overflow.entries.first?.at == base.addingTimeInterval(600))

    check("перемешанная история выправляется по времени",
          MoodRules.normalized([theirs[0], mine[1], mine[0]]).map(\.at)
              == [mine[0], mine[1], theirs[0]].map(\.at))
}

// MARK: - Браузер по умолчанию

func browser(_ id: String, _ name: String) -> BrowserApp {
    BrowserApp(bundleID: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
}

do {
    let safari = browser("com.apple.Safari", "Safari")
    let chrome = browser("com.google.Chrome", "Google Chrome")
    let yandex = browser("ru.yandex.desktop.yandex-browser", "Yandex")
    let all = [yandex, safari, chrome]        // как их отдаёт система: текущий первым

    let plain = BrowserRules.panelList(installed: all, hidden: [], current: yandex.bundleID)
    check("порядок плашек — по имени, а не по пригодности",
          plain.map(\.name) == ["Google Chrome", "Safari", "Yandex"],
          "получено \(plain.map(\.name))")

    // Порядок не должен зависеть от того, кто сейчас по умолчанию: иначе
    // плашки менялись бы местами после каждого переключения, а нажимают
    // их по памяти.
    let afterSwitch = BrowserRules.panelList(installed: [chrome, safari, yandex],
                                             hidden: [], current: chrome.bundleID)
    check("переключение не переставляет плашки", afterSwitch.map(\.name) == plain.map(\.name))

    let filtered = BrowserRules.panelList(installed: all, hidden: [safari.bundleID],
                                          current: yandex.bundleID)
    check("снятый галочкой браузер в панель не идёт",
          filtered.map(\.bundleID) == [chrome.bundleID, yandex.bundleID])

    // Блок называется «Браузер по умолчанию» — не показать в нём текущий
    // значило бы соврать; заодно это спасает от пустого блока.
    let hiddenCurrent = BrowserRules.panelList(installed: all,
                                               hidden: [safari.bundleID, yandex.bundleID],
                                               current: yandex.bundleID)
    check("текущий браузер показывается даже со снятой галочкой",
          hiddenCurrent.map(\.bundleID) == [chrome.bundleID, yandex.bundleID])

    let everythingHidden = BrowserRules.panelList(
        installed: all,
        hidden: Set(all.map(\.bundleID)),
        current: chrome.bundleID)
    check("все галочки сняты — остаётся хотя бы текущий",
          everythingHidden.map(\.bundleID) == [chrome.bundleID])

    // Одна и та же программа может лежать в двух местах — например, копия
    // в «Загрузках» рядом с установленной.
    let twice = [chrome,
                 BrowserApp(bundleID: chrome.bundleID, name: "Google Chrome",
                            url: URL(fileURLWithPath: "/Users/me/Downloads/Google Chrome.app")),
                 safari]
    let unique = BrowserRules.panelList(installed: twice, hidden: [], current: chrome.bundleID)
    check("две копии одной программы дают одну плашку",
          unique.map(\.bundleID) == [chrome.bundleID, safari.bundleID],
          "получено \(unique.map(\.bundleID))")
    check("остаётся та копия, которую система назвала первой",
          unique.first?.url.path == "/Applications/Google Chrome.app")

    // Браузер по умолчанию мог быть удалён: система тогда не назовёт никого.
    let unknown = BrowserRules.panelList(installed: all, hidden: [], current: nil)
    check("без текущего браузера список не ломается", unknown.count == 3)
}

do {
    // Спрятанные браузеры едут в файле настроек и переживают его запись.
    var settings = baseSettings()
    settings.browserPickerEnabled = true
    settings.browserPickerHidden = ["com.apple.Safari"]
    guard let data = try? JSONEncoder().encode(settings),
          let restored = try? JSONDecoder().decode(AppSettings.self, from: data) else {
        check("настройки браузера переживают запись и чтение", false, "не удалось закодировать")
        exit(1)
    }
    check("настройки браузера переживают запись и чтение", restored == settings)

    // Файл, записанный до появления блока: оба поля берут значения по умолчанию,
    // и блок не возникает в панели сам собой.
    let old = decodeSettings("{ \"monthlyAmount\": 210000 }")
    check("старый файл не включает блок браузера", old?.browserPickerEnabled == false)
    check("старый файл не прячет браузеров", old?.browserPickerHidden.isEmpty == true)
}

// MARK: - Таймер: часы и подписи

do {
    check("остаток округляется вверх", TimerRules.clock(0.4) == "0:01", TimerRules.clock(0.4))
    check("ровные двадцать пять минут", TimerRules.clock(25 * 60) == "25:00")
    check("меньше минуты", TimerRules.clock(29) == "0:29")
    check("больше часа", TimerRules.clock(3900) == "1:05:00", TimerRules.clock(3900))
    check("ноль", TimerRules.clock(0) == "0:00")

    check("длительность в секундах", TimerRules.length(30) == "30 с")
    check("длительность в минутах", TimerRules.length(25 * 60) == "25 мин")
    check("ровный час без нулевых минут", TimerRules.length(3600) == "1 ч", TimerRules.length(3600))
    check("час с минутами", TimerRules.length(3900) == "1 ч 5 мин")
    check("полторы минуты", TimerRules.length(90) == "1 мин 30 с", TimerRules.length(90))
}

// MARK: - Таймер: ход, пауза и сон компьютера

do {
    let start = moment(2026, 8, 12, 14, 0)
    let run = TimerRules.start(TimerPreset(name: "Фокус", seconds: 25 * 60), now: start)

    check("срок = старт плюс длительность", run.deadline == start.addingTimeInterval(1500))

    if case .running(let left) = TimerRules.phase(run, now: start.addingTimeInterval(60)) {
        check("через минуту осталось 24", nearly(left, 1440))
    } else {
        check("через минуту таймер идёт", false)
    }

    check("в середине пути пройдена половина",
          nearly(TimerRules.progress(run, now: start.addingTimeInterval(750)), 0.5))

    // Последние три секунды — мигание, и ни секундой раньше.
    check("за 4 секунды до конца не мигает",
          !TimerRules.blinking(run, now: start.addingTimeInterval(1496)))
    check("за 3 секунды до конца мигает",
          TimerRules.blinking(run, now: start.addingTimeInterval(1497)))
    check("за секунду до конца мигает",
          TimerRules.blinking(run, now: start.addingTimeInterval(1499.5)))

    check("после срока показывается «Готово»",
          TimerRules.phase(run, now: start.addingTimeInterval(1501)) == .done)
    check("через три секунды «Готово» снимается",
          TimerRules.phase(run, now: start.addingTimeInterval(1503.5)) == .gone)

    // Компьютер спал полчаса: мигать и поздравлять задним числом нечего.
    check("проспанный таймер исчезает без мигания",
          TimerRules.phase(run, now: start.addingTimeInterval(3600)) == .gone)
    check("проспанный таймер не мигает",
          !TimerRules.blinking(run, now: start.addingTimeInterval(3600)))

    // Пауза держит остаток, сколько бы ни длилась: срок едет вместе с ней.
    let paused = TimerRules.paused(run, now: start.addingTimeInterval(300))
    check("пауза запомнила остаток", nearly(paused.pausedRemaining ?? 0, 1200))
    check("на паузе фаза не идёт",
          TimerRules.phase(paused, now: start.addingTimeInterval(3600)) == .paused(remaining: 1200))
    check("на паузе прогресс стоит",
          nearly(TimerRules.progress(paused, now: start.addingTimeInterval(3600)), 0.2))

    let resumed = TimerRules.resumed(paused, now: start.addingTimeInterval(3600))
    check("продолжение отсчитывает остаток заново",
          resumed.deadline == start.addingTimeInterval(3600 + 1200))
    check("продолженный таймер снова идёт", !resumed.isPaused)

    // Стрелка обходит круг за минуту и на паузе замирает.
    check("стрелка на старте вверху", nearly(TimerRules.handAngle(run, now: start), 0))
    check("через полминуты стрелка внизу",
          nearly(TimerRules.handAngle(run, now: start.addingTimeInterval(30)), 180))
    check("через минуту стрелка снова вверху",
          nearly(TimerRules.handAngle(run, now: start.addingTimeInterval(60)), 0))
    check("на паузе стрелка стоит",
          nearly(TimerRules.handAngle(paused, now: start.addingTimeInterval(3600)),
                 TimerRules.handAngle(paused, now: start.addingTimeInterval(310))))

    // Мигание: полсекунды горит, полсекунды нет.
    let tick = Date(timeIntervalSince1970: 1_000_000)
    check("мигание меняется каждые полсекунды",
          TimerRules.blinkOn(tick) != TimerRules.blinkOn(tick.addingTimeInterval(0.5)))
    check("мигание повторяется через секунду",
          TimerRules.blinkOn(tick) == TimerRules.blinkOn(tick.addingTimeInterval(1)))
}

// MARK: - Таймер: пресеты и итог дня

do {
    // Файл настроек могли править руками: ноль и сутки в таймер не проходят.
    check("слишком короткий приводится к минимуму",
          TimerPreset(name: "Ноль", seconds: 0).duration == TimeInterval(TimerRules.minSeconds))
    check("слишком длинный приводится к максимуму",
          TimerPreset(name: "Сутки", seconds: 86_400).duration == TimeInterval(TimerRules.maxSeconds))

    let messy = [
        TimerPreset(name: "  ", seconds: 60),
        TimerPreset(name: "Фокус", seconds: 0),
        TimerPreset(name: "Перерыв", seconds: 300),
        TimerPreset(name: "Лишний", seconds: 60),
    ]
    let fixed = TimerRules.normalized(messy)
    check("больше трёх таймеров не показывается", fixed.count == TimerRules.maxPresets)
    check("пустое имя заменяется", fixed[0].name == "Таймер")
    check("длительность приводится к границам", fixed[1].seconds == TimerRules.minSeconds)
    check("нормальный пресет не меняется", fixed[2] == messy[2])

    // Счёт запусков: по каждому таймеру отдельно и только за нужный день.
    // Общей суммы нет намеренно: шесть подходов по полминуты и один помидор
    // на двадцать пять минут дают «28 минут», и это ничего не значит.
    let today = DayStamp(year: 2026, month: 8, day: 12)
    let yesterday = DayStamp(year: 2026, month: 8, day: 11)
    let focus = UUID()
    let grip = UUID()
    let log = [
        TimerDone(preset: focus, at: moment(2026, 8, 11, 12, 0), day: yesterday, name: "Фокус", seconds: 1500),
        TimerDone(preset: focus, at: moment(2026, 8, 12, 11, 0), day: today, name: "Фокус", seconds: 1500),
        TimerDone(preset: grip, at: moment(2026, 8, 12, 12, 0), day: today, name: "Эспандер", seconds: 30),
        TimerDone(preset: grip, at: moment(2026, 8, 12, 12, 1), day: today, name: "Эспандер", seconds: 30),
    ]
    check("счёт считает только свой таймер и только свой день",
          TimerRules.launches(log, preset: grip, on: today) == 2,
          "\(TimerRules.launches(log, preset: grip, on: today))")
    check("вчерашние заходы в сегодняшний счёт не идут",
          TimerRules.launches(log, preset: focus, on: today) == 1)
    check("незнакомый таймер — ноль", TimerRules.launches(log, preset: UUID(), on: today) == 0)
    check("подсказка про запуски", TimerRules.launchNote(2) == "Сегодня запускали 2 раза",
          TimerRules.launchNote(2))
    check("подсказка, когда ещё не запускали",
          TimerRules.launchNote(0) == "Сегодня ещё не запускали")

    // Удалённый таймер уносит свой счёт: иначе файл копил бы историю того,
    // чего в панели давно нет.
    let kept = TimerRules.pruned(log, keeping: [focus])
    check("записи удалённого таймера выброшены", kept.count == 2)
    check("записи живого таймера остались", kept.allSatisfy { $0.preset == focus })

    // Журнал запусков переживает запись и чтение, а битая запись не уносит
    // с собой остальные.
    guard let logData = try? TimerLog.encode(log) else {
        check("журнал запусков кодируется", false)
        exit(1)
    }
    let restoredLog = TimerLog.decode(logData)
    check("журнал запусков переживает запись и чтение", restoredLog.entries == log)
    check("целых записей не потеряно", restoredLog.skipped == 0)

    let brokenLog = TimerLog.decode(Data(#"{"version":1,"entries":[{"at":"не дата"},{"preset":"\#(focus.uuidString)","at":"2026-08-12T09:00:00Z"}]}"#.utf8))
    check("битая запись выбрасывается по одной", brokenLog.entries.count == 1)
    check("выброшенные записи считаются", brokenLog.skipped == 1)

    // Настройки таймера переживают запись и чтение, а старый файл его не включает.
    var settings = baseSettings()
    settings.timerEnabled = true
    settings.timerDial = .hand
    settings.timerPresets = [TimerPreset(name: "Эспандер", seconds: 30)]
    guard let data = try? JSONEncoder().encode(settings),
          let restored = try? JSONDecoder().decode(AppSettings.self, from: data) else {
        check("настройки таймера переживают запись и чтение", false, "не удалось закодировать")
        exit(1)
    }
    check("настройки таймера переживают запись и чтение", restored == settings)

    let old = decodeSettings("{ \"monthlyAmount\": 210000 }")
    check("старый файл не включает таймер", old?.timerEnabled == false)
    check("у старого файла три заготовки", old?.timerPresets.count == 3)
    check("по умолчанию в строке меню кольцо", old?.timerDial == .ring)
}

// MARK: - Таймер: горячие клавиши

do {
    // Подпись собирается в том же порядке, в каком модификаторы пишет система.
    let full = TimerHotkey(keyCode: 25, command: true, option: true, control: true, shift: true)
    check("подпись сочетания", TimerRules.hotkeyName(full) == "⌃⌥⇧⌘9", TimerRules.hotkeyName(full))
    check("подпись без модификаторов — только клавиша",
          TimerRules.hotkeyName(TimerHotkey(keyCode: 3)) == "F")
    check("имя особой клавиши", TimerRules.keyName(49) == "Пробел")
    check("незнакомая клавиша называется кодом", TimerRules.keyName(200) == "клавиша 200")

    // Одного Shift мало: ⇧1 — это «!», и таймер запускался бы посреди набора.
    check("Shift сам по себе не годится", !TimerHotkey(keyCode: 18, shift: true).isValid)
    check("Cmd годится", TimerHotkey(keyCode: 18, command: true).isValid)
    check("Alt годится", TimerHotkey(keyCode: 18, option: true).isValid)
    check("Ctrl годится", TimerHotkey(keyCode: 18, control: true).isValid)

    // Назначение снимает сочетание с прежнего владельца: два таймера на одних
    // клавишах — это молчаливая поломка одного из них.
    let combo = TimerHotkey(keyCode: 18, command: true, option: true)
    let presets = [
        TimerPreset(name: "Фокус", seconds: 1500, hotkey: combo),
        TimerPreset(name: "Эспандер", seconds: 30),
    ]
    let moved = TimerRules.assigning(combo, to: presets[1].id, in: presets)
    check("сочетание переехало на новый таймер", moved[1].hotkey == combo)
    check("у прежнего владельца сочетание снято", moved[0].hotkey == nil)

    let cleared = TimerRules.assigning(nil, to: presets[0].id, in: presets)
    check("пустое назначение снимает сочетание", cleared[0].hotkey == nil)

    let refused = TimerRules.assigning(TimerHotkey(keyCode: 18, shift: true),
                                       to: presets[0].id, in: presets)
    check("негодное сочетание не назначается", refused[0].hotkey == nil)

    // Сочетание переживает файл настроек.
    var settings = baseSettings()
    settings.timerPresets = [TimerPreset(name: "Эспандер", seconds: 30, hotkey: combo)]
    guard let data = try? JSONEncoder().encode(settings),
          let restored = try? JSONDecoder().decode(AppSettings.self, from: data) else {
        check("сочетание переживает запись и чтение", false, "не удалось закодировать")
        exit(1)
    }
    check("сочетание переживает запись и чтение", restored.timerPresets.first?.hotkey == combo)

    // Файл, записанный до появления клавиш: поле просто пустое.
    let old = decodeSettings("{ \"monthlyAmount\": 210000 }")
    check("у старого файла сочетаний нет",
          old?.timerPresets.allSatisfy { $0.hotkey == nil } == true)
}

// MARK: - Таймер и напоминания о настроении

do {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = moscow
    let e = Engine(settings: baseSettings())

    func shift(_ day: DayStamp) -> (start: Date, end: Date)? {
        guard e.state(of: day, now: day.startOfDay(in: calendar)).isWorkday else { return nil }
        return e.shift(for: day)
    }

    let now = moment(2026, 8, 12, 10, 55)        // среда, до первого напоминания
    let plain = MoodReminderRules.plan(now: now, calendar: calendar, shift: shift, marks: [])
    check("без таймера первое напоминание в 11:00",
          plain.first == moment(2026, 8, 12, 11, 0),
          plain.first.map { Fmt.clock($0, timeZone: moscow) } ?? "нет")

    // Фокус-сессия до 11:19, тишина до 11:20 — напоминание уезжает на её конец.
    let focusEnd = moment(2026, 8, 12, 11, 20)
    let shifted = MoodReminderRules.plan(now: now, calendar: calendar, shift: shift,
                                         marks: [], focusEnd: focusEnd)
    check("напоминание внутри сессии сдвигается на её конец",
          shifted.first == focusEnd,
          shifted.first.map { Fmt.clock($0, timeZone: moscow) } ?? "нет")
    check("напоминание не пропадает совсем", shifted.count == plain.count)
    check("следующие напоминания стоят на своих местах",
          shifted.contains(moment(2026, 8, 12, 14, 30)))

    // Два напоминания, попавшие в одну сессию, складываются в одно:
    // звучать подряд им незачем.
    let long = MoodReminderRules.plan(now: now, calendar: calendar, shift: shift,
                                      marks: [], focusEnd: moment(2026, 8, 12, 14, 40))
    check("два напоминания в одной сессии складываются в одно",
          long.count == plain.count - 1, "получено \(long.count) против \(plain.count)")
    check("сложенное напоминание встаёт на конец сессии",
          long.first == moment(2026, 8, 12, 14, 40))

    // Сессия кончилась раньше первого напоминания — план не трогается.
    let early = MoodReminderRules.plan(now: now, calendar: calendar, shift: shift,
                                       marks: [], focusEnd: moment(2026, 8, 12, 10, 58))
    check("сессия до напоминания план не двигает", early == plain)
}

// MARK: - Итог

if failures.isEmpty {
    print("✅ Все проверки пройдены (\(checks))")
    exit(0)
} else {
    print("❌ Провалено \(failures.count) из \(checks):")
    failures.forEach { print("   \($0)") }
    exit(1)
}
