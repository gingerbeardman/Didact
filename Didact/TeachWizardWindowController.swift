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

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class TeachWizardWindowController: NSObject, NSWindowDelegate {
    private let monitorName: String
    private let session: LearnSession
    private let knownConfigs: [MonitorConfig]   // for auto-filling from known profiles
    private let edid: [MonitorConfig.EDIDMatch]?   // this display's EDID, stamped into the saved profile
    private let displayID: CGDirectDisplayID    // to detect HDR support for the Color Mode step
    private let onSaved: () -> Void   // reload configs so the monitor lights up
    private let onClose: () -> Void

    private var templates: [ControlTemplate] {
        ControlTemplate.all.filter {
            $0.label.caseInsensitiveCompare("Moon Halo") != .orderedSame
        }
    }
    private var autoFilled: [Control] = []      // confirmed from a known profile
    private var includeAutoFilled = true            // user can drop the auto-filled extras at the summary
    private var recognizedProfile: MonitorConfig?   // monitor matched a known profile distinctively
    private var useRecognized = false               // adopt the recognized profile wholesale
    private var capsCodes: Set<UInt8> = []          // VCP codes the monitor advertised, for the missing-feature gate

    private var window: NSWindow?
    private var progressLabel: NSTextField?
    private var titleLabel: NSTextField?
    private var instructionLabel: NSTextField?
    private var statusLabel: NSTextField?
    private let minimumDetectingDuration: TimeInterval = 2
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
    private var includeExtrasCheckbox: NSButton?   // summary: drop the auto-filled extras
    private var copyButton: NSButton?              // DEBUG: copy the profile to the clipboard

    // State
    private var index = 0
    private var learned: [Int: LearnedControl] = [:]
    private var autoAccepted: Set<Int> = []   // template indices accepted from caps with no user step

    // "More controls": standard MCCS controls the monitor advertises that the
    // guided templates didn't cover, offered as an opt-in checklist (named from the
    // spec — never unknown codes) after the guided steps.
    private struct DiscoveryRow { let code: UInt8; let name: String; let continuous: Bool; let values: [Int]; let max: UInt16; let include: NSButton }
    private var discoverable: [(code: UInt8, name: String, continuous: Bool, values: [Int], max: UInt16)]?  // nil = not scanned yet
    private var discoveryRows: [DiscoveryRow] = []
    private var discoveryBuilt = false
    private var onDiscovery = false
    private var pastDiscovery = false
    private var discovered: [Control] = []   // controls the user named on the discovery list
    private var discoveryScroll: NSScrollView?
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
    private var hdrOptionCheckbox: NSButton?   // Color Mode step: opt in to an HDR toggle

    init(monitorName: String, session: LearnSession, knownConfigs: [MonitorConfig],
         edid: [MonitorConfig.EDIDMatch]?, displayID: CGDirectDisplayID,
         onSaved: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.monitorName = monitorName
        self.session = session
        self.knownConfigs = knownConfigs
        self.edid = edid
        self.displayID = displayID
        self.onSaved = onSaved
        self.onClose = onClose
    }

    /// Whether this display can show HDR — used to offer an HDR pseudo-option on the
    /// Color Mode step. A display reports an EDR headroom > 1 when HDR-capable.
    private func displaySupportsHDR() -> Bool {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return false }
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
    }

    /// The Color Mode step (a proprietary, verifiable cycle — not Moon Halo) on an
    /// HDR-capable display: offer to add an HDR toggle the wizard can't learn via DDC.
    private func shouldOfferHDR(_ item: LearnedControl) -> Bool {
        let t = item.template
        return t.kind == .cycle && t.tier == .proprietary && !t.noVerify && !t.noRead && displaySupportsHDR()
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
                // Capabilities codes drive the "your monitor may not have this" gate.
                self.session.capabilityCodes { [weak self] codes in
                    self?.capsCodes = codes
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
        includeExtrasCheckbox?.isHidden = true
        copyButton?.isHidden = true
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
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 370),
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

        let discovery = NSScrollView()
        discovery.translatesAutoresizingMaskIntoConstraints = false
        discovery.hasVerticalScroller = true
        discovery.borderType = .bezelBorder
        discovery.drawsBackground = false
        discovery.isHidden = true
        self.discoveryScroll = discovery

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

        let includeExtras = NSButton(checkboxWithTitle: "Include auto-filled controls",
                                     target: self, action: #selector(includeExtrasChanged(_:)))
        includeExtras.state = .on
        includeExtras.isHidden = true
        includeExtras.translatesAutoresizingMaskIntoConstraints = false
        self.includeExtrasCheckbox = includeExtras

        let leftButtons = NSStackView(views: [back])
        leftButtons.translatesAutoresizingMaskIntoConstraints = false
        var rightItems: [NSView] = [retry, skip, primary, done]
        #if DEBUG
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyTapped))
        copy.bezelStyle = .rounded
        copy.isHidden = true
        self.copyButton = copy
        rightItems.insert(copy, at: 2)   // sits just before the Save/Submit primary
        #endif
        let rightButtons = NSStackView(views: rightItems)
        rightButtons.translatesAutoresizingMaskIntoConstraints = false
        rightButtons.spacing = 8

        [progress, title, instruction, status, spin, cadence, container, scroll, discovery, leftButtons, rightButtons, includeExtras]
            .forEach { content.addSubview($0) }

        NSLayoutConstraint.activate([
            // Pin the content to a fixed size. Without this the non-resizable window
            // sizes to its fitting width, and the wrapping text labels report a
            // different intrinsic width on each step — so the window visibly jumps
            // width between Welcome, the steps, and the summary. A fixed size makes
            // every screen identical and forces the long copy to wrap.
            content.widthAnchor.constraint(equalToConstant: 580),
            content.heightAnchor.constraint(equalToConstant: 370),

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

            discovery.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 12),
            discovery.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            discovery.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            discovery.bottomAnchor.constraint(equalTo: rightButtons.topAnchor, constant: -14),

            leftButtons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            leftButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            rightButtons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rightButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            includeExtras.centerYAnchor.constraint(equalTo: rightButtons.centerYAnchor),
            includeExtras.leadingAnchor.constraint(equalTo: leftButtons.trailingAnchor, constant: 16),
            includeExtras.trailingAnchor.constraint(lessThanOrEqualTo: rightButtons.leadingAnchor, constant: -12),
        ])

        window.contentView = content
        self.window = window
    }

    // MARK: - Step flow

    /// Template indices the user actually steps through (everything not accepted
    /// straight from the capabilities string).
    private var pendingSteps: [Int] { templates.indices.filter { !autoAccepted.contains($0) } }

    /// Before stepping, accept everything DDC reports for certain — universal
    /// controls advertised in the capabilities string, and a Colour Mode we can
    /// fingerprint — with no confirmation. Only the uncertain controls (Moon Halo,
    /// anything not cleanly advertised) remain as steps.
    private func autoAcceptThenStep() {
        let detectingStartedAt = Date()
        setStatus("Detecting standard controls…")
        instructionLabel?.stringValue = "Reading the controls your monitor reports automatically…"
        spinner?.startAnimation(nil)
        summaryScroll?.isHidden = true
        controlContainer?.isHidden = true
        retryButton?.isHidden = true
        skipButton?.isHidden = true
        primaryButton?.isHidden = true
        doneButton?.isHidden = true
        copyButton?.isHidden = true
        backButton?.isEnabled = false
        autoAcceptNext(0, startedAt: detectingStartedAt)
    }

    private func autoAcceptNext(_ i: Int, startedAt: Date) {
        guard i < templates.count else {
            afterMinimumDetectingDuration(since: startedAt) { [weak self] in
                guard let self else { return }
                self.spinner?.stopAnimation(nil)
                self.index = 0
                self.showStep()
            }
            return
        }
        let t = templates[i]
        let onResult: (LearnSession.Detected?) -> Void = { [weak self] detected in
            guard let self else { return }
            if let d = detected {
                self.learned[i] = LearnedControl(template: t, code: d.code, max: d.max,
                    options: self.cycleOptions(t, code: d.code, values: d.values, capsDiscrete: d.capsDiscrete))
                self.detectedCurrent[i] = d.current
                self.autoAccepted.insert(i)
            }
            self.autoAcceptNext(i + 1, startedAt: startedAt)
        }
        if t.standardCode != nil {
            // A spec control that's advertised in caps is known for certain.
            session.autoDetect(t) { onResult($0?.inCaps == true ? $0 : nil) }
        } else if t.kind == .cycle {
            // A proprietary cycle we can fingerprint from caps (e.g. Colour Mode).
            session.capsMatch(t, excluding: excludedCodes(for: t)) { onResult($0) }
        } else {
            onResult(nil)
        }
    }

    private func showStep() {
        resetStepTransients()
        discoveryScroll?.isHidden = true
        guard index < templates.count else { enterDiscoveryOrSummary(); return }
        if autoAccepted.contains(index) { advance(); return }   // accepted from caps — no step

        summaryScroll?.isHidden = true
        includeExtrasCheckbox?.isHidden = true
        copyButton?.isHidden = true
        instructionLabel?.isHidden = false
        statusLabel?.isHidden = false

        let template = templates[index]
        let pending = pendingSteps
        let pos = pending.firstIndex(of: index) ?? 0
        progressLabel?.stringValue = "Step \(pos + 1) of \(pending.count)"
        titleLabel?.stringValue = template.label
        backButton?.isEnabled = pos > 0
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
        let detectingStartedAt = Date()

        if template.standardCode != nil {
            setStatus("Detecting…")
            instructionLabel?.stringValue = "Checking whether your monitor reports this control automatically…"
            session.autoDetect(template) { [weak self] detected in
                guard let self, self.isCurrent(template) else { return }
                self.afterMinimumDetectingDuration(since: detectingStartedAt) { [weak self] in
                    guard let self, self.isCurrent(template) else { return }
                    if let detected {
                        let item = LearnedControl(template: template, code: detected.code, max: detected.max,
                                                  options: self.cycleOptions(template, code: detected.code, values: detected.values, capsDiscrete: detected.capsDiscrete))
                        self.enterConfirm(item, current: detected.current, auto: true)
                    } else {
                        self.enterManualLearning(template)
                    }
                }
            }
        } else {
            // Proprietary cycle: try to identify it from the capabilities fingerprint
            // (e.g. the colour-mode register advertising the BenQ preset values)
            // before asking the user to teach it by hand — observation alone often
            // locks onto a coupled register (brightness, night mode).
            setStatus("Detecting…")
            instructionLabel?.stringValue = "Checking your monitor’s capabilities…"
            session.capsMatch(template, excluding: excludedCodes(for: template)) { [weak self] detected in
                guard let self, self.isCurrent(template) else { return }
                self.afterMinimumDetectingDuration(since: detectingStartedAt) { [weak self] in
                    guard let self, self.isCurrent(template) else { return }
                    if let detected {
                        let item = LearnedControl(template: template, code: detected.code, max: detected.max,
                                                  options: self.cycleOptions(template, code: detected.code, values: detected.values, capsDiscrete: detected.capsDiscrete))
                        self.enterConfirm(item, current: detected.current, auto: true)
                    } else {
                        self.enterManualLearning(template)
                    }
                }
            }
        }
    }

    private func afterMinimumDetectingDuration(since start: Date, perform action: @escaping () -> Void) {
        let remaining = minimumDetectingDuration - Date().timeIntervalSince(start)
        guard remaining > 0 else {
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: action)
    }

    private func enterManualLearning(_ template: ControlTemplate) {
        resetStepTransients()
        controlContainer?.isHidden = true
        retryButton?.isHidden = true
        startCadence()   // shows the rhythm; replaces the plain spinner here

        var instruction = ""
        // Proprietary features (Moon Halo, picture modes) are model-specific — most
        // monitors don't have them. Lead with that so the user skips rather than
        // pressing an unrelated button and teaching a wrong code.
        if template.tier == .proprietary {
            instruction += "Many monitors don’t have this — if yours doesn’t, click Skip. Otherwise, "
        }
        instruction += "on your monitor’s own on-screen menu, \(template.action). Each time the bar below fills, change the setting once — wait for the next fill before changing it again. A few times is enough."
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

        // When the code a known profile uses for this proprietary feature isn't in
        // the monitor's advertised capabilities, it almost certainly lacks the
        // feature — say so plainly so the user Skips instead of teaching noise.
        let likelyAbsent = template.tier == .proprietary
            && !capsCodes.isEmpty
            && (expectedCode(for: template).map { !capsCodes.contains($0) } ?? false)
        if likelyAbsent {
            setStatus("Not found in your monitor’s capabilities — it likely doesn’t have this. Skip unless you’re sure.", color: .systemOrange)
        } else {
            setStatus("Waiting for a change…")
        }

        session.beginLearning(expectedKind: template.kind, expectedCode: expectedCode(for: template),
                              excludedCodes: excludedCodes(for: template)) { [weak self] update in
            guard let self, self.isCurrent(template) else { return }
            switch update {
            case let .detecting(_, count):
                self.sweepCompleted()   // one sweep done → reset the cadence fill
                self.setStatus(count == 0
                    ? "Waiting for a change… switch it on the monitor."
                    : "Got it \(count)× — keep switching slowly, once per progress bar tick.")
            case let .learned(code, max, current, values, capsDiscrete):
                self.session.endLearning()
                self.stopCadence()
                let item = LearnedControl(template: template, code: code, max: max,
                                          options: self.cycleOptions(template, code: code, values: values, capsDiscrete: capsDiscrete))
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
        var guidance = needsLabeling(item)
            ? "We found \(item.options?.count ?? 0) modes but don't know their names. Tap “Set” to see each one on the monitor, type its name, then Confirm."
            : "Use the control below to check it actually changes your monitor, then Confirm. If nothing happens, Detect Again."
        // This control can't be read back, so Didact can't confirm the write landed —
        // the user's eyes are the only check. Steer them to Skip a no-op rather than
        // commit a control their monitor doesn't really have.
        if item.template.noVerify || item.template.noRead {
            guidance += " This setting can’t be read back, so watch the monitor as you test — if nothing changes, click Skip; your monitor may not have it."
        }
        instructionLabel?.stringValue = guidance

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

    /// The standard range registers (brightness/contrast/volume/sharpness). A
    /// proprietary mode-switch must never resolve onto one of these — they only
    /// move as a side-effect of changing a preset.
    private static let universalRangeCodes: Set<UInt8> = Set(
        ControlTemplate.all
            .filter { $0.tier == .universal && $0.kind == .range }
            .compactMap { $0.standardCode })

    /// Codes detection must not pick for this step: every code already committed to
    /// another control, plus — for a proprietary control — the standard range
    /// registers a preset drags along. The code a known profile expects for THIS
    /// control is never excluded (LearnSession protects it).
    private func excludedCodes(for template: ControlTemplate) -> Set<UInt8> {
        var excluded = Set(learned.filter { $0.key != index }.values.map { $0.code })
        if template.tier == .proprietary { excluded.formUnion(Self.universalRangeCodes) }
        return excluded
    }

    private func cycleOptions(_ template: ControlTemplate, code: UInt8, values: [Int], capsDiscrete: Bool) -> [ControlTemplate.OptionTemplate]? {
        guard template.kind == .cycle else { return nil }
        let known = Dictionary((template.options ?? []).map { ($0.value, $0.label) }, uniquingKeysWith: { a, _ in a })
        // Prefer the template's own names, then the MCCS standard value name, and
        // only fall back to the plain decimal value (more useful than raw hex — e.g.
        // gamma reads "100", not "Mode 0x64") when neither knows the value.
        func label(_ value: Int) -> String {
            known[value] ?? MCCS.valueName(code, value) ?? "\(value)"
        }

        // The monitor advertised an explicit value list → it's authoritative for
        // WHICH modes exist.
        if capsDiscrete, !values.isEmpty {
            let present = values.sorted()
            let namedKnown = present.filter { known[$0] != nil }
            // If the template recognizes a strong majority of the advertised modes,
            // this is a known family (e.g. the BenQ colour-mode register): keep just
            // the named ones, dropping internal/omitted values like an HDR-only mode.
            // Otherwise label everything — on an unfamiliar monitor an unknown value
            // is a real mode we mustn't lose, so show it as "Mode 0x##" to be named.
            if namedKnown.count * 3 >= present.count * 2 {
                // The caps order is arbitrary and we can't see the OSD's order, so
                // present named modes alphabetically for a stable, scannable list.
                return namedKnown
                    .map { ControlTemplate.OptionTemplate(value: $0, label: known[$0]!) }
                    .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            }
            return present.map { ControlTemplate.OptionTemplate(value: $0, label: label($0)) }
        }

        // Bare code (no advertised value list, e.g. Moon Halo). Our only sources are
        // what we observed — unreliable for a noRead/noVerify control, and prone to
        // high-byte noise — and the template's curated hints. Prefer the template's
        // option set when we're confident this really is the control: its spec code,
        // a known-profile hint, or an unverifiable cycle that can't be learned by
        // observation anyway (P1 keeps detection off the wrong register; the step
        // warns when the feature looks absent). Otherwise the values are another
        // control's — label what was observed so the user names the real modes.
        let trustTemplate = code == template.standardCode
            || code == expectedCode(for: template)
            || template.noRead || template.noVerify
        if trustTemplate, let opts = template.options, !opts.isEmpty { return opts }
        return values.isEmpty ? nil : values.sorted().map { .init(value: $0, label: label($0)) }
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
        hdrOptionCheckbox = nil

        let control: NSView
        switch template.kind {
        case .range:
            control = makeSliderControl(min: template.suggestedMin ?? 0,
                                        max: item.max > 0 ? Int(item.max) : (template.fallbackMax ?? 100),
                                        current: current)
        case .cycle:
            // The HDR pseudo-option (if any) is opted into via the checkbox below, not
            // tested as a DDC value — filter it out of the live test control.
            let options = (item.options ?? template.options ?? []).filter { !$0.hdr }
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

        // On an HDR-capable display, offer to add an HDR mode the wizard can't learn
        // over DDC (it switches macOS HDR instead). Stacked under the test control.
        let view: NSView
        if shouldOfferHDR(item) {
            let cb = NSButton(checkboxWithTitle: "This monitor has an HDR mode (adds a toggle that switches macOS HDR)",
                              target: nil, action: nil)
            cb.state = (item.options ?? []).contains { $0.hdr } ? .on : .off
            cb.translatesAutoresizingMaskIntoConstraints = false
            hdrOptionCheckbox = cb
            let stack = NSStackView(views: [control, cb])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            view = stack
        } else {
            view = control
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
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

    // MARK: - Discovery (caps-driven "More controls")

    /// After the guided steps: scan for extra advertised codes the templates didn't
    /// cover and offer them as an optional review list, then go to the summary.
    private func enterDiscoveryOrSummary() {
        if pastDiscovery { showSummary(); return }
        if let codes = discoverable {                       // already scanned
            codes.isEmpty ? showSummary() : showDiscovery(codes)
            return
        }
        // Scan once. Exclude what we've already handled (templates + learned codes).
        resetStepTransients()
        summaryScroll?.isHidden = true
        discoveryScroll?.isHidden = true
        controlContainer?.isHidden = true
        instructionLabel?.isHidden = false
        statusLabel?.isHidden = false
        retryButton?.isHidden = true; skipButton?.isHidden = true
        primaryButton?.isHidden = true; doneButton?.isHidden = true; copyButton?.isHidden = true
        backButton?.isEnabled = false
        titleLabel?.stringValue = "More controls"
        progressLabel?.stringValue = "Almost done"
        instructionLabel?.stringValue = "Scanning your monitor’s capabilities for extra controls…"
        setStatus("")
        spinner?.startAnimation(nil)

        let used = Set(learned.values.map { $0.code })
        let standard = Set(templates.compactMap { $0.standardCode })
        session.discoverableCodes(excluding: used.union(standard)) { [weak self] codes in
            guard let self else { return }
            self.discoverable = codes
            self.spinner?.stopAnimation(nil)
            codes.isEmpty ? self.showSummary() : self.showDiscovery(codes)
        }
    }

    private func showDiscovery(_ codes: [(code: UInt8, name: String, continuous: Bool, values: [Int], max: UInt16)]) {
        resetStepTransients()
        onDiscovery = true
        spinner?.stopAnimation(nil)
        summaryScroll?.isHidden = true
        controlContainer?.isHidden = true
        instructionLabel?.isHidden = false
        statusLabel?.isHidden = true
        copyButton?.isHidden = true
        progressLabel?.stringValue = "More controls"
        titleLabel?.stringValue = "More controls"
        instructionLabel?.stringValue = "Your monitor also reports these standard controls (named from the VESA MCCS spec). Tick any you’d like to include — all optional."

        if !discoveryBuilt { buildDiscoveryRows(codes); discoveryBuilt = true }
        discoveryScroll?.isHidden = false

        backButton?.isEnabled = !pendingSteps.isEmpty   // nowhere to go back to if all auto-accepted
        retryButton?.isHidden = true
        skipButton?.isHidden = true
        doneButton?.isHidden = true
        primaryButton?.isHidden = false
        primaryButton?.title = "Continue"
        primaryButton?.isEnabled = true
    }

    private func buildDiscoveryRows(_ codes: [(code: UInt8, name: String, continuous: Bool, values: [Int], max: UInt16)]) {
        // A grid so the code and type line up in columns instead of trailing each
        // (variable-width) name raggedly.
        let grid = NSGridView()
        grid.rowSpacing = 9
        grid.columnSpacing = 16
        discoveryRows = []

        for entry in codes {
            let include = NSButton(checkboxWithTitle: entry.name, target: nil, action: nil)
            include.state = .off

            let code = NSTextField(labelWithString: String(format: "0x%02X", entry.code))
            code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            code.textColor = .secondaryLabelColor

            let type = NSTextField(labelWithString: entry.continuous ? "range" : "modes")
            type.font = .systemFont(ofSize: 11)
            type.textColor = .tertiaryLabelColor

            grid.addRow(with: [include, code, type])
            discoveryRows.append(DiscoveryRow(code: entry.code, name: entry.name, continuous: entry.continuous,
                                              values: entry.values, max: entry.max, include: include))
        }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 2).xPlacement = .leading
        // Inset via the grid's own padding — the scroll view manages the document
        // view's frame and ignores leading constraints, so do the margins internally.
        grid.column(at: 0).leadingPadding = 16
        grid.column(at: 2).trailingPadding = 16
        if grid.numberOfRows > 0 {
            grid.row(at: 0).topPadding = 12
            grid.row(at: grid.numberOfRows - 1).bottomPadding = 12
        }

        grid.layoutSubtreeIfNeeded()
        let gridSize = grid.fittingSize
        let contentWidth = discoveryScroll?.contentSize.width ?? gridSize.width
        let document = FlippedDocumentView(frame: NSRect(
            x: 0, y: 0,
            width: max(contentWidth, gridSize.width),
            height: gridSize.height
        ))
        document.autoresizingMask = [.width]
        grid.frame = NSRect(origin: .zero, size: gridSize)
        document.addSubview(grid)
        discoveryScroll?.documentView = document
    }

    /// Turn each ticked row into a control, named by its MCCS standard name. Ranges
    /// use the monitor's reported max; a two-value control becomes an on/off toggle
    /// (e.g. Audio Mute); other discrete controls become a cycle whose options carry
    /// their MCCS value names where the spec defines them.
    private func commitDiscovery() {
        discovered = discoveryRows.compactMap { row -> Control? in
            guard row.include.state == .on else { return nil }
            let vcp = HexValue(Int(row.code))
            if row.continuous || row.values.isEmpty {
                return Control(kind: .range, label: row.name, vcp: vcp, min: 0, max: row.max > 0 ? Int(row.max) : 100)
            }
            // Two advertised values → an on/off toggle. Prefer 0x01 as "on"
            // (the DDC convention; e.g. Audio Mute 01h = Mute, 02h = Un-mute).
            if row.values.count == 2 {
                let on = row.values.contains(1) ? 1 : (row.values.max() ?? row.values[0])
                let off = row.values.first { $0 != on } ?? row.values[0]
                return Control(kind: .toggle, label: row.name, vcp: vcp,
                               onValue: HexValue(on), offValue: HexValue(off))
            }
            let opts = row.values.map {
                Control.Option(value: HexValue($0), label: MCCS.valueName(row.code, $0) ?? "\($0)")
            }
            return Control(kind: .cycle, label: row.name, vcp: vcp, options: opts)
        }
    }

    // MARK: - Summary & save

    private func showSummary() {
        resetStepTransients()
        spinner?.stopAnimation(nil)
        controlContainer?.isHidden = true
        instructionLabel?.isHidden = true
        statusLabel?.isHidden = true
        summaryScroll?.isHidden = false
        discoveryScroll?.isHidden = true
        onDiscovery = false
        includeExtrasCheckbox?.isHidden = true   // shown below only when there are extras to drop
        copyButton?.isHidden = false             // DEBUG only; created only in debug builds
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
                if includeAutoFilled {
                    lines.append("Auto-filled from a known profile (verified against your monitor):")
                    for c in extras {
                        let code = c.featureCode.map(Self.hex) ?? "?"
                        lines.append("＋ \(c.label ?? "Control") — \(code) (\(c.kind.rawValue))")
                    }
                } else {
                    lines.append("\(extras.count) auto-filled control(s) excluded — tick the box below to include them.")
                }
            }
            // Controls the user named on the "More controls" discovery list.
            if !discovered.isEmpty {
                lines.append("")
                lines.append("Extra controls you added:")
                for c in discovered {
                    let code = c.featureCode.map(Self.hex) ?? "?"
                    lines.append("＋ \(c.label ?? "Control") — \(code) (\(c.kind.rawValue))")
                }
            }
            // Only meaningful before saving and only when there's something to drop.
            includeExtrasCheckbox?.isHidden = saved || extras.isEmpty
            includeExtrasCheckbox?.state = includeAutoFilled ? .on : .off
            let dupes = MonitorConfigBuilder.duplicateCodes(orderedLearned())
            if !dupes.isEmpty {
                lines.append("")
                lines.append("⚠️ \(dupes.map(Self.hex).joined(separator: ", ")) learned for more than one control — review before saving.")
            }
            summaryTextView?.string = lines.joined(separator: "\n")
            // Back goes to discovery (if any) or the last step; disabled once saved
            // or when there's nothing earlier to return to.
            let canGoBack = (discoverable.map { !$0.isEmpty } ?? false) || !pendingSteps.isEmpty
            backButton?.isEnabled = !saved && canGoBack
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
                comment: "Matched to Didact's verified \"\(profile.name)\" profile.",
                schemaVersion: profile.schemaVersion ?? 1)
        }
        let config = MonitorConfigBuilder.build(name: monitorName, learned: orderedLearned(),
                                                extras: (includeAutoFilled ? autoFilled : []) + discovered + rdSeriesExtras(),
                                                orderedLike: recognizedProfile, edid: edid)
        return isRDSeries ? withRDSharedRegisterMasks(withRDColorMode(config)) : config
    }

    /// The RD-series Color Mode order as it appears in the monitor's OSD.
    private static let rdColorModeOrder = [
        "Coding - Dark Theme", "Coding - Light Theme", "Coding - Paper Color",
        "M-book", "Cinema", "Game", "HDR", "ePaper", "sRGB", "User",
    ]

    /// Match the RD-series OSD: add Game (0x28) — which the firmware omits from the
    /// capabilities list even though the mode works — and order Color Mode like the
    /// on-screen menu (rather than the alphabetical default we use for unknown sets).
    private func withRDColorMode(_ config: MonitorConfig) -> MonitorConfig {
        let order = Self.rdColorModeOrder
        func rank(_ label: String) -> Int {
            order.firstIndex { $0.caseInsensitiveCompare(label) == .orderedSame } ?? order.count
        }
        let controls = config.controls.map { control -> Control in
            guard control.kind == .cycle,
                  control.label?.caseInsensitiveCompare("Color Mode") == .orderedSame,
                  var options = control.options else { return control }
            if !options.contains(where: { $0.value?.value == 0x28 }) {
                options.append(Control.Option(value: HexValue(0x28), label: "Game"))
            }
            // RD-series has an HDR picture mode that toggles macOS HDR (no DDC value).
            if !options.contains(where: { $0.hdr == true }) {
                options.append(Control.Option(label: "HDR", hdr: true))
            }
            options.sort { rank($0.label) < rank($1.label) }
            var copy = control
            copy.options = options
            return copy
        }
        return MonitorConfig(name: config.name, match: config.match, edid: config.edid,
                             controls: controls, comment: config.comment, schemaVersion: config.schemaVersion)
    }

    /// BenQ RD-series ("BenQ RD280UG") — the name has "RD" followed by a digit. These
    /// monitors reuse/repurpose codes for proprietary features (Moon Halo, Coding
    /// Booster, Eye Care) the wizard can't learn by observation, so we add them from
    /// the known layout — but only for an RD-series monitor, to avoid mislabelling
    /// those codes on anything else.
    private var isRDSeries: Bool {
        guard let r = monitorName.range(of: "RD", options: .caseInsensitive) else { return false }
        return monitorName[r.upperBound...].first?.isNumber == true
    }

    /// Proprietary controls known to live at fixed codes on RD-series monitors,
    /// added when the monitor actually advertises each code. Mirrors the curated
    /// bundled profile so a freshly-taught RD monitor gains Moon Halo's packed
    /// brightness/colour temp and the Eye Care set.
    private func rdSeriesExtras() -> [Control] {
        var extras: [Control] = []

        if isRDSeries {
            if !orderedLearned().contains(where: { $0.template.label.caseInsensitiveCompare("Moon Halo") == .orderedSame }) {
                extras.append(Control(kind: .cycle, label: "Moon Halo", vcp: HexValue(0xD7), valueMask: HexValue(0x00FF),
                                      options: [.init(value: HexValue(0x30), label: "Auto"),
                                                .init(value: HexValue(0x20), label: "On"),
                                                .init(value: HexValue(0x10), label: "Off")],
                                      noRead: true, noVerify: true))
            }
            extras.append(Control(kind: .cycle, label: "Moon Halo Light Mode", vcp: HexValue(0xD7), valueMask: HexValue(0xFF00),
                                  options: [.init(value: HexValue(0x0100), label: "270°"),
                                            .init(value: HexValue(0x0200), label: "360°")],
                                  noVerify: true))
        }

        // Moon Halo's own backlight brightness + colour temp, packed into d9
        // (high/low byte) — distinct from the monitor's main Brightness/Colour Temp.
        // Brightness is read-only while Moon Halo is on Auto (it drives it itself).
        if isRDSeries, capsCodes.contains(0xD9) {
            let disable = Control.Condition(vcp: HexValue(0xD7), equals: HexValue(0x30))
            extras.append(Control(kind: .range, label: "Moon Halo Brightness", vcp: HexValue(0xD9), byte: .low,
                                  min: 1, max: 10, disableWhen: disable))
            extras.append(Control(kind: .range, label: "Moon Halo Color Temperature", vcp: HexValue(0xD9), byte: .high,
                                  min: 1, max: 7))
        }

        guard isRDSeries else { return extras }

        // Eye Care features are hidden in sRGB / HDR (no effect there), matching the
        // curated profile. Build that condition from the learned Color Mode + sRGB.
        let colorMode = orderedLearned().first(where: { $0.template.label.caseInsensitiveCompare("Color Mode") == .orderedSame })
        let cmCode = colorMode.map { HexValue(Int($0.code)) }
        let srgb = colorMode?.options?.first(where: { $0.label.range(of: "sRGB", options: .caseInsensitive) != nil })?.value
        let eyeHide: Control.Condition = (cmCode != nil && srgb != nil)
            ? Control.Condition(vcp: cmCode, equalsAny: [HexValue(srgb!)], system: "hdr")
            : Control.Condition(system: "hdr")

        if capsCodes.contains(0xD1) {
            extras.append(Control(kind: .cycle, label: "Night Mode", vcp: HexValue(0xD1),
                                  options: [.init(value: HexValue(2), label: "Auto"),
                                            .init(value: HexValue(1), label: "On"),
                                            .init(value: HexValue(0), label: "Off")]))
        }
        if capsCodes.contains(0xD0) {
            extras.append(Control(kind: .range, label: "Night Level", vcp: HexValue(0xD0), min: 1, max: 10))
        }
        if capsCodes.contains(0x19) {
            extras.append(Control(kind: .range, label: "Low Blue Light", vcp: HexValue(0x19), min: 0, max: 5, hideWhen: eyeHide))
        }
        if capsCodes.contains(0xE5) {
            extras.append(Control(kind: .range, label: "Sensitivity", vcp: HexValue(0xE5), min: 1, max: 10, hideWhen: eyeHide))
        }
        if capsCodes.contains(0xE2) {
            extras.append(Control(kind: .toggle, label: "Auto Brightness", vcp: HexValue(0xE2),
                                  onValue: HexValue(255), offValue: HexValue(0), noRead: true, hideWhen: eyeHide))
        }
        return extras
    }

    private func withRDSharedRegisterMasks(_ config: MonitorConfig) -> MonitorConfig {
        guard isRDSeries else { return config }
        let controls = config.controls.map { control -> Control in
            guard control.label?.caseInsensitiveCompare("Moon Halo") == .orderedSame,
                  control.featureCode == 0xD7,
                  control.valueMask == nil else { return control }
            var copy = control
            copy.valueMask = HexValue(0x00FF)
            return copy
        }
        return MonitorConfig(name: config.name, match: config.match, edid: config.edid,
                             controls: controls, comment: config.comment, schemaVersion: config.schemaVersion)
    }

    private func orderedLearned() -> [LearnedControl] {
        templates.indices.compactMap { learned[$0] }
    }

    /// A code learned for two controls is almost always a mis-detection (a preset
    /// dragging brightness along). Block the save on it — returning to the summary
    /// to re-teach — rather than shipping a profile where two controls fight over
    /// one register. Returns true when it's safe to proceed.
    private func confirmDuplicateCodes() -> Bool {
        let dupes = MonitorConfigBuilder.duplicateCodes(orderedLearned())
        guard !dupes.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Two controls share \(dupes.map(Self.hex).joined(separator: ", "))"
        alert.informativeText = """
        More than one control was learned on the same VCP code — usually because changing a preset also moved another setting (e.g. brightness), so detection locked onto the wrong one. Saving this would make those controls fight over one register.

        Go back, use “Detect Again” on the affected control, and adjust only that setting on the monitor.
        """
        alert.addButton(withTitle: "Go Back & Fix")
        alert.addButton(withTitle: "Save Anyway")
        return alert.runModal() != .alertFirstButtonReturn   // proceed only on "Save Anyway"
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
        onSaved()       // reload, then hand off to Edit Menu as the final arranging step
        window?.close()
    }

    private func shareToGitHub() {
        let prefilled = CommunitySubmission.submit(config: finalConfig(), capabilities: capabilitiesString)
        summaryTextView?.string += prefilled
            ? "\n\nProfile + capabilities also copied to the clipboard."
            : "\n\nProfile + capabilities copied to the clipboard — paste them into the issue body (⌘V)."
    }

    // MARK: - Actions

    @objc private func includeExtrasChanged(_ sender: NSButton) {
        includeAutoFilled = sender.state == .on
        showSummary()   // refresh the listed extras
    }

    #if DEBUG
    @objc private func copyTapped() {
        CommunitySubmission.copyToClipboard(config: finalConfig(), capabilities: capabilitiesString)
        copyButton?.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton?.title = "Copy" }
    }
    #endif

    @objc private func doneTapped() {
        window?.close()   // windowWillClose stops the session and clears the reference
    }

    @objc private func backTapped() {
        // Navigate only — keep whatever was already learned so it's restored. Skip
        // over auto-accepted controls (they have no step).
        let pending = pendingSteps
        if onDiscovery {                          // discovery list → back to last step
            onDiscovery = false
            if let last = pending.last { index = last; showStep() }
            return
        }
        if index >= templates.count {            // summary → discovery (if any) else last step
            if let codes = discoverable, !codes.isEmpty {
                pastDiscovery = false
                showDiscovery(codes)
            } else if let last = pending.last {
                index = last; showStep()
            }
            return
        }
        if let pos = pending.firstIndex(of: index), pos > 0 {
            index = pending[pos - 1]
            showStep()
        }
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
                                      options: self.cycleOptions(template, code: chosen.code, values: chosen.values, capsDiscrete: chosen.capsDiscrete))
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
                autoAcceptThenStep()
            }
        } else if awaitingChoice {              // cycle detecting → pick from changes
            chooseManually()
        } else if index < templates.count {     // confirm the detected control
            if var item = pending {
                // Start from the user's mode names if they labeled, else what we learned.
                var options = labelingFields.isEmpty ? item.options : labeledOptions()
                // Add/remove the HDR pseudo-option per the checkbox (Color Mode step).
                if item.template.kind == .cycle, let cb = hdrOptionCheckbox {
                    var list = (options ?? []).filter { !$0.hdr }
                    if cb.state == .on { list.append(.init(value: 0, label: "HDR", hdr: true)) }
                    options = list
                }
                if !labelingFields.isEmpty || hdrOptionCheckbox != nil {
                    item = LearnedControl(template: item.template, code: item.code, max: item.max, options: options)
                }
                learned[index] = item
            }
            advance()
        } else if onDiscovery {                  // "More controls" list → commit, then summary
            commitDiscovery()
            pastDiscovery = true
            showSummary()
        } else if saved {                        // summary, after save
            shareToGitHub()
        } else {                                 // summary, before save
            guard confirmDuplicateCodes() else { return }
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
        hdrOptionCheckbox = nil
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
