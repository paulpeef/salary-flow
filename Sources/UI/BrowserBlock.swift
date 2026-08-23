import AppKit
import SwiftUI

/// Выбор браузера по умолчанию в панели.
///
/// Стоит последним, под опросом: это не то, зачем панель открывают, но именно
/// панель — самое частое место, куда человек и так заглядывает несколько раз
/// за день. Системные настройки для той же смены требуют четырёх шагов вглубь.
///
/// Блок появляется, только когда его включили в настройках: у большинства
/// браузер один, и переключать им нечего.
struct BrowserBlock: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browsers: BrowserSwitcher

    private var list: [BrowserApp] {
        BrowserRules.panelList(installed: browsers.installed,
                               hidden: Set(model.settings.browserPickerHidden),
                               current: browsers.currentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            // Один браузер переключать не на что. Строка на месте плашек, а не
            // пустота: блок включили руками, и молчание выглядело бы поломкой.
            if list.count < 2 {
                Text("Других браузеров на этой машине не нашлось")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                WrapFlow(spacing: 5, lineSpacing: 5) {
                    ForEach(list) { chip($0) }
                }
            }
        }
        // Своего `onAppear` здесь нет намеренно: список перечитывает модель
        // в момент раскрытия панели — и она же делает это при запуске,
        // при включении тумблера и при возвращении в приложение. Второй
        // источник тех же вызовов пришлось бы держать с ней в согласии руками.
    }

    /// Заголовок он же место для отказа: отдельной строкой сообщение о неудаче
    /// меняло бы высоту панели, а она должна быть постоянной.
    private var header: some View {
        Text(browsers.failure ?? "Браузер по умолчанию")
            .font(.system(size: 11))
            .foregroundStyle(browsers.failure == nil ? Color.secondary : Color.orange)
            .textCase(.uppercase)
            .lineLimit(1)
            .help(browsers.failure == nil
                  ? "Нажмите на браузер, чтобы он открывал ссылки. Вопросов система не задаёт, но пересчитывает не мгновенно — плашка пару секунд остаётся приглушённой."
                  : "Система не дала сменить хозяина ссылок. Дословный отказ — в журнале.")
    }

    private func chip(_ browser: BrowserApp) -> some View {
        let selected = browser.bundleID == browsers.currentID
        let pending = browsers.switching == browser.bundleID

        return Button {
            browsers.setDefault(browser)
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: BrowserIcon.image(for: browser))
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(browser.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            // Те же плашки, что и у опроса: одна панель — один язык. Цвет
            // системный, а не свой: выбранный браузер — это состояние системы,
            // а не настроение, и придумывать ему отдельный цвет незачем.
            .background(selected ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.06),
                        in: Capsule())
            .overlay {
                if selected {
                    Capsule().strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1)
                }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            // Ждём ответа системы: плашка приглушена, но не исчезает и размера
            // не меняет — иначе панель дёрнулась бы на время системного вопроса.
            .opacity(pending ? 0.45 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Выключается только плашка, ответа по которой ждём. Текущую не
        // выключаем: `.disabled` гасит и текст, а самая читаемая плашка
        // в блоке должна быть как раз та, что показывает нынешний выбор.
        // Нажатие по ней и так ничего не делает — это проверяется в модели.
        .disabled(pending)
        .help(selected ? "\(browser.name) уже открывает ссылки"
                       : "Открывать ссылки в \(browser.name)")
    }
}

// MARK: - Иконки

/// Иконки программ у системы спрашиваются один раз за сеанс: панель
/// перерисовывается раз в секунду, и ходить за ними на каждый тик незачем.
@MainActor
enum BrowserIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for browser: BrowserApp) -> NSImage {
        if let cached = cache[browser.bundleID] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: browser.url.path)
        cache[browser.bundleID] = icon
        return icon
    }
}

// MARK: - Раздел настроек

/// «Браузер» в окне настроек: включить блок в панели и выбрать, какие браузеры
/// в нём показывать.
struct BrowserTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browsers: BrowserSwitcher

    var body: some View {
        Form {
            Section {
                // Кто сейчас по умолчанию, здесь не повторяется: это написано
                // строкой ниже, в самом списке. Дважды на одном экране —
                // ровно та тавтология, которую отсюда уже однажды убирали.
                Toggle("Показывать выбор в панели", isOn: $model.settings.browserPickerEnabled)
            } header: {
                Text("Браузер по умолчанию")
            } footer: {
                Text("Блок появится внизу панели, под опросом: рабочий браузер и личный переключаются одним нажатием, не заходя в системные настройки. Никаких вопросов система при этом не задаёт — то же самое делают «Основные → Веб-браузер по умолчанию», только в четыре шага. Само по себе, без нажатия, приложение браузер не меняет никогда.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if browsers.installed.isEmpty {
                    Text("Браузеров на этой машине не нашлось").foregroundStyle(.secondary)
                } else {
                    ForEach(browsers.installed) { browser in
                        Toggle(isOn: shown(browser)) {
                            HStack(spacing: 6) {
                                Image(nsImage: BrowserIcon.image(for: browser))
                                    .resizable().frame(width: 16, height: 16)
                                Text(browser.name)
                                if browser.bundleID == browsers.currentID {
                                    Text("сейчас по умолчанию")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Какие показывать в панели")
            } footer: {
                Text("Список — это всё, что на машине умеет открывать ссылки; новый браузер появится в нём сам. Текущий показывается в панели всегда, даже со снятой галочкой: блок называется «Браузер по умолчанию», и не показать в нём тот, который сейчас по умолчанию, было бы враньём.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Раздел открыли — перечитываем: браузер могли поставить или сменить,
        // пока приложение работало.
        .onAppear { browsers.refresh() }
    }

    private func shown(_ browser: BrowserApp) -> Binding<Bool> {
        Binding(
            get: { !model.settings.browserPickerHidden.contains(browser.bundleID) },
            set: { show in
                var hidden = Set(model.settings.browserPickerHidden)
                if show { hidden.remove(browser.bundleID) } else { hidden.insert(browser.bundleID) }
                // Порядок в файле настроек постоянный: иначе каждая правка
                // выглядела бы в копии для переезда как другое значение.
                model.settings.browserPickerHidden = hidden.sorted()
            }
        )
    }
}
