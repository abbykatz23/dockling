import AppKit

/// A small speech-bubble-style panel shown on Dock-icon click while a session
/// is awaiting input — shows the question and a text field, in the spirit of
/// Masko Code's popover per DOCKLING_SPEC.md's Phase 3 design. Not pixel-anchored
/// to the actual Dock tile position (AppKit doesn't expose that for a regular
/// app's custom Dock tile); approximated as centered near the bottom of the
/// screen, which is where the Dock usually is.
final class ReplyPanelController: NSObject, NSTextFieldDelegate {
    private var panel: NSPanel?
    private var activeField: NSTextField?
    private let onSubmit: (String) -> Void

    private let width: CGFloat = 340
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 16
    private let labelFieldGap: CGFloat = 12
    private let fieldHeight: CGFloat = 24
    private let maxLabelHeight: CGFloat = 400 // clamp for pathologically long questions, rather than growing off-screen
    private let questionFont = NSFont.systemFont(ofSize: 12)

    init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
    }

    func show(question: String) {
        panel?.close()

        let labelWidth = width - horizontalPadding * 2
        let unclampedHeight = ceil((question as NSString).boundingRect(
            with: NSSize(width: labelWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: questionFont]
        ).height)
        let labelHeight = min(unclampedHeight, maxLabelHeight)
        let height = verticalPadding * 2 + labelHeight + labelFieldGap + fieldHeight

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screenFrame.midX - width / 2, y: screenFrame.minY + 16)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
                             styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                             backing: .buffered, defer: false)
        panel.title = "Dockling"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let label = NSTextField(wrappingLabelWithString: question)
        label.frame = NSRect(x: horizontalPadding, y: verticalPadding + fieldHeight + labelFieldGap,
                              width: labelWidth, height: labelHeight)
        label.font = questionFont
        label.textColor = .secondaryLabelColor
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        contentView.addSubview(label)

        let field = NSTextField(frame: NSRect(x: horizontalPadding, y: verticalPadding, width: labelWidth, height: fieldHeight))
        field.placeholderString = "Reply…"
        field.target = self
        field.action = #selector(submit(_:))
        field.delegate = self
        contentView.addSubview(field)
        activeField = field

        panel.contentView = contentView
        self.panel = panel

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(field)
    }

    @objc private func submit(_ sender: NSTextField) {
        let text = sender.stringValue
        panel?.close()
        panel = nil
        guard !text.isEmpty else { return }
        onSubmit(text)
    }
}
