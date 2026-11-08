import ArborCore
import Darwin
import Foundation

/// What keeps an idle app busy (`ARBOR_IDLE_PROFILE=1`, benchmark `idle` step); debug only. Every 10 ms, threads
/// that used CPU get their stack sampled while suspended. Its own CPU is reported apart so idle figures can exclude it.
final class IdleProfiler: @unchecked Sendable {
    static var isRequested: Bool { Automation.environment["ARBOR_IDLE_PROFILE"] == "1" }

    private struct ThreadRecord {
        var name: String
        var isMain: Bool
        var startCPU: Double
        var lastCPU: Double
    }

    private let lock = NSLock()
    private var running = true
    private var records: [UInt64: ThreadRecord] = [:]
    private var stacks: [[UInt]: Int] = [:]
    private var samples = 0
    private var ownCPU: Double = 0
    private let mainThreadID: UInt64
    private var thread: Thread?

    init() {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)   // created on the main thread
        mainThreadID = id
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "arbor.idle-profiler"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stops sampling and returns the report lines, plus the profiler's own CPU seconds.
    func stop() -> (lines: [String], profilerCPU: Double) {
        lock.lock(); running = false; lock.unlock()
        Thread.sleep(forTimeInterval: 0.03)   // let the last tick finish
        lock.lock(); defer { lock.unlock() }
        var lines: [String] = []
        let busy = records.values.map { ($0, ($0.lastCPU - $0.startCPU) * 1000) }.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }
        for (record, ms) in busy {
            let name = record.name.isEmpty ? "(unnamed)" : record.name.replacingOccurrences(of: " ", with: "_")
            lines.append(String(format: "idlethread name=%@ main=%d cpu_ms=%.1f", name, record.isMain ? 1 : 0, ms))
        }
        lines.append(String(format: "idleprofile samples=%d profiler_cpu_ms=%.1f threads_busy=%d", samples, ownCPU * 1000, busy.count))
        for (stack, count) in stacks.sorted(by: { $0.value > $1.value }).prefix(12) {
            let frames = stack.prefix(14).map(Self.symbol).joined(separator: " < ")
            lines.append("idlestack count=\(count) \(frames)")
        }
        return (lines, ownCPU)
    }

    // MARK: Sampling

    private func run() {
        let me = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, me) }
        while true {
            lock.lock(); let keepGoing = running; lock.unlock()
            if !keepGoing { break }
            tick(skipping: me)
            ownCPU = Self.cpuSeconds(me) ?? ownCPU
            usleep(10_000)
        }
    }

    private func tick(skipping me: thread_act_t) {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        lock.lock(); defer { lock.unlock() }
        samples += 1
        for i in 0..<Int(count) {
            let thread = list[i]
            guard thread != me, let cpu = Self.cpuSeconds(thread), let id = Self.threadID(thread) else { continue }
            if var record = records[id] {
                let used = cpu - record.lastCPU
                record.lastCPU = cpu
                records[id] = record
                if used > 0.000_05, let stack = Self.stack(of: thread) { stacks[stack, default: 0] += 1 }
            } else {
                records[id] = ThreadRecord(name: Self.name(of: thread), isMain: id == mainThreadID, startCPU: cpu, lastCPU: cpu)
            }
        }
    }

    // MARK: Mach helpers

    private static func cpuSeconds(_ thread: thread_act_t) -> Double? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let seconds = Double(info.user_time.seconds + info.system_time.seconds)
        return seconds + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }

    private static func threadID(_ thread: thread_act_t) -> UInt64? {
        var info = thread_identifier_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.thread_id : nil
    }

    private static func name(of thread: thread_act_t) -> String {
        guard let pthread = pthread_from_mach_thread_np(thread) else { return "" }
        var buffer = [CChar](repeating: 0, count: 64)
        pthread_getname_np(pthread, &buffer, buffer.count)
        return String(cString: buffer)
    }

    /// Frame-pointer return addresses, innermost first; read while suspended, every frame must lie in the stack.
    private static func stack(of thread: thread_act_t) -> [UInt]? {
        #if arch(arm64)
        guard let pthread = pthread_from_mach_thread_np(thread) else { return nil }
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread))
        let bottom = top &- UInt(pthread_get_stacksize_np(pthread))
        guard thread_suspend(thread) == KERN_SUCCESS else { return nil }
        defer { thread_resume(thread) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let mask: UInt = 0x0000_007F_FFFF_FFFF   // drop pointer-authentication bits
        var frames: [UInt] = [UInt(state.__pc) & mask, UInt(state.__lr) & mask]
        var fp = UInt(state.__fp)
        while frames.count < 48, fp > bottom, fp &+ 16 <= top, fp % 8 == 0 {
            guard let frame = UnsafePointer<UInt>(bitPattern: fp) else { break }
            let next = frame[0], ret = frame[1] & mask
            if ret == 0 { break }
            frames.append(ret)
            if next <= fp { break }
            fp = next
        }
        return frames
        #else
        return nil
        #endif
    }

    private static func symbol(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return String(format: "0x%lx", address) }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        let name = info.dli_sname.map { String(cString: $0) } ?? String(format: "0x%lx", address)
        return "\(image)`\(name)"
    }
}
