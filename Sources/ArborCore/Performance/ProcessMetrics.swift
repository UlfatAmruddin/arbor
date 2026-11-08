import Darwin
import Foundation

/// Process memory and CPU (spec §15.3, FE-252). The gate metric is `phys_footprint` (Activity Monitor's
/// "Memory"), which excludes shared framework pages; resident size is context only.
public struct ProcessMetrics: Equatable, Sendable {
    public var footprint: UInt64
    /// Lifetime peak footprint.
    public var peakFootprint: UInt64
    /// Includes shared framework pages; not a gate.
    public var resident: UInt64
    /// User + system CPU time.
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

    /// From the kernel's process start time.
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
