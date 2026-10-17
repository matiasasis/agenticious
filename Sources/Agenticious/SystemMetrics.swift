import Darwin
import Foundation

struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func utilization(since previous: CPUTicks) -> Double? {
        let busy = Double(user &- previous.user) + Double(system &- previous.system) + Double(nice &- previous.nice)
        let total = busy + Double(idle &- previous.idle)
        return total > 0 ? busy / total : nil
    }
}

struct SystemMetrics {
    var cpu: Double?
    var cpuUnavailable = false
    var memoryUsed: UInt64?
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var pressure: Int?
    var diskFree: Int64?
    var diskTotal: Int64?

    var memoryFraction: Double? {
        guard let memoryUsed, memoryTotal > 0 else { return nil }
        return min(1, Double(memoryUsed) / Double(memoryTotal))
    }

    var diskFraction: Double? {
        guard let diskFree, let diskTotal, diskTotal > 0 else { return nil }
        return min(1, max(0, 1 - Double(diskFree) / Double(diskTotal)))
    }

    var pressureLabel: String {
        switch pressure {
        case 1: "Normal pressure"
        case 2: "Elevated pressure"
        case 4: "High pressure"
        default: "Pressure unavailable"
        }
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}

actor SystemMetricsReader {
    private var previousCPU: CPUTicks?

    func reset() { previousCPU = nil }

    func read() -> SystemMetrics {
        var result = SystemMetrics()
        let ticks = cpuTicks()
        result.cpuUnavailable = ticks == nil
        if let ticks, let previousCPU { result.cpu = ticks.utilization(since: previousCPU) }
        previousCPU = ticks
        result.memoryUsed = memoryUsed()
        var pressure: Int32 = 0
        var size = MemoryLayout.size(ofValue: pressure)
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 {
            result.pressure = Int(pressure)
        }
        let disk = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        result.diskFree = disk?.volumeAvailableCapacity.map(Int64.init)
        result.diskTotal = disk?.volumeTotalCapacity.map(Int64.init)
        return result
    }

    private func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func memoryUsed() -> UInt64? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let allocated = UInt64(info.active_count) + UInt64(info.inactive_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let reclaimable = UInt64(info.purgeable_count) + UInt64(info.external_page_count)
        return min(ProcessInfo.processInfo.physicalMemory, (allocated - min(allocated, reclaimable)) * UInt64(vm_kernel_page_size))
    }
}

@MainActor
final class SystemMetricsMonitor: ObservableObject {
    @Published private(set) var current = SystemMetrics()
    @Published private(set) var cpuHistory: [Double] = []
    private let reader = SystemMetricsReader()

    init(current: SystemMetrics = SystemMetrics(), cpuHistory: [Double] = []) {
        self.current = current
        self.cpuHistory = cpuHistory
    }

    func sampleWhileVisible() async {
        await reader.reset()
        cpuHistory = []
        while !Task.isCancelled {
            let reading = await reader.read()
            guard !Task.isCancelled else { return }
            current = reading
            if let cpu = reading.cpu { cpuHistory = Array((cpuHistory + [cpu]).suffix(60)) }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
}
