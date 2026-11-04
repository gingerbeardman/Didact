//
//  BtnQApp.swift
//  BtnQ
//
//  A menu-bar-only app to control a BenQ monitor over DDC/CI. No settings
//  window — everything lives in the status-bar menu, built generically from a
//  JSON monitor config (see MonitorConfig.swift / Monitors/*.json).
//

import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@main
struct DidactApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var configs: [MonitorConfig] = []
    private var displays: [DisplayController] = []
    private var active: DisplayController?
    private var listenWindow: ListenWindowController?
    private var teachWindow: TeachWizardWindowController?
    private var menuEditorWindow: MenuEditorWindowController?
    private var isOpeningMenu = false
    private var isMenuOpen = false
    private var refreshInFlight = false
    private var refreshTimer: Timer?

    // Media keys (brightness/volume/mute)
    private enum DefaultsKey {
        static let setupWizardSeen = "hasSeenSetupWizard"
    }
    private var mediaKeyTap: MediaKeyTap?
    private var mediaKeyRouter: MediaKeyRouter?
    private let mediaKeyOSD = MediaKeyOSD()
    private let audioMonitor = DefaultAudioOutputMonitor()
    private var mediaKeySettings = MediaKeySettingsStore.load()
    private var mediaKeysSuspended = false
    private var mediaKeyTapFailed = false
    private var axPollTimer: Timer?
    private var axPollDeadline = Date.distantPast
    private var lastMediaKeyAdjustment = Date.distantPast
    /// Visibility snapshot (hidden control stateKeys) frozen while the menu is open,
    /// so a post-open value refresh can't change the row set and jump the height.
    private var frozenHidden: Set<String>?

    // Boxed references stored on menu items (Control is a value type).
    private final class CycleChoice { let control: Control; let value: Int; let isHDR: Bool
        init(_ control: Control, _ value: Int, isHDR: Bool = false) { self.control = control; self.value = value; self.isHDR = isHDR } }
    private final class ToggleRef { let control: Control; init(_ c: Control) { control = c } }
    private final class DisplayRef { let controller: DisplayController; init(_ c: DisplayController) { controller = c } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        migrateLegacyData()
        configs = MonitorConfigStore.load()
        setupStatusItem()
        rescanDisplays()
        startBackgroundRefresh()
        setupMediaKeys()

        // Re-scan automatically when displays are plugged in / out or rearranged.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Onboard at startup. The first launch shows the full setup wizard even
        // when the monitor is already recognized, so the media-key offer is not
        // limited to people whose monitor needed teaching. After that, open the
        // teach wizard when there's no supported monitor to control (so an
        // unknown display can be set up), and always in debug builds so the
        // wizard is easy to iterate on. Guarded so it never pops the "no display"
        // alert when nothing teachable is connected.
        let firstRun = !UserDefaults.standard.bool(forKey: DefaultsKey.setupWizardSeen)
        #if DEBUG
        let autoTeach = true
        #else
        let autoTeach = (active == nil)
        #endif
        if (firstRun || autoTeach), teachableServiceExists() {
            openTeach(showMediaKeys: firstRun)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        axPollTimer?.invalidate()
        stopMediaKeyTap()
        audioMonitor.stop()
        mediaKeyOSD.hideImmediately()
    }

    @objc private func screensChanged() {
        mediaKeyOSD.hideImmediately()
        rescanDisplays()
        maybeShowFirstRunWizard()
    }

    /// One-time carry-over from the app's former name (BtnQ): taught monitor
    /// profiles, and the few persisted preferences that live under the old bundle
    /// ID (menu-bar icon, write-only control states).
    private func migrateLegacyData() {
        MonitorConfigStore.migrateLegacyMonitorsIfNeeded()
        guard let legacy = UserDefaults(suiteName: "com.gingerbeardman.BtnQ") else { return }
        let std = UserDefaults.standard
        if std.object(forKey: iconKey) == nil, let icon = legacy.string(forKey: iconKey) {
            std.set(icon, forKey: iconKey)
        }
        for (key, value) in legacy.dictionaryRepresentation() where key.hasPrefix("btnq.state.") {
            if std.object(forKey: key) == nil { std.set(value, forKey: key) }
        }
    }

    // MARK: - Status item

    // Menu bar icon choice (SF Symbol name), persisted.
    private let iconKey = "menuBarIcon"
    static let defaultIcon = "slider.horizontal.below.square.filled.and.square"
    static let iconChoices: [(label: String, symbol: String)] = [
        ("Sun Max", "sun.max"),
        ("Sun Max Fill", "sun.max.fill"),
        ("Sun Min", "sun.min"),
        ("Sun Min Fill", "sun.min.fill"),
        ("Display", "display"),
        ("Sliders", "slider.vertical.3"),
        ("Sliders Square", "slider.horizontal.below.square.filled.and.square"),
        ("Dial Low", "dial.low"),
        ("Dial High", "dial.high"),
        ("Contrast", "circle.righthalf.filled"),
        ("Moon Fill", "moon.fill"),
        ("Moon Stars", "moon.stars"),
        ("Crescent", "moonphase.waning.crescent"),
        ("Rectangle", "rectangle"),
        ("Rectangle Portrait", "rectangle.portrait"),
    ]
    private var iconName: String {
        get { UserDefaults.standard.string(forKey: iconKey) ?? Self.defaultIcon }
        set { UserDefaults.standard.set(newValue, forKey: iconKey); updateStatusIcon() }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        statusMenu.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(openStatusMenu)
    }

    private func startBackgroundRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(timeInterval: 10, target: self,
                                            selector: #selector(backgroundRefreshTick),
                                            userInfo: nil, repeats: true)
        refreshTimer?.tolerance = 3
    }

    @objc private func backgroundRefreshTick() {
        // A refresh queued in the middle of a held key would delay the key writes
        // and then read back over them. Let the keys settle first.
        guard Date().timeIntervalSince(lastMediaKeyAdjustment) > 1.5,
              displays.allSatisfy({ !$0.isAdjusting }) else { return }
        refreshActive(rebuildWhenDone: false)
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        if let image = Self.monochromeSymbol(iconName, accessibility: "Didact") {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "Didact"
        }
    }

    /// A flat, monochrome template image for an SF Symbol. `isTemplate` alone
    /// doesn't flatten symbols that default to variable/multicolour rendering
    /// (e.g. `display`, `slider.horizontal.below.square.filled.and.square`), so
    /// force a monochrome rendering configuration too.
    static func monochromeSymbol(_ name: String, accessibility: String? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: accessibility) else { return nil }
        let image = base.withSymbolConfiguration(.preferringMonochrome()) ?? base
        image.isTemplate = true
        return image
    }

    // MARK: - Display discovery

    /// The display's EDID vendor and product numbers (as CoreGraphics reports
    /// them, matching Lunar's DisplayVendorID/DisplayProductID), or nil when the
    /// value is unknown/reserved.
    static func edidIDs(for displayID: CGDirectDisplayID) -> (vendor: Int?, product: Int?) {
        func valid(_ v: UInt32) -> Int? { (v == 0 || v == 0xFFFF_FFFF) ? nil : Int(v) }
        return (valid(CGDisplayVendorNumber(displayID)), valid(CGDisplayModelNumber(displayID)))
    }

    private func rescanDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let online = Array(ids.prefix(Int(count)))

        let matches = AppleSiliconDDC.getServiceMatches(displayIDs: online)
        var controllers: [DisplayController] = []
        for match in matches {
            guard let service = match.service else { continue }
            let details = match.serviceDetails
            let productName = details.productName
            let (vendor, product) = Self.edidIDs(for: match.displayID)
            guard let config = configs.first(where: {
                $0.matches(productName: productName, vendor: vendor, product: product)
            }) else { continue }
            let stableID = [details.edidUUID, details.alphanumericSerialNumber, productName]
                .first(where: { !$0.isEmpty }) ?? "\(match.displayID)"
            controllers.append(DisplayController(
                displayID: match.displayID,
                service: service,
                productName: productName.isEmpty ? config.name : productName,
                stableID: stableID,
                config: config))
        }

        displays = controllers
        // Keep the same display selected, but adopt the freshly-built controller so
        // a reloaded/edited config takes effect (the old controller holds the old
        // config). Fall back to the first display when the selection is gone.
        if let current = active, let same = displays.first(where: { $0.displayID == current.displayID }) {
            active = same
        } else {
            active = displays.first
        }
        refreshInFlight = false
        refreshActive(rebuildWhenDone: true)
        rebuildMenu()
        refreshMediaKeySnapshot()
        if displays.isEmpty {
            stopMediaKeyTap()
        } else {
            ensureMediaKeysStarted()
        }
    }

    private func refreshActive(rebuildWhenDone: Bool, rebuildOpenMenuWhenDone: Bool = false) {
        guard let active, !refreshInFlight, !isMenuOpen else { return }
        let wasCold = !active.hasInitialValues
        refreshInFlight = true
        active.refreshAll { [weak self] in
            guard let self else { return }
            self.refreshInFlight = false
            self.refreshMediaKeySnapshot()
            if rebuildWhenDone, (!self.isMenuOpen || rebuildOpenMenuWhenDone || wasCold) {
                if self.isMenuOpen, wasCold {
                    self.frozenHidden = Set(active.config.controls.filter { active.isHidden($0) }.map(\.stateKey))
                }
                self.rebuildMenu()
            }
        }
    }

    // MARK: - Menu building

    @objc private func openStatusMenu() {
        guard !isOpeningMenu else { return }
        isOpeningMenu = true

        if let active, active.hasInitialValues {
            frozenHidden = Set(active.config.controls.filter { active.isHidden($0) }.map(\.stateKey))
        } else {
            frozenHidden = nil
            refreshActive(rebuildWhenDone: true, rebuildOpenMenuWhenDone: true)
        }
        rebuildMenu()
        isOpeningMenu = false
        statusItem.popUpMenu(statusMenu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu, !isOpeningMenu {
            ensureMediaKeysStarted()
            rebuildMenu()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = menu === statusMenu
        // Freeze which controls are visible for this open. Reads happen outside
        // the open-menu path so the row set doesn't mutate under the pointer.
        if menu === statusMenu, let active, active.hasInitialValues {
            frozenHidden = Set(active.config.controls.filter { active.isHidden($0) }.map(\.stateKey))
        } else {
            frozenHidden = nil
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        frozenHidden = nil   // re-evaluate visibility fresh on the next open
        refreshActive(rebuildWhenDone: false)
        maybeShowFirstRunWizard()
    }

    private func rebuildMenu() {
        let menu = statusMenu
        menu.removeAllItems()

        guard let active else {
            let item = NSMenuItem(title: "No supported monitor found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            addAppMenu(to: menu)
            return
        }

        // Monitor name as a disabled header at the very top.
        let nameItem = NSMenuItem(title: active.productName, action: nil, keyEquivalent: "")
        nameItem.isEnabled = false
        menu.addItem(nameItem)

        guard active.hasInitialValues else {
            let item = NSMenuItem(title: refreshInFlight ? "Reading monitor…" : "Monitor values not loaded", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            addAppMenu(to: menu)
            return
        }

        // When more than one supported display is connected, offer a switcher.
        if displays.count > 1 {
            addDisplayPicker(to: menu, active: active)
        }
        menu.addItem(.separator())

        // When any item shows a checkmark, AppKit widens the menu's state-column
        // gutter and shifts every native title right. Custom slider views don't
        // shift automatically, so match the inset (only toggles that are on draw
        // a checkmark in the main menu — cycle checkmarks live in submenus).
        let checked = active.config.controls.contains { control in
            guard control.kind == .toggle, control.hidden != true, active.isOn(control) else { return false }
            let hidden = frozenHidden?.contains(control.stateKey) ?? active.isHidden(control)
            return !hidden
        }
        let sliderInset: CGFloat = checked ? 24.5 : 14

        // Flat list of controls. Both `group` and `section` boundaries become a
        // separator — but only if real controls precede it, so there are never
        // leading or doubled dividers. No text headings: plain macOS menu.
        let displayLabels = Self.menuDisplayLabels(active.config.controls)
        var addedSinceSeparator = false
        for control in active.config.controls {
            // Use the frozen snapshot while the menu is open so a post-open refresh
            // can't change which rows are present (and jump the height).
            if control.hidden == true { continue }   // user-hidden via Edit Menu
            let hidden = frozenHidden?.contains(control.stateKey) ?? active.isHidden(control)
            if !control.isHeader && hidden { continue }
            // Drop a redundant prefix shared with a sibling in the group (so
            // "Moon Halo Brightness" reads as "Brightness" under the Moon Halo divider).
            var control = control
            if let shorter = displayLabels[control.stateKey] { control.label = shorter }
            switch control.kind {
            case .group, .section:
                if addedSinceSeparator {
                    menu.addItem(.separator())
                    addedSinceSeparator = false
                }
            case .range:
                menu.addItem(rangeItem(control, active: active, inset: sliderInset)); addedSinceSeparator = true
            case .cycle:
                menu.addItem(cycleItem(control, active: active)); addedSinceSeparator = true
            case .toggle:
                menu.addItem(toggleItem(control, active: active)); addedSinceSeparator = true
            }
        }

        menu.addItem(.separator())
        addAppMenu(to: menu)
    }

    /// Display labels that drop a prefix shared with a sibling in the same group —
    /// e.g. "Moon Halo Brightness" → "Brightness" when it sits in the Moon Halo group
    /// next to "Moon Halo". Keyed by stateKey; cosmetic only (the saved label is
    /// unchanged). Groups are the spans between header/divider entries.
    private static func menuDisplayLabels(_ controls: [Control]) -> [String: String] {
        var result: [String: String] = [:]
        var group: [Control] = []
        func flush() {
            let labels = group.compactMap(\.label)
            for c in group {
                guard let label = c.label,
                      let parent = labels
                        .filter({ $0 != label && label.hasPrefix($0 + " ") })
                        .max(by: { $0.count < $1.count }) else { continue }
                let stripped = String(label.dropFirst(parent.count + 1))
                if !stripped.isEmpty { result[c.stateKey] = stripped }
            }
            group.removeAll()
        }
        for c in controls {
            if c.isHeader { flush() } else { group.append(c) }
        }
        flush()
        return result
    }

    private func rangeItem(_ control: Control, active: DisplayController, inset: CGFloat) -> NSMenuItem {
        let item = NSMenuItem()
        let value = active.value(for: control) ?? control.min ?? 0
        let enabled = active.hasInitialValues && !active.isDisabled(control)
        item.view = SliderMenuItemView(
            title: control.label ?? "",
            min: control.min ?? 0,
            max: control.max ?? 100,
            step: control.stepValue,
            value: value,
            inset: inset,
            enabled: enabled) { [weak self, weak active] newValue in
                guard let active else { return }
                active.set(control, to: newValue, throttle: true)
                _ = self
            }
        return item
    }

    private func cycleItem(_ control: Control, active: DisplayController) -> NSMenuItem {
        let parent = NSMenuItem(title: control.label ?? "", action: nil, keyEquivalent: "")
        let current = active.value(for: control)
        let hasHDR = control.options?.contains { $0.hdr == true } ?? false
        let hdrOn = hasHDR && active.isHDREnabled

        // Show the current selection on the parent (dimmed) — HDR wins when on.
        let selectedLabel = hdrOn
            ? control.options?.first(where: { $0.hdr == true })?.label
            : control.options?.first(where: { $0.value?.value == current })?.label
        if let selected = selectedLabel {
            let title = NSMutableAttributedString(string: (control.label ?? "") + "   ")
            title.append(NSAttributedString(
                string: selected, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            parent.attributedTitle = title
        }

        if active.isDisabled(control) {
            parent.isEnabled = false
            return parent
        }
        let submenu = NSMenu()
        for option in control.options ?? [] {
            let opt = NSMenuItem(title: option.label, action: #selector(selectCycle(_:)), keyEquivalent: "")
            opt.target = self
            if option.hdr == true {
                opt.representedObject = CycleChoice(control, 0, isHDR: true)
                opt.state = active.isHDREnabled ? .on : .off
            } else if let value = option.value?.value {
                opt.representedObject = CycleChoice(control, value)
                opt.state = (!hdrOn && value == current) ? .on : .off
            }
            submenu.addItem(opt)
        }
        parent.submenu = submenu
        return parent
    }

    private func toggleItem(_ control: Control, active: DisplayController) -> NSMenuItem {
        let item = NSMenuItem(title: control.label ?? "", action: #selector(toggle(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ToggleRef(control)
        item.state = active.isOn(control) ? .on : .off
        item.isEnabled = !active.isDisabled(control)
        return item
    }

    private func addDisplayPicker(to menu: NSMenu, active: DisplayController) {
        let parent = NSMenuItem(title: "Switch Display", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for display in displays {
            let item = NSMenuItem(title: display.productName, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = DisplayRef(display)
            item.state = (display.displayID == active.displayID) ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addAppMenu(to menu: NSMenu) {
        let app = NSMenuItem(title: "Didact", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        func add(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.isEnabled = enabled
            submenu.addItem(item)
        }

        // Talk to the current display.
        add("Refresh from Monitor", #selector(refresh), enabled: active != nil)
        add("Rescan Displays", #selector(rescan))

        submenu.addItem(.separator())

        // Add / share monitor support. Teach is always enabled (its purpose is to
        // support a monitor that matches no config yet); the others need a display.
        add("Set Up This Monitor…", #selector(openTeachFromMenu))
        add("Edit Menu…", #selector(openMenuEditor), enabled: activeHasUserProfile())
        add("Submit to Community…", #selector(openSubmit), enabled: activeHasUserProfile())
        // Raw VCP change log — a developer diagnostic, not needed by end users now
        // that the Teach wizard exists. Debug builds only.
        #if DEBUG
        submenu.addItem(.separator())
        add("Listen for Changes…", #selector(openListen), enabled: active != nil)
        #endif

        submenu.addItem(.separator())

        // Manage the profile files.
        add("Reload Configs", #selector(reloadConfigs))
        add("Open Configs Folder", #selector(openMonitorsFolder))

        submenu.addItem(.separator())

        // App preferences.
        let iconItem = NSMenuItem(title: "Menu Bar Icon", action: nil, keyEquivalent: "")
        let iconMenu = NSMenu()
        for choice in Self.iconChoices.sorted(by: { $0.label < $1.label }) {
            let it = NSMenuItem(title: choice.label, action: #selector(selectIcon(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = choice.symbol
            it.state = (iconName == choice.symbol) ? .on : .off
            it.image = Self.monochromeSymbol(choice.symbol, accessibility: choice.label)  // flat preview
            iconMenu.addItem(it)
        }
        iconItem.submenu = iconMenu
        submenu.addItem(iconItem)

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        submenu.addItem(launch)

        submenu.addItem(.separator())

        let mediaKeys = NSMenuItem(title: "Media Keys", action: nil, keyEquivalent: "")
        let mediaMenu = NSMenu()

        let master = NSMenuItem(title: "Use Media Keys",
                                action: #selector(toggleMediaKeys), keyEquivalent: "")
        master.target = self
        master.state = mediaKeySettings.masterEnabled ? .on : .off
        master.isEnabled = mediaKeySettings.masterEnabled
            || (!displays.isEmpty
                && (mediaKeySettings.brightnessEnabled || mediaKeySettings.audioEnabled))
        mediaMenu.addItem(master)

        let brightness = NSMenuItem(title: "Brightness Keys",
                                    action: #selector(toggleBrightnessKeys), keyEquivalent: "")
        brightness.target = self
        brightness.state = mediaKeySettings.brightnessEnabled ? .on : .off
        mediaMenu.addItem(brightness)

        let audio = NSMenuItem(title: "Volume & Mute Keys",
                               action: #selector(toggleAudioKeys), keyEquivalent: "")
        audio.target = self
        audio.state = mediaKeySettings.audioEnabled ? .on : .off
        mediaMenu.addItem(audio)

        if displays.isEmpty {
            mediaMenu.addItem(.separator())
            let note = NSMenuItem(title: "No supported monitor", action: nil, keyEquivalent: "")
            note.isEnabled = false
            mediaMenu.addItem(note)
        } else if mediaKeySettings.masterEnabled {
            mediaMenu.addItem(.separator())
            if !AXIsProcessTrusted() {
                let grant = NSMenuItem(title: "Grant Accessibility Permission…",
                                       action: #selector(grantAccessibility), keyEquivalent: "")
                grant.target = self
                mediaMenu.addItem(grant)
            } else if mediaKeyTapFailed {
                let retry = NSMenuItem(title: "Retry Media Keys",
                                       action: #selector(retryMediaKeys), keyEquivalent: "")
                retry.target = self
                mediaMenu.addItem(retry)
                let input = NSMenuItem(title: "Check Input Monitoring Permission…",
                                       action: #selector(openInputMonitoring), keyEquivalent: "")
                input.target = self
                mediaMenu.addItem(input)
            }
        }

        mediaKeys.submenu = mediaMenu
        mediaKeys.state = mediaKeySettings.masterEnabled ? .on : .off
        submenu.addItem(mediaKeys)

        submenu.addItem(.separator())

        add("About Didact…", #selector(showAbout))
        add("Quit Didact", #selector(quit), key: "q")

        app.submenu = submenu
        menu.addItem(app)
    }

    // MARK: - Actions

    @objc private func selectCycle(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? CycleChoice else { return }
        if choice.isHDR {
            active?.setHDR(true)                                  // turn on macOS HDR
        } else {
            if active?.isHDREnabled == true { active?.setHDR(false) }  // leaving HDR for a DDC mode
            active?.set(choice.control, to: choice.value)
        }
        refreshAfterChange()
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ToggleRef, let active else { return }
        let control = ref.control
        let next = active.isOn(control) ? control.offValue?.value : control.onValue?.value
        if let next { active.set(control, to: next) }
        refreshAfterChange()
    }

    /// A cycle/toggle change (notably Color Mode) can re-adjust other controls
    /// on the hardware, so re-read after it. Rebuild immediately for the change
    /// itself, then again when the fresh values land.
    private func refreshAfterChange() {
        rebuildMenu()
        refreshActive(rebuildWhenDone: true)
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? DisplayRef else { return }
        active = ref.controller
        refreshActive(rebuildWhenDone: true)
        rebuildMenu()
    }

    @objc private func refresh() {
        refreshActive(rebuildWhenDone: true)
    }

    @objc private func rescan() {
        rescanDisplays()
    }

    @objc private func reloadConfigs() {
        configs = MonitorConfigStore.load()
        rescanDisplays()
    }

    @objc private func openMonitorsFolder() {
        MonitorConfigStore.ensureUserDirectory()
        NSWorkspace.shared.open(MonitorConfigStore.userDirectory)
    }

    /// Show a Dock icon (so the app can be ⌘-Tabbed to) while any of our real
    /// windows is open; drop back to a menu-bar-only agent once they're all closed.
    private func updateDockVisibility() {
        let anyOpen = teachWindow != nil || menuEditorWindow != nil || listenWindow != nil
        NSApp.setActivationPolicy(anyOpen ? .regular : .accessory)
    }

    @objc private func openListen() {
        guard let active else { return }
        if listenWindow == nil {
            listenWindow = ListenWindowController(
                title: active.productName,
                makeListener: { onLog in active.makeListener(onLog: onLog) },
                onClose: { [weak self] in self?.listenWindow = nil; self?.updateDockVisibility() })
        }
        updateDockVisibility()
        listenWindow?.show()
    }

    @objc private func openTeachFromMenu() {
        openTeach(showMediaKeys: false)
    }

    /// First-run setup opens the wizard once, even for a recognized monitor, so
    /// the media-key offer is not hidden from people who don't need to teach one.
    private func maybeShowFirstRunWizard() {
        guard !UserDefaults.standard.bool(forKey: DefaultsKey.setupWizardSeen),
              !displays.isEmpty, teachWindow == nil, !isMenuOpen,
              teachableServiceExists() else { return }
        openTeach(showMediaKeys: true)
    }

    private func markSetupWizardSeen() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.setupWizardSeen)
    }

    private func openTeach(showMediaKeys: Bool) {
        // Prefer the active matched display — its LearnSession shares the serial
        // DDC queue, so probe reads stay ordered with normal control I/O.
        if let active {
            presentTeach(session: active.makeLearnSession(), name: active.productName,
                         displayID: active.displayID, showMediaKeys: showMediaKeys,
                         readyProfile: showMediaKeys ? active.config : nil)
            return
        }
        // No matched config: resolve a raw service for an online external display.
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let matches = AppleSiliconDDC.getServiceMatches(displayIDs: Array(ids.prefix(Int(count))))
            .filter { $0.service != nil }

        guard !matches.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No external display found"
            alert.informativeText = "Connect a DDC/CI-capable monitor over DisplayPort or USB-C and try again."
            alert.runModal()
            return
        }

        let chosen: AppleSiliconDDC.Arm64Service
        if matches.count == 1 {
            chosen = matches[0]
        } else {
            let alert = NSAlert()
            alert.messageText = "Which display do you want to teach?"
            for match in matches.prefix(3) { alert.addButton(withTitle: displayName(match)) }
            alert.addButton(withTitle: "Cancel")
            let offset = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard offset >= 0, offset < min(3, matches.count) else { return }
            chosen = matches[offset]
        }

        guard let service = chosen.service else { return }
        let queue = DispatchQueue(label: "com.gingerbeardman.Didact.teach.\(chosen.displayID)")
        presentTeach(session: LearnSession(service: service, queue: queue), name: displayName(chosen),
                     displayID: chosen.displayID, showMediaKeys: showMediaKeys, readyProfile: nil)
    }

    /// Whether there's anything the teach wizard could run against — the active
    /// matched display, or any online external display with a DDC service.
    private func teachableServiceExists() -> Bool {
        if active != nil { return true }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return AppleSiliconDDC.getServiceMatches(displayIDs: Array(ids.prefix(Int(count))))
            .contains { $0.service != nil }
    }

    @objc private func openMenuEditor() {
        guard let active else { return }
        if menuEditorWindow == nil {
            menuEditorWindow = MenuEditorWindowController(
                config: active.config,
                onSaved: { [weak self] _ in self?.reloadConfigs() },
                onClose: { [weak self] in self?.menuEditorWindow = nil; self?.updateDockVisibility() })
        }
        updateDockVisibility()
        menuEditorWindow?.show()
    }

    @objc private func openSubmit() {
        guard let active else { return }
        // Read the live capabilities dump to include with the profile, then submit.
        active.readCapabilities { [weak self] caps in
            let prefilled = CommunitySubmission.submit(config: active.config, capabilities: caps)
            if !prefilled { self?.notifyClipboardSubmission() }
        }
    }

    /// The full profile + capabilities are too long for GitHub to pre-fill, so
    /// they went to the clipboard — tell the user to paste them in.
    private func notifyClipboardSubmission() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Profile copied to the clipboard"
        alert.informativeText = "It’s too long for GitHub to pre-fill. In the new issue that just opened, paste it into the description (⌘V) and submit."
        alert.runModal()
    }

    /// True when the user has saved their own profile for the active monitor —
    /// only then is there something worth submitting (a bundled-only monitor has
    /// nothing new to contribute).
    private func activeHasUserProfile() -> Bool {
        guard let active else { return false }
        return FileManager.default.fileExists(atPath: MonitorConfigStore.fileURL(forName: active.config.name).path)
    }

    private func displayName(_ match: AppleSiliconDDC.Arm64Service) -> String {
        let name = match.serviceDetails.productName
        return name.isEmpty ? "Display \(match.displayID)" : name
    }

    private func presentTeach(session: LearnSession, name: String,
                              displayID: CGDirectDisplayID, showMediaKeys: Bool,
                              readyProfile: MonitorConfig?) {
        let (vendor, product) = Self.edidIDs(for: displayID)
        let edid = (vendor != nil && product != nil) ? [MonitorConfig.EDIDMatch(vendor: vendor!, product: product!)] : nil
        // The first-run path should recognize an already-working user profile so
        // it can go straight to the summary instead of re-teaching it. A manual
        // re-teach keeps using only curated bundled profiles, so a user's own
        // earlier (possibly wrong) profile can't feed its mistakes back in.
        let knownConfigs = showMediaKeys
            ? MonitorConfigStore.load()
            : MonitorConfigStore.loadBundled()
        if showMediaKeys {
            // Mark on presentation, not on close: quitting with the window open
            // should not bring the first-run wizard back on the next launch.
            markSetupWizardSeen()
        }
        if teachWindow == nil {
            teachWindow = TeachWizardWindowController(
                monitorName: name, session: session, knownConfigs: knownConfigs, edid: edid,
                displayID: displayID,
                readyProfile: readyProfile,
                mediaKeySettings: mediaKeySettings,
                showMediaKeysStep: showMediaKeys,
                onMediaKeySettingsChanged: { [weak self] settings in
                    guard let self else { return }
                    self.applyMediaKeySettings(settings)
                    if self.mediaKeySettings.masterEnabled, !AXIsProcessTrusted() {
                        // The wizard already showed the explanation next to the
                        // switch; this is the explicit enable that asks macOS.
                        self.requestAccessibility()
                        self.startAXPolling()
                    }
                },
                onSaved: { [weak self] in
                    self?.reloadConfigs()
                    self?.openMenuEditor()   // final step: arrange/hide/group the menu
                },
                onClose: { [weak self] in
                    if showMediaKeys { self?.markSetupWizardSeen() }
                    self?.teachWindow = nil
                    self?.updateDockVisibility()
                })
        }
        updateDockVisibility()
        teachWindow?.show()
    }

    @objc private func selectIcon(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String else { return }
        iconName = symbol   // setter updates the status icon
        rebuildMenu()
    }

    // MARK: - Media keys

    private func setupMediaKeys() {
        audioMonitor.start { [weak self] in self?.refreshMediaKeySnapshot() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
        ensureMediaKeysStarted()
    }

    private func ensureMediaKeysStarted() {
        guard mediaKeySettings.isActive, !displays.isEmpty,
              mediaKeyTap == nil, AXIsProcessTrusted() else { return }
        startMediaKeyTap()
    }

    private func startMediaKeyTap() {
        guard mediaKeySettings.isActive, !displays.isEmpty,
              mediaKeyTap == nil, AXIsProcessTrusted() else { return }
        let router = mediaKeyRouter ?? MediaKeyRouter()
        router.onAction = { [weak self] action in self?.performMediaKey(action) }
        mediaKeyRouter = router
        refreshMediaKeySnapshot()

        let tap = MediaKeyTap(
            handler: { [weak router] event in
                guard let router else { return false }
                return router.handle(event, pointer: CGEvent(source: nil)?.location)
            },
            onDisabled: { [weak self] in
                DispatchQueue.main.async { self?.mediaKeyTapWasDisabled() }
            })
        if tap.start() {
            mediaKeyTap = tap
            mediaKeyTapFailed = false
        } else {
            mediaKeyTapFailed = true
            NSLog("Didact: media key tap could not be created")
        }
    }

    private func stopMediaKeyTap() {
        mediaKeyTap?.stop()
        mediaKeyTap = nil
        mediaKeyTapFailed = false
    }

    private func mediaKeyTapWasDisabled() {
        stopMediaKeyTap()
        mediaKeyTapFailed = true
        refreshMediaKeySnapshot()
        rebuildMenu()
    }

    /// Save a settings change and make the tap match it. The router snapshot is
    /// refreshed immediately so a key pressed right after the menu closes sees
    /// the new role flags.
    private func applyMediaKeySettings(_ settings: MediaKeySettings) {
        mediaKeySettings = MediaKeySettingsStore.save(settings)
        refreshMediaKeySnapshot()
        if mediaKeySettings.isActive {
            if AXIsProcessTrusted(), !displays.isEmpty {
                ensureMediaKeysStarted()
            } else {
                stopMediaKeyTap()
            }
        } else {
            axPollTimer?.invalidate()
            axPollTimer = nil
            stopMediaKeyTap()
            mediaKeyOSD.hideImmediately()
        }
        rebuildMenu()
    }

    @objc private func toggleMediaKeys() {
        if mediaKeySettings.masterEnabled {
            var settings = mediaKeySettings
            settings.masterEnabled = false
            applyMediaKeySettings(settings)
            return
        }

        // Don't ask for system access before there's a monitor to control.
        guard !displays.isEmpty else { return }
        guard confirmAccessibilityExplanation() else { return }

        var settings = mediaKeySettings
        settings.masterEnabled = true
        applyMediaKeySettings(settings)

        if !AXIsProcessTrusted() {
            requestAccessibility()
            startAXPolling()
        }
    }

    @objc private func toggleBrightnessKeys() {
        var settings = mediaKeySettings
        settings.brightnessEnabled.toggle()
        applyMediaKeySettings(settings)
    }

    @objc private func toggleAudioKeys() {
        var settings = mediaKeySettings
        settings.audioEnabled.toggle()
        applyMediaKeySettings(settings)
    }

    /// Explain what Accessibility is used for before macOS shows its own prompt.
    /// Only needed when access is missing; if it is already granted, enabling the
    /// feature is silent.
    private func confirmAccessibilityExplanation() -> Bool {
        guard !AXIsProcessTrusted() else { return true }

        let alert = NSAlert()
        alert.messageText = "Accessibility Access"
        alert.informativeText = """
        Didact needs Accessibility access to read the brightness, volume and mute keys. \
        It reads only those five media keys — never normal typing — and you can revoke \
        access at any time in System Settings.

        If macOS does not show its prompt, use Didact ▸ Media Keys ▸ Grant Accessibility \
        Permission… to open the right settings pane.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func retryMediaKeys() {
        guard mediaKeySettings.isActive else { return }
        stopMediaKeyTap()
        if AXIsProcessTrusted() {
            startMediaKeyTap()
        } else {
            startAXPolling()
        }
        refreshMediaKeySnapshot()
        rebuildMenu()
    }

    @objc private func grantAccessibility() {
        requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startAXPolling()
    }

    @objc private func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func startAXPolling() {
        axPollTimer?.invalidate()
        axPollDeadline = Date().addingTimeInterval(120)
        axPollTimer = Timer.scheduledTimer(timeInterval: 1, target: self,
                                           selector: #selector(axPollTick),
                                           userInfo: nil, repeats: true)
    }

    @objc private func axPollTick() {
        if AXIsProcessTrusted() {
            axPollTimer?.invalidate()
            axPollTimer = nil
            startMediaKeyTap()
            refreshMediaKeySnapshot()
            rebuildMenu()
        } else if Date() > axPollDeadline {
            axPollTimer?.invalidate()
            axPollTimer = nil
        }
    }

    private func refreshMediaKeySnapshot() {
        guard let router = mediaKeyRouter else { return }
        let states = displays.map { controller in
            MediaKeyDisplayState(
                displayID: controller.displayID,
                bounds: CGDisplayBounds(controller.displayID),
                productName: controller.productName,
                brightness: roleState(controller, .brightness),
                volume: roleState(controller, .volume),
                mute: roleState(controller, .mute))
        }
        let audio = DefaultAudioOutput.current()
        let matched = MediaKeyRouter.matchDisplayID(for: audio.name, in: states)
        router.update(
            displays: states,
            audio: MediaKeyAudioState(name: audio.name,
                                      hasNativeVolume: audio.hasNativeVolume,
                                      matchedDisplayID: matched),
            settings: mediaKeySettings,
            permissionGranted: AXIsProcessTrusted(),
            suspended: mediaKeysSuspended)
    }

    private func roleState(_ controller: DisplayController,
                           _ role: Control.Role) -> MediaKeyRoleState? {
        guard let control = controller.config.control(forRole: role) else { return nil }
        return MediaKeyRoleState(
            control: control,
            isVisible: control.hidden != true && !controller.isHidden(control),
            isEnabled: !controller.isDisabled(control),
            hasValue: controller.cachedValue(for: control) != nil,
            isOn: control.kind == .toggle ? controller.isOn(control) : false)
    }

    private func performMediaKey(_ action: MediaKeyAction) {
        guard mediaKeySettings.isActive, !mediaKeysSuspended,
              let controller = displays.first(where: { $0.displayID == action.displayID }),
              let control = controller.config.control(forRole: action.role),
              control.hidden != true, !controller.isHidden(control) else { return }

        switch action.role {
        case .brightness:
            guard mediaKeySettings.brightnessEnabled else { return }
        case .volume, .mute:
            guard mediaKeySettings.audioEnabled else { return }
        }

        lastMediaKeyAdjustment = Date()

        switch action.role {
        case .brightness:
            guard !controller.isDisabled(control),
                  let current = controller.cachedValue(for: control) else { return }
            let next = clamp(current + action.direction * control.keyStep, to: control)
            if next != current { controller.setKey(control, to: next) }
            showMediaKeyOSD(.brightness, value: next,
                            min: control.min ?? 0, max: control.max ?? 100,
                            displayID: action.displayID, muted: false)

        case .volume:
            guard let current = controller.cachedValue(for: control) else { return }
            let mute = controller.config.control(forRole: .mute)
            let muted = mute.map {
                !controller.isDisabled($0) &&
                controller.cachedValue(for: $0) == $0.onValue?.value
            } ?? false
            // Volume is disabled while muted in wizard-built profiles; allow that
            // one case so a volume key can unmute and adjust in one press.
            guard !controller.isDisabled(control) || muted else { return }
            if muted, let mute, let off = mute.offValue?.value {
                controller.set(mute, to: off)
            }
            let next = clamp(current + action.direction * control.keyStep, to: control)
            if next != current { controller.setKey(control, to: next) }
            showMediaKeyOSD(.volume, value: next,
                            min: control.min ?? 0, max: control.max ?? 100,
                            displayID: action.displayID, muted: false)

        case .mute:
            guard !controller.isDisabled(control),
                  let on = control.onValue?.value,
                  let off = control.offValue?.value else { return }
            let wasMuted = controller.isOn(control)
            controller.set(control, to: wasMuted ? off : on)
            showMediaKeyOSD(.mute, value: wasMuted ? 1 : 0,
                            min: 0, max: 1,
                            displayID: action.displayID, muted: !wasMuted)
        }
    }

    private func clamp(_ value: Int, to control: Control) -> Int {
        let lo = control.min ?? 0
        let hi = control.max ?? value
        return Swift.min(Swift.max(value, lo), hi)
    }

    private func showMediaKeyOSD(_ role: Control.Role, value: Int, min: Int, max: Int,
                                 displayID: CGDirectDisplayID, muted: Bool) {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main
        guard let screen else { return }
        mediaKeyOSD.show(role: role, value: value, min: min, max: max,
                         muted: muted, on: screen)
    }

    @objc private func systemWillSleep() {
        mediaKeysSuspended = true
        mediaKeyOSD.hideImmediately()
        refreshMediaKeySnapshot()
    }

    @objc private func systemDidWake() {
        mediaKeysSuspended = false
        rescanDisplays()
        refreshMediaKeySnapshot()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Didact: launch at login toggle failed: \(error)")
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
