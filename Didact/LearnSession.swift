//
//  LearnSession.swift
//  BtnQ
//
//  Drives the Teach wizard's code discovery. Three jobs, all on the owning
//  DisplayController's serial queue so probe reads never interleave with normal
//  control I/O:
//    1. prepare() — read the capabilities string and a one-time baseline of every
//       candidate code (also capturing each code's reported max).
//    2. autoDetect() — for a standard VESA control, confirm its spec-defined code
//       is present (in the capabilities list, or simply readable) with no user
//       effort.
//    3. beginLearning() — for everything else, poll while the user works the
//       physical button and report which code changes the most.
//
//  Verdicts are delivered on the main thread; all mutable state lives on the
//  queue, like DDCListener.
//

import Foundation

enum LearnUpdate {
    /// Still watching: the current front-runner (nil if nothing has moved yet)
    /// and how many times it has changed.
    case detecting(leader: UInt8?, count: Int)
    /// Confident: this code is the control, with its reported max, the value it
    /// currently holds (to seed the test control), and every discrete value
    /// discovered for it (from the capabilities list and from what was observed
    /// while teaching) — used to populate a cycle's option list.
    case learned(code: UInt8, max: UInt16, current: Int, values: [Int], capsDiscrete: Bool)
}

final class LearnSession {
    struct Detected {
        let code: UInt8
        let max: UInt16
        let current: Int
        /// Discrete values discovered for this code.
        let values: [Int]
        /// True when the capabilities string lists this code WITH a value group
        /// (authoritative). False when listed bare or absent — then the values are
        /// only what was observed, and a template's full set may be more complete.
        let capsDiscrete: Bool
    }

    private let service: IOAVService
    private let queue: DispatchQueue

    // Captured by prepare() (capabilities) and at the start of manual learning
    // (baseline); read on the queue during ticks.
    private var baseline: [UInt8: Int] = [:]
    private var maxValue: [UInt8: UInt16] = [:]
    private var capabilities: [UInt8: [Int]] = [:]
    private var probeCodes: [UInt8] = []        // the codes worth reading on this monitor

    // Per-control learning state (queue-confined).
    private var timer: DispatchSourceTimer?
    private var counting = false
    private var resolved = false
    private var changeCount: [UInt8: Int] = [:]
    private var lastSeen: [UInt8: Int] = [:]
    private var observed: [UInt8: Set<Int>] = [:]   // distinct values seen per code while teaching
    private var expectedKind: Control.Kind?         // the control being taught, to bias resolution
    private var expectedCode: UInt8?                // code a known profile expects for this control
    private var onUpdate: ((LearnUpdate) -> Void)?

    /// A code must change at least this many times to be a candidate…
    private let requiredChanges = 3
    /// …and lead the runner-up by at least this much, so two codes moving
    /// together (or one stray drift) never auto-resolves.
    private let leadMargin = 2

    init(service: IOAVService, queue: DispatchQueue) {
        self.service = service
        self.queue = queue
    }

    // MARK: - Setup

    /// Read the capabilities string and the baseline. `completion` fires on the
    /// main thread with the raw capabilities string (nil if the monitor didn't
    /// answer) for display/logging; auto-detect and learning work either way.
    func prepare(completion: @escaping (String?) -> Void) {
        let svc = service
        queue.async {
            let capsString = AppleSiliconDDC.readCapabilities(service: svc)
            self.capabilities = capsString.map { AppleSiliconDDC.parseVCPCodes(from: $0) } ?? [:]
            NSLog("Didact: capabilities string = %@", capsString ?? "(none — monitor didn't answer)")
            let codes = self.capabilities.keys.sorted().map { String(format: "0x%02X", $0) }
            NSLog("Didact: parsed %d VCP code(s): %@", codes.count, codes.joined(separator: " "))
            // Probe only the codes the monitor advertises. Reading a nonexistent
            // code is the slowest case — it exhausts the whole write/retry budget
            // before giving up — and the blind fallback sweeps the entire
            // 0xD0–0xFF vendor range, most of which don't exist. With a real
            // capabilities list we skip all of that. Excluded are codes that
            // change in response to OTHER controls — guaranteed false positives:
            //   0x02 New Control Value, 0x52 Active Control (report what just
            //   changed), 0xE1 BenQ active-control counter, 0xE3 light-meter drift.
            // Plus reset/save (never touch) and the noisy firmware-version code.
            let exclude: Set<UInt8> = [0x02, 0x04, 0x08, 0x0C, 0x52, 0xC9, 0xE1, 0xE3]
            self.probeCodes = self.capabilities.isEmpty
                ? DDCProbe.learnCodes
                : self.capabilities.keys.filter { !exclude.contains($0) }.sorted()
            // NB: the full baseline sweep is deliberately NOT done here — it's the
            // slow part, and the first step only needs the capabilities string.
            // Auto-detect reads its one code on demand; the baseline is built when
            // a manual learning step starts (beginLearning).
            self.startTimer()
            DispatchQueue.main.async { completion(capsString) }
        }
    }

    /// Confirm a standard control's spec-defined code is present, returning it and
    /// its max. Present means: listed in the capabilities `vcp(...)`, or simply
    /// readable with a non-zero max. Returns nil for proprietary controls (no
    /// standard code) or absent features.
    func autoDetect(_ template: ControlTemplate, completion: @escaping (Detected?) -> Void) {
        guard let code = template.standardCode else { completion(nil); return }
        let svc = service
        queue.async {
            // Read just this one code on demand (no full baseline needed yet).
            let reply = AppleSiliconDDC.read(service: svc, command: code, numOfRetryAttemps: 2)
            if let reply { self.baseline[code] = Int(reply.current); self.maxValue[code] = reply.max }
            let inCaps = self.capabilities[code] != nil
            let max = reply?.max ?? 0
            let present = inCaps || (reply != nil && max > 0)
            let result = present
                ? Detected(code: code, max: max, current: reply.map { Int($0.current) } ?? 0,
                           values: (self.capabilities[code] ?? []).sorted(),
                           capsDiscrete: !(self.capabilities[code]?.isEmpty ?? true))
                : nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Manual learning

    /// Begin watching for the active control. Resets the tally; `onUpdate` fires
    /// on the main thread every sweep with progress, then once with `.learned`.
    func beginLearning(expectedKind: Control.Kind, expectedCode: UInt8?, onUpdate: @escaping (LearnUpdate) -> Void) {
        let svc = service
        queue.async {
            self.expectedCode = expectedCode
            // Build the baseline now (the slow sweep) against the monitor's
            // current state, so changes during this window are detected cleanly.
            // Deferring it to here keeps the wizard's first step fast.
            self.baseline = [:]
            for code in self.probeCodes {
                if let reply = AppleSiliconDDC.read(service: svc, command: code, numOfWriteCycles: 1) {
                    self.baseline[code] = Int(reply.current)
                    self.maxValue[code] = reply.max
                }
            }
            self.changeCount = [:]
            self.lastSeen = self.baseline
            self.observed = [:]
            self.expectedKind = expectedKind
            self.resolved = false
            self.onUpdate = onUpdate
            self.counting = true
        }
    }

    /// Stop watching (e.g. when the user Skips or moves to an auto-detected step).
    func endLearning() {
        queue.async {
            self.counting = false
            self.onUpdate = nil
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.counting = false
            self.onUpdate = nil
        }
    }

    /// Every code that changed at all this learning window, most-changed first,
    /// with its discovered values and current reading. For the manual "pick from
    /// changes" escape hatch when auto-resolution can't separate a preset from the
    /// controls it drags along.
    func candidates(completion: @escaping ([(code: UInt8, changes: Int, values: [Int], current: Int, capsDiscrete: Bool)]) -> Void) {
        queue.async {
            let list = self.changeCount
                .filter { $0.value > 0 }
                .sorted { $0.value > $1.value }
                .map { (code: $0.key,
                        changes: $0.value,
                        values: Set(self.capabilities[$0.key] ?? []).union(self.observed[$0.key] ?? []).sorted(),
                        current: self.lastSeen[$0.key] ?? self.baseline[$0.key] ?? 0,
                        capsDiscrete: !(self.capabilities[$0.key]?.isEmpty ?? true)) }
            DispatchQueue.main.async { completion(list) }
        }
    }

    /// Controls from known profiles that this monitor's capabilities confirm, so
    /// the wizard can auto-fill them. Safe to call after prepare().
    func confirmedControls(from configs: [MonitorConfig], completion: @escaping ([Control]) -> Void) {
        queue.async {
            let result = KnownProfileMatcher.confirmedControls(from: configs, capabilities: self.capabilities)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The known profile this monitor distinctively matches, if any. Safe after prepare().
    func recognizedProfile(from configs: [MonitorConfig], completion: @escaping (MonitorConfig?) -> Void) {
        queue.async {
            let result = KnownProfileMatcher.recognizedProfile(from: configs, capabilities: self.capabilities)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Write a value to a feature so the user can test a just-detected control.
    /// The wizard's templates never use packed/multiplexed registers, so a plain
    /// write is enough.
    func write(code: UInt8, value: UInt16) {
        let svc = service
        queue.async { _ = AppleSiliconDDC.write(service: svc, command: code, value: value) }
    }

    // MARK: - Polling (runs on `queue`)

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        guard counting, !resolved else { return }

        for code in baseline.keys {
            guard let reply = AppleSiliconDDC.read(service: service, command: code, numOfWriteCycles: 1) else { continue }
            let value = Int(reply.current)
            if let previous = lastSeen[code], previous != value {
                changeCount[code, default: 0] += 1
                // Record both sides of the transition so a cycle's full set of
                // discrete values (e.g. every color mode) is captured as the user
                // steps through them.
                observed[code, default: []].insert(previous)
                observed[code, default: []].insert(value)
            }
            lastSeen[code] = value
        }

        let callback = onUpdate
        if let code = resolveCode() {
            resolved = true
            counting = false
            let max = maxValue[code] ?? 0
            let current = lastSeen[code] ?? baseline[code] ?? 0
            baseline[code] = current   // so the next control starts fresh
            let values = Set(capabilities[code] ?? []).union(observed[code] ?? []).sorted()
            let capsDiscrete = !(capabilities[code]?.isEmpty ?? true)
            DispatchQueue.main.async { callback?(.learned(code: code, max: max, current: current, values: values, capsDiscrete: capsDiscrete)) }
        } else {
            let top = changeCount.max { $0.value < $1.value }
            let leader = (top?.value ?? 0) > 0 ? top?.key : nil
            DispatchQueue.main.async { callback?(.detecting(leader: leader, count: top?.value ?? 0)) }
        }
    }

    /// Decide which code is the control, or nil to keep watching.
    private func resolveCode() -> UInt8? {
        // Strong prior: a known profile says this control lives on a specific code.
        // If that exact code is clearly responding, trust it — this disambiguates
        // a coupled side-effect (e.g. colour temp) that changes in lockstep with
        // the preset. Safe because a monitor using a different code wouldn't be
        // moving this one.
        if let code = expectedCode, (changeCount[code] ?? 0) >= requiredChanges { return code }

        let candidates = changeCount.filter { $0.value >= requiredChanges }
        guard !candidates.isEmpty else { return nil }

        if expectedKind == .cycle { return resolveCycle(Array(candidates.keys)) }

        // Ranges/toggles: require a clear leader so a code that merely co-moves
        // doesn't win.
        let ranked = candidates.sorted { $0.value > $1.value }
        let runnerUp = ranked.dropFirst().first?.value ?? 0
        return ranked.first!.value >= runnerUp + leadMargin ? ranked.first!.key : nil
    }

    /// Cycles are the hard case: changing a preset (notably Color Mode) perturbs
    /// other codes too, and ambient/auto features (auto-brightness, light sensor)
    /// drift on their own — especially with a hand near the panel. The code the
    /// user is actually driving is the one that changes the MOST, so rank by
    /// change-count and require a clear margin; restrict to codes the caps marks
    /// discrete and whose observed values genuinely belong to that code, so a
    /// drifting sensor still has to out-change the thing being toggled.
    private func resolveCycle(_ candidates: [UInt8]) -> UInt8? {
        // Discrete codes whose observed values are all legitimate members of their
        // advertised set (rejects codes changing for unrelated reasons).
        let discrete = candidates.filter { code in
            guard let caps = capabilities[code], !caps.isEmpty else { return false }
            let set = Set(caps)
            let seen = observed[code] ?? []
            return !seen.isEmpty && seen.allSatisfy(set.contains)
        }

        if !discrete.isEmpty {
            let ranked = discrete.sorted { (changeCount[$0] ?? 0) > (changeCount[$1] ?? 0) }
            if discrete.count == 1 { return ranked[0] }
            let topCount = changeCount[ranked[0]] ?? 0
            let secondCount = changeCount[ranked[1]] ?? 0
            return topCount >= secondCount + leadMargin ? ranked[0] : nil
        }

        // No discrete candidate (e.g. Moon Halo, listed bare) → the code that
        // changes the most, with a margin.
        let ranked = candidates.sorted { (changeCount[$0] ?? 0) > (changeCount[$1] ?? 0) }
        guard let top = ranked.first else { return nil }
        let topCount = changeCount[top] ?? 0
        let secondCount = ranked.dropFirst().first.map { changeCount[$0] ?? 0 } ?? 0
        return topCount >= secondCount + leadMargin ? top : nil
    }
}
