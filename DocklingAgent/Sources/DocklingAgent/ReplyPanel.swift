import AppKit

/// A small speech-bubble-style panel shown on Dock-icon click while a session
/// is awaiting input — shows the question and a text field, in the spirit of
/// Masko Code's popover per DOCKLING_SPEC.md's Phase 3 design. Positioned
/// directly above the Dock on whichever screen the click actually happened
/// on, centered under the click point.
///
/// This intentionally does NOT use the Accessibility API to look up the Dock
/// icon's exact frame: with multiple displays, macOS mirrors the same Dock
/// icons across each screen's Dock, but there's only one AX element per icon,
/// anchored to the "real" (laptop) Dock — so an AX-based lookup places the
/// popover on the wrong screen when the user clicks a mirrored copy. The
/// click's own location is already on the correct screen, so it's used
/// directly instead (see DOCKLING_SPEC.md discussion / git history for the
/// abandoned DockPosition.swift + PositionServer.swift approach).
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
    private let dockGap: CGFloat = 8 // small gap so the panel doesn't touch the Dock

    init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
    }

    /// `clickLocation` is `NSEvent.mouseLocation` captured as close as
    /// possible to the Dock click (AppKit global coordinates: bottom-left
    /// origin, Y-up), so it's still on the screen the user actually clicked.
    func show(question: String, near clickLocation: NSPoint) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(clickLocation) }) ?? NSScreen.main
        buildAndShow(question: question, clickLocation: clickLocation, screen: screen)
    }

    private func buildAndShow(question: String, clickLocation: NSPoint, screen: NSScreen?) {
        panel?.close()

        let labelWidth = width - horizontalPadding * 2
        let unclampedHeight = ceil((question as NSString).boundingRect(
            with: NSSize(width: labelWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: questionFont]
        ).height)
        let labelHeight = min(unclampedHeight, maxLabelHeight)
        let height = verticalPadding * 2 + labelHeight + labelFieldGap + fieldHeight

        let origin: NSPoint
        if let screen {
            // visibleFrame already excludes the Dock's reserved space, so its
            // minY is exactly the top of the Dock on this screen.
            let clampedX = min(max(clickLocation.x - width / 2, screen.frame.minX), screen.frame.maxX - width)
            origin = NSPoint(x: clampedX, y: screen.visibleFrame.minY + dockGap)
        } else {
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            origin = NSPoint(x: screenFrame.midX - width / 2, y: screenFrame.minY + 16)
        }

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

        // No NSApp.activate() — a .nonactivatingPanel can become key and take
        // input without a full app-switch, which is what was making this feel
        // slow (a real macOS app-activation animation on every open).
        panel.makeKeyAndOrderFront(nil)
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
