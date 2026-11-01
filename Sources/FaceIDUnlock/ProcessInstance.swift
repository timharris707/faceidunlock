import Darwin
import Foundation

/// Kernel start time distinguishes process instances even when a PID is reused.
struct ProcessInstance: Equatable {
    typealias InfoReader = (pid_t, inout proc_bsdinfo) -> Int32
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func read(pid: pid_t, readInfo: InfoReader = kernelInfo) throws -> Self {
        guard pid > 0 else { throw ProcessInstanceError.unavailable }
        var info = proc_bsdinfo()
        let bytesRead = readInfo(pid, &info)
        guard bytesRead == Int32(MemoryLayout<proc_bsdinfo>.size),
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0,
              info.pbi_start_tvusec < 1_000_000 else {
            throw ProcessInstanceError.unavailable
        }
        return Self(pid: pid, startSeconds: info.pbi_start_tvsec,
                    startMicroseconds: info.pbi_start_tvusec)
    }

    /// Return inspection results only while the same kernel process still exists.
    static func verifying<Value>(pid: pid_t, readInfo: InfoReader = kernelInfo,
                                 inspect: (Self) throws -> Value) throws -> Value {
        let before = try read(pid: pid, readInfo: readInfo)
        let result = try inspect(before)
        guard try read(pid: pid, readInfo: readInfo) == before else {
            throw ProcessInstanceError.changed
        }
        return result
    }

    static func kernelInfo(pid: pid_t, info: inout proc_bsdinfo) -> Int32 {
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    }
}

enum ProcessInstanceError: LocalizedError {
    case unavailable, changed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Cannot verify the live prompt process."
        case .changed: return "The prompt process changed during verification."
        }
    }
}
