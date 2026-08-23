import AppKit

/// Кто открывает ссылки — и переключение этого одним нажатием.
///
/// Зачем это в счётчике зарплаты: рабочий браузер и личный у одного человека
/// разные, а переключаются они в системных настройках — четыре экрана вглубь,
/// по нескольку раз в день. Панель счётчика и так открывается чаще всего
/// остального, и место для такого переключателя в ней уже есть.
///
/// Приложение ничего не меняет само: список читается, а переключение бывает
/// только по нажатию. Никаких вопросов при этом система не задаёт — про то,
/// какую схему она отдаёт, а какую нет, написано у `setDefault`.
@MainActor
final class BrowserSwitcher: ObservableObject {
    /// Всё, что умеет открывать https, — по одному на программу, в порядке имён.
    @Published private(set) var installed: [BrowserApp] = []
    /// Кто открывает ссылки прямо сейчас.
    @Published private(set) var currentID: String?
    /// На кого переключаемся. Система принимает запрос сразу, а пересчитывает
    /// погодя — плашка приглушена, пока смена не подтвердится чтением.
    @Published private(set) var switching: String?
    /// Короткая причина, по которой последняя попытка не удалась. Показывается
    /// на месте заголовка блока: отдельной строкой она меняла бы высоту панели.
    @Published private(set) var failure: String?

    /// Ссылка, по которой у системы спрашивают, кто её откроет. Домен взят
    /// из RFC 2606 — он для примеров и существует именно для такого.
    /// Никуда не ходим: вопрос задаётся LaunchServices, а не сети.
    private static let probe = URL(string: "https://example.com")!

    /// Превью подсовывает свой список: снимки интерфейса не должны зависеть
    /// от того, какие браузеры стоят на машине, где их сняли.
    private var overridden = false

    // MARK: Что стоит сейчас

    /// Спросить систему заново.
    ///
    /// Зовётся при каждом раскрытии панели: браузер по умолчанию меняют и мимо
    /// приложения — в системных настройках или самим браузером при запуске,
    /// — и показывать вчерашний ответ нельзя.
    func refresh() {
        guard !overridden else { return }
        let workspace = NSWorkspace.shared
        let found = workspace.urlsForApplications(toOpen: Self.probe).compactMap(Self.describe)
        installed = BrowserRules.sorted(BrowserRules.unique(found))
        // Спрашиваем про http: это та схема, которую переставляем сами,
        // и https ходит за ней следом.
        currentID = Self.handler(scheme: "http")
        // Панель раскрыли заново — прошлая попытка так или иначе позади,
        // держать плашку приглушённой больше нечем.
        switching = nil
    }

    /// Кто откроет ссылку с этой схемой.
    private static func handler(scheme: String) -> String? {
        guard let url = URL(string: "\(scheme)://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }

    private static func describe(_ url: URL) -> BrowserApp? {
        guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        // Имя берём у Finder: у Яндекс.Браузера в бандле лежит «Yandex»,
        // и это как раз то имя, под которым его знает владелец машины.
        return BrowserApp(bundleID: id,
                          name: FileManager.default.displayName(atPath: url.path),
                          url: url)
    }

    // MARK: Переключение

    /// Сделать этот браузер тем, кто открывает ссылки.
    ///
    /// Переставляется схема `http`, и это главное, что тут надо знать.
    /// Схему `https` система не отдаёт никому: и новый `NSWorkspace`,
    /// и старый `LaunchServices` отвечают на неё `OSStatus -54` — отказ
    /// в правах (проверено зондом 2026-08-23, macOS 26.5.2). Зато `http`
    /// меняется свободно и без всяких вопросов, а `https` переезжает следом
    /// сам: браузер по умолчанию система считает одной ролью, а не двумя
    /// схемами. Права для этого не нужны и не бывают — сторонним программам
    /// такого разрешения macOS не выдаёт вовсе.
    func setDefault(_ browser: BrowserApp) {
        guard browser.bundleID != currentID else { return }
        // Ответа на прошлый запрос ещё нет — второй поверх него ничего
        // не ускорит. Ожидание снимается ответом или ближайшим раскрытием
        // панели, так что залипнуть навсегда ему нечем.
        guard switching == nil else { return }
        guard !overridden else {           // превью: показать выбор, ничего не трогая
            currentID = browser.bundleID
            return
        }

        switching = browser.bundleID
        failure = nil
        Log.info("браузер по умолчанию: переключаю на \(browser.name)")

        Task { @MainActor in
            switch await Self.makeDefault(browser) {
            case .accepted(let how):
                Log.info("браузер по умолчанию: запрос принят (\(how))")
                await confirm(browser)
            case .refused(let reason):
                Log.warn("браузер по умолчанию: система отказала — \(reason)")
                failure = "Не удалось сменить"
                switching = nil
                refresh()
            }
        }
    }

    private enum Attempt {
        case accepted(String)
        case refused(String)
    }

    /// Сначала нынешний способ, потом прежний.
    ///
    /// На схеме `http` работает как раз нынешний: живая проверка из приложения
    /// (2026-08-23) дала «запрос принят (NSWorkspace)», и до запасного пути
    /// дело не дошло. Отказывает `NSWorkspace` только на `https`, а её мы
    /// и не трогаем. Запасной путь оставлен на случай, когда откажет и `http`:
    /// цена ему — одна строка отказа в журнале.
    private static func makeDefault(_ browser: BrowserApp) async -> Attempt {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: browser.url,
                                                               toOpenURLsWithScheme: "http")
            return .accepted("NSWorkspace")
        } catch {
            let status = setHandler(scheme: "http", bundleID: browser.bundleID)
            guard status != noErr else { return .accepted("LaunchServices") }
            return .refused("NSWorkspace — \(error.localizedDescription); LaunchServices — OSStatus \(status)")
        }
    }

    /// Прежний способ. В заголовках он помечен `API_TO_BE_DEPRECATED`:
    /// замена объявлена, но дата не назначена, поэтому компилятор молчит
    /// и вызов остаётся законным. Как только Apple назначит дату, здесь
    /// появится предупреждение — это и будет напоминанием проверить,
    /// не начал ли `NSWorkspace` пускать схему `http`.
    private static func setHandler(scheme: String, bundleID: String) -> OSStatus {
        LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)
    }

    /// Успех не объявляется, а дожидается.
    ///
    /// Система принимает запрос сразу, а пересчитывает погодя: зонд, прочитавший
    /// хозяина ссылок в ту же миллисекунду, увидел прежнего — и соврал. Поэтому
    /// спрашиваем несколько раз в течение трёх секунд. Столько же и висит
    /// приглушённой плашка, так что ожидание видно.
    private func confirm(_ browser: BrowserApp) async {
        for _ in 0..<15 {
            currentID = Self.handler(scheme: "http")
            if matches(browser) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        switching = nil

        guard matches(browser) else {
            failure = "Не удалось сменить"
            Log.warn("браузер по умолчанию: запрос приняли, но хозяин ссылок не сменился — остался \(currentID ?? "неизвестно кто")")
            return
        }

        failure = nil
        Log.info("браузер по умолчанию: теперь \(browser.name)")

        // Схему https мы не трогали — она должна переехать сама. Если однажды
        // не переедет, ссылки пойдут в прежний браузер, и понять это по одной
        // выделенной плашке будет невозможно: пусть остаётся след в журнале.
        let secure = Self.handler(scheme: "https")
        if secure?.caseInsensitiveCompare(browser.bundleID) != .orderedSame {
            Log.warn("браузер по умолчанию: https остался у \(secure ?? "никого") — ссылки https пойдут туда")
        }
    }

    /// Сравнение без учёта регистра: LaunchServices хранит идентификаторы
    /// так, как их записали при регистрации, и совпадение по буквам
    /// гарантировать нельзя.
    private func matches(_ browser: BrowserApp) -> Bool {
        currentID?.caseInsensitiveCompare(browser.bundleID) == .orderedSame
    }

    // MARK: Превью

    /// Подставить список для оффскрин-рендера. Работает только там, где нет
    /// бандла, — в самом приложении вызов ничего не делает.
    func overrideForPreview(installed: [BrowserApp], current: String?) {
        guard Bundle.main.bundleIdentifier == nil else { return }
        overridden = true
        self.installed = BrowserRules.sorted(installed)
        currentID = current
    }
}
