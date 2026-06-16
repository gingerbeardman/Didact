//
//  DisplayController.swift
//  BtnQ
//
//  Owns one matched display: its DDC service, its config, and the cached value
//  of every control. All DDC I/O runs on a private serial queue (each read/write
//  can sleep tens of milliseconds with retries); the cache and all callbacks are
//  confined to the main actor.
//

import AppKit

@MainActor
final class DisplayController {
    let displayID: CGDirectDisplayID
    let productName: String
    let config: MonitorConfig

    private let service: IOAVService
    private let stableID: String
    private let queue: DispatchQueue
    private var cache: [String: Int] = [:]
    private var throttleWork: [String: DispatchWorkItem] = [:]

    /// False until the first hardware read completes; the UI disables sliders
    /// until then so they don't show a default value that snaps to the real one.
    private(set) var hasInitialValues = false

    init(displayID: CGDirectDisplayID, service: IOAVService, productName: String,
         stableID: String, config: MonitorConfig) {
        self.displayID = displayID
        self.service = service
        self.productName = productName
        self.stableID = stableID
        self.config = config
        self.queue = DispatchQueue(label: "com.gingerbeardman.Didact.ddc.\(displayID)")
        loadPersistedValues()
    }

    // MARK: - Reading

    /// The cached value of a control, or a sensible default (range → min,
    /// toggle → off) when nothing is known yet. Cycles return nil until read.
    func value(for control: Control) -> Int? {
        if let v = cache[control.stateKey] { return v }
        switch control.kind {
        case .range: return control.min ?? 0
        case .toggle: return control.offValue?.value
        default: return nil
        }
    }

    func isOn(_ control: Control) -> Bool {
        value(for: control) == control.onValue?.value
    }

    // MARK: - macOS HDR (system toggle, not DDC)

    var isHDREnabled: Bool {
        CoreDisplay_Display_IsHDRModeEnabled(displayID)
    }

    func setHDR(_ enabled: Bool) {
        CoreDisplay_Display_SetHDRModeEnabled(displayID, enabled)
    }

    /// True when the control's `disableWhen` condition is met (the referenced
    /// control currently holds the given value). Used to render it read-only.
    func isDisabled(_ control: Control) -> Bool { control.disableWhen.map(matches) ?? false }
    func isHidden(_ control: Control) -> Bool { control.hideWhen.map(matches) ?? false }

    private func matches(_ cond: Control.Condition) -> Bool {
        if cond.system == "hdr", isHDREnabled { return true }
        guard let vcp = cond.vcp else { return false }
        let key = "\(vcp.value)/\(cond.channel?.value ?? -1)/"   // matches stateKey (no byte)
        guard let value = cache[key] else { return false }
        if let equals = cond.equals, value == equals.value { return true }
        if let any = cond.equalsAny, any.contains(where: { $0.value == value }) { return true }
        return false
    }

    /// Read every readable control from the hardware, then update the cache and
    /// invoke `completion` on the main actor.
    func refreshAll(completion: @escaping @MainActor () -> Void) {
        let readable = config.controls.filter { $0.isReadable }
        let svc = service
        queue.async {
            var results: [String: Int] = [:]
            for control in readable {
                guard let code = control.featureCode else { continue }
                if let reply = AppleSiliconDDC.read(service: svc, command: code),
                   let value = control.interpretRead(Int(reply.current)) {
                    results[control.stateKey] = value
                }
            }
            DispatchQueue.main.async {
                for (k, v) in results { self.cache[k] = v }
                self.hasInitialValues = true
                completion()
            }
        }
    }

    // MARK: - Writing

    /// Set a control's value: update the cache optimistically and write to the
    /// hardware. Range controls are throttled (sliders fire rapidly); cycles and
    /// toggles write immediately.
    func set(_ control: Control, to value: Int, throttle: Bool = false) {
        cache[control.stateKey] = value
        persistIfNeeded(control, value: value)

        if throttle {
            let key = control.stateKey
            throttleWork[key]?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.performWrite(control, value: value) }
            throttleWork[key] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
        } else {
            performWrite(control, value: value)
        }
    }

    private func performWrite(_ control: Control, value: Int) {
        guard let code = control.featureCode else { return }
        let payload: UInt16
        if control.byte != nil {
            // Packed 16-bit register (e.g. d9 = (temp<<8)|brightness): write all
            // of this register's byte-controls together — this control's new
            // value plus the siblings' current cached values — or the other byte
            // gets clobbered.
            var reg = 0
            for sibling in config.controls where sibling.featureCode == code && sibling.byte != nil {
                let v = (sibling.stateKey == control.stateKey) ? value : (cache[sibling.stateKey] ?? sibling.min ?? 0)
                switch sibling.byte {
                case .high: reg |= (v & 0xFF) << 8
                case .low: reg |= (v & 0xFF)
                case nil: break
                }
            }
            payload = UInt16(reg & 0xFFFF)
        } else if let channel = control.channelByte {
            payload = (UInt16(channel) << 8) | UInt16(value & 0xFF)
        } else {
            payload = UInt16(value & 0xFFFF)
        }
        let svc = service
        queue.async {
            _ = AppleSiliconDDC.write(service: svc, command: code, value: payload)
        }
    }

    // MARK: - Listen mode

    /// Make a listener bound to this display, sharing the DDC queue so probe
    /// reads stay serialized with normal control I/O. The config's controls let
    /// the listener label recognised vs. unrecognised values.
    func makeListener(onLog: @escaping (String) -> Void) -> DDCListener {
        DDCListener(service: service, queue: queue, controls: config.controls, onLog: onLog)
    }

    /// Make a teach session bound to this display, sharing the DDC queue so its
    /// probe reads stay serialized with normal control I/O.
    func makeLearnSession() -> LearnSession {
        LearnSession(service: service, queue: queue)
    }

    /// Read this display's raw DDC capabilities string (for a community submission).
    func readCapabilities(completion: @escaping @MainActor (String?) -> Void) {
        let svc = service
        queue.async {
            let caps = AppleSiliconDDC.readCapabilities(service: svc)
            DispatchQueue.main.async { completion(caps) }
        }
    }

    // MARK: - Persistence (for write-only / unreadable controls)

    private func persistIfNeeded(_ control: Control, value: Int) {
        guard control.noRead == true else { return }
        UserDefaults.standard.set(value, forKey: defaultsKey(control))
    }

    private func loadPersistedValues() {
        for control in config.controls where control.noRead == true && !control.isHeader {
            let key = defaultsKey(control)
            if UserDefaults.standard.object(forKey: key) != nil {
                cache[control.stateKey] = UserDefaults.standard.integer(forKey: key)
            }
        }
    }

    private func defaultsKey(_ control: Control) -> String {
        "btnq.state.\(stableID).\(control.stateKey)"
    }
}
