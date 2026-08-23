import Foundation

/// Браузер, установленный на этой машине.
///
/// Ни иконок, ни системных вызовов здесь нет намеренно: правила показа должны
/// проверяться тестами, а тесты собираются без AppKit и без LaunchServices.
/// Всё, что спрашивается у системы, живёт в `BrowserSwitcher`.
struct BrowserApp: Identifiable, Equatable {
    /// Идентификатор бандла: им браузер опознаётся и в системе, и в настройках.
    /// Путь для этого не годится — программу переносят, а выбор должен остаться.
    var bundleID: String
    /// Имя, как его показывает Finder: «Google Chrome», «Yandex», «Safari».
    var name: String
    var url: URL

    var id: String { bundleID }
}

/// Правила показа списка браузеров. Отдельно от системы, потому что именно
/// в них живут решения, которые легко нарушить правкой интерфейса.
enum BrowserRules {
    /// Что показать в панели.
    ///
    /// Текущий браузер показывается всегда, даже если галочка с него снята:
    /// блок называется «Браузер по умолчанию», и не показать в нём именно тот,
    /// который сейчас по умолчанию, значит соврать. Заодно это спасает от
    /// пустого блока, если человек снял все галочки.
    static func panelList(installed: [BrowserApp], hidden: Set<String>, current: String?) -> [BrowserApp] {
        sorted(unique(installed)).filter { $0.bundleID == current || !hidden.contains($0.bundleID) }
    }

    /// Порядок — по имени, а не по «пригодности», в которой их отдаёт система.
    /// Системный порядок ставит текущий браузер первым, и плашки менялись бы
    /// местами после каждого переключения — а нажимают их по памяти, не глядя.
    static func sorted(_ list: [BrowserApp]) -> [BrowserApp] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Одна и та же программа может лежать в нескольких местах — в «Программах»
    /// и, скажем, в «Загрузках». Оставляем первую: система отдаёт копии
    /// в порядке пригодности к запуску, и первая — та, которую она выберет сама.
    static func unique(_ list: [BrowserApp]) -> [BrowserApp] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.bundleID).inserted }
    }
}
