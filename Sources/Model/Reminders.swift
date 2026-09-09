import Foundation

// MARK: - Разрешение на уведомления

/// Что система думает про наши уведомления.
///
/// Состояний пять, а не два, потому что «разрешено» и «человек это увидит» —
/// разные вещи: уведомления можно разрешить и тут же выключить баннеры, и тогда
/// напоминание молча ляжет в Центр уведомлений. Такой случай надо показывать
/// отдельно, иначе приложение обещает то, чего не будет.
enum ReminderAccess: Equatable {
    /// Нет бандла — превью и тесты. Спрашивать не у кого и некому.
    case unavailable
    case notAsked
    /// Разрешено, баннер всплывёт.
    case granted
    /// Разрешено, но без баннера: напоминание не попадётся на глаза.
    case silenced
    case denied

    /// Дойдёт ли уведомление хоть куда-нибудь.
    var allowsDelivery: Bool { self == .granted || self == .silenced }

    /// Для журнала. Ответ системы обязан быть записан: именно потому, что его
    /// не писали, неверный вердикт трое суток нельзя было ни увидеть, ни
    /// опровергнуть — в журнале стояло только «разрешение не выдано».
    var title: String {
        switch self {
        case .unavailable: return "уведомления недоступны"
        case .notAsked: return "разрешение ещё не спрашивали"
        case .granted: return "разрешено"
        case .silenced: return "разрешено, но показ на экране выключен"
        case .denied: return "запрещено"
        }
    }
}

/// Ровно те поля системных настроек уведомлений, от которых зависит вердикт.
///
/// `UNNotificationSettings` приходит из другого потока, за границу актора его
/// тащить нельзя, и в тестах он не создаётся. Поэтому решение принимается не по
/// нему, а по трём простым значениям, снятым на месте, — и поэтому правило
/// проверяется тестами, а не только руками.
struct ReminderSettingsFacts: Equatable {
    enum Authorization: Equatable { case notDetermined, denied, authorized }

    var authorization: Authorization
    /// Баннеры на экране включены.
    var alertsShown: Bool
    /// Доставленное хранится в Центре уведомлений.
    var keptInNotificationCenter: Bool

    init(authorization: Authorization,
         alertsShown: Bool = true,
         keptInNotificationCenter: Bool = true) {
        self.authorization = authorization
        self.alertsShown = alertsShown
        self.keptInNotificationCenter = keptInNotificationCenter
    }
}

/// Итог проверки «дойдёт ли уведомление на самом деле».
enum ReminderTest: Equatable {
    /// Доставлено, и баннер должен был всплыть.
    case delivered
    /// Доставлено, но всплыть не могло: баннеры выключены.
    case deliveredQuietly
    /// Система приняла уведомление, а до Центра оно не дошло.
    case lost
    /// Система отказалась принимать.
    case rejected(String)

    /// Дошло ли до человека. По этому раскрашивается строка результата:
    /// «доставлено, но молча» — тоже неполадка, а не успех.
    var isSuccess: Bool { self == .delivered }

    var message: String {
        switch self {
        case .delivered:
            return "Проверочное уведомление доставлено — напоминания дойдут."
        case .deliveredQuietly:
            return "Доставлено, но баннера не будет: в настройках уведомлений выключен показ на экране."
        case .lost:
            return "Система приняла уведомление, но до Центра оно не дошло — возможно, включён режим «Не беспокоить»."
        case .rejected(let reason):
            return "Не удалось отправить: \(reason)"
        }
    }
}

/// Как из ответа системы получается вердикт.
///
/// Правило вынесено из `MoodReminder` отдельно и без единого обращения
/// к `UserNotifications`: именно здесь приложение однажды спутало «система
/// не приняла запрос» с «человек запретил» и трое суток показывало
/// предупреждение о запрете при выданном разрешении.
enum ReminderAccessRules {
    static func verdict(_ facts: ReminderSettingsFacts) -> ReminderAccess {
        switch facts.authorization {
        case .notDetermined: return .notAsked
        case .denied: return .denied
        case .authorized: return facts.alertsShown ? .granted : .silenced
        }
    }

    /// Что считать результатом проверки.
    ///
    /// - Parameters:
    ///   - access: вердикт, перечитанный у системы перед отправкой;
    ///   - keptInCenter: хранит ли система доставленное — если нет, отсутствие
    ///     уведомления в Центре ничего не доказывает и потерей не считается;
    ///   - rejection: причина, по которой система не приняла уведомление;
    ///   - foundInCenter: нашлось ли уведомление в Центре после отправки.
    static func testVerdict(access: ReminderAccess,
                            keptInCenter: Bool,
                            rejection: String?,
                            foundInCenter: Bool) -> ReminderTest {
        if let rejection { return .rejected(rejection) }
        // Проверить нечем — судим по настройкам, а не объявляем потерю.
        guard foundInCenter || keptInCenter else {
            return access == .silenced ? .deliveredQuietly : .delivered
        }
        guard foundInCenter else { return .lost }
        return access == .silenced ? .deliveredQuietly : .delivered
    }
}

/// Одно напоминание: во сколько спрашивать.
///
/// Своим типом, а не голым `TimeOfDay`, ради строки списка в настройках: ей
/// нужен неизменный опознаватель. Без него SwiftUI считает строку новой на
/// каждую правку времени — поле теряет фокус на первой же набранной цифре,
/// а две строки, сошедшиеся на одной минуте, схлопываются в одну прямо
/// под руками.
struct MoodReminderTime: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var time: TimeOfDay

    init(id: UUID = UUID(), _ time: TimeOfDay) {
        self.id = id
        self.time = time
    }

    init(hour: Int, minute: Int) {
        self.init(TimeOfDay(hour: hour, minute: minute))
    }

    /// Сравниваются только времена: опознаватель нужен списку в настройках,
    /// а «настройки изменились» он значить не должен. Иначе заново собранный
    /// список тех же времён считался бы правкой — и заставлял бы перекладывать
    /// системные сроки на ровном месте.
    static func == (lhs: MoodReminderTime, rhs: MoodReminderTime) -> Bool {
        lhs.time == rhs.time
    }

    func hash(into hasher: inout Hasher) { hasher.combine(time) }
}

/// Чем напоминать отметить настроение.
enum MoodReminderStyle: String, Codable, CaseIterable, Identifiable {
    /// Системное уведомление: баннер с быстрыми ответами. Дойдёт, даже если
    /// человек смотрит в другое приложение, но зависит от разрешения,
    /// от стиля показа и от «Не беспокоить».
    case notification
    /// Приложение само раскрывает панель в нужную минуту. Разрешения не нужно
    /// вовсе — и спросить не у кого, и запретить нечего, — но увидеть это можно
    /// только сидя за этим компьютером: панель ничего не оставляет после себя.
    case panel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notification: return "Уведомлением"
        case .panel: return "Раскрывать панель"
        }
    }
}

/// Когда панель раскрывается сама.
///
/// Правило отдельное и чистое по той же причине, по которой отдельно живёт
/// вердикт про разрешение: «раскрыть» и «промолчать» здесь решаются
/// на глазок легко, а проверяются только тестом.
enum PanelReminderRules {
    /// Насколько поздно панель ещё имеет смысл раскрывать.
    ///
    /// Компьютер мог спать, а человек — сидеть в другом приложении во весь
    /// экран. Панель, выскочившая через час после срока, — не напоминание,
    /// а неожиданность: спрашивает про «сейчас», а «сейчас» уже другое.
    static let lateness: TimeInterval = 5 * 60

    enum Verdict: Equatable {
        /// Срок ещё не подошёл.
        case wait
        case open
        /// Опоздали настолько, что раскрывать уже незачем.
        case skip
    }

    static func verdict(now: Date, due: Date?) -> Verdict {
        guard let due else { return .wait }
        guard now >= due else { return .wait }
        return now.timeIntervalSince(due) <= lateness ? .open : .skip
    }

    /// Ближайший ещё не наступивший срок из плана.
    static func next(after now: Date, in plan: [Date]) -> Date? {
        plan.first { $0 > now }
    }
}

/// Когда напоминать отметить настроение.
///
/// Времена задаёт человек, но не с чистого листа: у каждого свой рабочий день,
/// и напоминание в одиннадцать утра тому, кто работает ночью, бессмысленно.
/// Поэтому при включении три точки высчитываются из самой смены, а дальше
/// их можно двигать, добавлять и убирать. Всё остальное — какие дни рабочие
/// и где границы смены — приходит снаружи, из того же расчёта, что и деньги.
/// Здесь только правила, без обращения к системному времени: момент передаётся
/// параметром, и поэтому правила проверяются тестами.
enum MoodReminderRules {
    /// Три раза за смену по умолчанию: втянулся, середина, конец. Больше —
    /// назойливо, меньше — не видно, как настроение меняется внутри дня.
    static let perDay = 3

    /// Больше пяти напоминаний за день не поставить. Шестое — уже не
    /// напоминание, а дёрганье: опрос на одно нажатие, а не рабочая задача.
    static let maxPerDay = 5

    /// Время, к которому всё сводится, когда предложить нечего: смена
    /// не посчиталась, список пуст, час не разобрался. Полдень —
    /// единственное время суток, которое не выглядит случайным.
    static let noon = TimeOfDay(hour: 12, minute: 0)

    /// На сколько суток вперёд раскладываются напоминания. Система держит их
    /// у себя и покажет, даже если приложение в этот момент не работает;
    /// список перекладывается заново при правке настроек, при смене суток
    /// и после каждой отметки.
    static let horizonDays = 7

    /// Если отметка была незадолго до напоминания, оно не нужно: человек
    /// только что ответил ровно на этот вопрос.
    static let quietAfterMark: TimeInterval = 45 * 60

    /// Минимальный зазор между напоминаниями. Заодно спасает короткую смену:
    /// на двухчасовой три точки иначе слиплись бы в одну.
    static let minimumGap: TimeInterval = 5 * 60

    /// Три момента внутри одной смены.
    ///
    /// Первый — когда человек уже втянулся, но день ещё весь впереди; второй —
    /// ровно посередине; третий — незадолго до конца, пока день ещё можно
    /// оценить, а не вспоминать его завтра. Впритык к началу и к концу
    /// напоминание не ставится: в эти минуты человек занят приходом и уходом.
    static func times(start: Date, end: Date) -> [Date] {
        let span = end.timeIntervalSince(start)
        guard span >= minimumGap * 2 else { return [roundedToFiveMinutes(start + span / 2)] }

        // Не раньше 15% смены и не позже часа от начала; и не впритык к концу.
        let lead = min(60 * 60, span * 0.15)
        let tail = min(45 * 60, span * 0.10)
        let raw = [start + lead, start + span / 2, end - tail].map(roundedToFiveMinutes)

        var result: [Date] = []
        for moment in raw.sorted() {
            guard let last = result.last else {
                result.append(moment)
                continue
            }
            if moment.timeIntervalSince(last) >= minimumGap { result.append(moment) }
        }
        return result
    }

    /// Ближайшее круглое время: «напомню в 11:20» читается как решение,
    /// «в 11:17» — как сбой. Все нынешние часовые пояса кратны пяти минутам,
    /// поэтому округлять можно прямо по абсолютному времени.
    private static func roundedToFiveMinutes(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 300).rounded() * 300)
    }

    /// Времена по умолчанию — те самые три точки смены, только по стенным
    /// часам: их и подставляет включённый тумблер.
    ///
    /// Считается на условных сутках от начала эпохи, чтобы правило про точки
    /// внутри смены осталось одно. Вторая его копия, живущая в минутах
    /// от полуночи, рано или поздно разошлась бы с первой.
    static func defaultTimes(start: TimeOfDay, end: TimeOfDay) -> [TimeOfDay] {
        let midnight = Date(timeIntervalSince1970: 0)
        var endMinutes = end.minutesFromMidnight
        // Конец не позже начала — смена ночная и переходит через полночь.
        if endMinutes <= start.minutesFromMidnight { endMinutes += 24 * 60 }
        let moments = times(start: midnight + TimeInterval(start.minutesFromMidnight) * 60,
                            end: midnight + TimeInterval(endMinutes) * 60)
        let result = moments.map { moment -> TimeOfDay in
            let minutes = Int(moment.timeIntervalSince(midnight) / 60) % (24 * 60)
            return TimeOfDay(hour: minutes / 60, minute: minutes % 60)
        }
        // Пустым список быть не может: смена всегда даёт хотя бы одну точку.
        // Но если однажды сможет — лучше полдень, чем тишина под включённым
        // тумблером.
        return result.isEmpty ? [noon] : result
    }

    static func canAdd(_ times: [MoodReminderTime]) -> Bool { times.count < maxPerDay }

    /// Список, приведённый к правилам: по возрастанию времени и не длиннее пяти.
    ///
    /// Зовётся, когда строку добавили или убрали, но не когда правят время
    /// в самой строке: пересортировка на каждую набранную цифру уводила бы
    /// строку из-под курсора прямо во время правки.
    static func tidied(_ times: [MoodReminderTime]) -> [MoodReminderTime] {
        Array(times.sorted { $0.time.minutesFromMidnight < $1.time.minutesFromMidnight }
            .prefix(maxPerDay))
    }

    /// Время для новой строки: через час после самой поздней, а если день
    /// на этом кончился — первая свободная пятиминутка дальше по кругу.
    /// Час выбран, чтобы новое напоминание не встало впритык к соседнему.
    ///
    /// Первое напоминание в пустом списке — полдень: с него человеку понятнее
    /// всего двигать время в свою сторону.
    static func timeForNew(after times: [MoodReminderTime]) -> TimeOfDay {
        let taken = Set(times.map(\.time.minutesFromMidnight))
        let latest = times.map(\.time.minutesFromMidnight).max()
        let from = latest.map { $0 + 60 } ?? noon.minutesFromMidnight
        for step in 0..<(24 * 12) {
            let minutes = (from + step * 5) % (24 * 60)
            guard !taken.contains(minutes) else { continue }
            return TimeOfDay(hour: minutes / 60, minute: minutes % 60)
        }
        return noon
    }

    /// Тумблер и список времён — одна настройка, а не две.
    ///
    /// Включённые напоминания без единого времени — обещание, которого
    /// приложение не выполнит; выключенные с хвостом времён — мусор в файле.
    /// Правило одно на все входы: окно настроек, копия с другой машины,
    /// файл, поправленный руками.
    ///
    /// - Parameter fillEmpty: чем считать пустой список. Тумблер только что
    ///   включили или файл записан версией без выбора времени — значит надо
    ///   поставить времена по умолчанию. Человек удалил последнюю строку —
    ///   значит напоминаний больше нет, и тумблер гаснет следом.
    static func settled(enabled: Bool,
                        times: [MoodReminderTime],
                        fillEmpty: Bool,
                        defaults: [TimeOfDay]) -> (enabled: Bool, times: [MoodReminderTime]) {
        guard enabled else { return (false, []) }
        guard !times.isEmpty else {
            return fillEmpty ? (true, defaults.map { MoodReminderTime($0) }) : (false, [])
        }
        return (true, tidied(times))
    }

    /// Момент этого времени суток в этой смене.
    ///
    /// Отсчитывается от начала суток, в которые смена началась: время человек
    /// выбирает по стенным часам, а не относительно смены. Ночная смена —
    /// единственное исключение: время, попадающее в её вторую половину, уезжает
    /// на следующие сутки, иначе напоминание встало бы за двадцать часов
    /// до смены, к которой относится. Всё, что в смену так и не попало,
    /// остаётся на своих сутках: человек мог поставить напоминание и до неё.
    static func moment(of time: TimeOfDay,
                       in shift: (start: Date, end: Date),
                       calendar: Calendar) -> Date? {
        let midnight = calendar.startOfDay(for: shift.start)
        guard let plain = calendar.date(byAdding: .minute,
                                        value: time.minutesFromMidnight, to: midnight) else { return nil }
        guard plain < shift.start,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: plain),
              nextDay <= shift.end else { return plain }
        return nextDay
    }

    /// План на ближайшие дни. Нерабочие дни пропускаются целиком: в отпуске,
    /// в праздник и в выходной вопросов про работу быть не должно.
    ///
    /// - Parameters:
    ///   - times: во сколько напоминать — то, что стоит в настройках;
    ///   - shift: границы смены этого дня либо nil, если день нерабочий;
    ///   - marks: моменты уже сделанных отметок;
    ///   - focusEnd: конец идущей фокус-сессии, до которого напоминать нельзя.
    static func plan(now: Date,
                     calendar: Calendar,
                     times: [TimeOfDay],
                     shift: (DayStamp) -> (start: Date, end: Date)?,
                     marks: [Date],
                     focusEnd: Date? = nil) -> [Date] {
        guard !times.isEmpty else { return [] }
        var result: [Date] = []
        let today = calendar.startOfDay(for: now)
        for offset in 0..<horizonDays {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { break }
            guard let bounds = shift(DayStamp(date, in: calendar)) else { continue }
            for time in times {
                guard let moment = moment(of: time, in: bounds, calendar: calendar),
                      moment > now else { continue }
                let answeredJustBefore = marks.contains {
                    $0 <= moment && moment.timeIntervalSince($0) < quietAfterMark
                }
                if !answeredJustBefore { result.append(moment) }
            }
        }
        // Два одинаковых времени в настройках дают один и тот же момент,
        // а звучать ему дважды незачем.
        var seen = Set<Date>()
        return shifted(result.sorted().filter { seen.insert($0).inserted }, pastFocus: focusEnd)
    }

    /// Напоминание, попавшее в фокус-сессию, сдвигается на её конец.
    ///
    /// Раскрытая панель посреди помидора — ровно то, от чего таймер и
    /// защищает; уведомление посреди него не лучше. Пропускать напоминание
    /// совсем тоже нельзя: напоминаний за смену и так немного.
    ///
    /// Сдвинутые моменты складываются в один: двум напоминаниям, уехавшим
    /// на один и тот же конец сессии, незачем звучать подряд.
    private static func shifted(_ plan: [Date], pastFocus focusEnd: Date?) -> [Date] {
        guard let focusEnd else { return plan }
        var result: [Date] = []
        for moment in plan {
            let moved = moment <= focusEnd ? focusEnd : moment
            if let last = result.last, moved.timeIntervalSince(last) < minimumGap { continue }
            result.append(moved)
        }
        return result
    }
}
