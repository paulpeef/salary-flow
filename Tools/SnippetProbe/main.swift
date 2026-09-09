import AppKit
import Foundation

// Зонд заготовок: гоняет настоящую модель по настоящему буферу обмена.
//
// Отвечает на то, чего не видят ни тесты, ни оффскрин-рендер. Тесты проверяют
// правила на строках, рендер — как плашка выглядит на одном кадре. А сюда
// не подставить ничего: `NSPasteboard` — системная вещь, и «текст правда лёг
// в буфер» проверяется только настоящим буфером. Здесь же проверяется отметка
// «скопировано»: она гаснет сама через полторы секунды, и её жизнь видна
// только живой модели с живыми часами.
//
// Чужой буфер обмена зонд возвращает как было: содержимое снимается перед
// работой со всеми типами данных и кладётся обратно в конце.
// Запуск: ./Tools/snippetprobe.sh

var failures: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("  \(ok ? "✓" : "✗") \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
    if !ok { failures.append(name) }
}

/// Крутим настоящий RunLoop: отметка гаснет из `Task` на главной очереди,
/// и подменять ожидание сном потока нельзя — задача просто не выполнится.
@MainActor
func wait(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Снимок чужого буфера обмена — со всеми типами, а не только строкой:
/// вернуть надо ровно то, что человек копировал до запуска зонда.
func snapshotPasteboard() -> [NSPasteboardItem] {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    }
}

func restorePasteboard(_ items: [NSPasteboardItem]) {
    let board = NSPasteboard.general
    board.clearContents()
    if !items.isEmpty { board.writeObjects(items) }
}

func clipboard() -> String? { NSPasteboard.general.string(forType: .string) }

/// «Пикл» Chromium, собранный так же, как его кладёт Slack: u32 число пар,
/// дальше пары строк UTF-16 с длиной в символах и выравниванием до 4 байт.
/// Нужен, чтобы прогнать через настоящий буфер обмена ровно тот случай,
/// на котором заготовка ломалась.
func chromiumPickle(_ entries: [(String, String)]) -> Data {
    var payload = Data()

    func uint32(_ value: Int) {
        var little = UInt32(value).littleEndian
        payload.append(Data(bytes: &little, count: 4))
    }

    func string16(_ text: String) {
        let units = Array(text.utf16)
        uint32(units.count)
        for unit in units {
            var little = unit.littleEndian
            payload.append(Data(bytes: &little, count: 2))
        }
        while payload.count % 4 != 0 { payload.append(0) }
    }

    uint32(entries.count)
    for (key, value) in entries {
        string16(key)
        string16(value)
    }

    var size = UInt32(payload.count).littleEndian
    var data = Data(bytes: &size, count: 4)
    data.append(payload)
    return data
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    print("== Зонд заготовок ==")

    let saved = snapshotPasteboard()
    print("\nБуфер обмена снят: элементов \(saved.count) (вернём в конце)")

    let model = AppModel()

    let link = Snippet(name: "Созвон", text: "  https://example.test/room  \n")
    let address = Snippet(name: "Адрес", text: "Улица, дом 24\n3 этаж")
    let empty = Snippet(name: "Пустая", text: "   \n ")

    var settings = model.settings
    settings.snippetsEnabled = true
    settings.snippets = [link, address, empty]
    model.settings = settings

    check("заготовки подхватились моделью", model.snippets.count == 3)

    // MARK: Нажатие кладёт текст в буфер

    print("\nНажатие на заготовку")
    model.copySnippet(link)
    check("текст лёг в буфер обмена без пробелов по краям",
          clipboard() == "https://example.test/room",
          "в буфере «\(clipboard() ?? "пусто")»")
    check("плашка показывает «скопировано»", model.copiedSnippet == link.id)

    // MARK: Отметка гаснет сама

    print("\nЖизнь отметки «скопировано» (\(SnippetRules.flashSeconds) с)")
    wait(SnippetRules.flashSeconds - 0.4)
    check("за полсекунды до срока отметка ещё горит", model.copiedSnippet == link.id)
    wait(0.8)
    check("после срока отметка погасла", model.copiedSnippet == nil)

    // MARK: Перевод строки внутри заготовки

    print("\nЗаготовка в несколько строк")
    model.copySnippet(address)
    check("перевод строки внутри текста уцелел",
          clipboard() == "Улица, дом 24\n3 этаж",
          "в буфере «\(clipboard() ?? "пусто")»")

    // MARK: Пустая заготовка чужой буфер не трогает

    print("\nПустая заготовка")
    // Сперва даём погаснуть отметке прошлой заготовки: иначе проверка ниже
    // увидела бы её и не отличила от зажжённой пустой.
    wait(SnippetRules.flashSeconds + 0.2)
    let before = clipboard()
    model.copySnippet(empty)
    check("буфер остался нетронутым", clipboard() == before,
          "было «\(before ?? "пусто")», стало «\(clipboard() ?? "пусто")»")
    check("отметка не зажглась", model.copiedSnippet == nil)

    // MARK: Второе нажатие поверх первого

    // Отметка от первой заготовки гаснет по таймеру, заведённому в момент
    // нажатия. Если его не снять, он погасит и отметку второй — раньше срока.
    print("\nДва нажатия подряд")
    model.copySnippet(link)
    wait(0.8)
    model.copySnippet(address)
    check("отметка переехала на вторую заготовку", model.copiedSnippet == address.id)
    wait(SnippetRules.flashSeconds - 0.6)
    check("таймер первой не гасит отметку второй", model.copiedSnippet == address.id)
    wait(0.8)
    check("отметка второй гаснет в свой срок", model.copiedSnippet == nil)

    // MARK: Форматирование через настоящий буфер

    // Ради этого куска зонд и нужен больше всего: «ссылка переживёт вставку»
    // проверяется только настоящим буфером обмена, куда сначала кладут
    // размеченный кусок — так же, как это делает Slack, — а потом смотрят,
    // что оттуда достала модель и что она положила обратно.
    print("\nЗаготовка с форматированием")

    let linked = NSMutableAttributedString(string: "Zoom")
    linked.addAttribute(.link, value: URL(string: "https://example.test/room")!,
                        range: NSRange(location: 0, length: linked.length))
    let source = NSPasteboardItem()
    source.setData(SnippetRules.rtfData(linked)!, forType: .rtf)
    source.setString("Zoom", forType: .string)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([source])

    var withSlot = model.settings
    withSlot.snippetsEnabled = true
    withSlot.snippets = [Snippet(name: "Созвон", text: "")]
    model.settings = withSlot
    let slot = model.settings.snippets[0].id

    let capture = model.captureSnippetFromClipboard(into: slot)
    check("из буфера взято форматирование",
          { if case .rich = capture { return true }; return false }(),
          SnippetRules.captureNote(capture))
    check("поле текста заполнилось само", model.settings.snippets[0].text == "Zoom")
    check("заготовка помечена как форматированная", model.settings.snippets[0].isRich)

    // А теперь обратно: нажатие на плашку должно положить в буфер все три
    // представления — размеченное для родных программ, HTML для Electron
    // и голую строку для полей, где форматирования не бывает.
    NSPasteboard.general.clearContents()
    model.copySnippet(model.settings.snippets[0])
    let board = NSPasteboard.general
    check("в буфере есть размеченный текст", board.data(forType: .rtf) != nil)
    check("в буфере есть HTML для Electron", board.data(forType: .html) != nil)
    check("в буфере есть простая строка", clipboard() == "Zoom")

    var pasted: String?
    if let data = board.data(forType: .rtf),
       let restored = NSAttributedString(rtf: data, documentAttributes: nil) {
        restored.enumerateAttribute(.link,
                                    in: NSRange(location: 0, length: restored.length)) { value, _, _ in
            if let url = value as? URL { pasted = url.absoluteString }
            if let text = value as? String { pasted = text }
        }
    }
    check("ссылка дошла до буфера обмена",
          pasted == "https://example.test/room", "получено \(pasted ?? "ничего")")

    // MARK: Разметка из программ на Electron

    // Slack, Notion и прочее на Electron кладут в буфер HTML, а RTF не кладут
    // вовсе. Разметку надо вернуть дословно — именно её они и читают
    // при вставке; пересобранная из RTF, она была бы уже не той.
    print("\nРазметка из программ на Electron (HTML)")

    let slackHTML = Data("""
    <meta charset='utf-8'><span style="color: rgb(29, 28, 29); white-space: pre-wrap;">\
    <a class="c-link" href="https://example.test/j/1234567890" rel="noopener noreferrer" \
    target="_blank">Личная комната</a></span>
    """.utf8)
    let electron = NSPasteboardItem()
    electron.setData(slackHTML, forType: .html)
    electron.setString("Личная комната", forType: .string)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([electron])

    var htmlSlot = model.settings
    htmlSlot.snippets = [Snippet(name: "Комната", text: "")]
    model.settings = htmlSlot
    let htmlID = model.settings.snippets[0].id

    let htmlCapture = model.captureSnippetFromClipboard(into: htmlID)
    check("HTML без RTF берётся с форматированием",
          { if case .rich = htmlCapture { return true }; return false }(),
          SnippetRules.captureNote(htmlCapture))
    check("разметка сохранена дословно", model.settings.snippets[0].html == slackHTML)
    check("для родных программ достроен RTF", model.settings.snippets[0].rich != nil)
    check("ссылку видно в заготовке",
          SnippetRules.firstLink(in: model.settings.snippets[0]) == "https://example.test/j/1234567890")
    check("в простом варианте ссылки нет — и программа об этом знает",
          SnippetRules.linkMissingFromText(model.settings.snippets[0]) != nil)

    NSPasteboard.general.clearContents()
    model.copySnippet(model.settings.snippets[0])
    check("разметка вернулась в буфер дословно",
          SnippetRules.clipboardHTML(NSPasteboard.general) == slackHTML)
    check("рядом лежит RTF для родных программ",
          SnippetRules.clipboardRTF(NSPasteboard.general) != nil)
    check("рядом лежит простая строка", clipboard() == "Личная комната")

    // MARK: Так кладёт Slack

    // Ровно тот случай, на котором заготовка ломалась дважды: Slack не кладёт
    // ни RTF, ни HTML — только строку и свой «пикл» Chromium, внутри которого
    // лежит «дельта» со ссылкой в атрибуте. Форма снята зондом буфера
    // с живого Slack (2026-09-04), адрес здесь выдуман.
    print("\nБуфер обмена в том виде, в каком его кладёт Slack")

    let delta = """
    {"ops":[{"insert":{"slackemoji":{"text":":slack_call:"}}},{"insert":" "},\
    {"attributes":{"link":"https://example.test/my/room?pwd=abc.1"},"insert":"Zoom"},\
    {"insert":" "}]}
    """
    let slackItem = NSPasteboardItem()
    slackItem.setData(chromiumPickle([("public.utf8-plain-text", ":slack_call: Zoom "),
                                      ("slack/texty", delta)]),
                      forType: SnippetRules.chromiumCustomType)
    slackItem.setString(":slack_call: Zoom ", forType: .string)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([slackItem])

    check("общей разметки в таком буфере нет вовсе",
          SnippetRules.clipboardHTML(NSPasteboard.general) != nil
            && NSPasteboard.general.data(forType: .html) == nil)

    var slackSlot = model.settings
    slackSlot.snippets = [Snippet(name: "Zoom", text: "")]
    model.settings = slackSlot
    let slackID = model.settings.snippets[0].id

    let slackCapture = model.captureSnippetFromClipboard(into: slackID)
    check("из буфера Slack берётся форматирование",
          { if case .rich = slackCapture { return true }; return false }(),
          SnippetRules.captureNote(slackCapture))
    check("ссылка достаётся из дельты",
          SnippetRules.firstLink(in: model.settings.snippets[0])
            == "https://example.test/my/room?pwd=abc.1",
          SnippetRules.firstLink(in: model.settings.snippets[0]) ?? "ничего")
    check("простой вариант — тот, что дал Slack",
          model.settings.snippets[0].text == ":slack_call: Zoom")

    NSPasteboard.general.clearContents()
    model.copySnippet(model.settings.snippets[0])
    check("в буфер вернулась разметка, которую читают все",
          SnippetRules.clipboardHTML(NSPasteboard.general) != nil)
    check("рядом лежит RTF для родных программ",
          SnippetRules.clipboardRTF(NSPasteboard.general) != nil)

    var backLink: String?
    if let data = SnippetRules.clipboardRTF(NSPasteboard.general),
       let restored = SnippetRules.attributed(rtf: data) {
        backLink = SnippetRules.firstLink(restored)
    }
    check("ссылка дошла до буфера живой",
          backLink == "https://example.test/my/room?pwd=abc.1", backLink ?? "ничего")

    // MARK: Блок выключили

    print("\nБлок выключили в настройках")
    model.copySnippet(link)
    var off = model.settings
    off.snippetsEnabled = false
    model.settings = off
    check("отметка снята вместе с блоком", model.copiedSnippet == nil)

    restorePasteboard(saved)
    print("\nБуфер обмена возвращён: «\(clipboard()?.prefix(40) ?? "пусто")»")

    print("")
    if failures.isEmpty {
        print("✅ Зонд прошёл")
        exit(0)
    } else {
        print("❌ Провалено: \(failures.count)")
        failures.forEach { print("   \($0)") }
        exit(1)
    }
}
