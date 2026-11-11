import CoreAudio
import Foundation

/// Coupe le son du Mac pendant une dictée (musique, vidéo, notifications) et le rétablit ensuite.
/// Seulement si le son n'était pas déjà coupé : on ne rallume jamais ce que l'utilisateur avait éteint.
enum SoundMute {
    private static var mutedByUs: AudioDeviceID?

    static func begin() {
        guard Settings.muteWhileDictating, mutedByUs == nil, let device = outputDevice() else { return }
        guard let muted = mute(of: device), !muted else { return }
        if setMute(true, on: device) { mutedByUs = device }
    }

    static func end() {
        guard let device = mutedByUs else { return }
        mutedByUs = nil
        _ = setMute(false, on: device)
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func outputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var where_ = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func mute(of device: AudioDeviceID) -> Bool? {
        var where_ = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &where_) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMute(_ muted: Bool, on device: AudioDeviceID) -> Bool {
        var where_ = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &where_, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
