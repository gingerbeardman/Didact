//
//  DDCListener.swift
//  BtnQ
//
//  Polls a set of candidate VCP codes and reports any that change, so you can
//  discover an unmapped feature: start listening, then press the buttons on the
//  monitor's own OSD and watch which code moves.
//
//  Runs on the owning DisplayController's serial queue so DDC reads never
//  interleave with normal control reads/writes. Log lines are delivered on the
//  main thread.
//

import Foundation

final class DDCListener {
    private let service: IOAVService
    private let queue: DispatchQueue
    private let codeControls: [UInt8: [Control]]
    private let onLog: (String) -> Void

    private var timer: DispatchSourceTimer?
    private var baseline: [UInt8: Int] = [:]
    private var live: [UInt8] = []
    private var started = false

    init(service: IOAVService, queue: DispatchQueue, controls: [Control],
         onLog: @escaping (String) -> Void) {
        self.service = service
        self.queue = queue
        // A feature code can back more than one control (e.g. D9 = Moon Halo
        // brightness and color temp), so map code -> [controls].
        var map: [UInt8: [Control]] = [:]
        for control in controls {
            if let code = control.featureCode { map[code, default: []].append(control) }
        }
        self.codeControls = map
        self.onLog = onLog
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Snapshot / diff

    private var snapshotPrev: [UInt8: Int]?

    /// Read every candidate code once and diff against the previous snapshot.
    /// Use this to find a setting that can only be changed by another DDC app
    /// (e.g. Display Pilot): set the value and QUIT that app, snapshot, set the
    /// other value and quit, snapshot again — the diff is just that setting.
    func snapshot() {
        queue.async { self.takeSnapshot() }
    }

    private func takeSnapshot() {
        var current: [UInt8: Int] = [:]
        for code in DDCProbe.scanCodes {
            // Two agreeing reads: rejects transient bus garbage (e.g. the 0x202
            // values that appear when another DDC app hasn't fully quit).
            guard let a = AppleSiliconDDC.read(service: service, command: code, numOfRetryAttemps: 3),
                  let b = AppleSiliconDDC.read(service: service, command: code, numOfRetryAttemps: 3),
                  a.current == b.current else { continue }
            current[code] = Int(a.current)
        }
        defer { snapshotPrev = current }

        guard let prev = snapshotPrev else {
            emit("════ SNAPSHOT A stored (\(current.count) codes). Change the setting in the other app, QUIT it, then Snapshot again. ════")
            return
        }
        let changed = Set(prev.keys).intersection(current.keys)
            .filter { prev[$0] != current[$0] }
            .sorted()
        if changed.isEmpty {
            emit("════ SNAPSHOT DIFF: no codes changed ════")
        } else {
            emit("════ SNAPSHOT DIFF: \(changed.count) code(s) changed ════")
            for code in changed {
                emit(line(code: code, old: prev[code]!, new: current[code]!))
            }
        }
    }

    // MARK: - Polling (runs on `queue`)

    private func tick() {
        if !started {
            // Thorough one-time baseline: generous retries so no live code is missed.
            for code in DDCProbe.scanCodes {
                if let reply = AppleSiliconDDC.read(service: service, command: code, numOfRetryAttemps: 3) {
                    baseline[code] = Int(reply.current)
                    live.append(code)
                }
            }
            started = true
            emit("— listening on \(live.count) codes — now change a setting using the buttons on the monitor itself —")
            return
        }

        for code in live {
            // Reliable polling: keep the library's default ~50ms read-settle and
            // retries so slow codes (e.g. the multiplexed Moon Halo register) are
            // never dropped — aggressive timing silently skipped exactly the codes
            // we care about. One write cycle instead of two shaves a little time
            // without hurting reliability. DDC has no passive bus tap, so every
            // code must be actively read; a full sweep is inherently a few seconds.
            guard let reply = AppleSiliconDDC.read(service: service, command: code, numOfWriteCycles: 1) else { continue }
            let value = Int(reply.current)
            if let previous = baseline[code], previous != value {
                baseline[code] = value
                emit(line(code: code, old: previous, new: value))
            }
        }
    }

    private func line(code: UInt8, old: Int, new: Int) -> String {
        let controls = codeControls[code] ?? []
        let multiplexed = controls.contains { $0.channelByte != nil }
        let name = multiplexed ? "multiplexed" : (controls.first?.label ?? "unmapped")
        let base = String(format: "VCP %02X  %@   %d → %d   [0x%X → 0x%X]", code, name, old, new, old, new)
        guard !controls.isEmpty else { return base }
        return base + "   \(describe(controls, old)) → \(describe(controls, new))"
    }

    /// Describe a raw value: for a multiplexed register (high byte selects a
    /// channel, e.g. Moon Halo on D9) decode `channel:value` and name the
    /// channel when known; otherwise give the recognised meaning of the value.
    private func describe(_ controls: [Control], _ raw: Int) -> String {
        // Packed register (e.g. d9 = (temp<<8)|brightness): show each byte's value.
        let packed = controls.filter { $0.byte != nil }
        if !packed.isEmpty {
            let parts = packed.compactMap { c in c.label.map { "\($0)=\(c.byteValue(raw))" } }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        if controls.contains(where: { $0.channelByte != nil }) {
            let channel = UInt8((raw >> 8) & 0xFF)
            let value = raw & 0xFF
            if let label = controls.first(where: { $0.channelByte == channel })?.label {
                return "\(label)=\(value)"
            }
            return String(format: "ch 0x%02X=%d", channel, value)
        }
        for control in controls {
            if let label = control.recognise(raw) { return label }
        }
        return "unrecognised"
    }

    private func emit(_ message: String) {
        let log = onLog
        DispatchQueue.main.async { log(message) }
    }
}
