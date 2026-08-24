import Combine
import CoreGraphics
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
///
/// Главный урок этого монитора: работающий процесс ещё не значит захват.
/// Первая версия считала признаком сам факт, что процесс из списка есть, —
/// и всю осень прятала суммы на каждой конференции Zoom, потому что `CptHost`
/// поднимается при входе в звонок и висит до его конца. Теперь у каждого
/// подозреваемого свой признак, см. `CaptureEvidence`.
@MainActor
final class PrivacyMonitor: ObservableObject {
    @Published private(set) var reason: PrivacyReason? {
        didSet { if reason != oldValue { onChange?(reason) } }
    }

    /// Вызывается только при смене состояния — опрос идёт каждые три секунды,
    /// дёргать перерисовку на каждый тик незачем.
    var onChange: ((PrivacyReason?) -> Void)?

    /// Кандидаты, которые работают, но захвата не показывают. Раздел
    /// приватности показывает их человеку: «Zoom в звонке, экран не
    /// показывают» — это ответ на вопрос, который иначе задают журналу.
    @Published private(set) var quietCandidates: [String] = []
    var onQuietChange: (([String]) -> Void)?

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

    /// Когда в последний раз видели признак захвата и сколько его держать.
    private var lastTriggerSeen: Date?
    private var lastTriggerHold: TimeInterval = PrivacyMonitor.presenceCooldown

    /// Сколько держать приватный режим после того, как пропал признак-присутствие.
    ///
    /// Скриншот — событие мгновенное: к моменту, когда опрос заметит
    /// `screencapture`, снимок уже сделан, и первый кадр детектором не закрыть.
    /// Выдержка нужна лишь чтобы убрать мигание «спрятал-показал» и прикрыть
    /// серию снимков подряд. Держать долго смысла нет — цифры не должны
    /// пропадать надолго после случайного скриншота.
    private static let presenceCooldown: TimeInterval = 3

    /// Сколько держать режим после того, как пропала рамка демонстрации.
    ///
    /// Заметно дольше: рамку во время показа Zoom иногда передаёт от `CptHost`
    /// главному процессу и обратно, и на один-два опроса она у подозреваемого
    /// исчезает (видно в замере 24.08.2026: 14:00:16 и 14:00:18). Без выдержки
    /// цифры мигали бы посреди демонстрации — а это ровно тот случай, когда
    /// их видеть не должны.
    private static let frameCooldown: TimeInterval = 12

    /// Процессы, которые уже работали в момент запуска приложения.
    /// Отсечка нужна только признаку-присутствию: демонстрация экрана всегда
    /// начинается ПОСЛЕ, а фоновый агент удалёнки висит с самой загрузки
    /// системы, и без неё счётчик прятался бы навсегда. Запись выбывает
    /// из списка, как только процесс исчез, поэтому следующий его запуск
    /// уже засчитается.
    private var processesRunningAtStartup: Set<String> = []

    /// О каких кандидатах журнал уже предупредил. Без этой отсечки строка
    /// повторялась бы каждые три секунды всю конференцию.
    private var quietReported: Set<String> = []

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
            // Пока суммы спрятаны, объяснять, почему они не спрятаны, незачем.
            report(quiet: [])
            reason = .camera
            return
        }
        var quiet: [String] = []
        if settings.privacyOnCapture {
            let running = ProcessList.all()
            processesRunningAtStartup.formIntersection(running.map(\.name))

            let suspects = settings.captureSuspects
            // Список окон спрашиваем, только когда есть у кого их искать:
            // без запущенного Zoom обходить каждые три секунды все окна
            // системы незачем.
            let owners = CaptureDetector.needsWindowList(suspects: suspects, running: running)
                ? WindowCensus.onscreenOwners()
                : []

            let verdict = CaptureDetector.verdict(suspects: suspects,
                                                  running: running,
                                                  windowOwners: owners,
                                                  ignoring: processesRunningAtStartup)
            quiet = verdict.quiet

            if let hit = verdict.capture {
                lastTriggerSeen = Date()
                lastTriggerHold = hit.evidence == .sharingFrame
                    ? PrivacyMonitor.frameCooldown
                    : PrivacyMonitor.presenceCooldown
                report(quiet: quiet.filter { $0 != hit.process })
                reason = .capture(hit.process)
                return
            }
        }

        // Признак пропал — держим режим ещё немного. Рамку во время показа
        // Zoom на пару опросов теряет, и это как раз тот случай: кандидат
        // сейчас «молчит», но суммы всё ещё спрятаны, и обещать обратное нельзя.
        if let seen = lastTriggerSeen, Date().timeIntervalSince(seen) < lastTriggerHold {
            report(quiet: [])
            return
        }
        lastTriggerSeen = nil
        report(quiet: quiet)
        reason = nil
    }

    /// Кандидат работает, но захвата не видно. Это и есть та строка, которой
    /// не хватало: без неё вопрос «почему суммы спрятаны» каждый раз
    /// превращался в расследование.
    private func report(quiet names: [String]) {
        let fresh = Set(names)
        for name in fresh.subtracting(quietReported).sorted() {
            Log.info("приватность: \(name) работает, но окна демонстрации нет — суммы не прячу")
        }
        guard fresh != quietReported else { return }
        quietReported = fresh
        quietCandidates = names
        onQuietChange?(names)
    }
}

// MARK: - Решение

/// Процесс, признанный захватом экрана.
struct CaptureHit: Equatable {
    let process: String
    let evidence: CaptureEvidence
}

/// Что монитор увидел за один опрос.
struct CaptureVerdict: Equatable {
    /// Процесс, который действительно похож на захват экрана.
    var capture: CaptureHit?
    /// Кандидаты, которые работают, но признаков захвата не показывают.
    var quiet: [String] = []
}

/// Чистое решение «прятать или нет» по списку процессов и списку окон.
/// Вынесено из монитора, чтобы его можно было прогнать тестами на выдуманных
/// данных: живой Zoom в тестах не поднимешь.
enum CaptureDetector {
    /// Есть ли смысл спрашивать систему про окна: хоть один процесс, который
    /// засчитывают по рамке, должен работать.
    static func needsWindowList(suspects: [CaptureSuspect], running: [RunningProcess]) -> Bool {
        suspects.contains { suspect in
            suspect.evidence == .sharingFrame
                && running.contains { matches(suspect, $0) }
        }
    }

    /// Совпадение по части имени, регистр не важен — «CptHost» и «cpthost»
    /// это одно и то же. Правило одно на всех, чтобы отбор кандидатов
    /// и решение по ним не могли разойтись.
    static func matches(_ suspect: CaptureSuspect, _ process: RunningProcess) -> Bool {
        let needle = suspect.needle.lowercased()
        guard !needle.isEmpty else { return false }
        return process.name.lowercased().contains(needle)
    }

    static func verdict(suspects: [CaptureSuspect],
                        running: [RunningProcess],
                        windowOwners: Set<Int32>,
                        ignoring ignoredNames: Set<String> = []) -> CaptureVerdict {
        var verdict = CaptureVerdict()
        for suspect in suspects {
            for process in running where matches(suspect, process) {
                switch suspect.evidence {
                case .presence:
                    // Отсечка по старту нужна только здесь: там, где признаком
                    // служит окно, процесс с загрузки системы и так не мешает.
                    guard !ignoredNames.contains(process.name) else { continue }
                    if verdict.capture == nil {
                        verdict.capture = CaptureHit(process: process.name, evidence: .presence)
                    }
                case .sharingFrame:
                    if windowOwners.contains(process.pid) {
                        if verdict.capture == nil {
                            verdict.capture = CaptureHit(process: process.name, evidence: .sharingFrame)
                        }
                    } else if !verdict.quiet.contains(process.name) {
                        verdict.quiet.append(process.name)
                    }
                }
            }
        }
        return verdict
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

// MARK: - Окна

/// Кто сейчас рисует окна на экране.
///
/// Список окон CoreGraphics отдаёт без всяких разрешений: без права на запись
/// экрана скрыты только заголовки окон, а владелец, слой и размеры — нет.
/// Нам нужен ровно владелец, поэтому разрешение приложению не требуется.
enum WindowCensus {
    static func onscreenOwners() -> Set<Int32> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var owners: Set<Int32> = []
        for window in list {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            owners.insert(pid)
        }
        return owners
    }
}

// MARK: - Процессы

/// Работающий процесс: имя и номер. Номер нужен, чтобы спросить про его окна, —
/// имён в списке окон нет, там только владелец-процесс.
struct RunningProcess: Equatable {
    let pid: Int32
    let name: String
}

/// Список работающих процессов через sysctl — без запуска `ps` каждые три секунды.
enum ProcessList {
    static func names() -> [String] { all().map(\.name) }

    static func all() -> [RunningProcess] {
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
            return name.isEmpty ? nil : RunningProcess(pid: procs[index].kp_proc.p_pid, name: name)
        }
    }
}
