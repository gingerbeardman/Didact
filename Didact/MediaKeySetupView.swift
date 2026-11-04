
import AppKit
import ApplicationServices

@MainActor
final class MediaKeySetupView: NSView {
    private let masterButton = NSButton(
        checkboxWithTitle: "Use media keys for external monitors",
        target: nil, action: nil)
    private let brightnessButton = NSButton(
        checkboxWithTitle: "Brightness keys (F1 / F2)",
        target: nil, action: nil)
    private let audioButton = NSButton(
        checkboxWithTitle: "Volume and mute keys (F10 / F11 / F12)",
        target: nil, action: nil)
    private let explanationLabel = NSTextField(wrappingLabelWithString: """
        macOS requires Accessibility permission for Didact to read these keys. \
        Didact reads only the brightness, volume and mute keys — never normal \
        typing — and you can turn it off at any time in Didact ▸ Media Keys.
        """)
    private let touchBarNote = NSTextField(wrappingLabelWithString: """
        Touch Bar: use the volume –, mute and + buttons, not the slider. They \
        still work when macOS shows the audio controls as disabled.
        """)
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")

    private(set) var settings: MediaKeySettings

    init(settings: MediaKeySettings) {
        self.settings = settings.normalized
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for button in [masterButton, brightnessButton, audioButton] {
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        masterButton.action = #selector(masterChanged)
        brightnessButton.action = #selector(roleChanged)
        audioButton.action = #selector(roleChanged)

        explanationLabel.font = .systemFont(ofSize: 12)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(explanationLabel)

        permissionLabel.font = .systemFont(ofSize: 12)
        permissionLabel.textColor = .secondaryLabelColor
        permissionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(permissionLabel)

        if TouchBar.isPresent {
            touchBarNote.font = .systemFont(ofSize: 12)
            touchBarNote.textColor = .systemOrange
            touchBarNote.translatesAutoresizingMaskIntoConstraints = false
            addSubview(touchBarNote)
        }

        var constraints = [
            masterButton.topAnchor.constraint(equalTo: topAnchor),
            masterButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            masterButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            brightnessButton.topAnchor.constraint(equalTo: masterButton.bottomAnchor, constant: 6),
            brightnessButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            brightnessButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            audioButton.topAnchor.constraint(equalTo: brightnessButton.bottomAnchor, constant: 4),
            audioButton.leadingAnchor.constraint(equalTo: brightnessButton.leadingAnchor),
            audioButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            explanationLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            explanationLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            permissionLabel.topAnchor.constraint(equalTo: explanationLabel.bottomAnchor, constant: 8),
            permissionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            permissionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            permissionLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]

        if TouchBar.isPresent {
            constraints += [
                touchBarNote.topAnchor.constraint(equalTo: audioButton.bottomAnchor, constant: 8),
                touchBarNote.leadingAnchor.constraint(equalTo: leadingAnchor),
                touchBarNote.trailingAnchor.constraint(equalTo: trailingAnchor),
                explanationLabel.topAnchor.constraint(equalTo: touchBarNote.bottomAnchor, constant: 12),
            ]
        } else {
            constraints.append(explanationLabel.topAnchor.constraint(equalTo: audioButton.bottomAnchor, constant: 12))
        }

        NSLayoutConstraint.activate(constraints)

        applySettings()
        refreshPermissionStatus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshPermissionStatus() {
        let trusted = AXIsProcessTrusted()
        permissionLabel.stringValue = trusted
            ? "Accessibility: Granted"
            : "Accessibility: Not granted — macOS will ask when you continue. You can also grant it later in Didact ▸ Media Keys."
        permissionLabel.textColor = trusted ? .secondaryLabelColor : .systemOrange
        permissionLabel.isHidden = !settings.masterEnabled
    }

    @objc private func masterChanged() {
        settings.masterEnabled = masterButton.state == .on
        settings = settings.normalized
        applySettings()
    }

    @objc private func roleChanged() {
        settings.brightnessEnabled = brightnessButton.state == .on
        settings.audioEnabled = audioButton.state == .on
        settings = settings.normalized
        applySettings()
    }

    private func applySettings() {
        masterButton.state = settings.masterEnabled ? .on : .off
        brightnessButton.state = settings.brightnessEnabled ? .on : .off
        audioButton.state = settings.audioEnabled ? .on : .off

        masterButton.isEnabled = settings.brightnessEnabled || settings.audioEnabled
        if !masterButton.isEnabled { masterButton.state = .off }
        refreshPermissionStatus()
    }
}
