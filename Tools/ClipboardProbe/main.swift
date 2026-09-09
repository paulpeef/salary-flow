import AppKit
import Foundation

// Зонд буфера обмена: печатает, что в нём сейчас лежит и что из этого возьмёт
// заготовка.
//
// Нужен ровно там, где рассуждать бесполезно: какие типы кладёт конкретная
// программа — Slack, Notion, почта, — не написано нигде, и «взялось простым
// текстом» без этого списка не с чем сверить.
//
// Ничего не меняет: только читает буфер и печатает. Порядок работы —
// скопировать нужное в программе и запустить `./Tools/clipboardprobe.sh`.

func human(_ bytes: Int) -> String {
    bytes < 1024 ? "\(bytes) Б" : String(format: "%.1f КБ", Double(bytes) / 1024)
}

/// Кусок содержимого — чтобы видеть, что именно приехало. Показывается начало:
/// разметка начинается с самого важного, а целиком она нечитаема.
func preview(_ data: Data, limit: Int = 400) -> String {
    guard let text = String(data: data, encoding: .utf8) else { return "(не текст)" }
    let flat = text.replacingOccurrences(of: "\n", with: "⏎")
    return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    let board = NSPasteboard.general

    print("== Зонд буфера обмена ==")
    print("Смена буфера №\(board.changeCount)")

    let types = board.types ?? []
    print("\nТипы, которые отдаёт буфер (\(types.count)):")
    if types.isEmpty {
        print("  — ни одного, буфер пуст")
    }
    for type in types {
        let size = board.data(forType: type).map { human($0.count) } ?? "нет данных"
        print("  · \(type.rawValue) — \(size)")
    }

    // Разбор по элементам: программы кладут один элемент с несколькими
    // представлениями, но кладут и по-другому — это видно только так.
    if let items = board.pasteboardItems, items.count != 1 {
        print("\nЭлементов в буфере: \(items.count)")
        for (index, item) in items.enumerated() {
            print("  \(index + 1): \(item.types.map(\.rawValue).joined(separator: ", "))")
        }
    }

    // Программы на Electron кладут разметку не под общим типом, а в свой
    // «пикл». Разбираем и печатаем, что в нём лежит: без этого «ссылка есть,
    // а заготовка её не видит» ничем не объяснить.
    if let custom = board.data(forType: SnippetRules.chromiumCustomType) {
        let entries = SnippetRules.chromiumCustom(custom)
        print("\nВнутри org.chromium.web-custom-data (\(human(custom.count))):")
        if entries.isEmpty {
            print("  — разобрать не удалось. Первые байты:")
            let head = custom.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("    \(head)")
        }
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            print("  · \(key) — \(value.count) символов")
            print("    \(preview(Data(value.utf8), limit: 300))")
        }
    }

    let rtf = SnippetRules.clipboardRTF(board)
    let html = SnippetRules.clipboardHTML(board)
    let plain = board.string(forType: .string)

    print("\nЧто из этого берёт заготовка:")
    print("  размеченный текст (RTF): \(rtf.map { human($0.count) } ?? "нет")")
    print("  разметка HTML: \(html.map { human($0.count) } ?? "нет")")
    print("  простая строка: \(plain.map { "«\(preview(Data($0.utf8), limit: 120))»" } ?? "нет")")

    if let rtf, let attributed = SnippetRules.attributed(rtf: rtf) {
        print("  RTF разобрался: да, форматирование — \(SnippetRules.hasFormatting(attributed) ? "есть" : "нет")")
        if let link = SnippetRules.firstLink(attributed) { print("  ссылка в RTF: \(link)") }
    } else if rtf != nil {
        print("  RTF разобрался: нет")
    }

    if let html {
        if let attributed = SnippetRules.attributed(html: html) {
            print("  HTML разобрался: да, форматирование — \(SnippetRules.hasFormatting(attributed) ? "есть" : "нет")")
            if let link = SnippetRules.firstLink(attributed) { print("  ссылка в HTML: \(link)") }
        } else {
            print("  HTML разобрался: нет, судим по самой разметке — \(SnippetRules.looksFormatted(html: html) ? "форматирование есть" : "форматирования не видно")")
            if let link = SnippetRules.firstHref(html) { print("  ссылка в разметке: \(link)") }
        }
        print("\nНачало разметки:\n  \(preview(html))")
    }

    let capture = SnippetRules.capture(rtf: rtf, html: html, plain: plain)
    print("\nИтог: \(SnippetRules.captureNote(capture))")
    switch capture {
    case .rich(let text, let keptRTF, let keptHTML):
        print("  простой вариант: «\(text)»")
        print("  сохранится RTF: \(keptRTF.map { human($0.count) } ?? "нет")")
        print("  сохранится HTML: \(keptHTML.map { human($0.count) } ?? "нет")")
    case .plain(let text), .tooBig(let text):
        print("  простой вариант: «\(text)»")
    case .empty:
        break
    }
}
