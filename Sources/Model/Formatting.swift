import Foundation

/// Форматирование денег. Отдельный тип, потому что NumberFormatter дорогой:
/// на каждый тик его пересоздавать нельзя.
struct MoneyFormatter {
    private let formatter: NumberFormatter
    let decimals: Int

    init(settings: AppSettings, decimals: Int? = nil) {
        let d = decimals ?? settings.decimals
        self.decimals = d
        let f = NumberFormatter()
        f.numberStyle = .currency
        // Разделители пиним к русской локали: интерфейс русский, и «4 520,83 ₽»
        // не должно превращаться в «4,520.83 ₽» из-за системного языка.
        f.locale = Locale(identifier: "ru_RU")
        f.currencyCode = settings.currencyCode
        f.minimumFractionDigits = d
        f.maximumFractionDigits = d
        f.usesGroupingSeparator = true
        let trimmed = settings.customCurrencySymbol.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            f.currencySymbol = trimmed
        }
        formatter = f
    }

    func string(_ value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
    }
}

enum Fmt {
    /// «4 ч 32 мин», «12 мин», «48 с» — для остатка смены.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h) ч \(m) мин" }
        if m > 0 { return "\(m) мин" }
        return "\(s) с"
    }

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Название месяца в винительном падеже: «за август», «за сентябрь».
    static func monthName(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = timeZone
        f.dateFormat = "LLLL"
        return f.string(from: date)
    }

    static func day(_ stamp: DayStamp) -> String {
        String(format: "%02d.%02d.%04d", stamp.day, stamp.month, stamp.year)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// «14 дней», «21 день», «2 дня».
    static func days(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "\(n) день" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(n) дня" }
        return "\(n) дней"
    }
}

extension DayState {
    var title: String {
        switch self {
        case .notEmployed: return "Вне периода работы"
        case .weekend: return "Выходной"
        case .holiday: return "Праздник"
        case .paidLeave(let kind): return kind.title
        case .unpaid: return "День за свой счёт"
        case .beforeShift: return "Рабочий день ещё не начался"
        case .working: return "Идёт рабочий день"
        case .afterShift: return "Рабочий день окончен"
        }
    }

    var symbol: String {
        switch self {
        case .notEmployed: return "pause.circle"
        case .weekend: return "sun.max"
        case .holiday: return "party.popper"
        case .paidLeave(let kind): return kind.symbol
        case .unpaid: return "minus.circle"
        case .beforeShift: return "clock"
        case .working: return "drop.fill"
        case .afterShift: return "moon.zzz"
        }
    }
}
