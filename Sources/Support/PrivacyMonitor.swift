import Combine
import CoreMediaIO
import Darwin
import Foundation

/// Почему счётчик сейчас спрятан.
enum PrivacyReason: Equatable {
    case manual
    case camera
    case capture(String)   // имя процесса, который захватывает экран

    var title: String {
        switch self {
        case .manual: return "Суммы скрыты вручную"
        case .camera: return "Включена камера — похоже на видеозвонок"
        case .capture(let process): return "Идёт захват экрана (\(process))"
        }
    }
}

/// Следит за признаками того, что экран сейчас видит кто-то ещё.
///
/// Спрятать окно от захвата на уровне системы нельзя: `NSWindow.sharingType = .none`
/// с macOS 15.4 игнорируется, и публичной замены Apple не дала. Поэтому единственный
/// рабочий подход — заметить звонок или запись и убрать цифры самим.
@MainActor
final class PrivacyMonitor: ObservableObject {
    @Published private(set) var reason: PrivacyReason? {
        didSet { if reason != oldValue { onChange?(reason) } }
    }

    /// Вызывается только при смене состояния — опрос идёт каждые три секунды,
    /// дёргать перерисовку на каждый тик незачем.
    var onChange: ((PrivacyReason?) -> Void)?

    var settings: AppSettings = AppSettings() {
        didSet {
            guard settings.privacyOnCamera != oldValue.privacyOnCamera
                    || settings.privacyOnCapture != oldValue.privacyOnCapture
                    || settings.privacyExtraProcesses != oldValue.privacyExtraProcesses
            else { return }
            poll()
        }
    }

    private var timer: Timer?

    /// Когда в последний раз видели признак захвата.
    private var lastTriggerSeen: Date?

    /// Сколько держать приватный режим после того, как признак пропал.
    ///
    /// Скриншот — событие мгновенное: к моменту, когда опрос заметит
    /// `screencapture`, снимок уже сделан, и первый кадр детектором не закрыть.
    /// Выдержка нужна лишь чтобы убрать мигание «спрятал-показал» и прикрыть
    /// серию снимков подряд. Держать долго смысла нет — цифры не должны
    /// пропадать надолго после случайного скриншота.
    private static let cooldown: TimeInterval = 3

    /// Процессы, которые уже работали в момент запуска приложения.
    /// Демонстрация экрана всегда начинается ПОСЛЕ — а фоновый агент удалёнки
    /// висит с самой загрузки системы, и без этой отсечки счётчик прятался бы
    /// навсегда. Запись выбывает из списка, как только процесс исчез,
    /// поэтому следующий его запуск уже засчитается.
    private var processesRunningAtStartup: Set<String> = []

    init() {
        processesRunningAtStartup = Set(ProcessList.names())
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func poll() {
        if settings.privacyOnCamera, CameraWatch.anyCameraIsRunning() {
            reason = .camera
            return
        }
        if settings.privacyOnCapture {
            let running = ProcessList.names()
            processesRunningAtStartup.formIntersection(running)
            if let process = ProcessList.firstMatch(settings.captureProcessNames,
                                                    in: running,
                                                    ignoring: processesRunningAtStartup) {
                lastTriggerSeen = Date()
                reason = .capture(process)
                return
            }
        }

        // Признак пропал — держим режим ещё немного.
        if let seen = lastTriggerSeen, Date().timeIntervalSince(seen) < PrivacyMonitor.cooldown {
            return
        }
        lastTriggerSeen = nil
        reason = nil
    }
}

// MARK: - Камера

/// Опрос камер через CoreMediaIO. Разрешений не требует: спрашиваем не картинку,
/// а состояние устройства — «его кто-то сейчас использует».
enum CameraWatch {
    static func anyCameraIsRunning() -> Bool {
        devices().contains { isRunning($0) }
    }

    private static func devices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))

        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0,
              size > 0 else { return [] }

        let capacity = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: capacity)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                        size, &used, &ids) == 0 else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func isRunning(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &address, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return status == 0 && value != 0
    }
}

// MARK: - Процессы

/// Список имён работающих процессов через sysctl — без запуска `ps` каждые три секунды.
enum ProcessList {
    /// Первый работающий процесс, чьё имя содержит один из образцов.
    /// Регистр не важен — «CptHost» и «cpthost» это одно и то же.
    static func firstMatch(_ needles: [String],
                           in running: [String]? = nil,
                           ignoring ignored: Set<String> = []) -> String? {
        guard !needles.isEmpty else { return nil }
        let list = running ?? names()
        for needle in needles {
            let lowered = needle.lowercased()
            if let hit = list.first(where: { !ignored.contains($0) && $0.lowercased().contains(lowered) }) {
                return hit
            }
        }
        return nil
    }

    static func names() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // Список процессов может подрасти между двумя вызовами — берём с запасом.
        size += size / 8
        let capacity = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let count = min(capacity, size / MemoryLayout<kinfo_proc>.stride)
        return (0..<count).compactMap { index in
            let comm = procs[index].kp_proc.p_comm
            let size = MemoryLayout.size(ofValue: comm)
            let name = withUnsafeBytes(of: comm) { buffer -> String in
                guard let base = buffer.baseAddress else { return "" }
                return base.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
            }
            return name.isEmpty ? nil : name
        }
    }
}
