import AppKit
import Carbon.HIToolbox

/// Горячие клавиши, запускающие таймеры откуда угодно.
///
/// Через Carbon (`RegisterEventHotKey`), а не через `NSEvent.addGlobalMonitor`,
/// по одной причине: глобальный монитор требует разрешения «Универсальный
/// доступ» — того самого, где человека просят пустить программу управлять
/// компьютером. Ради запуска таймера просить такое нельзя. Carbon-регистрация
/// не спрашивает ничего (проверено зондом: `status = 0` без единого разрешения),
/// и система сама будит приложение на нужном сочетании.
///
/// Плата известна и названа в интерфейсе: если сочетание уже занято системой
/// или другой программой, регистрация всё равно проходит успешно, а нажатие
/// до нас не доходит. Отличить это в коде нельзя — `RegisterEventHotKey`
/// на ⌘Space отвечает тем же `noErr`, что и на свободное сочетание.
@MainActor
final class HotKeyCenter {
    /// Что делать, когда сочетание нажали. Передаётся таймер, которому оно
    /// назначено.
    var onTrigger: ((UUID) -> Void)?

    private struct Registration {
        let ref: EventHotKeyRef
        let preset: UUID
    }

    /// Что сейчас висит, по номеру, который выдан системе.
    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    /// Обработчик Carbon — это чистая C-функция, замыкание с контекстом
    /// в неё не передать. Поэтому живой центр один на приложение, и функция
    /// обращается к нему.
    private static var shared: HotKeyCenter?

    /// Повесить ровно те сочетания, что назначены сейчас, и снять все прежние.
    ///
    /// Полная перевеска, а не разбор разницы: сочетаний три, снятие и
    /// регистрация стоят микросекунды, а сверять два списка руками — это
    /// ещё одно место, где состояние системы может разойтись с настройками.
    func apply(_ presets: [TimerPreset], enabled: Bool) {
        unregisterAll()
        HotKeyCenter.shared = self
        guard enabled else { return }
        installHandlerIfNeeded()

        for preset in presets {
            guard let hotkey = preset.hotkey, hotkey.isValid else { continue }
            var ref: EventHotKeyRef?
            let id = nextID
            nextID += 1
            let status = RegisterEventHotKey(
                UInt32(hotkey.keyCode),
                carbonModifiers(hotkey),
                EventHotKeyID(signature: HotKeyCenter.signature, id: id),
                GetEventDispatcherTarget(), 0, &ref
            )
            if status == noErr, let ref {
                registrations[id] = Registration(ref: ref, preset: preset.id)
                Log.info("горячая клавиша повешена: \(TimerRules.hotkeyName(hotkey)) → «\(preset.name)»")
            } else {
                // Единственный отказ, который сюда доходит, — сочетание уже
                // занято нами же. Остальное система принимает молча.
                Log.warn("не удалось повесить горячую клавишу \(TimerRules.hotkeyName(hotkey)): код \(status)")
            }
        }
    }

    /// Сколько сочетаний висит на самом деле. Отличается от числа назначенных:
    /// негодные пропускаются, занятые нами же система не отдаёт второй раз.
    /// По этому числу зонд и проверяет, что регистрация проходит.
    var registeredCount: Int { registrations.count }

    func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations = [:]
    }

    // MARK: Внутреннее

    /// Метка наших сочетаний в общей очереди системы: 'SFLW'.
    private static let signature = OSType(0x53464C57)

    private func carbonModifiers(_ hotkey: TimerHotkey) -> UInt32 {
        var mask: Int = 0
        if hotkey.command { mask |= cmdKey }
        if hotkey.option { mask |= optionKey }
        if hotkey.control { mask |= controlKey }
        if hotkey.shift { mask |= shiftKey }
        return UInt32(mask)
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            // Обработчик приходит с главного потока — но C-функция об этом
            // не знает, и компилятору надо сказать словами.
            MainActor.assumeIsolated {
                HotKeyCenter.shared?.fire(number)
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ id: UInt32) {
        guard let registration = registrations[id] else { return }
        onTrigger?(registration.preset)
    }
}

// MARK: - Запись сочетания

/// Ловит одно нажатие, чтобы назначить его таймеру.
///
/// Монитор локальный, а не глобальный: он видит только события, пришедшие
/// в наше окно, и потому не требует никаких разрешений. Окно настроек в этот
/// момент как раз впереди, так что ловить больше нечего и незачем.
@MainActor
final class HotKeyRecorder: ObservableObject {
    /// Чей ряд сейчас ждёт нажатия. `nil` — никто не ждёт.
    @Published private(set) var recording: UUID?

    private var monitor: Any?
    private var onResult: ((TimerHotkey?) -> Void)?

    /// Начать запись. `result` зовётся один раз: с сочетанием, с `nil`
    /// для очистки — или не зовётся вовсе, если запись отменили.
    func start(for preset: UUID, result: @escaping (TimerHotkey?) -> Void) {
        stop()
        recording = preset
        onResult = result
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // Из события забираем только код и модификаторы: сам `NSEvent`
            // через границу актора не пройдёт, а больше от него ничего и не надо.
            let code = Int(event.keyCode)
            let flags = event.modifierFlags
            let swallowed = MainActor.assumeIsolated { self.handle(keyCode: code, flags: flags) }
            return swallowed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        onResult = nil
    }

    /// `true` — событие съедено и до полей ввода не дойдёт: иначе назначение
    /// ⌘W закрыло бы окно настроек прямо во время записи.
    private func handle(keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case kVK_Escape:
            stop()
            return true
        case kVK_Delete, kVK_ForwardDelete:
            // Забой снимает сочетание — так это устроено везде, где их назначают.
            onResult?(nil)
            stop()
            return true
        default:
            break
        }

        let hotkey = TimerHotkey(
            keyCode: keyCode,
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift)
        )
        // Без Cmd, Alt или Ctrl сочетание не годится: одна буква перехватывалась
        // бы у всех программ разом. Ждём дальше, а не отменяем запись молча —
        // человек просто нажал не то.
        guard hotkey.isValid else { return true }

        onResult?(hotkey)
        stop()
        return true
    }
}
