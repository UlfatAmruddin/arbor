import Darwin
import Foundation

/// Memory and CPU figures for the current process (spec §15.3, FE-252).
///
/// The gate metric is **physical footprint** (`phys_footprint`): the number Activity Monitor shows as
/// "Memory" and `footprint(1)` reports. It counts dirty and compressed pages the process owns and
/// leaves out clean, shared and purgeable memory, so it does not double-count system frameworks.
/// Resident size is reported for context only.
public struct ProcessMetrics: Equatable, Sendable {
    /// Physical footprint in bytes.
    public var footprint: UInt64
    /// Lifetime peak of the physical footprint in bytes.
    public var peakFootprint: UInt64
    /// Resident set size in bytes (includes shared framework pages; not a gate).
    public var resident: UInt64
    /// User + system CPU time consumed so far, in seconds.
    public var cpuSeconds: Double

    public static func current() -> ProcessMetrics {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        guard result == KERN_SUCCESS else {
            return ProcessMetrics(footprint: 0, peakFootprint: 0, resident: 0, cpuSeconds: cpu)
        }
        return ProcessMetrics(footprint: info.phys_footprint, peakFootprint: UInt64(max(0, info.ledger_phys_footprint_peak)),
                              resident: info.resident_size, cpuSeconds: cpu)
    }

    /// Seconds since this process started (from the kernel's process start time).
    public static func secondsSinceLaunch() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - started
    }

    public static func megabytes(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
}
