import AppKit

/// A small speech-bubble-style panel shown on Dock-icon click while a session
/// is awaiting input — shows the question and a text field, in the spirit of
/// Masko Code's popover per DOCKLING_SPEC.md's Phase 3 design. Not pixel-anchored
/// to the actual Dock tile position (AppKit doesn't expose that for a regular
/// app's custom Dock tile); approximated as centered near the bottom of the
/// screen, which is where the Dock usually is.
final class ReplyPanelController: NSObject, NSTextFieldDelegate {
    private var panel: NSPanel?
    private let onSubmit: (String) -> Void

    init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
    }

    func show(question: String) {
        panel?.close()

        let width: CGFloat = 320
        let height: CGFloat = 110
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
        label.frame = NSRect(x: 16, y: height - 52, width: width - 32, height: 40)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        contentView.addSubview(label)

        let field = NSTextField(frame: NSRect(x: 16, y: 16, width: width - 32, height: 24))
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

    private var activeField: NSTextField?

    @objc private func submit(_ sender: NSTextField) {
        let text = sender.stringValue
        panel?.close()
        panel = nil
        guard !text.isEmpty else { return }
        onSubmit(text)
    }
}
