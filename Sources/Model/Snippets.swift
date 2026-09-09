import AppKit
import Foundation

/// Заготовки под рукой: то, что приходится набирать или искать заново по
/// нескольку раз в неделю — ссылка на свой Zoom, рабочая почта, номер телефона,
/// адрес офиса. Нажатие в панели кладёт заготовку в буфер обмена, дальше
/// обычная вставка.
///
/// Здесь только правила, без буфера обмена и без интерфейса: сам `NSPasteboard`
/// живёт в модели приложения, а всё, что можно проверить тестами, — тут.

// MARK: - Заготовка

/// Одна заготовка: как её зовут и что копировать.
///
/// Имя и текст — разные вещи намеренно. В панели видно только имя: её
/// открывают и во время демонстрации экрана, а в заготовке может лежать
/// что угодно, вплоть до домашнего адреса. Поэтому текст не показывается
/// нигде, кроме окна настроек, — ни на плашке, ни в подсказке к ней.
struct Snippet: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var text: String

    /// Тот же текст с форматированием, в двух видах — ровно так, как их отдал
    /// буфер обмена. Оба необязательны: `nil` и там и там — заготовка простая.
    ///
    /// Хранятся дословно, а не приводятся к одному виду. Это главный урок
    /// первой попытки: перевод HTML → RTF при взятии и обратно при нажатии
    /// проходил через разбор `NSAttributedString`, и всё, чего разбор не понял,
    /// терялось молча. Чужую разметку понимать не надо — её надо вернуть той
    /// программе, которая её и понимает. В файле настроек оба куска лежат
    /// base64: глазами их не читают, а править руками там нечего.
    var rich: Data?

    /// HTML из программы-источника. Его читают программы на Electron —
    /// Slack, Notion и прочие; именно он и делает вставку кликабельной ссылкой.
    var html: Data?

    init(id: UUID = UUID(), name: String, text: String,
         rich: Data? = nil, html: Data? = nil) {
        self.id = id
        self.name = name
        self.text = text
        self.rich = rich
        self.html = html
    }

    /// То, что в самом деле ложится в буфер.
    ///
    /// Пробелы и переводы строк по краям срезаются: они приезжают из копипасты
    /// незаметно для человека, а вставленная ссылка с хвостовым переводом
    /// строки отправляет сообщение раньше, чем он дописал фразу.
    var payload: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Заготовку есть чем копировать. Пустую плашку в панели не убираем,
    /// но и нажать её нельзя — см. `SnippetRules.chipHint`.
    var isReady: Bool { !payload.isEmpty }

    /// В заготовке есть форматирование — ссылки, выделение, цвет.
    var isRich: Bool { rich != nil || html != nil }
}

// MARK: - Правила

enum SnippetRules {
    /// Шесть — предел. Плашки раскладываются тем же облаком, что и опрос
    /// настроения: шесть коротких имён укладываются в два ряда, а дальше блок
    /// начинает соперничать с опросом за высоту панели. Точное число рядов
    /// задают имена, поэтому в настройках сказано, что имя лучше короткое.
    static let maxSlots = 6

    /// Предел длины текста. Заготовка — это ссылка или дежурная фраза,
    /// а не документ; четырёх тысяч знаков хватает на любую из них с запасом.
    /// Ограничение нужно файлу настроек: он целиком перезаписывается на каждое
    /// нажатие клавиши в любом поле окна.
    static let maxTextLength = 4000

    /// Предел размера форматированного куска.
    ///
    /// Шестьдесят четыре килобайта — это несколько страниц размеченного текста
    /// и заведомо больше, чем «слово со ссылкой». Ограничение нужно файлу
    /// настроек: он перезаписывается целиком на каждое нажатие клавиши в любом
    /// поле окна, и таскать в нём мегабайт чужой разметки незачем. Не влезло —
    /// заготовка берётся простым текстом, и об этом говорится вслух.
    static let maxRichBytes = 64 * 1024

    /// Сколько плашка держит отметку «скопировано».
    ///
    /// Полторы секунды: меньше — не успеть заметить, если в момент нажатия
    /// смотрел на другое окно; больше — отметка ещё висит, когда человек
    /// вернулся копировать второе.
    static let flashSeconds: TimeInterval = 1.5

    /// Имя для заготовки, которую только что завели или у которой стёрли имя.
    static let defaultName = "Заготовка"

    /// Сколько знаков имени помещается на плашке.
    ///
    /// Ровно столько, сколько влезает в половину ширины панели: длинное имя
    /// иначе занимает весь ряд один, и шесть заготовок вырастают в шесть рядов.
    /// Обрезка живёт только в панели — в настройках человек видит своё имя
    /// целиком и правит именно его.
    static let chipNameLength = 18

    /// Заготовки, приведённые к правилам. Файл настроек правят руками и везут
    /// с другой машины — оттуда может приехать и седьмая заготовка, и пустое имя.
    static func normalized(_ list: [Snippet]) -> [Snippet] {
        list.prefix(maxSlots).map { item in
            var fixed = item
            let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            fixed.name = trimmed.isEmpty ? defaultName : trimmed
            fixed.text = clamped(item.text)
            // Форматирование без текста — это блоб, который некуда положить:
            // такую плашку и нажать нельзя. Слишком большой кусок отбрасывается
            // по той же причине, по которой он не берётся из буфера.
            if !fixed.isReady { fixed.rich = nil; fixed.html = nil }
            if (fixed.rich?.count ?? 0) > maxRichBytes { fixed.rich = nil }
            if (fixed.html?.count ?? 0) > maxRichBytes { fixed.html = nil }
            return fixed
        }
    }

    /// Текст в допустимых границах. Режем с конца: начало заготовки человек
    /// набирал осознанно, а хвост чаще всего прилетел вставкой.
    static func clamped(_ text: String) -> String {
        text.count <= maxTextLength ? text : String(text.prefix(maxTextLength))
    }

    /// Имя на плашке. Обрезается посередине, а не с конца: «Zoom — личная
    /// комн…» и «Zoom — рабочая комн…» ничем не отличаются друг от друга.
    static func chipName(_ name: String) -> String {
        guard name.count > chipNameLength else { return name }
        let head = name.prefix((chipNameLength - 1) / 2)
        let tail = name.suffix(chipNameLength - 1 - head.count)
        return "\(head)…\(tail)"
    }

    /// Подсказка на плашке.
    ///
    /// Текста заготовки в ней нет и не будет: подсказка всплывает от наведения
    /// мыши, а мышь по панели водят и на демонстрации экрана. Показать личную
    /// ссылку всем зрителям звонка ровно тогда, когда её собрались отправить
    /// одному, — цена, которой эта подсказка не стоит.
    static func chipHint(name: String, isReady: Bool, copied: Bool) -> String {
        if copied { return "«\(name)» в буфере обмена — вставляйте" }
        if !isReady { return "«\(name)» пока пустая: текст вписывается в настройках, раздел «Под рукой»" }
        return "Скопировать «\(name)» в буфер обмена"
    }

    /// Сколько заготовок ещё можно завести.
    static func canAdd(_ list: [Snippet]) -> Bool { list.count < maxSlots }
}

// MARK: - Взять из буфера обмена

/// Что удалось взять из буфера.
enum SnippetCapture: Equatable {
    /// Текст с форматированием: ссылки и выделение переживут вставку.
    /// Оба куска необязательны, но хотя бы один есть.
    case rich(text: String, rtf: Data?, html: Data?)
    /// Форматирования в буфере не было — взяли простой текст.
    case plain(String)
    /// Форматирование было, но слишком большое: взяли простой текст.
    case tooBig(text: String)
    /// В буфере нечего брать.
    case empty

    /// Текст, который в итоге лёг в заготовку. `nil` — не легло ничего.
    var text: String? {
        switch self {
        case .rich(let text, _, _), .plain(let text), .tooBig(let text): return text
        case .empty: return nil
        }
    }
}

extension SnippetRules {
    /// Разобрать содержимое буфера обмена.
    ///
    /// Разметка сохраняется дословно — той самой, какой её положила
    /// программа-источник, и обоими кусками сразу, если их два. Приводить
    /// чужой HTML к RTF (как это делалось в первой попытке) нельзя: перевод
    /// идёт через разбор `NSAttributedString`, и всё, чего разбор не понял,
    /// пропадает молча — а понимать чужую разметку и не требуется, её надо
    /// вернуть в буфер той программе, которая её понимает.
    ///
    /// Разбор всё же делается, но только ради двух вопросов: есть ли тут
    /// вообще форматирование и что показать в поле, если строки не дали.
    /// Не разобралось — не беда: тогда о форматировании судим по самой
    /// разметке, а текст берём из строки.
    ///
    /// Простой текст берётся тот, что положила сама программа-источник:
    /// это её решение, чем заменить форматированный кусок там, где вставляют
    /// голый текст. Своего ответа на этот вопрос у счётчика быть не может.
    static func capture(rtf: Data?, html: Data?, plain: String?) -> SnippetCapture {
        let fromRTF = rtf.flatMap { attributed(rtf: $0) }
        let fromHTML = html.flatMap { attributed(html: $0) }

        let fallback = clamped((plain ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let visible = (fromRTF ?? fromHTML)?.string
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = clamped(fallback.isEmpty ? visible : fallback)

        guard !text.isEmpty else { return .empty }

        // Спрашиваем оба куска, а не первый попавшийся: программа может
        // положить простой RTF и размеченный HTML разом, и решение по одному
        // только RTF потеряло бы ссылку, лежащую рядом.
        var formatted = [fromRTF, fromHTML].compactMap { $0 }.contains(where: hasFormatting)
        if !formatted, fromHTML == nil { formatted = looksFormatted(html: html) }

        guard formatted else { return .plain(text) }

        // Дословно то, что дали; чего не дали — восстанавливаем из того, что
        // есть, чтобы вставка работала и в родных программах, и в Electron.
        var keptRTF = fits(rtf)
        var keptHTML = fits(html)
        if keptRTF == nil, let source = fromHTML ?? fromRTF { keptRTF = fits(rtfData(source)) }
        if keptHTML == nil, let source = fromRTF ?? fromHTML { keptHTML = fits(htmlData(source)) }

        guard keptRTF != nil || keptHTML != nil else { return .tooBig(text: text) }
        return .rich(text: text, rtf: keptRTF, html: keptHTML)
    }

    /// Кусок влезает в файл настроек. Пустой не считается: класть в буфер
    /// нечего, а строка «с форматированием» была бы неправдой.
    static func fits(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= maxRichBytes else { return nil }
        return data
    }

    // MARK: Что спрашивать у буфера обмена

    /// Типы, под которыми программы кладут разметку HTML.
    ///
    /// Список, а не один `public.html`, потому что кладут по-разному: родные
    /// программы — под системным типом, программы на Electron (Slack и прочие)
    /// иногда под своим, унаследованным от веба. Спрашиваем по очереди
    /// и берём первое, что отдали.
    static let htmlTypes: [NSPasteboard.PasteboardType] = [
        .html,
        NSPasteboard.PasteboardType("Apple HTML pasteboard type"),
        NSPasteboard.PasteboardType("text/html"),
        NSPasteboard.PasteboardType("public.html"),
    ]

    /// То же для размеченного текста.
    static let rtfTypes: [NSPasteboard.PasteboardType] = [
        .rtf,
        NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type"),
        NSPasteboard.PasteboardType("public.rtf"),
    ]

    /// Свой тип Chromium: сюда программы на Electron кладут то, что страница
    /// положила в буфер сама, — в том числе разметку.
    static let chromiumCustomType = NSPasteboard.PasteboardType("org.chromium.web-custom-data")

    static func clipboardHTML(_ board: NSPasteboard) -> Data? {
        if let direct = first(of: htmlTypes, in: board) { return direct }
        // Slack общего типа не кладёт вовсе (замерено 2026-09-04 зондом:
        // в буфере только строка и три своих типа Chromium). Разметка лежит
        // в его «пикле» — оттуда её и достаём, иначе ссылка теряется, хотя
        // в буфере она есть.
        if let custom = board.data(forType: chromiumCustomType) {
            return htmlFromChromium(custom)
        }
        return nil
    }

    /// Разметка из «пикла» Chromium.
    static func htmlFromChromium(_ data: Data) -> Data? {
        let entries = chromiumCustom(data)
        for key in ["text/html", "html", "public.html"] {
            if let html = entries[key], !html.isEmpty { return Data(html.utf8) }
        }
        // Разметки может не быть вовсе: Slack кладёт «дельту» — свой список
        // кусков с атрибутами (замерено на живом буфере: `slack/texty`).
        // Ключ не зашиваем — пробуем разобрать каждое значение: формат
        // узнаётся по содержимому, а имя ему могут завтра сменить.
        for (_, value) in entries.sorted(by: { $0.key < $1.key }) {
            if let html = htmlFromDelta(value) { return html }
        }
        return nil
    }

    /// Разметка из «дельты» — так описывают текст редакторы на Quill,
    /// в том числе окно набора сообщения в Slack:
    ///
    ///     {"ops":[{"insert":{"slackemoji":{"text":":wave:"}}},
    ///             {"attributes":{"link":"https://…"},"insert":"Zoom"}]}
    ///
    /// Собираем из неё обычный HTML: он и есть общий язык, который понимают
    /// и Slack, и Notion, и почта. Своего формата Slack от нас не ждёт —
    /// вставку он разбирает из разметки, как от любой чужой программы.
    ///
    /// Разбираем ровно то, что бывает в заготовке: текст, ссылку, выделение.
    /// Всё незнакомое пропускаем молча — задача не повторить чужой редактор,
    /// а не потерять ссылку.
    static func htmlFromDelta(_ json: String) -> Data? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ops = root["ops"] as? [[String: Any]], !ops.isEmpty else { return nil }

        var html = ""
        var formatted = false

        for op in ops {
            var piece = ""
            if let text = op["insert"] as? String {
                piece = text
            } else if let object = op["insert"] as? [String: Any] {
                // Вставка-объект: эмодзи, упоминание, канал. Берём то, чем
                // она подписана, — при вставке Slack узнает своё сам.
                piece = deltaObjectText(object)
            }
            guard !piece.isEmpty else { continue }

            var chunk = escapedHTML(piece)
            let attributes = op["attributes"] as? [String: Any] ?? [:]

            if attributes["code"] as? Bool == true { chunk = "<code>\(chunk)</code>"; formatted = true }
            if attributes["bold"] as? Bool == true { chunk = "<b>\(chunk)</b>"; formatted = true }
            if attributes["italic"] as? Bool == true { chunk = "<i>\(chunk)</i>"; formatted = true }
            if attributes["strike"] as? Bool == true { chunk = "<s>\(chunk)</s>"; formatted = true }
            if let link = attributes["link"] as? String, !link.isEmpty {
                chunk = "<a href=\"\(escapedHTML(link))\">\(chunk)</a>"
                formatted = true
            }

            html += chunk
        }

        // Дельта без единого выделения — это просто текст, и разметка из неё
        // не нужна: строка в буфере уже есть.
        guard formatted, !html.isEmpty else { return nil }
        return Data(("<meta charset=\"utf-8\">" + html).utf8)
    }

    /// Чем подписана вставка-объект: `{"slackemoji":{"text":":wave:"}}`.
    static func deltaObjectText(_ object: [String: Any]) -> String {
        if let text = object["text"] as? String { return text }
        for value in object.values {
            if let text = value as? String { return text }
            if let nested = value as? [String: Any], let text = nested["text"] as? String {
                return text
            }
        }
        return ""
    }

    static func escapedHTML(_ text: String) -> String {
        var escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "\n", with: "<br>")
        return escaped
    }

    /// Разбор `org.chromium.web-custom-data`.
    ///
    /// Формат — «пикл» Chromium: `uint32` размер полезной части, дальше
    /// `uint32` число пар, дальше сами пары «тип → содержимое». Каждая
    /// строка — `uint32` длины в символах UTF-16, сами символы и выравнивание
    /// до четырёх байт. Заголовок кладут не все, поэтому пробуем с ним
    /// и без него.
    ///
    /// Разбор нарочно недоверчивый: это чужой двоичный формат, приезжающий
    /// из другой программы, и любая неожиданность в нём должна кончаться
    /// пустым ответом, а не порчей заготовки.
    static func chromiumCustom(_ data: Data) -> [String: String] {
        for start in [4, 0] {
            let entries = chromiumCustom(data, from: start)
            if !entries.isEmpty { return entries }
        }
        return [:]
    }

    private static func chromiumCustom(_ data: Data, from start: Int) -> [String: String] {
        let bytes = [UInt8](data)
        var offset = start

        func uint32() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            offset += 4
            return Int(value)
        }

        func string16() -> String? {
            guard let count = uint32(), count >= 0, count < 1_000_000 else { return nil }
            let size = count * 2
            guard offset + size <= bytes.count else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(count)
            for index in stride(from: offset, to: offset + size, by: 2) {
                units.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            }
            offset += size
            // Выравнивание до четырёх байт — так пишет `base::Pickle`.
            offset = (offset + 3) & ~3
            return String(decoding: units, as: UTF16.self)
        }

        guard let count = uint32(), count > 0, count <= 64 else { return [:] }

        var entries: [String: String] = [:]
        for _ in 0..<count {
            guard let key = string16(), let value = string16() else { return entries }
            entries[key] = value
        }
        return entries
    }

    static func clipboardRTF(_ board: NSPasteboard) -> Data? {
        first(of: rtfTypes, in: board)
    }

    private static func first(of types: [NSPasteboard.PasteboardType],
                              in board: NSPasteboard) -> Data? {
        for type in types {
            if let data = board.data(forType: type), !data.isEmpty { return data }
        }
        return nil
    }

    static func attributed(rtf: Data) -> NSAttributedString? {
        NSAttributedString(rtf: rtf, documentAttributes: nil)
    }

    static func attributed(html: Data) -> NSAttributedString? {
        try? NSAttributedString(
            data: html,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
    }

    /// Есть ли в куске хоть что-то, ради чего стоит хранить разметку.
    ///
    /// Не всякий RTF в буфере — форматирование: простой текст из редактора
    /// приезжает размеченным в один шрифт, и хранить ради него блоб, а потом
    /// писать на строке «с форматированием» было бы неправдой. Признаком
    /// считаем ссылку, подчёркивание, зачёркивание, жирный или наклонный
    /// шрифт — либо просто то, что кусок неоднороден.
    static func hasFormatting(_ attributed: NSAttributedString) -> Bool {
        var runs = 0
        var found = false
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attrs, _, stop in
            runs += 1
            if attrs[.link] != nil || attrs[.underlineStyle] != nil
                || attrs[.strikethroughStyle] != nil {
                found = true
                stop.pointee = true
                return
            }
            if let font = attrs[.font] as? NSFont,
               !font.fontDescriptor.symbolicTraits.intersection([.bold, .italic]).isEmpty {
                found = true
                stop.pointee = true
            }
        }
        return found || runs > 1
    }

    /// Запасной признак — по самой разметке, без разбора.
    ///
    /// Нужен там, где разбор не справился: он ходит в WebKit и на чужой
    /// вёрстке может вернуть пустоту, а ссылка в ней при этом есть. Ищем
    /// только то, что не бывает у простого текста: разметку абзацев и цвета
    /// сюда не берём — ими Electron заворачивает и обычное выделение строки.
    static func looksFormatted(html: Data?) -> Bool {
        guard let html, let text = String(data: html, encoding: .utf8) else { return false }
        let lower = text.lowercased()
        return ["<a ", "<b>", "<strong", "<em", "<i>", "<u>", "<li", "<h1", "<h2", "<code"]
            .contains { lower.contains($0) }
    }

    static func rtfData(_ attributed: NSAttributedString) -> Data? {
        try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func htmlData(_ attributed: NSAttributedString) -> Data? {
        try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                             documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
    }

    /// HTML из хранимого RTF — для программ, которые предпочитают его,
    /// когда своего HTML у заготовки нет (её взяли из родной программы).
    static func htmlData(fromRTF rtf: Data) -> Data? {
        attributed(rtf: rtf).flatMap(htmlData)
    }

    /// Видимый текст из хранимого RTF — для проверок и зондов.
    static func plainText(fromRTF rtf: Data) -> String? {
        attributed(rtf: rtf)?.string
    }

    // MARK: Ссылки

    /// Первая ссылка в заготовке — из разметки, а не из текста.
    static func firstLink(in snippet: Snippet) -> String? {
        if let rtf = snippet.rich, let found = attributed(rtf: rtf).flatMap(firstLink) {
            return found
        }
        if let html = snippet.html {
            if let found = attributed(html: html).flatMap(firstLink) { return found }
            return firstHref(html)
        }
        return nil
    }

    static func firstLink(_ attributed: NSAttributedString) -> String? {
        var found: String?
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if let url = value as? URL { found = url.absoluteString; stop.pointee = true }
            if let text = value as? String { found = text; stop.pointee = true }
        }
        return found
    }

    /// Ссылка прямо из разметки, без разбора: `href="…"`.
    static func firstHref(_ html: Data) -> String? {
        guard let text = String(data: html, encoding: .utf8) else { return nil }
        guard let range = text.range(of: "href=[\"']([^\"']+)[\"']",
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        let piece = text[range]
        guard let open = piece.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let value = piece[piece.index(after: open)...].dropLast()
        return value.isEmpty ? nil : String(value)
    }

    /// Ссылка, которой нет в простом варианте.
    ///
    /// Ровно это и объясняет, почему «Zoom» со ссылкой внутри, вставленный
    /// в Telegram, превращается в слово «Zoom»: Telegram берёт из буфера
    /// голую строку, а ссылка живёт в разметке.
    static func linkMissingFromText(_ snippet: Snippet) -> String? {
        guard let link = firstLink(in: snippet) else { return nil }
        return snippet.payload.contains(link) ? nil : link
    }

    /// Подпись про простой вариант — почему в Telegram вставляется слово,
    /// а не ссылка.
    static let plainLinkNote =
        "Ссылки нет в простом варианте: где форматирование не поддерживается, вставится только текст"

    /// Что написать под строкой заготовки в настройках.
    ///
    /// Пустая заготовка молчать не должна: ровно на этом человек и споткнулся —
    /// вписал название, не заметил второго поля и получил в панели плашку,
    /// которая не нажимается.
    static func statusNote(_ snippet: Snippet) -> String? {
        if !snippet.isReady { return "Текст не задан — плашка в панели не нажимается" }
        if snippet.isRich { return "С форматированием: ссылки и выделение переживут вставку" }
        return nil
    }

    /// Чем ответить на нажатие «Взять из буфера».
    static func captureNote(_ capture: SnippetCapture) -> String {
        switch capture {
        case .rich: return "Взято с форматированием"
        case .plain: return "Взят простой текст: форматирования в буфере не было"
        case .tooBig: return "Форматирование не влезло — взят простой текст"
        case .empty: return "В буфере обмена нечего взять"
        }
    }
}
