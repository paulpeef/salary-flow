import Darwin
import Foundation
import os

/// Журнал приложения: файл, который можно открыть и прочитать через месяц,
/// плюс дублирование в системный лог для Console.app.
///
/// Отдельная задача журнала — отвечать на вопрос «оно вылетело или я сам его закрыл».
/// Для этого при старте кладётся файл-метка, а при штатном выходе снимается: если
/// при следующем запуске метка на месте, прошлый сеанс закончился аварийно.
enum Log {
    /// Каталог переопределяется переменной окружения, чтобы вспомогательные
    /// инструменты (превью, тесты) не писали в боевой журнал и, главное,
    /// не оставляли метку сеанса — иначе следующий запуск виджета принимал бы
    /// её за собственное аварийное завершение.
    static let directory: URL = {
        if let custom = ProcessInfo.processInfo.environment["SALARYFLOW_LOG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/SalaryFlow")
    }()

    static var fileURL: URL { directory.appendingPathComponent("salaryflow.log") }
    static var previousFileURL: URL { directory.appendingPathComponent("salaryflow.log.1") }
    static var markerURL: URL { directory.appendingPathComponent("session.running") }

    private static let queue = DispatchQueue(label: "io.github.paulpeef.salaryflow.log")
    private static let system = Logger(subsystem: "io.github.paulpeef.salaryflow", category: "app")
    private static let maxBytes = 1_000_000

    /// Отдельный дескриптор, открытый заранее: в обработчике сигнала нельзя
    /// пользоваться Foundation, там допустим только write(2).
    nonisolated(unsafe) private static var rawDescriptor: Int32 = -1

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: Запись

    static func info(_ message: String) { write("INFO ", message) }
    static func warn(_ message: String) { write("WARN ", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        bootstrap()
        let line = "\(stamp.string(from: Date())) [\(level)] \(message)\n"
        system.log("\(message, privacy: .public)")
        queue.async {
            prepareDirectory()
            rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private static func prepareDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    /// Одна ротация: журнал не должен расти бесконечно, но и терять историю
    /// целиком тоже не должен — предыдущий кусок остаётся рядом.
    private static func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        try? FileManager.default.removeItem(at: previousFileURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousFileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    static func recentLines(_ count: Int = 200) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }

    // MARK: Сеанс

    /// Шапка сеанса должна оказаться первой строкой файла, что бы ни записалось
    /// раньше всего. Поэтому её ставит не вызывающий код, а сам журнал —
    /// один раз, при первой же записи.
    nonisolated(unsafe) private static var didBootstrap = false

    static func bootstrap() {
        // Переезд с прежнего имени — раньше, чем откроется файл журнала.
        _ = Migration.performed
        var isFirstCall = false
        queue.sync {
            if !didBootstrap {
                didBootstrap = true
                isFirstCall = true
            }
        }
        // Вложенный вызов из startSession сюда уже не пройдёт — рекурсии нет.
        guard isFirstCall else { return }
        startSession(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            bundlePath: Bundle.main.bundlePath
        )
    }

    private static func startSession(version: String, bundlePath: String) {
        prepareDirectory()
        rawDescriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)

        let previous = try? String(contentsOf: markerURL, encoding: .utf8)
        write("INFO ", "─── запуск: версия \(version), \(bundlePath)")

        // Метку ставит и проверяет только настоящее приложение: у отдельного
        // исполняемого файла нет идентификатора пакета, и путать их нельзя.
        guard Bundle.main.bundleIdentifier != nil else { return }

        if let previous, !previous.isEmpty {
            warn("предыдущий сеанс не завершился штатно → \(previous.trimmingCharacters(in: .whitespacesAndNewlines))")
            if let report = latestCrashReport() {
                warn("похоже, есть отчёт системы о падении: \(report.path)")
            } else {
                warn("отчёта системы о падении нет — вероятно, процесс убили извне, а не он упал сам")
            }
        }

        let marker = "pid \(getpid()), старт \(stamp.string(from: Date())), версия \(version)"
        try? marker.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    static func endSession(reason: String) {
        info("─── штатное завершение: \(reason)")
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Свежий отчёт macOS о падении именно этого приложения, если он есть.
    private static func latestCrashReport() -> URL? {
        let reports = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: reports, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files
            .filter { $0.lastPathComponent.lowercased().hasPrefix("salaryflow") }
            .max { left, right in
                let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
    }

    // MARK: Падения

    static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            Log.error("НЕПЕРЕХВАЧЕННОЕ ИСКЛЮЧЕНИЕ: \(exception.name.rawValue) — \(exception.reason ?? "без причины")")
            Log.error("стек: \(exception.callStackSymbols.prefix(20).joined(separator: " | "))")
            // Даём очереди журнала успеть дописать до того, как процесс умрёт.
            Log.queue.sync {}
        }

        for signalNumber in [SIGSEGV, SIGABRT, SIGILL, SIGFPE, SIGBUS, SIGTRAP] {
            signal(signalNumber) { number in
                Log.writeFromSignalHandler("АВАРИЯ: сигнал \(number)")
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 32)
                let count = backtrace(&frames, Int32(frames.count))
                if Log.rawDescriptor >= 0 { backtrace_symbols_fd(&frames, count, Log.rawDescriptor) }
                signal(number, SIG_DFL)
                raise(number)
            }
        }

        // Пересборка и выключение системы шлют SIGTERM. Это не падение,
        // и в журнале это должно выглядеть именно так.
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber) { number in
                Log.writeFromSignalHandler("завершение по сигналу \(number) — обычно пересборка или выключение")
                unlink(Log.markerPath)
                _exit(0)
            }
        }
    }

    /// Путь к метке в виде C-строки: в обработчике сигнала строить его уже нельзя.
    nonisolated(unsafe) private static let markerPath: UnsafePointer<CChar> = {
        let path = Log.directory.appendingPathComponent("session.running").path
        return UnsafePointer(strdup(path))
    }()

    private static func writeFromSignalHandler(_ message: String) {
        guard rawDescriptor >= 0 else { return }
        let line = "\n*** \(message) ***\n"
        line.withCString { pointer in
            _ = Darwin.write(rawDescriptor, pointer, strlen(pointer))
        }
    }
}
