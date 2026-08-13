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
    check("положительных состояний ровно два",
          MoodKind.allCases.filter(\.isPositive).count == 2)
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
    check("серия «хочу уйти» поднимает тревогу",
          quitInsights.contains { $0.level == .alarm && $0.text.contains("Не хочу здесь работать") })
    check("тяжёлый фон назван тяжёлым",
          quitInsights.contains { $0.text.contains("Настроение тяжёлое") })
    check("серия тяжёлых дней найдена", quitStats.worstStreak >= 3,
          "получено \(quitStats.worstStreak)")

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

// MARK: - Итог

if failures.isEmpty {
    print("✅ Все проверки пройдены (\(checks))")
    exit(0)
} else {
    print("❌ Провалено \(failures.count) из \(checks):")
    failures.forEach { print("   \($0)") }
    exit(1)
}
