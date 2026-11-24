import Foundation
import CoreFoundation

/// Reads the CPU die temperature on Apple Silicon via the (private but stable) IOHID
/// event system – the same source tools like "Stats" use. Loaded dynamically, so if
/// anything is missing (e.g. on Intel Macs) it simply returns nil.
final class TemperatureSensor {
    static let shared = TemperatureSensor()

    private typealias CreateFn = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
    private typealias SetMatchingFn = @convention(c) (OpaquePointer, UnsafeRawPointer) -> Int32
    private typealias CopyServicesFn = @convention(c) (OpaquePointer) -> OpaquePointer?
    private typealias CopyPropertyFn = @convention(c) (OpaquePointer, UnsafeRawPointer) -> OpaquePointer?
    private typealias CopyEventFn = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias GetFloatFn = @convention(c) (OpaquePointer, Int32) -> Double

    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?
    /// (service, name) – service references are retained via the services array.
    private var cpuServices: [OpaquePointer] = []
    private var servicesArray: CFArray?
    private var client: OpaquePointer?
    private var available = true
    private let lock = NSLock()

    private static let temperatureType: Int64 = 15            // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16     // IOHIDEventFieldBase(type)

    private init() {}

    func cpuTemperature() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard available else { return nil }
        if client == nil, !setUp() {
            available = false
            return nil
        }
        guard let copyEvent, let getFloat else { return nil }
        var values: [Double] = []
        for service in cpuServices {
            guard let event = copyEvent(service, Self.temperatureType, 0, 0) else { continue }
            let value = getFloat(event, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
            if value > 5 && value < 130 { values.append(value) }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func setUp() -> Bool {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let propertySym = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let eventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSym = dlsym(handle, "IOHIDEventGetFloatValue") else { return false }

        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let setMatching = unsafeBitCast(matchSym, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(servicesSym, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(propertySym, to: CopyPropertyFn.self)
        copyEvent = unsafeBitCast(eventSym, to: CopyEventFn.self)
        getFloat = unsafeBitCast(floatSym, to: GetFloatFn.self)

        guard let client = create(nil) else { return false }
        self.client = client

        let matching: NSDictionary = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        _ = setMatching(client, Unmanaged.passUnretained(matching).toOpaque())

        guard let servicesRef = copyServices(client) else { return false }
        let services = Unmanaged<CFArray>.fromOpaque(UnsafeRawPointer(servicesRef)).takeRetainedValue()
        servicesArray = services

        let productKey = "Product" as NSString
        var all: [(OpaquePointer, String)] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = OpaquePointer(raw)
            var name = ""
            if let prop = copyProperty(service, Unmanaged.passUnretained(productKey).toOpaque()) {
                let object = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(prop)).takeRetainedValue()
                name = (object as? String) ?? ""
            }
            all.append((service, name))
        }
        // CPU clusters: "pACC/eACC MTR Temp Sensor" (M1) or "PMU tdie" (M2 and newer).
        var cpu = all.filter { $0.1.contains("ACC MTR") }
        if cpu.isEmpty { cpu = all.filter { $0.1.contains("tdie") } }
        if cpu.isEmpty { cpu = all.filter { $0.1.hasPrefix("PMU") } }
        cpuServices = cpu.map { $0.0 }
        return !cpuServices.isEmpty
    }
}
