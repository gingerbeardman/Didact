
import AppKit
import CoreGraphics
import Foundation

struct MediaKeyRoleState {
    let control: Control
    let isVisible: Bool
    let isEnabled: Bool
    let hasValue: Bool
    let isOn: Bool
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
    let direction: Int
}

final class MediaKeyRouter {
    private let lock = NSLock()
    private var displays: [MediaKeyDisplayState] = []
    private var audio = MediaKeyAudioState(name: nil, hasNativeVolume: false, matchedDisplayID: nil)
    private var settings = MediaKeySettings()
    private var permissionGranted = false
    private var suspended = false

    var onAction: ((MediaKeyAction) -> Void)?

    func update(displays: [MediaKeyDisplayState],
                audio: MediaKeyAudioState,
                settings: MediaKeySettings,
                permissionGranted: Bool,
                suspended: Bool) {
        lock.lock()
        self.displays = displays
        self.audio = audio
        self.settings = settings
        self.permissionGranted = permissionGranted
        self.suspended = suspended
        lock.unlock()
    }

    func handle(_ event: MediaKeyEvent, pointer: CGPoint?) -> Bool {
        guard let action = route(event, pointer: pointer) else { return false }
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
        return true
    }

    func route(_ event: MediaKeyEvent, pointer: CGPoint?) -> MediaKeyAction? {
        lock.lock()
        defer { lock.unlock() }

        guard settings.isActive, permissionGranted, !suspended, event.isDown else { return nil }
        let modifiers = event.modifiers.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return nil }

        switch event.key {
        case .brightnessUp, .brightnessDown:
            guard settings.brightnessEnabled,
                  let point = pointer,
                  let display = Self.display(at: point, in: displays),
                  Self.valid(display.brightness, requireEnabled: true) else { return nil }
            return MediaKeyAction(displayID: display.displayID, role: .brightness,
                                  direction: event.key == .brightnessUp ? 1 : -1)

        case .volumeUp, .volumeDown:
            guard settings.audioEnabled, !audio.hasNativeVolume,
                  let displayID = volumeTarget(pointer: pointer),
                  let display = displays.first(where: { $0.displayID == displayID }) else { return nil }
            return MediaKeyAction(displayID: display.displayID, role: .volume,
                                  direction: event.key == .volumeUp ? 1 : -1)

        case .mute:
            guard settings.audioEnabled, !audio.hasNativeVolume,
                  let displayID = muteTarget(pointer: pointer),
                  let display = displays.first(where: { $0.displayID == displayID }) else { return nil }
            return MediaKeyAction(displayID: display.displayID, role: .mute, direction: 0)
        }
    }

    private func volumeTarget(pointer: CGPoint?) -> CGDirectDisplayID? {
        if let matched = audio.matchedDisplayID {
            guard let display = displays.first(where: { $0.displayID == matched }),
                  Self.validVolume(display.volume, mute: display.mute) else { return nil }
            return display.displayID
        }
        guard let point = pointer,
              let display = Self.display(at: point, in: displays),
              Self.validVolume(display.volume, mute: display.mute) else { return nil }
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

    private static func validVolume(_ volume: MediaKeyRoleState?,
                                    mute: MediaKeyRoleState?) -> Bool {
        guard let volume, volume.isVisible, volume.hasValue else { return false }
        if volume.isEnabled { return true }
        guard let mute, mute.isVisible, mute.isEnabled, mute.hasValue else { return false }
        return mute.isOn
    }

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

    static func normalizedName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
