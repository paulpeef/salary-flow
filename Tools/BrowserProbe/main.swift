import AppKit

// Зонд смены браузера по умолчанию.
//
// Отдельного «браузера по умолчанию» в системе нет: есть хозяин схемы ссылок.
// Схему `https` macOS не отдаёт никому (`OSStatus -54`, отказ в правах),
// а `http` меняется свободно — и `https` переезжает следом сам. Зонд это
// и меряет: спрашивает двумя способами, а потом ждёт, пока система пересчитает.
//
// Тестом это не проверить: ответ даёт система, и он зависит от того,
// кто спрашивает и на какой схеме.
//
// Зонд ничего не восстанавливает: если смена пройдёт, браузер по умолчанию
// действительно сменится — за этим сюда и приходят. Вернуть обратно можно
// этим же зондом, назвав прежний браузер.
//
// Запуск: ./Tools/browserprobe.sh [bundle-id]

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.google.Chrome"

func handler(_ scheme: String) -> String {
    guard let url = URL(string: "\(scheme)://example.com"),
          let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "никто" }
    return Bundle(url: app)?.bundleIdentifier ?? app.path
}

func report(_ title: String) {
    print("   \(title): http → \(handler("http")), https → \(handler("https"))")
}

func describe(_ error: Error) -> String {
    let e = error as NSError
    var text = "\(e.domain) код \(e.code) — \(e.localizedDescription)"
    if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
        text += "\n     внутри: \(underlying.domain) код \(underlying.code)"
    }
    return text
}

/// Система принимает запрос сразу, а пересчитывает погодя: чтение в ту же
/// миллисекунду показывает прежнего хозяина. Ждём до трёх секунд.
func waitForChange(to target: String) {
    for step in 1...15 {
        if handler("http").caseInsensitiveCompare(target) == .orderedSame {
            print("   ✓ система пересчитала за \(step * 200) мс")
            return
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    print("   ✗ за три секунды хозяин ссылок не сменился")
}

guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) else {
    print("✗ Не нашёл программу \(target)")
    exit(1)
}

print("Зонд смены браузера по умолчанию")
print("   цель: \(target) — \(appURL.path)")
print("   зонд запущен как: \(Bundle.main.bundleIdentifier ?? "голый исполняемый файл, без бандла")")
report("до")

// 1. Схема http нынешним способом — тем же, что первым пробует приложение.
print("\n1. NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:) — http")
var accepted = false
let semaphore = DispatchSemaphore(value: 0)
NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { error in
    if let error {
        print("   ✗ \(describe(error))")
    } else {
        print("   ✓ запрос принят")
        accepted = true
    }
    semaphore.signal()
}
semaphore.wait()

// 2. Прежний способ — запасной путь приложения.
if !accepted {
    print("\n2. LSSetDefaultHandlerForURLScheme — http")
    let status = LSSetDefaultHandlerForURLScheme("http" as CFString, target as CFString)
    print(status == noErr ? "   ✓ запрос принят (OSStatus 0)" : "   ✗ OSStatus \(status)")
    accepted = status == noErr
}

// 3. Схема https: её система защищает. Пробуем ради проверки, что это
//    всё ещё так, — и что http поехал без неё.
print("\n3. LSSetDefaultHandlerForURLScheme — https (её система обычно не отдаёт)")
let secure = LSSetDefaultHandlerForURLScheme("https" as CFString, target as CFString)
print(secure == noErr ? "   ✓ OSStatus 0 — отдала" : "   ✗ OSStatus \(secure) (-54 = отказ в правах)")

if accepted {
    print("\nЖду, пока система пересчитает")
    waitForChange(to: target)
}
report("итог")
