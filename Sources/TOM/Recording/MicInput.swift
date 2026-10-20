import AVFoundation
import Combine
import CoreAudio

/// Audio input devices and the user's choice among them. nil UID = follow
/// the system default input.
enum MicInput {
    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static let selectedUIDKey = "tom.micDeviceUID"

    static var selectedUID: String? {
        get { UserDefaults.standard.string(forKey: selectedUIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: selectedUIDKey) }
    }

    /// Devices with at least one input channel, in system order.
    static func devices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    /// Name of the device recordings will use.
    static func currentDeviceName() -> String {
        let all = devices()
        if let uid = selectedUID, let device = all.first(where: { $0.uid == uid }) { return device.name }
        if let id = defaultInputID(), let device = all.first(where: { $0.id == id }) { return device.name }
        return String(localized: "System default")
    }

    /// Points `engine`'s input at the chosen device and returns the format
    /// to install the tap with. A missing device (unplugged) leaves the
    /// system default in place.
    ///
    /// The tap must use the device's hardware format: after switching
    /// devices the input node's output format still describes the system
    /// default, and a tap in that format (say 16 kHz for a Bluetooth mic
    /// when the built-in one runs at 48 kHz) never receives a buffer.
    static func prepare(_ engine: AVAudioEngine) -> AVAudioFormat {
        if let uid = selectedUID, let device = devices().first(where: { $0.uid == uid }),
           let unit = engine.inputNode.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr { tomLog("MicInput: could not select \(device.name) (status \(status))") }
        }
        return engine.inputNode.inputFormat(forBus: 0)
    }

    /// Whether a recorded file holds any audio. File size can't tell: the
    /// WAV header AVAudioFile writes is 4 KB on its own.
    static func hasSamples(_ url: URL) -> Bool {
        ((try? AVAudioFile(forReading: url))?.length ?? 0) > 0
    }

    /// Peak level of a buffer, 0…1.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[i])) }
        return min(1, peak)
    }

    /// Overwrites a buffer with silence (mute keeps the timeline intact).
    static func silence(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if let data = buffer.floatChannelData {
            for c in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                data[c].update(repeating: 0, count: frames * (buffer.format.isInterleaved ? channels : 1))
            }
        } else if let data = buffer.int16ChannelData {
            for c in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                data[c].update(repeating: 0, count: frames * (buffer.format.isInterleaved ? channels : 1))
            }
        } else if let data = buffer.int32ChannelData {
            for c in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                data[c].update(repeating: 0, count: frames * (buffer.format.isInterleaved ? channels : 1))
            }
        }
    }

    private static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }
}

/// Live input level for the record panel's meter. Runs its own engine only
/// while the panel is open, so the mic indicator isn't on otherwise.
@MainActor
final class MicLevelMonitor: ObservableObject {
    @Published private(set) var level: Float = 0
    private var engine: AVAudioEngine?

    func start() {
        stop()
        let engine = AVAudioEngine()
        let format = MicInput.prepare(engine)
        let input = engine.inputNode
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let peak = MicInput.level(of: buffer)
            Task { @MainActor in
                guard let self else { return }
                // Fast attack, slow release reads better than raw peaks.
                self.level = peak > self.level ? peak : self.level * 0.8 + peak * 0.2
            }
        }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
            tomLog("MicLevelMonitor: could not start (\(error))")
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
    }
}
