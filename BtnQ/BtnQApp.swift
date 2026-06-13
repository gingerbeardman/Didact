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
struct BtnQApp: App {
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

    // Boxed references stored on menu items (Control is a value type).
    private final class CycleChoice { let control: Control; let value: Int; let isHDR: Bool
        init(_ control: Control, _ value: Int, isHDR: Bool = false) { self.control = control; self.value = value; self.isHDR = isHDR } }
    private final class ToggleRef { let control: Control; init(_ c: Control) { control = c } }
    private final class DisplayRef { let controller: DisplayController; init(_ c: DisplayController) { controller = c } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configs = MonitorConfigStore.load()
        setupStatusItem()
        rescanDisplays()

        // Re-scan automatically when displays are plugged in / out or rearranged.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() {
        rescanDisplays()
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
        if let image = Self.monochromeSymbol(iconName, accessibility: "BtnQ") {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "BtnQ"
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
            guard let config = configs.first(where: { $0.matches(productName: productName) }) else { continue }
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
        // Pull fresh values from the display each time the menu opens; the cache
        // shows instantly, then the menu updates when the read completes.
        active?.refreshAll { [weak self] in self?.rebuildMenu() }
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
            if !control.isHeader && active.isHidden(control) { continue }
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
        let app = NSMenuItem(title: "BtnQ", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let refresh = NSMenuItem(title: "Refresh from Monitor", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = active != nil
        submenu.addItem(refresh)

        let rescan = NSMenuItem(title: "Rescan Displays", action: #selector(rescan), keyEquivalent: "")
        rescan.target = self
        submenu.addItem(rescan)

        let reload = NSMenuItem(title: "Reload Configs", action: #selector(reloadConfigs), keyEquivalent: "")
        reload.target = self
        submenu.addItem(reload)

        let openFolder = NSMenuItem(title: "Open Monitors Folder", action: #selector(openMonitorsFolder), keyEquivalent: "")
        openFolder.target = self
        submenu.addItem(openFolder)

        let listen = NSMenuItem(title: "Listen for Changes…", action: #selector(openListen), keyEquivalent: "d")
        listen.target = self
        listen.isEnabled = active != nil
        submenu.addItem(listen)

        submenu.addItem(.separator())

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

        let about = NSMenuItem(title: "About BtnQ…", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        submenu.addItem(about)

        let quit = NSMenuItem(title: "Quit BtnQ", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        submenu.addItem(quit)

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
            NSLog("BtnQ: launch at login toggle failed: \(error)")
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
