
import AudioToolbox
import CoreAudio
import Foundation

struct DefaultAudioOutputState {
    let name: String?
    let hasNativeVolume: Bool
}

enum DefaultAudioOutput {
    static func current() -> DefaultAudioOutputState {
        guard let deviceID = defaultOutputDeviceID() else {
            return DefaultAudioOutputState(name: nil, hasNativeVolume: false)
        }
        return DefaultAudioOutputState(name: deviceName(deviceID),
                                       hasNativeVolume: hasSettableVolume(deviceID))
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func hasSettableVolume(_ deviceID: AudioDeviceID) -> Bool {
        if isSettable(deviceID, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume) {
            return true
        }
        if isSettable(deviceID, selector: kAudioDevicePropertyVolumeScalar) {
            return true
        }
        for channel in 1...2 where isSettable(deviceID,
                                               selector: kAudioDevicePropertyVolumeScalar,
                                               element: UInt32(channel)) {
            return true
        }
        return false
    }

    private static func isSettable(_ deviceID: AudioDeviceID,
                                   selector: AudioObjectPropertySelector,
                                   element: UInt32 = kAudioObjectPropertyElementMain) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else {
            return false
        }
        return settable.boolValue
    }
}

final class DefaultAudioOutputMonitor {
    private var listener: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start(onChange: @escaping () -> Void) {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { onChange() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        if status == noErr { listener = block }
    }

    func stop() {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
        self.listener = nil
    }
}
