import AppKit

enum MeetingClipboard {
    static func textForCopy(_ text: String) -> String {
        let chat = text.range(of: "\n\nЧат встречи\n")
        let speech = text[..<(chat?.lowerBound ?? text.endIndex)]
        let plain = String(speech).replacingOccurrences(
            of: #"(?m)^\[[0-9]{2,}:[0-5][0-9]:[0-5][0-9]\] (?=[^\n]+? — )"#,
            with: "", options: .regularExpression)
        return plain + (chat.map { String(text[$0.lowerBound...]) } ?? "")
    }

    @MainActor static func write(_ text: String, to board: NSPasteboard = .general) -> Bool {
        board.clearContents()
        guard board.setString(text, forType: .string) else { return false }
        // Another process can claim the board between writing and verification.
        let generation = board.changeCount
        return board.string(forType: .string) == text && board.changeCount == generation
    }
}

/// The popover closes when Spokenly shows its file window. Keep status visible
/// independently, without taking focus away from the user's work.
@MainActor final class MeetingNotice {
    private var panel: NSPanel?
    private var dismiss: Task<Void, Never>?

    func show(_ title: String, detail: String, icon: String = "exclamationmark.triangle") {
        dismiss?.cancel()
        panel?.orderOut(nil)
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleField, detailField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let symbol = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 21, weight: .medium))
        let image = NSImageView(image: symbol ?? NSImage())
        image.imageScaling = .scaleNone
        image.contentTintColor = .labelColor
        image.setAccessibilityElement(false)
        let row = NSStackView(views: [image, stack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        image.setContentHuggingPriority(.required, for: .horizontal)
        image.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleField.lineBreakMode = .byTruncatingTail
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 368, height: 82),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = background
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - 12))
        self.panel = panel
        panel.orderFrontRegardless()
        dismiss = Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            self.panel = nil
        }
    }
}
