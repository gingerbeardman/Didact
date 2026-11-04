
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Didact

struct MediaKeyTests {

    private func data1(_ key: MediaKey, state: Int, repeatKey: Bool = false) -> Int {
        (key.rawValue << 16) | (state << 8) | (repeatKey ? 1 : 0)
    }

    @Test func parsesBrightnessKeyDown() {
        let event = MediaKeyParser.parse(subtype: 8, data1: data1(.brightnessUp, state: 0xA), modifiers: [])
        #expect(event?.key == .brightnessUp)
        #expect(event?.isDown == true)
        #expect(event?.isUp == false)
        #expect(event?.isRepeat == false)
    }

    @Test func parsesKeyUpAndRepeat() {
        let up = MediaKeyParser.parse(subtype: 8, data1: data1(.volumeDown, state: 0xB), modifiers: [])
        #expect(up?.isDown == false)
        #expect(up?.isUp == true)

        let repeatEvent = MediaKeyParser.parse(subtype: 8, data1: data1(.mute, state: 0xA, repeatKey: true), modifiers: [])
        #expect(repeatEvent?.isDown == true)
        #expect(repeatEvent?.isRepeat == true)
    }

    @Test func rejectsUnknownKeysAndSubtypes() {
        #expect(MediaKeyParser.parse(subtype: 8, data1: (99 << 16) | (0xA << 8), modifiers: []) == nil)
        #expect(MediaKeyParser.parse(subtype: 9, data1: data1(.brightnessUp, state: 0xA), modifiers: []) == nil)
        #expect(MediaKeyParser.parse(subtype: 8, data1: (2 << 16) | (0x1 << 8), modifiers: []) == nil)
    }

    private func range(_ code: UInt8, min: Int = 0, max: Int = 100, step: Int? = nil) -> Control {
        Control(kind: .range, label: "Control", vcp: HexValue(Int(code)),
                min: min, max: max, step: step)
    }

    private func toggle(_ code: UInt8, on: Int = 1, off: Int = 2) -> Control {
        Control(kind: .toggle, label: "Mute", vcp: HexValue(Int(code)),
                onValue: HexValue(on), offValue: HexValue(off))
    }

    @Test func infersStandardRolesByFeatureCode() {
        #expect(range(0x10).role == .brightness)
        #expect(range(0x62).role == .volume)
        #expect(toggle(0x8D).role == .mute)
        #expect(range(0xD9).role == nil)
        #expect(range(0x12).role == nil)
    }

    @Test func picksTheStandardBrightnessNotAMoonHaloSibling() throws {
        let json = """
        {
          "schemaVersion": 1, "name": "Fake RD", "match": ["RD"],
          "controls": [
            { "kind": "range", "label": "Moon Halo Brightness", "vcp": "d9", "byte": "low", "min": 1, "max": 10 },
            { "kind": "range", "label": "Brightness", "vcp": "10", "min": 0, "max": 100 },
            { "kind": "range", "label": "Volume", "vcp": "62", "min": 0, "max": 50 }
          ]
        }
        """
        let config = try JSONDecoder().decode(MonitorConfig.self, from: Data(json.utf8))
        #expect(config.control(forRole: .brightness)?.featureCode == 0x10)
        #expect(config.control(forRole: .volume)?.featureCode == 0x62)
        #expect(config.control(forRole: .mute) == nil)
    }

    @Test func keyStepIsOneSixteenthExceptWhereProfileStepIsCoarser() {
        #expect(range(0x10, min: 0, max: 100).keyStep == 6)
        #expect(range(0x62, min: 0, max: 50).keyStep == 3)
        #expect(range(0x87, min: 1, max: 10).keyStep == 1)
        #expect(range(0x10, min: 0, max: 100, step: 5).keyStep == 6)
        #expect(range(0x10, min: 0, max: 100, step: 10).keyStep == 10)
    }

    private func roleState(_ control: Control,
                           visible: Bool = true,
                           enabled: Bool = true,
                           hasValue: Bool = true,
                           isOn: Bool = false) -> MediaKeyRoleState {
        MediaKeyRoleState(control: control, isVisible: visible,
                          isEnabled: enabled, hasValue: hasValue, isOn: isOn)
    }

    private func display(id: CGDirectDisplayID = 1,
                         bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
                         name: String = "BenQ EW270Q",
                         brightness: MediaKeyRoleState? = nil,
                         volume: MediaKeyRoleState? = nil,
                         mute: MediaKeyRoleState? = nil) -> MediaKeyDisplayState {
        MediaKeyDisplayState(
            displayID: id, bounds: bounds, productName: name,
            brightness: brightness ?? roleState(range(0x10)),
            volume: volume ?? roleState(range(0x62, min: 0, max: 50)),
            mute: mute ?? roleState(toggle(0x8D)))
    }

    private func audio(matched: CGDirectDisplayID? = nil, native: Bool = false) -> MediaKeyAudioState {
        MediaKeyAudioState(name: matched == nil ? nil : "BenQ EW270Q",
                           hasNativeVolume: native, matchedDisplayID: matched)
    }

    private func makeRouter(displays: [MediaKeyDisplayState],
                            audio: MediaKeyAudioState = MediaKeyAudioState(name: nil, hasNativeVolume: false,
                                                                           matchedDisplayID: nil),
                            settings: MediaKeySettings = MediaKeySettings(
                                masterEnabled: true,
                                brightnessEnabled: true,
                                audioEnabled: true),
                            permission: Bool = true,
                            suspended: Bool = false) -> MediaKeyRouter {
        let router = MediaKeyRouter()
        router.update(displays: displays, audio: audio, settings: settings,
                      permissionGranted: permission, suspended: suspended)
        return router
    }

    private func event(_ key: MediaKey, modifiers: NSEvent.ModifierFlags = []) -> MediaKeyEvent {
        MediaKeyEvent(key: key, isDown: true, isRepeat: false, isUp: false, modifiers: modifiers)
    }

    private func upEvent(_ key: MediaKey) -> MediaKeyEvent {
        MediaKeyEvent(key: key, isDown: false, isRepeat: false, isUp: true, modifiers: [])
    }

    @Test func brightnessRoutesToThePointerDisplay() {
        let router = makeRouter(displays: [display()])
        let action = router.route(event(.brightnessUp), pointer: CGPoint(x: 50, y: 50))
        #expect(action?.displayID == 1)
        #expect(action?.role == .brightness)
        #expect(action?.direction == 1)
    }

    @Test func brightnessPassesWhenPointerIsElsewhereOrValueIsUnknown() {
        let router = makeRouter(displays: [display()])
        #expect(router.route(event(.brightnessUp), pointer: CGPoint(x: 500, y: 500)) == nil)

        let unknown = makeRouter(displays: [display(brightness: roleState(range(0x10), hasValue: false))])
        #expect(unknown.route(event(.brightnessUp), pointer: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func modifiersPassThrough() {
        let router = makeRouter(displays: [display()])
        #expect(router.route(event(.brightnessUp, modifiers: .command), pointer: CGPoint(x: 50, y: 50)) == nil)
        #expect(router.route(event(.brightnessUp, modifiers: .option), pointer: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func functionAndCapsLockDoNotBlock() {
        let router = makeRouter(displays: [display()])
        #expect(router.route(event(.brightnessUp, modifiers: .function), pointer: CGPoint(x: 50, y: 50)) != nil)
        #expect(router.route(event(.brightnessUp, modifiers: .capsLock), pointer: CGPoint(x: 50, y: 50)) != nil)
    }

    @Test func keyUpIsNeverRouted() {
        let router = makeRouter(displays: [display()])
        #expect(router.route(upEvent(.brightnessUp), pointer: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func hiddenAndDisabledRolesPassThrough() {
        let hidden = makeRouter(displays: [
            display(brightness: roleState(range(0x10), visible: false)),
        ])
        #expect(hidden.route(event(.brightnessUp), pointer: CGPoint(x: 50, y: 50)) == nil)

        let disabled = makeRouter(displays: [
            display(brightness: roleState(range(0x10), enabled: false)),
        ])
        #expect(disabled.route(event(.brightnessUp), pointer: CGPoint(x: 50, y: 50)) == nil)

        let hiddenVolume = makeRouter(displays: [
            display(volume: roleState(range(0x62), visible: false)),
        ])
        #expect(hiddenVolume.route(event(.volumeUp), pointer: CGPoint(x: 50, y: 50)) == nil)

        let hiddenMute = makeRouter(displays: [
            display(mute: roleState(toggle(0x8D), visible: false)),
        ])
        #expect(hiddenMute.route(event(.mute), pointer: CGPoint(x: 50, y: 50)) == nil)

        let disabledMute = makeRouter(displays: [
            display(mute: roleState(toggle(0x8D), enabled: false)),
        ])
        #expect(disabledMute.route(event(.mute), pointer: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func volumeUsesAudioMatchedDisplayBeforeThePointer() {
        let displays = [
            display(id: 1, name: "Pointer Monitor"),
            display(id: 2, bounds: CGRect(x: 200, y: 0, width: 100, height: 100), name: "BenQ EW270Q"),
        ]
        let router = makeRouter(displays: displays, audio: audio(matched: 2))
        let action = router.route(event(.volumeDown), pointer: CGPoint(x: 50, y: 50))
        #expect(action?.displayID == 2)
        #expect(action?.role == .volume)
        #expect(action?.direction == -1)
    }

    @Test func volumePassesWhenTheDefaultOutputHasNativeVolume() {
        let router = makeRouter(displays: [display()], audio: audio(matched: 1, native: true))
        #expect(router.route(event(.volumeUp), pointer: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func volumeFallsBackToThePointerWhenAudioHasNoMatch() {
        let router = makeRouter(displays: [display()])
        let action = router.route(event(.volumeUp), pointer: CGPoint(x: 50, y: 50))
        #expect(action?.displayID == 1)
        #expect(action?.role == .volume)
    }

    @Test func volumeDoesNotFallBackWhenTheMatchedDisplayIsUnready() {
        let displays = [
            display(id: 1),
            display(id: 2, name: "BenQ EW270Q",
                    volume: roleState(range(0x62, min: 0, max: 50), hasValue: false)),
        ]
        let router = makeRouter(displays: displays, audio: audio(matched: 2))
        #expect(router.route(event(.volumeUp), pointer: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func volumeIsAllowedWhileDisabledOnlyBecauseMuteIsOn() {
        let muted = makeRouter(displays: [
            display(volume: roleState(range(0x62, min: 0, max: 50), enabled: false),
                    mute: roleState(toggle(0x8D), isOn: true)),
        ])
        #expect(muted.route(event(.volumeUp), pointer: CGPoint(x: 50, y: 50)) != nil)

        let disabled = makeRouter(displays: [
            display(volume: roleState(range(0x62, min: 0, max: 50), enabled: false),
                    mute: roleState(toggle(0x8D), isOn: false)),
        ])
        #expect(disabled.route(event(.volumeUp), pointer: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func muteDoesNotFallBackWhenTheMatchedDisplayIsUnready() {
        let displays = [
            display(id: 1),
            display(id: 2, name: "BenQ EW270Q",
                    mute: roleState(toggle(0x8D), hasValue: false)),
        ]
        let router = makeRouter(displays: displays, audio: audio(matched: 2))
        #expect(router.route(event(.mute), pointer: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func muteRoutesWhenAMuteControlExists() {
        let router = makeRouter(displays: [display()])
        let action = router.route(event(.mute), pointer: CGPoint(x: 50, y: 50))
        #expect(action?.displayID == 1)
        #expect(action?.role == .mute)
        #expect(action?.direction == 0)
    }

    @Test func audioNameMatchingNormalizesTransportSuffixes() {
        let states = [display(id: 7, name: "BenQ EW270Q")]
        #expect(MediaKeyRouter.matchDisplayID(for: "BenQ EW270Q (USB-C)", in: states) == 7)
        #expect(MediaKeyRouter.matchDisplayID(for: "External Headphones", in: states) == nil)
    }

    @Test func displayLookupUsesDisplayBounds() {
        let states = [
            display(id: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
            display(id: 2, bounds: CGRect(x: 100, y: 0, width: 100, height: 100)),
        ]
        #expect(MediaKeyRouter.display(at: CGPoint(x: 150, y: 50), in: states)?.displayID == 2)
        #expect(MediaKeyRouter.display(at: CGPoint(x: 250, y: 50), in: states) == nil)
    }

    @Test func masterOffPassesEveryKey() {
        let router = makeRouter(
            displays: [display()],
            settings: MediaKeySettings(masterEnabled: false))
        #expect(router.route(event(.brightnessUp), pointer: CGPoint(x: 50, y: 50)) == nil)
        #expect(router.route(event(.volumeUp), pointer: CGPoint(x: 50, y: 50)) == nil)
        #expect(router.route(event(.mute), pointer: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func brightnessOffStillRoutesAudio() {
        let router = makeRouter(
            displays: [display()],
            settings: MediaKeySettings(masterEnabled: true, brightnessEnabled: false))
        #expect(router.route(event(.brightnessUp), pointer: CGPoint(x: 50, y: 50)) == nil)
        #expect(router.route(event(.volumeDown), pointer: CGPoint(x: 50, y: 50)) != nil)
        #expect(router.route(event(.mute), pointer: CGPoint(x: 50, y: 50)) != nil)
    }

    @Test func audioOffStillRoutesBrightness() {
        let router = makeRouter(
            displays: [display()],
            settings: MediaKeySettings(masterEnabled: true, audioEnabled: false))
        #expect(router.route(event(.brightnessDown), pointer: CGPoint(x: 50, y: 50)) != nil)
        #expect(router.route(event(.volumeUp), pointer: CGPoint(x: 50, y: 50)) == nil)
        #expect(router.route(event(.mute), pointer: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test func bothRolesOffMeansTheFeatureIsInactive() {
        let settings = MediaKeySettings(masterEnabled: true,
                                        brightnessEnabled: false,
                                        audioEnabled: false)
        #expect(!settings.isActive)
        let normalized = settings.normalized
        #expect(!normalized.masterEnabled)
    }

    @Test func settingsDefaultToMasterOffWithBothRolesOn() {
        let name = "DidactTests.MediaKeySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = MediaKeySettingsStore.load(from: defaults)
        #expect(!settings.masterEnabled)
        #expect(settings.brightnessEnabled)
        #expect(settings.audioEnabled)
        #expect(!settings.isActive)
    }

    @Test func settingsPersistExplicitRoleChoices() {
        let name = "DidactTests.MediaKeySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        MediaKeySettingsStore.save(
            MediaKeySettings(masterEnabled: true,
                             brightnessEnabled: false,
                             audioEnabled: true),
            to: defaults)
        let loaded = MediaKeySettingsStore.load(from: defaults)
        #expect(loaded.masterEnabled)
        #expect(!loaded.brightnessEnabled)
        #expect(loaded.audioEnabled)
        #expect(loaded.isActive)
    }

    @Test func savingBothRolesOffAlsoClearsMaster() {
        let name = "DidactTests.MediaKeySettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let saved = MediaKeySettingsStore.save(
            MediaKeySettings(masterEnabled: true,
                             brightnessEnabled: false,
                             audioEnabled: false),
            to: defaults)
        #expect(!saved.masterEnabled)
        #expect(!MediaKeySettingsStore.load(from: defaults).masterEnabled)
    }

    @Test func coalescerWritesFirstAndLatestOnly() {
        let coalescer = KeyWriteCoalescer()
        #expect(coalescer.submit(key: "brightness", value: 10) == 10)
        #expect(coalescer.submit(key: "brightness", value: 20) == nil)
        #expect(coalescer.submit(key: "brightness", value: 30) == nil)
        #expect(coalescer.complete(key: "brightness") == 30)
        #expect(coalescer.complete(key: "brightness") == nil)
    }

    @Test func coalescerCancelDropsOnlyThePendingValue() {
        let coalescer = KeyWriteCoalescer()
        #expect(coalescer.submit(key: "volume", value: 5) == 5)
        #expect(coalescer.submit(key: "volume", value: 6) == nil)
        coalescer.cancel(key: "volume")
        #expect(coalescer.complete(key: "volume") == nil)
    }

    @Test func coalescerRearmsAfterACompletedWrite() {
        let coalescer = KeyWriteCoalescer()
        #expect(coalescer.submit(key: "brightness", value: 10) == 10)
        #expect(coalescer.complete(key: "brightness") == nil)
        #expect(coalescer.submit(key: "brightness", value: 16) == 16)
        #expect(coalescer.complete(key: "brightness") == nil)
    }
}
