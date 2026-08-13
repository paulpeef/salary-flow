import SwiftUI

/// Опрос в панели: «Как вы себя чувствуете?» и облако плашек.
///
/// Стоит внизу, под цифрами: человек уже посмотрел, сколько накапало, и в этот
/// момент у него есть секунда на один клик. Спрашивать раньше — значит мешать
/// тому, зачем панель открывали.
struct MoodBlock: View {
    @ObservedObject var model: AppModel
    @ObservedObject var log: MoodLog
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let marks = Set(model.currentMoodMarks())
        let hidden = model.amountsHidden

        VStack(alignment: .leading, spacing: 7) {
            // Заголовок без пояснений: плашки больше ничего не делают молча,
            // объяснять правила подписью в панели незачем. Полная формулировка
            // осталась в подсказке при наведении и в разделе статистики.
            Text("Как вы себя чувствуете?")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .help("Отметок можно поставить сколько нужно, и одно состояние можно отмечать хоть каждый час — как часто вы об этом вспоминаете, тоже данные. Пара минут после отметки плашка остаётся выделенной: нажатие в это время снимает её, если нажали не то.")

            // Плашки раскладываются всегда, даже когда спрятаны: их раскладка
            // задаёт высоту блока, а высота панели должна быть постоянной —
            // окно меню-бара перерисовывает подложку не в такт с содержимым.
            // Поэтому в приватном режиме они не убираются, а становятся
            // невидимыми, а поверх ложится объяснение.
            chips(marks: marks)
                .opacity(hidden ? 0 : 1)
                .overlay { if hidden { privacyPlaceholder } }
                .disabled(hidden)

            footer
        }
    }

    // MARK: Плашки

    private func chips(marks: Set<MoodKind>) -> some View {
        WrapFlow(spacing: 5, lineSpacing: 5) {
            ForEach(MoodKind.allCases) { kind in
                chip(kind, selected: marks.contains(kind))
            }
        }
    }

    /// Подсказка на плашке. У выделенной она говорит про снятие, потому что
    /// именно это нажатие и сделает, — а выделение живёт всего пару минут.
    private func chipHint(_ kind: MoodKind, selected: Bool) -> String {
        selected ? "\(kind.hint) — нажмите, чтобы снять отметку" : kind.hint
    }

    private func chip(_ kind: MoodKind, selected: Bool) -> some View {
        Button {
            model.toggleMood(kind)
        } label: {
            HStack(spacing: 4) {
                Text(kind.emoji).font(.system(size: 10))
                // Насыщенность шрифта одна и та же в обоих состояниях: от смены
                // на полужирный плашка становится шире, облако переносит её на
                // новую строку, и высота панели меняется. Выбор показывают
                // заливка и обводка.
                Text(kind.short).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(selected ? kind.tint.opacity(0.22) : Color.primary.opacity(0.06),
                        in: Capsule())
            .overlay {
                if selected {
                    Capsule().strokeBorder(kind.tint.opacity(0.75), lineWidth: 1)
                }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(chipHint(kind, selected: selected))
    }

    private var privacyPlaceholder: some View {
        Text("Опрос скрыт, пока экран могут видеть посторонние")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Подвал блока

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                activateApp()
                model.settingsSection = .mood
                openWindow(id: WindowID.settings)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chart.xyaxis.line")
                    Text("Посмотреть статистику")
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            // Именно .plain, а не .link: ссылочный стиль — AppKit-контрол,
            // и в оффскрин-рендер он не попадает, вместо него знак «нельзя».
            // Проверять эту кнопку было бы нечем.
            .buttonStyle(.plain)

            Spacer()

            // Строка всегда одна: подтверждение не должно менять высоту панели.
            if let at = model.lastMoodMark(), !model.amountsHidden {
                Text("отмечено в \(Fmt.clock(at, timeZone: model.settings.timeZone))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("Последняя сегодняшняя отметка. Отметиться снова можно в любой момент — то же состояние тоже.")
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Облако плашек

/// Раскладка «в строку, пока помещается». Ни `HStack`, ни `Grid` так не умеют:
/// первый выдавливает содержимое за край, второй требует одинаковых колонок,
/// а подписи здесь разной длины.
///
/// Набор плашек постоянный, поэтому и число строк постоянно — от этого зависит
/// неизменная высота панели.
struct WrapFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 272
        let rows = rows(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item { var index: Int; var size: CGSize }
    private struct Row { var items: [Item] = []; var height: CGFloat = 0 }

    private func rows(subviews: Subviews, width: CGFloat) -> [Row] {
        var result: [Row] = []
        var row = Row()
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.items.isEmpty, x + size.width > width {
                result.append(row)
                row = Row()
                x = 0
            }
            row.items.append(Item(index: index, size: size))
            row.height = max(row.height, size.height)
            x += size.width + spacing
        }
        if !row.items.isEmpty { result.append(row) }
        return result
    }
}

// MARK: - Цвета

extension MoodKind {
    /// Цвет состояния. Один и тот же на плашке, на графиках и в теплокарте —
    /// иначе пришлось бы каждый раз заново вспоминать, где какой.
    var tint: Color {
        switch self {
        case .good: return .green
        case .flow: return .mint
        case .tired: return .yellow
        case .hard: return .orange
        case .bored: return .gray
        case .nervous: return .purple
        case .homeSoon: return .blue
        case .quit: return .red
        }
    }
}

enum MoodPalette {
    /// Цвет по индексу 0…100: от красного через жёлтый к зелёному.
    /// Пороги те же, что в выводах, — картинка и текст должны говорить одно.
    static func color(index: Double) -> Color {
        switch index {
        case 70...: return .green
        case 55..<70: return Color.green.opacity(0.55)
        case 45..<55: return .yellow
        case 30..<45: return .orange
        default: return .red
        }
    }
}

extension MoodInsight.Level {
    var symbol: String {
        switch self {
        case .good: return "checkmark.circle"
        case .info: return "info.circle"
        case .attention: return "exclamationmark.circle"
        case .alarm: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .good: return .green
        case .info: return .secondary
        case .attention: return .orange
        case .alarm: return .red
        }
    }
}
