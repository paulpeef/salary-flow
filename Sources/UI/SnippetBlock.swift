import SwiftUI

/// Заготовки в панели: облако плашек, нажатие кладёт заготовку в буфер обмена.
///
/// Стоит под таймером и над опросом — там же, где и таймер, по той же причине:
/// это действие, ради которого панель открыли, а опрос — вопрос вдогонку.
/// Блок появляется, только когда его включили в настройках.
///
/// На плашке видно имя, а не текст, и это не экономия места: панель открывают
/// и во время демонстрации экрана. Личная ссылка на созвон, домашний адрес
/// и номер телефона не должны быть видны залу ровно в тот момент, когда их
/// собрались отправить одному человеку.
struct SnippetBlock: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            chips
        }
    }

    // MARK: Заголовок

    private var header: some View {
        Text("Под рукой")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .lineLimit(1)
            .help("Нажмите на заготовку — её текст ляжет в буфер обмена, дальше обычная вставка. Сам текст в панели не показывается, только название.")
    }

    // MARK: Плашки

    @ViewBuilder
    private var chips: some View {
        let list = model.snippets

        if list.isEmpty {
            // Блок включили руками — молчание выглядело бы поломкой.
            Text("Ни одной заготовки не заведено")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.vertical, 4)
        } else {
            // То же облако, что у опроса: одна панель — один язык раскладки.
            // Набор плашек постоянен, пока панель открыта, поэтому и число
            // рядов постоянно — от этого зависит неизменная высота панели.
            WrapFlow(spacing: 5, lineSpacing: 5) {
                ForEach(list) { chip($0) }
            }
        }
    }

    private func chip(_ snippet: Snippet) -> some View {
        let copied = model.copiedSnippet == snippet.id
        let ready = snippet.isReady

        return Button {
            model.copySnippet(snippet)
        } label: {
            HStack(spacing: 4) {
                // Ширина у значка постоянная: галочка и две страницы рисуются
                // разной шириной, а от смены ширины облако переносит плашку
                // на другой ряд — и панель дёргается на каждое нажатие.
                Image(systemName: symbol(ready: ready, copied: copied))
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 11)
                Text(SnippetRules.chipName(snippet.name))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            // Зелёная заливка на полторы секунды — тот же язык, что у выбранной
            // плашки настроения. Зелёный, а не системный синий: это не выбор,
            // который держится, а ответ «сделано», который сейчас погаснет.
            .background(copied ? Color.green.opacity(0.22) : Color.primary.opacity(0.06),
                        in: Capsule())
            .overlay {
                if copied {
                    Capsule().strokeBorder(Color.green.opacity(0.75), lineWidth: 1)
                }
            }
            .foregroundStyle(copied ? Color.primary : Color.secondary)
            // Пустая заготовка приглушена, но остаётся на месте: убрать её
            // из панели значило бы молча потерять то, что человек завёл сам.
            .opacity(ready ? 1 : 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .help(SnippetRules.chipHint(name: snippet.name, isReady: ready, copied: copied))
    }

    /// Значок на плашке: что она сделает или что уже сделала.
    private func symbol(ready: Bool, copied: Bool) -> String {
        if copied { return "checkmark" }
        return ready ? "doc.on.doc" : "square.dashed"
    }
}

// MARK: - Раздел настроек

/// «Под рукой» в окне настроек: включить блок в панели и завести сами заготовки.
struct SnippetsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Показывать заготовки в панели", isOn: $model.settings.snippetsEnabled)
            } header: {
                Text("Под рукой")
            } footer: {
                Text("Блок встанет в панели под таймером: нажатие кладёт заготовку в буфер обмена, дальше обычная вставка. В панели видно только название — текст не показывается там никогда, потому что панель открывают и во время демонстрации экрана. Сам по себе счётчик в буфер обмена не пишет и не заглядывает в него: он трогает буфер ровно на одно нажатие.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if model.settings.snippets.isEmpty {
                    Text("Ни одной заготовки не заведено").foregroundStyle(.secondary)
                } else {
                    ForEach($model.settings.snippets) { $snippet in
                        SnippetRow(model: model, snippet: $snippet)
                    }
                }

                Button {
                    model.settings.snippets.append(
                        Snippet(name: SnippetRules.defaultName, text: ""))
                } label: {
                    Label("Добавить заготовку", systemImage: "plus")
                }
                .disabled(!SnippetRules.canAdd(model.settings.snippets))
            } header: {
                Text("Что держать под рукой")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("У каждой заготовки две части: название — оно и стоит на плашке в панели — и текст, который ляжет в буфер обмена. Без текста плашка в панели видна, но не нажимается: копировать нечего.")
                    Text("«Взять из буфера» переносит в заготовку то, что скопировано прямо сейчас, вместе с форматированием: слово со ссылкой внутри, выделение, несколько абзацев. Скопируйте нужное в Slack, почте или заметках — и нажмите. Своего редактора с форматированием здесь нет намеренно: нужное уже набрано там, откуда его копируют.")
                    Text("Не больше шести: плашки раскладываются в панели облаком, как ответы опроса. Название лучше в одно слово — тогда все шесть укладываются в два ряда; длинное на плашке ужмётся до \(SnippetRules.chipNameLength) знаков.")
                    Text("Заготовки едут в копии для переезда вместе с остальными настройками и лежат в файле настроек открыто: паролям и кодам там не место, для них есть связка ключей.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Строка одной заготовки.
///
/// Своим типом, а не функцией, ради одной вещи: ответ на «Взять из буфера»
/// («взято с форматированием», «в буфере нечего брать») живёт в самой строке
/// и умирает вместе с ней. В разделе он был бы общим на все шесть строк,
/// и пришлось бы помнить, к какой из них относится.
private struct SnippetRow: View {
    @ObservedObject var model: AppModel
    @Binding var snippet: Snippet

    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Две части заготовки стоят друг под другом, а не в одну строку.
            // В строку они не помещались по-честному: поле текста ужималось
            // до полоски, и человек его просто не замечал — вписывал название
            // и получал в панели плашку, которая не нажимается.
            HStack(spacing: 8) {
                TextField("Название", text: $snippet.name)
                    .labelsHidden()
                    .frame(width: 130)

                Spacer(minLength: 8)

                Button("Взять из буфера") {
                    note = SnippetRules.captureNote(
                        model.captureSnippetFromClipboard(into: snippet.id))
                }
                .help("Скопируйте нужное в другой программе — со ссылками и выделением — и нажмите здесь. Заготовка запомнит скопированное как есть.")

                Button {
                    let id = snippet.id
                    model.settings.snippets.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Убрать эту заготовку")
            }

            // Поле растёт вниз, а не уезжает вбок: ссылка на созвон длиннее
            // строки, и проверить глазами, та ли она, в однострочном поле
            // нельзя — а править её будут раз в год, вслепую.
            // Поле правится всегда, в том числе у форматированной заготовки,
            // и это не оплошность: у такой заготовки два варианта — размеченный
            // и простой, — и поле показывает именно простой. Он и вставляется
            // туда, где форматирования не бывает (Telegram, поля ввода,
            // терминал), и решать, что там окажется, должен человек.
            TextField("Текст, который ляжет в буфер обмена", text: text, axis: .vertical)
                .labelsHidden()
                .lineLimit(1...4)
                .help(snippet.isRich
                      ? "Простой вариант: он вставится туда, где форматирования не бывает. Со ссылками и выделением вставится то, что взято из буфера."
                      : "Этот текст и ляжет в буфер обмена по нажатию на плашку")

            status
        }
        .padding(.vertical, 2)
    }

    /// Строки под полями: чего не хватает, что уже взято, чем это обернётся
    /// при вставке и чем ответило последнее нажатие.
    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !snippet.isReady {
                // Оранжевым, а не серым: ровно этого человек и не заметил.
                Label(SnippetRules.statusNote(snippet) ?? "", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if snippet.isRich {
                HStack(spacing: 8) {
                    Label(SnippetRules.statusNote(snippet) ?? "", systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    // Кнопкой с рамкой, а не ссылкой: `.buttonStyle(.link)`
                    // не попадает в оффскрин-рендер — грабля этого проекта,
                    // оплаченная ещё на опросе. Да и текст без рамки здесь
                    // не отличить от подписи слева.
                    Button("Убрать форматирование") {
                        snippet.rich = nil
                        snippet.html = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Оставить только текст — без ссылок и выделения")
                }

                // Ссылка есть в разметке, но её нет в простом варианте — ровно
                // это и превращает «Zoom» в слово «Zoom» при вставке туда,
                // где форматирования не бывает. Программа об этом знает,
                // значит должна сказать, а не оставлять выяснять опытом.
                if let link = SnippetRules.linkMissingFromText(snippet) {
                    HStack(spacing: 8) {
                        Label(SnippetRules.plainLinkNote, systemImage: "arrow.uturn.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 8)

                        Button("Подставить ссылку") { snippet.text = link }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("В поле встанет сам адрес: \(link)")
                    }
                }
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Длина режется на вводе, а не при показе: настройки перезаписываются
    /// целиком на каждое нажатие клавиши, и вставленный в поле роман попадал бы
    /// в файл ещё до того, как его кто-нибудь нормализует.
    private var text: Binding<String> {
        Binding(
            get: { snippet.text },
            set: { snippet.text = SnippetRules.clamped($0) }
        )
    }
}
