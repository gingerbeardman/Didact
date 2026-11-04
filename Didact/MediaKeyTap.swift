//
//  MediaKeyTap.swift
//  Didact
//
//  A session-level CGEventTap for the five system-defined media keys Didact can
//  map to DDC controls. The tap runs on its own run loop and does only parsing and
//  routing; DDC, CoreAudio and AppKit stay on the main actor. Accessibility is
//  required to create an active (not listen-only) tap, so start() fails cleanly
//  when the user has not granted it.
//

import AppKit
import CoreGraphics

final class MediaKeyTap {
    private let handler: (MediaKeyEvent) -> Bool
    private let onDisabled: () -> Void

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var swallowed: Set<Int> = []

    init(handler: @escaping (MediaKeyEvent) -> Bool,
         onDisabled: @escaping () -> Void) {
        self.handler = handler
        self.onDisabled = onDisabled
    }

    deinit { stop() }

    /// Create the tap and start its run loop. Returns false when the tap could not
    /// be created — normally because Accessibility is missing.
    @discardableResult
    func start() -> Bool {
        stop()
        swallowed.removeAll()

        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }

        self.port = port
        self.source = source

        let thread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()
            self.runLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Didact media keys"
        thread.stackSize = 64 * 1024
        self.thread = thread
        thread.start()
        return true
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        if let source { CFRunLoopSourceInvalidate(source) }
        port = nil
        source = nil
        runLoop = nil
        thread = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in self?.onDisabled() }
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event),
              let parsed = MediaKeyParser.parse(nsEvent) else {
            return Unmanaged.passUnretained(event)
        }

        let code = parsed.key.rawValue

        if parsed.isUp {
            // Swallow the release only for a press we took, so a key we passed
            // through stays consistent.
            return swallowed.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
        }

        let alreadySwallowed = swallowed.contains(code)
        let handled = handler(parsed)
        if handled || alreadySwallowed {
            if handled { swallowed.insert(code) }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

private let mediaKeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
