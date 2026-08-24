import AppKit
import CoreGraphics
import Darwin
import Foundation

// Зонд захвата экрана.
//
// Приложение считает, что экран уходит на сторону, если работает процесс
// из списка подозреваемых. Для `screencapture` это верно — он живёт ровно
// столько, сколько делается снимок. Для Zoom неверно: `CptHost` поднимается
// при входе в конференцию и висит до её конца, показывают экран или нет.
//
// Зонд меряет то, чем «висит» отличается от «работает»: сколько процессор
// ест кандидат и есть ли у него окна на экране (рамка демонстрации и панель
// «вы показываете экран» — это его окна). Заодно считает значки в строке меню:
// система сама вешает туда индикатор записи экрана.
//
// Тестом это не проверить: цифры даёт живой Zoom, а не код.
//
// Запуск: ./Tools/captureprobe.sh

// Вывод должен идти построчно, даже когда его перенаправляют в файл:
// зонд обрывают по Ctrl+C, и накопленный в буфере хвост иначе пропадёт.
setvbuf(stdout, nil, _IOLBF, 0)

let needles = CommandLine.arguments.count > 1
    ? Array(CommandLine.arguments.dropFirst())
    : ["cpthost", "caphost", "aomhost", "zoom", "screencapture", "screensharingd", "teams", "webex", "krisp"]

// MARK: - Процессы

struct Proc { let pid: Int32; let name: String }

func runningProcesses() -> [Proc] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    size += size / 8
    let capacity = size / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
    let count = min(capacity, size / MemoryLayout<kinfo_proc>.stride)
    return (0..<count).compactMap { index in
        let comm = procs[index].kp_proc.p_comm
        let bytes = MemoryLayout.size(ofValue: comm)
        let name = withUnsafeBytes(of: comm) { buffer -> String in
            guard let base = buffer.baseAddress else { return "" }
            return base.withMemoryRebound(to: CChar.self, capacity: bytes) { String(cString: $0) }
        }
        return name.isEmpty ? nil : Proc(pid: procs[index].kp_proc.p_pid, name: name)
    }
}

/// Сколько процессорного времени процесс потратил за всю жизнь, в наносекундах.
func cpuTime(_ pid: Int32) -> UInt64? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
        }
    }
    guard result == 0 else { return nil }
    return info.ri_user_time + info.ri_system_time
}

// MARK: - Окна

struct WindowStats { var total = 0; var onscreen = 0; var details: [String] = [] }

func windows() -> ([Int32: WindowStats], Int) {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var byPID: [Int32: WindowStats] = [:]
    var statusItems = 0
    for window in list {
        let pid = Int32(window[kCGWindowOwnerPID as String] as? Int ?? -1)
        let onscreen = (window[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        var stats = byPID[pid] ?? WindowStats()
        stats.total += 1
        if onscreen {
            stats.onscreen += 1
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = bounds["Width"] ?? "?", height = bounds["Height"] ?? "?"
            let x = bounds["X"] ?? "?", y = bounds["Y"] ?? "?"
            stats.details.append("слой \(layer) \(width)x\(height) в \(x),\(y)")
        }
        byPID[pid] = stats
        if onscreen, layer == 25,
           (window[kCGWindowOwnerName as String] as? String)?.isEmpty == false {
            statusItems += 1
        }
    }
    return (byPID, statusItems)
}

// MARK: - Опрос

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

print("""
Зонд захвата экрана
   Смотрит за процессами: \(needles.joined(separator: ", "))
   Печатает строку каждые 2 секунды. Прерывать — Ctrl+C.

   Что делать: запустить и, не закрывая, в Zoom нажать «Демонстрация экрана»,
   подержать секунд десять, остановить показ. Потом ещё раз — когда экран
   показывает кто-то другой. Разница между строками и есть ответ.

   Колонки: цп — доля одного ядра за последние 2 с; окна — сколько окон
   у процесса на экране / всего; значки — сколько значков в строке меню
   (система вешает туда индикатор записи экрана).

""")

var previous: [Int32: (UInt64, Date)] = [:]
var lastLine = ""

while true {
    let now = Date()
    let procs = runningProcesses().filter { proc in
        needles.contains { proc.name.lowercased().contains($0.lowercased()) }
    }
    let (windowsByPID, statusItems) = windows()

    var parts: [String] = []
    var detailLines: [String] = []
    for proc in procs.sorted(by: { $0.name < $1.name }) {
        var cpu = "?"
        if let time = cpuTime(proc.pid) {
            if let (before, at) = previous[proc.pid] {
                let elapsed = now.timeIntervalSince(at)
                let share = elapsed > 0 ? Double(time - before) / 1_000_000_000 / elapsed * 100 : 0
                cpu = String(format: "%.1f%%", share)
            } else {
                cpu = "—"
            }
            previous[proc.pid] = (time, now)
        }
        let stats = windowsByPID[proc.pid] ?? WindowStats()
        parts.append("\(proc.name)[\(proc.pid)] цп \(cpu) окна \(stats.onscreen)/\(stats.total)")
        if stats.onscreen > 0 {
            detailLines.append("      \(proc.name): " + stats.details.joined(separator: "; "))
        }
    }

    let line = "\(stamp.string(from: now))  значки \(statusItems)  " + parts.joined(separator: "  |  ")
    print(line)
    detailLines.forEach { print($0) }
    lastLine = line
    _ = lastLine
    Thread.sleep(forTimeInterval: 2)
}
