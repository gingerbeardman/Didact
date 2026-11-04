//
//  MediaKeyRouter.swift
//  Didact
//
//  Decides whether a media key belongs to a supported monitor and which display
//  it should move. The event tap calls route() on its own thread, so the snapshot
//  is immutable value types behind a lock and contains no AppKit objects. The
//  actual DDC work is dispatched to the main actor by the caller.
//

import AppKit
import CoreGraphics
import Foundation

struct MediaKeyRoleState {
    let control: Control
    let isVisible: Bool
    let isEnabled: Bool
    let hasValue: Bool
}

struct MediaKeyDisplayState {
    let displayID: CGDirectDisplayID
    let bounds: CGRect
    let productName: String
    let brightness: MediaKeyRoleState?
    let volume: MediaKeyRoleState?
    let mute: MediaKeyRoleState?
}

struct MediaKeyAudioState {
    let name: String?
    let hasNativeVolume: Bool
    let matchedDisplayID: CGDirectDisplayID?
}

struct MediaKeyAction {
    let displayID: CGDirectDisplayID
    let role: Control.Role
    let direction: Int // +1 up, -1 down, 0 for mute
}

final class MediaKeyRouter {
    private let lock = NSLock()
    private var displays: [MediaKeyDisplayState] = []
    private var audio = MediaKeyAudioState(name: nil, hasNativeVolume: false, matchedDisplayID: nil)
    private var enabled = false
    private var permissionGranted = false
    private var suspended = false

    /// Called on the main actor after a key has been accepted.
    var onAction: ((MediaKeyAction) -> Void)?

    func update(displays: [MediaKeyDisplayState],
                audio: MediaKeyAudioState,
                enabled: Bool,
                permissionGranted: Bool,
                suspended: Bool) {
        lock.lock()
        self.displays = displays
        self.audio = audio
        self.enabled = enabled
        self.permissionGranted = permissionGranted
        self.suspended = suspended
        lock.unlock()
    }

    /// Returns true when the tap should swallow the event. The action is
    /// dispatched to the main actor; the tap never touches DDC itself.
    func handle(_ event: MediaKeyEvent, pointer: CGPoint?) -> Bool {
        guard let action = route(event, pointer: pointer) else { return false }
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
        return true
    }

    /// Pure routing decision, used directly by tests.
    func route(_ event: MediaKeyEvent, pointer: CGPoint?) -> MediaKeyAction? {
        lock.lock()
        defer { lock.unlock() }

        guard enabled, permissionGranted, !suspended, event.isDown else { return nil }
        let modifiers = event.modifiers.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return nil }

        switch event.key {
        case .brightnessUp, .brightnessDown:
            guard let point = pointer,
                  let display = Self.display(at: point, in: displays),
                  Self.valid(display.brightness, requireEnabled: true) else { return nil }
            return MediaKeyAction(displayID: display.displayID, role: .brightness,
                                  direction: event.key == .brightnessUp ? 1 : -1)

        case .volumeUp, .volumeDown:
            guard !audio.hasNativeVolume,
                  let displayID = volumeTarget(pointer: pointer),
                  let display = displays.first(where: { $0.displayID == displayID }) else { return nil }
            return MediaKeyAction(displayID: display.displayID, role: .volume,
                                  direction: event.key == .volumeUp ? 1 : -1)

        case .mute:
            guard !audio.hasNativeVolume,
                  let displayID = muteTarget(pointer: pointer),
                  let display = displays.first(where: { $0.displayID == displayID }) else { return nil }
            return MediaKeyAction(displayID: display.displayID, role: .mute, direction: 0)
        }
    }

    // MARK: - Target selection

    private func volumeTarget(pointer: CGPoint?) -> CGDirectDisplayID? {
        // When the default output is a known display, never fall back to a
        // different one — adjusting the pointer's monitor would change the wrong
        // speakers. If its value isn't known yet, let the key through instead.
        if let matched = audio.matchedDisplayID {
            guard let display = displays.first(where: { $0.displayID == matched }),
                  Self.valid(display.volume, requireEnabled: false) else { return nil }
            return display.displayID
        }
        guard let point = pointer,
              let display = Self.display(at: point, in: displays),
              Self.valid(display.volume, requireEnabled: false) else { return nil }
        return display.displayID
    }

    private func muteTarget(pointer: CGPoint?) -> CGDirectDisplayID? {
        if let matched = audio.matchedDisplayID {
            guard let display = displays.first(where: { $0.displayID == matched }),
                  Self.valid(display.mute, requireEnabled: true) else { return nil }
            return display.displayID
        }
        guard let point = pointer,
              let display = Self.display(at: point, in: displays),
              Self.valid(display.mute, requireEnabled: true) else { return nil }
        return display.displayID
    }

    private static func valid(_ role: MediaKeyRoleState?, requireEnabled: Bool) -> Bool {
        guard let role, role.isVisible, role.hasValue else { return false }
        return requireEnabled ? role.isEnabled : true
    }

    // MARK: - Pure helpers

    static func display(at point: CGPoint, in displays: [MediaKeyDisplayState]) -> MediaKeyDisplayState? {
        displays.first { $0.bounds.contains(point) }
    }

    static func matchDisplayID(for audioName: String?,
                               in displays: [MediaKeyDisplayState]) -> CGDirectDisplayID? {
        guard let audioName, !audioName.isEmpty else { return nil }
        let target = normalizedName(audioName)
        guard target.count >= 4 else { return nil }
        return displays.first { display in
            let name = normalizedName(display.productName)
            guard name.count >= 4 else { return false }
            return name == target || name.contains(target) || target.contains(name)
        }?.displayID
    }

    /// Lowercase and strip punctuation/spaces so "BenQ EW270Q (USB-C)" matches
    /// "BenQ EW270Q". Digits are kept because model numbers distinguish displays.
    static func normalizedName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
