import Foundation

/// Переезд с прежнего имени SalaryDrop на Salary Flow.
///
/// Настройки и журнал лежат в каталогах, названных по имени приложения, а агент
/// автозапуска — по его идентификатору. Смена имени без переноса означала бы,
/// что пользователь снова открывает пустые настройки. Один раз это уже
/// случилось по другой причине, второго раза быть не должно.
///
/// Выполняется до того, как поднимется журнал и прочитаются настройки.
enum Migration {
    private static let oldName = "SalaryDrop"
    private static let oldAgentLabel = "dev.local.salarydrop"

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// Что сделали — чтобы записать в журнал, когда он уже поднимется.
    private(set) static var notes: [String] = []

    /// Переезд обязан случиться раньше всех, кто трогает эти каталоги.
    /// Полагаться на порядок инициализации нельзя: SwiftUI создаёт `AppModel`
    /// (а с ним и чтение настроек) до делегата приложения — проверено, настройки
    /// успевали создаться заново на новом месте, и переносить было уже нечего.
    /// `static let` ленив и потокобезопасен, поэтому выполнится ровно один раз,
    /// кто бы ни обратился первым.
    static let performed: Void = {
        Migration.run(newAppName: "SalaryFlow")
    }()

    static func run(newAppName: String) {
        moveDirectory(
            from: home.appendingPathComponent("Library/Application Support/\(oldName)"),
            to: home.appendingPathComponent("Library/Application Support/\(newAppName)"),
            what: "настройки", verb: "перенесены"
        )
        moveDirectory(
            from: home.appendingPathComponent("Library/Logs/\(oldName)"),
            to: home.appendingPathComponent("Library/Logs/\(newAppName)"),
            what: "журнал", verb: "перенесён"
        )
        removeOldLaunchAgent()
    }

    /// Переносим только если на новом месте пусто: повторный запуск не должен
    /// затирать уже накопленное новыми настройками.
    private static func moveDirectory(from old: URL, to new: URL, what: String, verb: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        guard !fm.fileExists(atPath: new.path) else {
            notes.append("\(what): каталог от SalaryDrop остался лежать рядом, новый уже был на месте")
            return
        }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            notes.append("\(what) \(verb) из SalaryDrop: \(new.path)")
        } catch {
            notes.append("не удалось перенести \(what) из SalaryDrop: \(error)")
        }
    }

    /// Старый агент указывает на исчезнувшее приложение и висел бы вечно.
    /// Новый зарегистрируется сам, если автозапуск включён в настройках.
    private static func removeOldLaunchAgent() {
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(oldAgentLabel).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())", plist.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        try? FileManager.default.removeItem(at: plist)
        notes.append("снят агент автозапуска от SalaryDrop")
    }
}
