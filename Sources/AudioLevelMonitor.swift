import AppKit
import CoreAudio

/// Live loudness of one app's audio output, captured with a Core Audio process tap (macOS 14.2+).
/// The tap follows the app's audio processes (helpers included), so the level matches what the status item shows.
/// The first tap triggers the system's "record system audio" prompt; if it is denied the level simply stays at zero.
final class AudioLevelMonitor {
    private let queue = DispatchQueue(label: "media-monitor.audio-tap")
    private let lock = NSLock()
    private var peak: Float = 0
    private(set) var callbacks = 0

    private var bundleID: String?
    private var tappedObjects: [AudioObjectID] = []
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?

    /// The app to listen to, or nil to stop listening.
    func follow(bundleID newID: String?) {
        queue.async { [weak self] in
            guard let self, newID != self.bundleID else { return }
            self.bundleID = newID
            self.teardown()
            self.timer?.cancel(); self.timer = nil
            guard newID != nil else { return }
            // Audio processes come and go (a tab starts playing, a helper restarts): re-check every second.
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1)
            t.setEventHandler { [weak self] in self?.retarget() }
            t.resume()
            self.timer = t
        }
    }

    /// Loudest level since the last call, 0...1 on a perceptual (dB) scale.
    func takeLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        let p = peak; peak = 0
        guard p > 0 else { return 0 }
        let db = 20 * log10(p)
        return min(max((db + 48) / 44, 0), 1)
    }

    // MARK: - Tap lifecycle (on `queue`)

    private func retarget() {
        guard let bundleID else { return }
        let objects = Self.processObjects(matching: bundleID)
        guard objects != tappedObjects else { return }
        teardown()
        guard !objects.isEmpty else { debug("\(bundleID): no audio process"); return }
        if start(objects) { tappedObjects = objects } else { teardown() }
    }

    /// Writes the tap's status to audio.txt, so it can be checked without the GUI.
    private func debug(_ text: String) {
        try? (text + "\n").write(to: BridgeFiles.directory.appendingPathComponent("audio.txt"), atomically: true, encoding: .utf8)
    }

    private func start(_ objects: [AudioObjectID]) -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { debug("tap \(objects): \(status)"); return false }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Media Monitor Level",
            kAudioAggregateDeviceUIDKey: "media-monitor-" + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        if let output = Self.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
        guard status == noErr else { debug("aggregate: \(status)"); return false }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, let procID else { debug("ioproc: \(status)"); return false }
        status = AudioDeviceStart(deviceID, procID)
        debug("tap \(objects) start: \(status)")
        return status == noErr
    }

    private func teardown() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedObjects = []
        lock.lock(); peak = 0; lock.unlock()
    }

    /// Realtime audio thread: keep only the running peak (RMS of each buffer).
    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        var sum: Float = 0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<n { sum += samples[i] * samples[i] }
            count += n
        }
        guard count > 0 else { return }
        let rms = (sum / Float(count)).squareRoot()
        lock.lock(); if rms > peak { peak = rms }; callbacks += 1; lock.unlock()
    }

    // MARK: - Core Audio lookups

    /// Audio process objects of the app and its helpers (e.g. com.google.Chrome.helper, com.soda.music.helper).
    private static func processObjects(matching bundleID: String) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &list) == noErr else { return [] }
        return list.filter { object in
            guard let id = string(object, kAudioProcessPropertyBundleID) else { return false }
            return id == bundleID || id.hasPrefix(bundleID + ".")
        }.sorted()
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let s = value.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }
}
