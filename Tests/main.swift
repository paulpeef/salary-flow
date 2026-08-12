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

// MARK: - Приватность: список процессов

do {
    let names = ProcessList.names()
    check("список процессов не пустой", names.count > 10, "получено \(names.count)")
    check("в списке есть launchd", names.contains { $0.lowercased() == "launchd" },
          "первые пять: \(names.prefix(5).joined(separator: ", "))")

    check("несуществующий процесс не находится",
          ProcessList.firstMatch(["ЗаведомоНетТакогоПроцесса12345"]) == nil)

    // Ищем по куску имени и без учёта регистра — как это делает монитор.
    check("совпадение по части имени и в другом регистре",
          ProcessList.firstMatch(["LAUNCHD"]) != nil)

    check("пустой список ничего не находит",
          ProcessList.firstMatch([]) == nil)

    // Дальше — на выдуманном списке процессов, чтобы результат не зависел
    // от того, что реально запущено на машине во время прогона.
    let fake = ["launchd", "Finder", "CptHost", "rudesktop_agent"]

    check("демонстрация экрана в Zoom ловится",
          ProcessList.firstMatch(AppSettings.defaultCaptureProcesses, in: fake) == "CptHost")

    check("фоновый агент удалёнки не считается захватом экрана",
          ProcessList.firstMatch(AppSettings.defaultCaptureProcesses,
                                 in: ["launchd", "rudesktop_agent", "AnyDesk"]) == nil,
          "в список по умолчанию попал постоянно работающий демон")

    check("процесс, работавший ещё до запуска приложения, игнорируется",
          ProcessList.firstMatch(AppSettings.defaultCaptureProcesses,
                                 in: fake, ignoring: ["CptHost"]) == nil)

    check("тот же процесс засчитывается, если его не было при старте",
          ProcessList.firstMatch(AppSettings.defaultCaptureProcesses,
                                 in: fake, ignoring: ["Finder"]) == "CptHost")

    check("свои процессы добавляются к встроенным",
          ProcessList.firstMatch(AppSettings.defaultCaptureProcesses + ["webex"],
                                 in: ["launchd", "WebexHelper"]) == "WebexHelper")

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
    { "monthlyAmount": 175000, "idleDisplay": "чтототакое", "decimals": "не число",
      "ranges": [ { "from": {"year":2026,"month":9,"day":1}, "to": {"year":2026,"month":9,"day":5} } ] }
    """
    let loaded = decodeSettings(broken)
    check("испорченное поле не уносит весь файл", loaded?.monthlyAmount == 175_000)
    check("испорченный перечислимый тип откатился к значению по умолчанию",
          loaded?.idleDisplay == .icon)
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
    check("текущая версия формата — вторая", AppSettings.currentSchemaVersion == 2)

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

// MARK: - Итог

if failures.isEmpty {
    print("✅ Все проверки пройдены (\(checks))")
    exit(0)
} else {
    print("❌ Провалено \(failures.count) из \(checks):")
    failures.forEach { print("   \($0)") }
    exit(1)
}
