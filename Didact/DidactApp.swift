//
//  BtnQApp.swift
//  BtnQ
//
//  A menu-bar-only app to control a BenQ monitor over DDC/CI. No settings
//  window — everything lives in the status-bar menu, built generically from a
//  JSON monitor config (see MonitorConfig.swift / Monitors/*.json).
//

import AppKit
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
    private var configs: [MonitorConfig] = []
    private var displays: [DisplayController] = []
    private var active: DisplayController?
    private var listenWindow: ListenWindowController?
    private var teachWindow: TeachWizardWindowController?
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

        // Re-scan automatically when displays are plugged in / out or rearranged.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Onboard at startup: open the teach wizard when there's no supported
        // monitor to control (so an unknown display can be set up), and always in
        // debug builds so the wizard is easy to iterate on. Guarded so it never
        // pops the "no display" alert when nothing teachable is connected.
        #if DEBUG
        let autoTeach = true
        #else
        let autoTeach = (active == nil)
        #endif
        if autoTeach, teachableServiceExists() { openTeach() }
    }

    @objc private func screensChanged() {
        rescanDisplays()
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
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
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
        if let active, displays.contains(where: { $0.displayID == active.displayID }) {
            // keep current selection
        } else {
            active = displays.first
        }
        active?.refreshAll { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
    }

    // MARK: - Menu building

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Freeze which controls are visible for this open so a post-open value
        // refresh can't change a `hideWhen` result and snap the menu height.
        // BUT only when we already have real values — on a cold cache (e.g. the
        // very first open before the launch read finishes) the visibility we'd
        // freeze is wrong, so leave it live and let the refresh correct it.
        if let active, active.hasInitialValues {
            frozenHidden = Set(active.config.controls.filter { active.isHidden($0) }.map(\.stateKey))
        } else {
            frozenHidden = nil
        }
        // Pull fresh values from the display; the cache shows instantly, then the
        // menu updates when the read completes (values, and — only on a cold first
        // open — visibility too).
        active?.refreshAll { [weak self] in self?.rebuildMenu() }
    }

    func menuDidClose(_ menu: NSMenu) {
        frozenHidden = nil   // re-evaluate visibility fresh on the next open
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
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

        // When more than one supported display is connected, offer a switcher.
        if displays.count > 1 {
            addDisplayPicker(to: menu, active: active)
        }
        menu.addItem(.separator())

        // When any item shows a checkmark, AppKit widens the menu's state-column
        // gutter and shifts every native title right. Custom slider views don't
        // shift automatically, so match the inset (only toggles that are on draw
        // a checkmark in the main menu — cycle checkmarks live in submenus).
        let checked = active.config.controls.contains { $0.kind == .toggle && active.isOn($0) }
        let sliderInset: CGFloat = checked ? 24.5 : 14

        // Flat list of controls. Both `group` and `section` boundaries become a
        // separator — but only if real controls precede it, so there are never
        // leading or doubled dividers. No text headings: plain macOS menu.
        var addedSinceSeparator = false
        for control in active.config.controls {
            // Use the frozen snapshot while the menu is open so a post-open refresh
            // can't change which rows are present (and jump the height).
            let hidden = frozenHidden?.contains(control.stateKey) ?? active.isHidden(control)
            if !control.isHeader && hidden { continue }
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
        add("Refresh from Monitor", #selector(refresh), key: "r", enabled: active != nil)
        add("Rescan Displays", #selector(rescan))

        submenu.addItem(.separator())

        // Add / share monitor support. Teach is always enabled (its purpose is to
        // support a monitor that matches no config yet); the others need a display.
        add("Set Up This Monitor…", #selector(openTeach))
        add("Submit to Community…", #selector(openSubmit), enabled: activeHasUserProfile())
        // Raw VCP change log — a developer diagnostic, not needed by end users now
        // that the Teach wizard exists. Debug builds only.
        #if DEBUG
        add("Listen for Changes…", #selector(openListen), key: "d", enabled: active != nil)
        #endif

        submenu.addItem(.separator())

        // Manage the profile files.
        add("Reload Configs", #selector(reloadConfigs))
        add("Open Monitors Folder", #selector(openMonitorsFolder))

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
        active?.refreshAll { [weak self] in self?.rebuildMenu() }
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? DisplayRef else { return }
        active = ref.controller
        active?.refreshAll { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
    }

    @objc private func refresh() {
        active?.refreshAll { [weak self] in self?.rebuildMenu() }
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

    @objc private func openListen() {
        guard let active else { return }
        if listenWindow == nil {
            listenWindow = ListenWindowController(
                title: active.productName,
                makeListener: { onLog in active.makeListener(onLog: onLog) },
                onClose: { [weak self] in self?.listenWindow = nil })
        }
        listenWindow?.show()
    }

    @objc private func openTeach() {
        // Prefer the active matched display — its LearnSession shares the serial
        // DDC queue, so probe reads stay ordered with normal control I/O.
        if let active {
            presentTeach(session: active.makeLearnSession(), name: active.productName,
                         displayID: active.displayID)
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
                     displayID: chosen.displayID)
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

    private func presentTeach(session: LearnSession, name: String, displayID: CGDirectDisplayID) {
        let (vendor, product) = Self.edidIDs(for: displayID)
        let edid = (vendor != nil && product != nil) ? [MonitorConfig.EDIDMatch(vendor: vendor!, product: product!)] : nil
        if teachWindow == nil {
            teachWindow = TeachWizardWindowController(
                monitorName: name, session: session, knownConfigs: MonitorConfigStore.loadBundled(), edid: edid,
                onSaved: { [weak self] in self?.reloadConfigs() },
                onClose: { [weak self] in self?.teachWindow = nil })
        }
        teachWindow?.show()
    }

    @objc private func selectIcon(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String else { return }
        iconName = symbol   // setter updates the status icon
        rebuildMenu()
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
