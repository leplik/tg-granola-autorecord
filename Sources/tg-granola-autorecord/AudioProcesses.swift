import AutorecordCore
import CoreAudio
import Darwin

/// Lists processes that CoreAudio tracks, with their microphone and speaker usage.
/// Needs macOS 14.4 or later and no special permission.
enum AudioProcesses {
    /// Only this user's processes: with fast user switching, CoreAudio also lists other sessions.
    static func snapshot() -> [AudioProcessState] {
        processObjectIDs().compactMap { objectID in
            let pid = pid(of: objectID)
            guard isOwnedByCurrentUser(pid: pid) else { return nil }
            return AudioProcessState(
                pid: pid,
                bundleID: bundleID(of: objectID),
                executablePath: executablePath(pid: pid),
                isRunningInput: flag(objectID, kAudioProcessPropertyIsRunningInput),
                isRunningOutput: flag(objectID, kAudioProcessPropertyIsRunningOutput)
            )
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var propertyAddress = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &propertyAddress, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &propertyAddress, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func pid(of objectID: AudioObjectID) -> pid_t {
        var propertyAddress = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func flag(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var propertyAddress = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func bundleID(of objectID: AudioObjectID) -> String? {
        var propertyAddress = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, pointer)
        }
        guard status == noErr, let string = value?.takeRetainedValue() else { return nil }
        let bundleID = string as String
        return bundleID.isEmpty ? nil : bundleID
    }

    private static func isOwnedByCurrentUser(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_eproc.e_ucred.cr_uid == getuid()
    }

    private static func executablePath(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
