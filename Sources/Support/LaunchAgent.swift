import Foundation

/// Автозапуск через LaunchAgent, а не через SMAppService: приложение
/// подписывается ad-hoc, и Service Management на такой подписи капризничает.
/// Плист лежит открытым текстом — его видно и можно удалить руками.
enum LaunchAgent {
    static let label = "io.github.paulpeef.salaryflow"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Что именно должен запускать агент: исполняемый файл внутри бандла.
    ///
    /// Раньше здесь был `/usr/bin/open -g <бандл>`, и macOS показывала
    /// уведомление «Приложение „open“ может работать в фоновом режиме» —
    /// система приписывала фоновую активность посреднику, а не приложению.
    /// Прямой путь к исполняемому файлу называет вещи своими именами.
    static var executablePath: String {
        Bundle.main.executableURL?.path
            ?? Bundle.main.bundlePath + "/Contents/MacOS/SalaryFlow"
    }

    /// Агент считается рабочим только если он есть и ведёт на текущее место
    /// приложения: после переезда в «Программы» старый плист указывает в пустоту.
    /// Плист от прежней версии (через `open`) сюда не подходит и будет переписан.
    static var isEnabled: Bool {
        registeredPath == executablePath
    }

    static var registeredPath: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return nil }
        return args.last
    }

    /// Лежит ли приложение в «Программах» — только оттуда автозапуск переживёт пересборку.
    static var appIsInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    static func setEnabled(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    private static func enable() {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            // Имя, под которым приложение показывается в «Объектах входа».
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? label]
        ]
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? data.write(to: plistURL, options: .atomic)
        launchctl(["bootout", domain, plistURL.path])   // на случай старой регистрации
        launchctl(["bootstrap", domain, plistURL.path])
    }

    private static func disable() {
        launchctl(["bootout", domain, plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static var domain: String { "gui/\(getuid())" }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
