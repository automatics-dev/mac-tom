import CoreAudio
import Darwin
import Foundation

/// Reports which application PIDs are actively capturing audio input, using
/// the public CoreAudio HAL (`kAudioHardwarePropertyProcessObjectList`).
/// Available on macOS 14+; older systems return an empty set so callers fall
/// back to title-only matching.
///
/// Browsers (Chrome/Safari/Brave/Edge) capture audio in a helper child
/// process, so the returned set includes every direct + ancestor PID of any
/// capturing process. Callers can probe by main-app PID without caring about
/// helper-process attribution.
enum ProcessAudioMonitor {
    static func appsCapturingInput() -> Set<pid_t> {
        guard #available(macOS 14.0, *) else {
            logOnce("macos<14, returning empty")
            return []
        }
        let direct = capturingInputProcessPIDs()
        if direct.isEmpty {
            logOnce("no direct capturing pids reported by HAL")
            return []
        }
        var expanded = direct
        for pid in direct {
            var current = pid
            var hops = 0
            while hops < 16 {
                guard let parent = parentPID(of: current), parent > 1, parent != current else { break }
                expanded.insert(parent)
                current = parent
                hops += 1
            }
        }
        let directSnapshot = direct.sorted().map(String.init).joined(separator: ",")
        let expandedSnapshot = expanded.sorted().map(String.init).joined(separator: ",")
        logOnce("direct=[\(directSnapshot)] expanded=[\(expandedSnapshot)]")
        return expanded
    }

    private static var loggedSnapshots: Set<String> = []
    private static let logQueue = DispatchQueue(label: "tom.process-audio-monitor.log")
    private static func logOnce(_ message: String) {
        logQueue.sync {
            if !loggedSnapshots.contains(message) {
                loggedSnapshots.insert(message)
                tomLog("ProcessAudioMonitor \(message)")
            }
        }
    }

    @available(macOS 14.0, *)
    private static func capturingInputProcessPIDs() -> Set<pid_t> {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &listAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &listAddress, 0, nil, &dataSize, &processObjects) == noErr else {
            return []
        }
        var capturing: Set<pid_t> = []
        for object in processObjects where isRunningInput(object) {
            if let pid = pid(for: object) {
                capturing.insert(pid)
            }
        }
        return capturing
    }

    @available(macOS 14.0, *)
    private static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    @available(macOS 14.0, *)
    private static func pid(for object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &processID) == noErr else {
            return nil
        }
        return processID > 0 ? processID : nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
