import Foundation
import AppKit
import Darwin

struct SystemSnapshot: Equatable {
    var cpuUsage: Double = 0            // 0…1 across all cores
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var swapUsed: UInt64 = 0
    var cpuTemperature: Double?         // °C, Apple Silicon only
    var thermalState: ProcessInfo.ThermalState = .nominal
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0

    var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }

    var thermalText: String {
        switch thermalState {
        case .nominal: return "Kühl"
        case .fair: return "Warm"
        case .serious: return "Heiß"
        case .critical: return "Kritisch"
        @unknown default: return "–"
        }
    }

    var temperatureText: String {
        if let cpuTemperature { return "\(Int(cpuTemperature.rounded()))°" }
        return thermalText
    }
}

/// System-wide stats. Sampling only runs while someone is looking (dashboard open,
/// task manager open, or stats enabled in the menu bar) – otherwise it costs nothing.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var memoryHistory: [Double] = Array(repeating: 0, count: 60)
    @Published private(set) var apps: [ProcessUsage] = []

    private var timer: Timer?
    private var users: [String: Bool] = [:]   // consumer id → needs per-app data
    private let queue = DispatchQueue(label: "com.simplex.suite.monitor", qos: .utility)
    private let sampler = ProcessSampler()
    private var lastTicks: (busy: UInt64, total: UInt64)?

    /// Start sampling for a consumer (e.g. "dashboard"). Call `release` when it disappears.
    func acquire(_ id: String, perApp: Bool) {
        users[id] = perApp
        restartTimer()
        sample()
    }

    func release(_ id: String) {
        users[id] = nil
        restartTimer()
    }

    private var interval: TimeInterval {
        users.isEmpty ? 0 : (users.count == 1 && users["menubar"] != nil ? 4 : 2)
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard !users.isEmpty else { return }
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        t.tolerance = interval * 0.25
        timer = t
    }

    func sample() {
        let wantsApps = users.values.contains(true)
        let showBackground = SuiteSettings.shared.taskManagerShowBackground
        let previous = lastTicks
        let sampler = self.sampler
        queue.async {
            var snap = SystemSnapshot()
            let ticks = Self.cpuTicks()
            if let previous, let ticks, ticks.total > previous.total {
                snap.cpuUsage = Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total)
            }
            let mem = Self.memory()
            snap.memoryUsed = mem.used
            snap.swapUsed = mem.swap
            snap.cpuTemperature = TemperatureSensor.shared.cpuTemperature()
            snap.thermalState = ProcessInfo.processInfo.thermalState
            if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
                snap.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
                snap.diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
            }
            let apps = wantsApps ? sampler.sample(includeBackground: showBackground) : nil
            Task { @MainActor in
                if let ticks { self.lastTicks = ticks }
                self.snapshot = snap
                self.cpuHistory = Array((self.cpuHistory + [snap.cpuUsage]).suffix(60))
                self.memoryHistory = Array((self.memoryHistory + [snap.memoryFraction]).suffix(60))
                if let apps { self.apps = apps }
            }
        }
    }

    // MARK: Mach helpers

    nonisolated private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        return (busy, busy + idle)
    }

    nonisolated private static func memory() -> (used: UInt64, swap: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var used: UInt64 = 0
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            // Like Activity Monitor: app memory + wired + compressed.
            let app = UInt64(stats.internal_page_count) - UInt64(min(stats.purgeable_count, stats.internal_page_count))
            used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return (used, swap.xsu_used)
    }
}

// MARK: - Per-app usage

struct ProcessUsage: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let isApp: Bool
    var cpu: Double          // percent of one core (like Activity Monitor)
    var memory: UInt64       // physical footprint, all processes of the app
    var processCount: Int
    var id: pid_t { pid }

    var icon: NSImage? {
        isApp ? NSRunningApplication(processIdentifier: pid)?.icon : nil
    }
}

/// Collects CPU and memory per app, including all helper processes that live inside the
/// app bundle (e.g. "Google Chrome Helper"). Runs on the monitor's background queue.
final class ProcessSampler {
    private var lastCPU: [pid_t: UInt64] = [:]   // ns
    private var lastTime: UInt64 = 0
    private var pathCache: [pid_t: String] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    func sample(includeBackground: Bool) -> [ProcessUsage] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = lastTime > 0 ? Double(now - lastTime) : 0
        lastTime = now

        // Running GUI apps and their bundle paths.
        let me = ProcessInfo.processInfo.processIdentifier
        let regularApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        var appByPrefix: [(prefix: String, pid: pid_t)] = []
        var usage: [pid_t: ProcessUsage] = [:]
        for app in regularApps {
            guard let path = app.bundleURL?.path else { continue }
            appByPrefix.append((path + "/", app.processIdentifier))
            usage[app.processIdentifier] = ProcessUsage(
                pid: app.processIdentifier,
                name: app.localizedName ?? (path as NSString).lastPathComponent,
                bundleID: app.bundleIdentifier, isApp: true, cpu: 0, memory: 0, processCount: 0)
        }

        var newCPU: [pid_t: UInt64] = [:]
        for pid in Self.allPIDs() where pid > 0 {
            guard let info = Self.rusage(pid) else { continue }
            let cpuNs = (info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom
            newCPU[pid] = cpuNs
            var cpuPercent = 0.0
            if elapsed > 0, let previous = lastCPU[pid], cpuNs >= previous {
                cpuPercent = Double(cpuNs - previous) / elapsed * 100
            }

            let path = pathCache[pid] ?? Self.path(of: pid)
            pathCache[pid] = path
            let owner = appByPrefix.first { path.hasPrefix($0.prefix) }?.pid

            if let owner, var entry = usage[owner] {
                entry.cpu += cpuPercent
                entry.memory += info.ri_phys_footprint
                entry.processCount += 1
                usage[owner] = entry
            } else if includeBackground, pid != me, !path.isEmpty {
                usage[pid] = ProcessUsage(pid: pid, name: (path as NSString).lastPathComponent, bundleID: nil,
                                          isApp: false, cpu: cpuPercent, memory: info.ri_phys_footprint, processCount: 1)
            }
        }
        lastCPU = newCPU
        pathCache = pathCache.filter { newCPU[$0.key] != nil }

        return usage.values
            .filter { $0.isApp || $0.memory > 0 }
            .sorted { $0.memory > $1.memory }
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        return Array(pids.prefix(Int(max(filled, 0))))
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    private static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }
}
