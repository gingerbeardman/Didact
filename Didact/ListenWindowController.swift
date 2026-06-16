//
//  ListenWindowController.swift
//  BtnQ
//
//  A simple logging window for Listen mode: a fixed-width, selectable (but not
//  editable) text view with Copy All / Clear. Listening runs only while the
//  window is open — it starts on show and stops when the window closes.
//

import AppKit

@MainActor
final class ListenWindowController: NSObject, NSWindowDelegate {
    private let windowTitle: String
    private let makeListener: (@escaping (String) -> Void) -> DDCListener
    private let onClose: () -> Void

    private var window: NSWindow?
    private var textView: NSTextView?
    private var searchField: NSSearchField?
    private var listener: DDCListener?

    private var allLines: [String] = []   // every logged line; the view shows the filtered subset
    private var filterText = ""

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init(title: String,
         makeListener: @escaping (@escaping (String) -> Void) -> DDCListener,
         onClose: @escaping () -> Void) {
        self.windowTitle = title
        self.makeListener = makeListener
        self.onClose = onClose
    }

    func show() {
        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        if listener == nil {
            append("Listening for DDC changes from \(windowTitle).")
            append("Press a button / change a setting on the monitor's own on-screen display; the VCP code that changes will appear below.")
            let listener = makeListener { [weak self] line in self?.append(line) }
            self.listener = listener
            listener.start()
        }
    }

    // MARK: - Window

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Listen — \(windowTitle)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView()

        let searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter lines…"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterChanged)
        self.searchField = searchField

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        self.textView = textView

        let snapshotButton = NSButton(title: "Snapshot", target: self, action: #selector(snapshotTapped))
        snapshotButton.bezelStyle = .rounded
        let copyButton = NSButton(title: "Copy All", target: self, action: #selector(copyAll))
        copyButton.bezelStyle = .rounded
        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clear))
        clearButton.bezelStyle = .rounded

        let leftButtons = NSStackView(views: [snapshotButton])
        leftButtons.translatesAutoresizingMaskIntoConstraints = false
        let rightButtons = NSStackView(views: [clearButton, copyButton])
        rightButtons.translatesAutoresizingMaskIntoConstraints = false
        rightButtons.spacing = 8

        content.addSubview(searchField)
        content.addSubview(scroll)
        content.addSubview(leftButtons)
        content.addSubview(rightButtons)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: rightButtons.topAnchor, constant: -8),

            leftButtons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            leftButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            rightButtons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            rightButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        window.contentView = content
        self.window = window
    }

    private func append(_ line: String) {
        let full = "\(Self.timeFormatter.string(from: Date()))  \(line)"
        allLines.append(full)
        if passes(full) { appendToView(full) }
    }

    private func appendToView(_ line: String) {
        guard let textView, let font = textView.font else { return }
        textView.textStorage?.append(NSAttributedString(
            string: line + "\n", attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        textView.scrollToEndOfDocument(nil)
    }

    private func passes(_ line: String) -> Bool {
        filterText.isEmpty || line.localizedCaseInsensitiveContains(filterText)
    }

    private func rebuildDisplay() {
        guard let textView, let font = textView.font else { return }
        let shown = allLines.filter(passes)
        let text = shown.isEmpty ? "" : shown.joined(separator: "\n") + "\n"
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - Actions

    @objc private func filterChanged() {
        filterText = searchField?.stringValue ?? ""
        rebuildDisplay()
    }

    @objc private func snapshotTapped() {
        clear()  // wipe live-polling noise so the snapshot result stands alone
        listener?.snapshot()
    }

    @objc private func copyAll() {
        guard let textView else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)   // copies the visible (filtered) lines
    }

    @objc private func clear() {
        allLines.removeAll()
        textView?.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        listener?.stop()
        listener = nil
        onClose()
    }
}
