import CoreAudio
import Foundation
import Observation

/// Snapshot of a CoreAudio device.
struct AudioDeviceInfo: Equatable, Identifiable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let nominalSampleRate: Double
    let inputChannels: Int
    let outputChannels: Int

    var isAt48k: Bool { abs(nominalSampleRate - 48_000) < 0.5 }
}

/// Watches `kAudioHardwarePropertyDevices` and publishes the Nano Cortex USB device
/// (matched by name) as soon as it appears. Tries to switch it to 48 kHz if needed.
@MainActor
@Observable
final class AudioDeviceMonitor {

    static let nanoNameMatch = "nano cortex"

    private(set) var nano: AudioDeviceInfo?
    private(set) var allDevices: [AudioDeviceInfo] = []
    private(set) var lastError: String?

    @ObservationIgnored private var devicesListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var rateListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var rateListenerDevice: AudioDeviceID?

    func start() {
        guard devicesListener == nil else { return }
        var address = Self.address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        devicesListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        refresh()
    }

    func refresh() {
        allDevices = Self.listDevices()
        let found = allDevices.first { $0.name.lowercased().contains(Self.nanoNameMatch) && $0.inputChannels > 0 && $0.outputChannels > 0 }
        if let found, !found.isAt48k {
            if Self.setNominalSampleRate(found.id, 48_000) {
                lastError = nil
            } else {
                lastError = "Could not set the Nano Cortex to 48 kHz (currently \(Int(found.nominalSampleRate)) Hz)."
            }
            nano = Self.info(for: found.id) ?? found
        } else {
            nano = found
        }
        watchSampleRate(of: nano?.id)
    }

    private func watchSampleRate(of device: AudioDeviceID?) {
        if let old = rateListenerDevice, let block = rateListener {
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(old, &address, DispatchQueue.main, block)
            rateListener = nil
            rateListenerDevice = nil
        }
        guard let device else { return }
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, let current = self.nano, current.id == device else { return }
                self.nano = Self.info(for: device) ?? current
            }
        }
        rateListener = block
        rateListenerDevice = device
        AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
    }

    // MARK: - CoreAudio helpers

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func listDevices() -> [AudioDeviceInfo] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { info(for: $0) }
    }

    static func info(for id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let name = string(id, kAudioObjectPropertyName) else { return nil }
        let uid = string(id, kAudioDevicePropertyDeviceUID) ?? ""
        return AudioDeviceInfo(id: id, uid: uid, name: name,
                               nominalSampleRate: nominalSampleRate(id),
                               inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                               outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput))
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return rate
    }

    @discardableResult
    static func setNominalSampleRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = rate
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        return status == noErr
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    @discardableResult
    static func setBufferFrameSize(_ id: AudioDeviceID, _ frames: UInt32) -> Bool {
        var address = Self.address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
