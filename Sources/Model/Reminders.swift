import Foundation

/// Когда напоминать отметить настроение.
///
/// Времена не задаются руками и не зашиты в код: у каждого свой рабочий день,
/// и напоминание в одиннадцать утра человеку с ночной сменой бессмысленно.
/// Поэтому три точки высчитываются из самой смены, а всё остальное — какие дни
/// рабочие и где границы смены — приходит снаружи, из того же расчёта, что
/// и деньги. Здесь только правило, без обращения к системному времени:
/// момент передаётся параметром, и поэтому правило проверяется тестами.
enum MoodReminderRules {
    /// Три раза за смену: втянулся, середина, конец. Больше — назойливо,
    /// меньше — не видно, как настроение меняется внутри дня.
    static let perDay = 3

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

    /// План на ближайшие дни. Нерабочие дни пропускаются целиком: в отпуске,
    /// в праздник и в выходной вопросов про работу быть не должно.
    ///
    /// - Parameters:
    ///   - shift: границы смены этого дня либо nil, если день нерабочий;
    ///   - marks: моменты уже сделанных отметок.
    static func plan(now: Date,
                     calendar: Calendar,
                     shift: (DayStamp) -> (start: Date, end: Date)?,
                     marks: [Date]) -> [Date] {
        var result: [Date] = []
        let today = calendar.startOfDay(for: now)
        for offset in 0..<horizonDays {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { break }
            guard let bounds = shift(DayStamp(date, in: calendar)) else { continue }
            for moment in times(start: bounds.start, end: bounds.end) where moment > now {
                let answeredJustBefore = marks.contains {
                    $0 <= moment && moment.timeIntervalSince($0) < quietAfterMark
                }
                if !answeredJustBefore { result.append(moment) }
            }
        }
        return result.sorted()
    }
}
