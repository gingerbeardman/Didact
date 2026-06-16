//
//  TeachWizardWindowController.swift
//  BtnQ
//
//  A step-by-step wizard that builds a monitor config by discovering each
//  control's VCP code. Standard controls (brightness, contrast, volume, input)
//  are auto-detected from the capabilities string with no user effort; the rest
//  are taught by asking the user to work the physical OSD button while we watch
//  which code moves. Each step ends on a test-and-confirm state: a live, working
//  control bound to the detected code, so the user can verify it actually moves
//  the monitor before committing. The result is saved to the Monitors folder and
//  the monitor becomes controllable immediately.
//
//  Modeled on ListenWindowController: a programmatic window with Auto Layout, a
//  session that starts on show and stops on close.
//

import AppKit

@MainActor
final class TeachWizardWindowController: NSObject, NSWindowDelegate {
    private let monitorName: String
    private let session: LearnSession
    private let knownConfigs: [MonitorConfig]   // for auto-filling from known profiles
    private let edid: [MonitorConfig.EDIDMatch]?   // this display's EDID, stamped into the saved profile
    private let onSaved: () -> Void   // reload configs so the monitor lights up
    private let onClose: () -> Void

    private let templates = ControlTemplate.all
    private var autoFilled: [Control] = []      // confirmed from a known profile
    private var recognizedProfile: MonitorConfig?   // monitor matched a known profile distinctively
    private var useRecognized = false               // adopt the recognized profile wholesale

    private var window: NSWindow?
    private var progressLabel: NSTextField?
    private var titleLabel: NSTextField?
    private var instructionLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var spinner: NSProgressIndicator?
    private var cadenceBar: NSProgressIndicator?         // fills once per detection sweep
    private var cadenceTimer: Timer?
    private var sweepDuration: TimeInterval = 2.5        // measured time per detection sweep
    private var cadenceStart: Date?
    private var lastSweepAt: Date?
    private var controlContainer: NSView?
    private var summaryScroll: NSScrollView?
    private var summaryTextView: NSTextView?

    private var backButton: NSButton?
    private var retryButton: NSButton?
    private var skipButton: NSButton?
    private var primaryButton: NSButton?
    private var doneButton: NSButton?

    // State
    private var index = 0
    private var learned: [Int: LearnedControl] = [:]
    private var detectedCurrent: [Int: Int] = [:]   // value seen at detection, to re-seed the test control
    private var prepared = false
    private var onIntro = false
    private var awaitingChoice = false   // cycle detecting: primary acts as "pick from changes"
    private var saved = false
    private var capabilitiesString: String?   // raw DDC dump, submitted alongside the config

    // Per-step transients
    private var pending: LearnedControl?          // detected, awaiting Confirm
    private var testCode: UInt8?                  // code the live test control writes to
    private var testOptions: [ControlTemplate.OptionTemplate]?
    private var testValueLabel: NSTextField?
    private var testWriteWork: DispatchWorkItem?
    private var labelingFields: [(value: Int, field: NSTextField)] = []   // user-named presets

    init(monitorName: String, session: LearnSession, knownConfigs: [MonitorConfig],
         edid: [MonitorConfig.EDIDMatch]?,
         onSaved: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.monitorName = monitorName
        self.session = session
        self.knownConfigs = knownConfigs
        self.edid = edid
        self.onSaved = onSaved
        self.onClose = onClose
    }

    func show() {
        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        if !prepared {
            showIntro()
            session.prepare { [weak self] capabilities in
                guard let self else { return }
                self.capabilitiesString = capabilities
                // Auto-fill controls a known profile + the capabilities dump confirm.
                self.session.confirmedControls(from: self.knownConfigs) { [weak self] controls in
                    self?.autoFilled = controls
                }
                // Recognize the monitor outright if a known profile matches distinctively.
                self.session.recognizedProfile(from: self.knownConfigs) { [weak self] profile in
                    self?.recognizedProfile = profile
                }
                self.prepared = true
                self.introReady()
            }
        }
    }

    // MARK: - Intro

    /// Shown while the capabilities read runs — uses the otherwise-empty step area
    /// to explain what the wizard does. Start stays disabled until the read ends.
    private func showIntro() {
        onIntro = true
        summaryScroll?.isHidden = true
        controlContainer?.isHidden = true
        instructionLabel?.isHidden = false
        statusLabel?.isHidden = false

        progressLabel?.stringValue = "Welcome to Didact"
        titleLabel?.stringValue = "Teach your monitor’s controls"
        instructionLabel?.stringValue = """
        Didact will build a control profile for this monitor. It detects the standard controls — brightness, contrast, volume, input — automatically. For anything else, it asks you to change that setting on the monitor’s own on-screen menu so it can learn the code.

        You’ll test each control as you go, skip any your monitor doesn’t have, then save at the end — and optionally share it so others with this monitor benefit.
        """

        backButton?.isEnabled = false
        retryButton?.isHidden = true
        skipButton?.isHidden = true
        doneButton?.isHidden = true
        primaryButton?.isHidden = false
        primaryButton?.title = "Start"
        primaryButton?.isEnabled = false

        setStatus("Reading your monitor’s capabilities…")
        spinner?.startAnimation(nil)
    }

    private func introReady() {
        guard onIntro else { return }
        spinner?.stopAnimation(nil)
        setStatus("Ready when you are.", color: .systemGreen)
        primaryButton?.isEnabled = true
    }

    // MARK: - Window

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Set Up — \(monitorName)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView()

        let progress = NSTextField(labelWithString: "")
        progress.font = .systemFont(ofSize: 11)
        progress.textColor = .secondaryLabelColor
        progress.translatesAutoresizingMaskIntoConstraints = false
        self.progressLabel = progress

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel = title

        let instruction = NSTextField(wrappingLabelWithString: "")
        instruction.font = .systemFont(ofSize: 13)
        instruction.translatesAutoresizingMaskIntoConstraints = false
        self.instructionLabel = instruction

        let status = NSTextField(labelWithString: "")
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.translatesAutoresizingMaskIntoConstraints = false
        self.statusLabel = status

        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.isDisplayedWhenStopped = false
        spin.translatesAutoresizingMaskIntoConstraints = false
        self.spinner = spin

        let cadence = NSProgressIndicator()
        cadence.style = .bar
        cadence.isIndeterminate = false
        cadence.minValue = 0
        cadence.maxValue = 1
        cadence.controlSize = .small
        cadence.isHidden = true
        cadence.translatesAutoresizingMaskIntoConstraints = false
        self.cadenceBar = cadence

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        self.controlContainer = container

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.isHidden = true
        let summary = NSTextView()
        summary.isEditable = false
        summary.isSelectable = true
        summary.isRichText = false
        summary.drawsBackground = true
        summary.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        summary.textColor = .labelColor
        summary.textContainerInset = NSSize(width: 8, height: 8)
        // A programmatic NSTextView needs these or its text container has no size
        // and lays out nothing (the symptom: a blank review screen).
        summary.autoresizingMask = [.width]
        summary.isVerticallyResizable = true
        summary.isHorizontallyResizable = false
        summary.minSize = NSSize(width: 0, height: 0)
        summary.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        summary.textContainer?.widthTracksTextView = true
        scroll.documentView = summary
        self.summaryScroll = scroll
        self.summaryTextView = summary

        let back = NSButton(title: "Back", target: self, action: #selector(backTapped))
        back.bezelStyle = .rounded
        self.backButton = back
        let retry = NSButton(title: "Detect Again", target: self, action: #selector(retryTapped))
        retry.bezelStyle = .rounded
        self.retryButton = retry
        let skip = NSButton(title: "Skip", target: self, action: #selector(skipTapped))
        skip.bezelStyle = .rounded
        self.skipButton = skip
        let primary = NSButton(title: "Continue", target: self, action: #selector(primaryTapped))
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        self.primaryButton = primary
        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.isHidden = true
        self.doneButton = done

        let leftButtons = NSStackView(views: [back])
        leftButtons.translatesAutoresizingMaskIntoConstraints = false
        let rightButtons = NSStackView(views: [retry, skip, primary, done])
        rightButtons.translatesAutoresizingMaskIntoConstraints = false
        rightButtons.spacing = 8

        [progress, title, instruction, status, spin, cadence, container, scroll, leftButtons, rightButtons]
            .forEach { content.addSubview($0) }

        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            title.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            instruction.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            instruction.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            instruction.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            status.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 14),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            spin.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            spin.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 8),

            cadence.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            cadence.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            cadence.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            container.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 14),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            container.bottomAnchor.constraint(equalTo: rightButtons.topAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: rightButtons.topAnchor, constant: -14),

            leftButtons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            leftButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            rightButtons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rightButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        window.contentView = content
        self.window = window
    }

    // MARK: - Step flow

    private func showStep() {
        resetStepTransients()
        guard index < templates.count else { showSummary(); return }

        summaryScroll?.isHidden = true
        instructionLabel?.isHidden = false
        statusLabel?.isHidden = false

        let template = templates[index]
        progressLabel?.stringValue = "Step \(index + 1) of \(templates.count)"
        titleLabel?.stringValue = template.label
        backButton?.isEnabled = index > 0
        doneButton?.isHidden = true

        // If this step was already learned (e.g. we came back to it), restore its
        // detected control rather than re-detecting. Only "Detect Again" re-learns.
        if let item = learned[index] {
            enterConfirm(item, current: detectedCurrent[index] ?? (template.suggestedMin ?? 0), auto: false)
            return
        }

        // Detecting state: spinner on, no test control, no Confirm yet.
        spinner?.startAnimation(nil)
        controlContainer?.isHidden = true
        retryButton?.isHidden = true
        primaryButton?.isHidden = true
        skipButton?.isHidden = false

        if template.standardCode != nil {
            setStatus("Detecting…")
            instructionLabel?.stringValue = "Checking whether your monitor reports this control automatically…"
            session.autoDetect(template) { [weak self] detected in
                guard let self, self.isCurrent(template) else { return }
                if let detected {
                    let item = LearnedControl(template: template, code: detected.code, max: detected.max,
                                              options: self.cycleOptions(template, values: detected.values, capsDiscrete: detected.capsDiscrete))
                    self.enterConfirm(item, current: detected.current, auto: true)
                } else {
                    self.enterManualLearning(template)
                }
            }
        } else {
            enterManualLearning(template)
        }
    }

    private func enterManualLearning(_ template: ControlTemplate) {
        resetStepTransients()
        controlContainer?.isHidden = true
        retryButton?.isHidden = true
        startCadence()   // shows the rhythm; replaces the plain spinner here

        var instruction = "On your monitor’s own on-screen menu, \(template.action). The bar below is a timer for each reading — change the setting once, wait for the bar to fill, then change it again. A few times is enough."
        if template.kind == .cycle {
            // Changing a preset can move several settings at once, so detection may
            // not lock on — offer a manual pick of the codes that changed.
            instruction += " If it won’t lock on, use “Pick from changes…”."
            awaitingChoice = true
            primaryButton?.isHidden = false
            primaryButton?.title = "Pick from changes…"
            primaryButton?.isEnabled = true
        } else {
            awaitingChoice = false
            primaryButton?.isHidden = true
        }
        instructionLabel?.stringValue = instruction
        setStatus("Waiting for a change…")

        session.beginLearning(expectedKind: template.kind, expectedCode: expectedCode(for: template)) { [weak self] update in
            guard let self, self.isCurrent(template) else { return }
            switch update {
            case let .detecting(_, count):
                self.sweepCompleted()   // one sweep done → reset the cadence fill
                self.setStatus(count == 0
                    ? "Waiting for a change… switch it on the monitor."
                    : "Got it \(count)× — keep switching slowly.")
            case let .learned(code, max, current, values, capsDiscrete):
                self.session.endLearning()
                self.stopCadence()
                let item = LearnedControl(template: template, code: code, max: max,
                                          options: self.cycleOptions(template, values: values, capsDiscrete: capsDiscrete))
                self.enterConfirm(item, current: current, auto: false)
            }
        }
    }

    // MARK: - Cadence indicator

    /// A bar that fills over each detection sweep. When it fills, Didact has read
    /// the monitor once — so the user learns to change the setting about once per
    /// fill (changing faster than a sweep can be missed).
    private func startCadence() {
        spinner?.stopAnimation(nil)
        cadenceBar?.isHidden = false
        cadenceBar?.doubleValue = 0
        sweepDuration = 2.5
        cadenceStart = Date()
        lastSweepAt = nil
        cadenceTimer?.invalidate()
        // Target/selector form keeps the tick on the main actor (no Sendable warning).
        cadenceTimer = Timer.scheduledTimer(timeInterval: 0.05, target: self,
                                            selector: #selector(cadenceTick), userInfo: nil, repeats: true)
    }

    @objc private func cadenceTick() {
        guard let start = cadenceStart else { return }
        cadenceBar?.doubleValue = min(1, Date().timeIntervalSince(start) / max(0.3, sweepDuration))
    }

    /// Called each time a sweep completes — measure its real duration and restart
    /// the fill toward the next one, so the bar tracks the actual cadence.
    private func sweepCompleted() {
        let now = Date()
        if let last = lastSweepAt { sweepDuration = min(8, max(0.6, now.timeIntervalSince(last))) }
        lastSweepAt = now
        cadenceStart = now
    }

    private func stopCadence() {
        cadenceTimer?.invalidate()
        cadenceTimer = nil
        cadenceBar?.isHidden = true
        cadenceBar?.doubleValue = 0
    }

    /// Detected — stop the spinner, remember it (so Back preserves it), and
    /// present a live control to test before committing.
    private func enterConfirm(_ item: LearnedControl, current: Int, auto: Bool) {
        session.endLearning()
        awaitingChoice = false
        spinner?.stopAnimation(nil)
        stopCadence()
        pending = item
        learned[index] = item
        detectedCurrent[index] = current

        let how = auto ? "Auto-detected" : "Learned"
        var status = "✓ \(how) \(Self.hex(item.code))"
        if item.template.kind == .cycle, let count = item.options?.count { status += " · \(count) options" }
        setStatus(status, color: .systemGreen)
        instructionLabel?.stringValue = needsLabeling(item)
            ? "We found \(item.options?.count ?? 0) modes but don't know their names. Tap “Set” to see each one on the monitor, type its name, then Confirm."
            : "Use the control below to check it actually changes your monitor, then Confirm. If nothing happens, Detect Again."

        showTestControl(for: item, current: current)

        retryButton?.isHidden = false
        skipButton?.isHidden = false
        primaryButton?.isHidden = false
        primaryButton?.title = "Confirm & Continue"
        primaryButton?.isEnabled = true
    }

    /// Build a cycle's options from the discrete values discovered on this
    /// monitor, labeling known values from the template and naming the rest
    /// generically. Falls back to the template's own options when nothing was
    /// discovered. Returns nil for non-cycle controls.
    /// The code a known (bundled) profile uses for a control with this label and
    /// kind — used as a strong hint to disambiguate detection on monitors we
    /// recognize. nil for unknown monitors.
    private func expectedCode(for template: ControlTemplate) -> UInt8? {
        for config in knownConfigs {
            if let match = config.controls.first(where: {
                $0.kind == template.kind && $0.label?.caseInsensitiveCompare(template.label) == .orderedSame
            }), let code = match.featureCode {
                return code
            }
        }
        return nil
    }

    private func cycleOptions(_ template: ControlTemplate, values: [Int], capsDiscrete: Bool) -> [ControlTemplate.OptionTemplate]? {
        guard template.kind == .cycle else { return nil }
        let labels = Dictionary((template.options ?? []).map { ($0.value, $0.label) }, uniquingKeysWith: { a, _ in a })
        func labeled(_ vals: [Int]) -> [ControlTemplate.OptionTemplate] {
            vals.map { ControlTemplate.OptionTemplate(value: $0, label: labels[$0] ?? String(format: "Mode 0x%02X", $0)) }
        }
        // The monitor advertised an explicit value list (e.g. Color Mode) → it's
        // authoritative for WHICH modes exist (robust to how the user cycled, or a
        // stray press). Order them by the template's familiar sequence, then
        // append any modes the monitor has that the template doesn't know.
        if capsDiscrete, !values.isEmpty {
            // The monitor advertised which values exist; keep only those that map
            // to a known mode name (in the template's familiar order). Unnamed
            // advertised values (e.g. 0x23) are dropped rather than shown as
            // "Mode 0x23". For an unrecognized monitor (no named matches) fall back
            // to labeling the raw values so it's still usable.
            let present = Set(values)
            let named = (template.options ?? []).filter { present.contains($0.value) }
            if !named.isEmpty { return named }
            return labeled(values.sorted())
        }
        // Listed bare (e.g. Moon Halo) → prefer the template's known set so we
        // don't save an incomplete cycle, falling back to whatever was observed.
        if let opts = template.options, !opts.isEmpty { return opts }
        return values.isEmpty ? nil : labeled(values)
    }

    private func advance() {
        index += 1
        showStep()
    }

    // MARK: - Live test control

    private func showTestControl(for item: LearnedControl, current: Int) {
        guard let container = controlContainer else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        let template = item.template
        testCode = item.code
        testOptions = nil
        testValueLabel = nil
        labelingFields = []

        let control: NSView
        switch template.kind {
        case .range:
            control = makeSliderControl(min: template.suggestedMin ?? 0,
                                        max: item.max > 0 ? Int(item.max) : (template.fallbackMax ?? 100),
                                        current: current)
        case .cycle:
            let options = item.options ?? template.options ?? []
            // For a proprietary cycle whose modes we couldn't name (e.g. Picture
            // Mode on a non-RD BenQ), let the user name each one instead of showing
            // "Mode 0x##". Universal/known cycles just use a popup to test.
            control = needsLabeling(item)
                ? makeLabelingControl(options: options)
                : makePopupControl(options: options, current: current)
        case .toggle:
            control = makeToggleControl(template: template, current: current)
        case .group, .section:
            control = NSView()
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)
        NSLayoutConstraint.activate([
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        container.isHidden = false
    }

    private func makeSliderControl(min: Int, max: Int, current: Int) -> NSView {
        let slider = NSSlider(value: Double(Swift.min(Swift.max(current, min), max)),
                              minValue: Double(min), maxValue: Double(max),
                              target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false

        let value = NSTextField(labelWithString: "\(current)")
        value.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 40).isActive = true
        testValueLabel = value

        let stack = NSStackView(views: [slider, value])
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    private func makePopupControl(options: [ControlTemplate.OptionTemplate], current: Int) -> NSView {
        testOptions = options
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.addItems(withTitles: options.map { $0.label })
        if let i = options.firstIndex(where: { $0.value == current }) { popup.selectItem(at: i) }
        return popup
    }

    private func makeToggleControl(template: ControlTemplate, current: Int) -> NSView {
        let toggle = NSButton(checkboxWithTitle: template.label, target: self, action: #selector(toggleChanged(_:)))
        toggle.state = (current == template.onValue) ? .on : .off
        return toggle
    }

    /// A proprietary cycle whose modes we couldn't name from a profile/template —
    /// the user should label them rather than ship "Mode 0x##".
    private func needsLabeling(_ item: LearnedControl) -> Bool {
        item.template.kind == .cycle && item.template.tier == .proprietary
            && (item.options ?? []).contains { $0.label.hasPrefix("Mode 0x") }
    }

    /// One row per discovered value: a "Set" button to apply it (so the user sees
    /// which preset it is on the monitor) and a field to name it. Scrollable, since
    /// there can be many modes.
    private func makeLabelingControl(options: [ControlTemplate.OptionTemplate]) -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false

        for opt in options {
            let set = NSButton(title: "Set", target: self, action: #selector(setModeTapped(_:)))
            set.bezelStyle = .rounded
            set.tag = opt.value
            let hex = NSTextField(labelWithString: String(format: "0x%02X", opt.value))
            hex.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            hex.textColor = .secondaryLabelColor
            let field = NSTextField(string: opt.label.hasPrefix("Mode 0x") ? "" : opt.label)
            field.placeholderString = "Name this mode"
            field.widthAnchor.constraint(equalToConstant: 240).isActive = true
            labelingFields.append((opt.value, field))
            let row = NSStackView(views: [set, hex, field])
            row.orientation = .horizontal
            row.spacing = 8
            rows.addArrangedSubview(row)
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = rows
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
        return scroll
    }

    @objc private func setModeTapped(_ sender: NSButton) {
        guard let code = testCode else { return }
        session.write(code: code, value: UInt16(sender.tag))
    }

    /// Options from the labeling fields (empty names fall back to a hex label).
    private func labeledOptions() -> [ControlTemplate.OptionTemplate] {
        labelingFields.map { value, field in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(value: value, label: name.isEmpty ? String(format: "Mode 0x%02X", value) : name)
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = sender.integerValue
        testValueLabel?.stringValue = "\(value)"
        guard let code = testCode else { return }
        // Debounce: a continuous slider fires faster than DDC can write.
        testWriteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.session.write(code: code, value: UInt16(value)) }
        testWriteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let code = testCode, let options = testOptions,
              sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < options.count else { return }
        session.write(code: code, value: UInt16(options[sender.indexOfSelectedItem].value))
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let code = testCode, let template = pending?.template else { return }
        let value = sender.state == .on ? template.onValue : template.offValue
        if let value { session.write(code: code, value: UInt16(value)) }
    }

    // MARK: - Summary & save

    private func showSummary() {
        resetStepTransients()
        spinner?.stopAnimation(nil)
        controlContainer?.isHidden = true
        instructionLabel?.isHidden = true
        statusLabel?.isHidden = true
        summaryScroll?.isHidden = false
        progressLabel?.stringValue = "Done"

        if useRecognized, let profile = recognizedProfile {
            titleLabel?.stringValue = saved ? "Saved" : "Recognized monitor"
            var lines = ["Matched to the verified “\(profile.name)” profile. Its full control set will be used:", ""]
            for control in profile.controls where !control.isHeader {
                let code = control.featureCode.map(Self.hex) ?? "?"
                lines.append("✓ \(control.label ?? "Control") — \(code) (\(control.kind.rawValue))")
            }
            summaryTextView?.string = lines.joined(separator: "\n")
            backButton?.isEnabled = false
            // Offer a manual path for variants / testing.
            retryButton?.isHidden = saved
            retryButton?.title = "Teach Manually Instead"
        } else {
            titleLabel?.stringValue = saved ? "Saved" : "Review & Save"
            var lines: [String] = []
            for i in templates.indices {
                let t = templates[i]
                if let item = learned[i] {
                    let detail: String
                    switch t.kind {
                    case .range: detail = "range \(t.suggestedMin ?? 0)–\(item.max > 0 ? Int(item.max) : (t.fallbackMax ?? 100))"
                    default: detail = t.kind.rawValue
                    }
                    lines.append("✓ \(t.label) — \(Self.hex(item.code)) (\(detail))")
                } else {
                    lines.append("— \(t.label) — skipped")
                }
            }
            // Extras auto-filled from a known profile (those the user didn't teach).
            let taught = Set(orderedLearned().map { MonitorConfigBuilder.stateKey(for: $0) })
            let extras = autoFilled.filter { !taught.contains($0.stateKey) }
            if !extras.isEmpty {
                lines.append("")
                lines.append("Auto-filled from a known profile (verified against your monitor):")
                for c in extras {
                    let code = c.featureCode.map(Self.hex) ?? "?"
                    lines.append("＋ \(c.label ?? "Control") — \(code) (\(c.kind.rawValue))")
                }
            }
            let dupes = MonitorConfigBuilder.duplicateCodes(orderedLearned())
            if !dupes.isEmpty {
                lines.append("")
                lines.append("⚠️ \(dupes.map(Self.hex).joined(separator: ", ")) learned for more than one control — review before saving.")
            }
            summaryTextView?.string = lines.joined(separator: "\n")
            backButton?.isEnabled = !saved
            retryButton?.isHidden = true
        }

        skipButton?.isHidden = true
        primaryButton?.isHidden = false
        primaryButton?.title = saved ? "Submit to Community" : "Save"
        primaryButton?.isEnabled = saved || useRecognized || !orderedLearned().isEmpty
        // A clear way off the final screen: "Done" before saving acts as Close.
        doneButton?.isHidden = false
        doneButton?.title = saved ? "Done" : "Close"
    }

    /// The config to save/submit: the recognized profile wholesale, or the
    /// taught controls plus auto-filled extras.
    private func finalConfig() -> MonitorConfig {
        if useRecognized, let profile = recognizedProfile {
            return MonitorConfig(
                name: monitorName, match: [monitorName], edid: edid, controls: profile.controls,
                comment: "Matched to Didact's verified “\(profile.name)” profile.",
                schemaVersion: profile.schemaVersion ?? 1)
        }
        return MonitorConfigBuilder.build(name: monitorName, learned: orderedLearned(),
                                          extras: autoFilled, orderedLike: recognizedProfile, edid: edid)
    }

    private func orderedLearned() -> [LearnedControl] {
        templates.indices.compactMap { learned[$0] }
    }

    private func saveConfig() {
        let config = finalConfig()
        do {
            try MonitorConfigStore.save(config, overwriting: false)
        } catch CocoaError.fileWriteFileExists {
            let alert = NSAlert()
            alert.messageText = "A config for “\(monitorName)” already exists."
            alert.informativeText = "Overwrite it with the controls you just taught?"
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try MonitorConfigStore.save(config, overwriting: true)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        saved = true
        onSaved()
        showSummary()
    }

    private func shareToGitHub() {
        let prefilled = CommunitySubmission.submit(config: finalConfig(), capabilities: capabilitiesString)
        summaryTextView?.string += prefilled
            ? "\n\nProfile + capabilities also copied to the clipboard."
            : "\n\nProfile + capabilities copied to the clipboard — paste them into the issue body (⌘V)."
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        window?.close()   // windowWillClose stops the session and clears the reference
    }

    @objc private func backTapped() {
        // Navigate only — keep whatever was already learned so it's restored.
        if index >= templates.count {           // on summary → back to last step
            index = templates.count - 1
        } else {
            index = max(0, index - 1)
        }
        showStep()
    }

    @objc private func skipTapped() {
        learned[index] = nil
        detectedCurrent[index] = nil
        advance()
    }

    @objc private func retryTapped() {
        // On the recognized-profile summary this button means "ignore the match
        // and teach manually" — drop into the normal stepping flow.
        if useRecognized {
            useRecognized = false
            index = 0
            showStep()
            return
        }
        // Otherwise: discard the prior result and learn this control again.
        learned[index] = nil
        detectedCurrent[index] = nil
        enterManualLearning(templates[index])
    }

    /// Escape hatch for cycles that won't auto-resolve: list the codes that
    /// changed and let the user pick the right one.
    private func chooseManually() {
        guard index < templates.count else { return }
        let template = templates[index]
        session.candidates { [weak self] candidates in
            guard let self, self.isCurrent(template) else { return }
            guard !candidates.isEmpty else {
                self.setStatus("Nothing has changed yet — adjust the control first.")
                return
            }
            let alert = NSAlert()
            alert.messageText = "Pick the \(template.label) code"
            alert.informativeText = "These codes changed while you were adjusting the control. Choose the one that matches."
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 25))
            for c in candidates {
                popup.addItem(withTitle: String(format: "0x%02X — changed %d×, %d value(s)", c.code, c.changes, c.values.count))
            }
            alert.accessoryView = popup
            alert.addButton(withTitle: "Use This")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn, popup.indexOfSelectedItem >= 0 else { return }

            let chosen = candidates[popup.indexOfSelectedItem]
            self.session.endLearning()
            let item = LearnedControl(template: template, code: chosen.code, max: 0,
                                      options: self.cycleOptions(template, values: chosen.values, capsDiscrete: chosen.capsDiscrete))
            self.enterConfirm(item, current: chosen.current, auto: false)
        }
    }

    @objc private func primaryTapped() {
        if onIntro {                            // Start → recognized profile or teaching
            onIntro = false
            if recognizedProfile != nil {
                useRecognized = true
                index = templates.count         // we're on the final summary, not a step
                showSummary()
            } else {
                showStep()
            }
        } else if awaitingChoice {              // cycle detecting → pick from changes
            chooseManually()
        } else if index < templates.count {     // confirm the detected control
            if var item = pending {
                if !labelingFields.isEmpty {    // commit the user's mode names
                    item = LearnedControl(template: item.template, code: item.code,
                                          max: item.max, options: labeledOptions())
                }
                learned[index] = item
            }
            advance()
        } else if saved {                        // summary, after save
            shareToGitHub()
        } else {                                 // summary, before save
            saveConfig()
        }
    }

    // MARK: - Helpers

    private func isCurrent(_ template: ControlTemplate) -> Bool {
        index < templates.count && templates[index].label == template.label
    }

    private func resetStepTransients() {
        session.endLearning()
        stopCadence()
        awaitingChoice = false
        testWriteWork?.cancel()
        testWriteWork = nil
        testCode = nil
        testOptions = nil
        testValueLabel = nil
        labelingFields = []
        pending = nil
        controlContainer?.subviews.forEach { $0.removeFromSuperview() }
    }

    private func setStatus(_ text: String, color: NSColor = .labelColor) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = color
    }

    private static func hex(_ code: UInt8) -> String { String(format: "0x%02X", code) }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopCadence()
        session.stop()
        onClose()
    }
}
