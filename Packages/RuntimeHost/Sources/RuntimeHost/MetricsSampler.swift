import Darwin
import DiagnosticsCore
import Foundation
import RuntimeAPI

/// Collects `MetricsSnapshot` figures on demand (diagnostics.md §5, #71).
///
/// There is no background polling: the sampler runs for `perfStatistics`,
/// `apkrun doctor --deep`, and bundle collection. The Virtualization XPC
/// service is found by process name, owner, and a start time after `VM_START`
/// (OQ-06); its footprint comes from `proc_pid_rusage`.
public struct MetricsSampler: Sendable {
    /// Process names tried for the Virtualization XPC service, in order (OQ-06).
    static let vmServiceNames = [
        "Virtual Machine",
        "com.apple.Virtualization.VirtualMachine",
        "com.apple.virtualization.vm",
    ]

    /// Creates a sampler.
    public init() {}

    /// apkrund's own memory and CPU figures, always collectible.
    public func daemonMetrics() -> (
        footprintBytes: Int64, residentBytes: Int64, cpuUserUs: Int64, cpuSystemUs: Int64
    ) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let infoResult = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPointer, &count)
            }
        }
        let footprint = infoResult == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
        let resident = infoResult == KERN_SUCCESS ? Int64(info.resident_size) : 0

        var basic = task_basic_info_64()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<task_basic_info_64>.size / MemoryLayout<integer_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { intPointer in
                task_info(
                    mach_task_self_, task_flavor_t(TASK_BASIC_INFO_64), intPointer, &basicCount)
            }
        }
        var userUs: Int64 = 0
        var systemUs: Int64 = 0
        if basicResult == KERN_SUCCESS {
            userUs =
                Int64(basic.user_time.seconds) * 1_000_000
                + Int64(basic.user_time.microseconds)
            systemUs =
                Int64(basic.system_time.seconds) * 1_000_000
                + Int64(basic.system_time.microseconds)
        }
        return (footprint, resident, userUs, systemUs)
    }

    /// The PID of the Virtualization XPC service that started after `vmStartUptimeNanos`,
    /// verified by name and owner (OQ-06). `nil` when no VM service is running.
    public func findVirtualMachineService(afterUptimeNanos vmStartUptimeNanos: UInt64) -> pid_t? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else {
            return nil
        }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let myUID = getuid()
        for pid in pids.prefix(Int(found)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = proc_pidinfo(
                pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard size == MemoryLayout<proc_bsdinfo>.size,
                info.pbi_uid == myUID
            else {
                continue
            }
            var comm = info.pbi_comm
            let commSize = MemoryLayout.size(ofValue: comm)
            let name = withUnsafePointer(to: &comm) { pointer -> String in
                pointer.withMemoryRebound(to: CChar.self, capacity: commSize) {
                    String(cString: $0)
                }
            }
            guard Self.vmServiceNames.contains(where: { name == $0 || name.hasPrefix($0) }) else {
                continue
            }
            // pbi_start_tvusec/seconds are since the epoch, not uptime; the service must also
            // postdate VM_START. A service started before the boot belongs to an older VM.
            let startedSeconds = TimeInterval(info.pbi_start_tvsec)
            let startedUptime = Self.epochSecondsToUptimeNanoseconds(startedSeconds)
            if startedUptime >= vmStartUptimeNanos || vmStartUptimeNanos == 0 {
                return pid
            }
        }
        return nil
    }

    /// The physical footprint of a process by PID (`proc_pid_rusage`, diagnostics.md §5).
    public func physFootprint(of pid: pid_t) -> Int64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePointer in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePointer)
            }
        }
        guard result == 0 else {
            return nil
        }
        return Int64(usage.ri_phys_footprint)
    }

    /// Converts epoch seconds (`proc_bsdinfo.pbi_start_tvsec`) to an estimated
    /// continuous-clock nanosecond value for comparison against `VM_START`.
    static func epochSecondsToUptimeNanoseconds(_ epochSeconds: TimeInterval) -> UInt64 {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 else {
            return 0
        }
        let processUptimeSeconds =
            epochSeconds - TimeInterval(boottime.tv_sec) - TimeInterval(boottime.tv_usec) / 1_000_000
        guard processUptimeSeconds > 0 else {
            return 0
        }
        return UInt64(processUptimeSeconds * 1_000_000_000)
    }
}
