import Foundation

// Apple Silicon exposes its temperature sensors through the private
// IOHIDEventSystem API. It needs no root and no entitlements, but the symbols
// are not in any public header, so they are resolved with dlsym.

private typealias ClientCreateFn  = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
private typealias SetMatchingFn   = @convention(c) (UnsafeMutableRawPointer?, CFDictionary?) -> Void
private typealias CopyServicesFn  = @convention(c) (UnsafeMutableRawPointer?) -> CFArray?
private typealias CopyPropertyFn  = @convention(c) (UnsafeMutableRawPointer?, CFString?) -> CFTypeRef?
private typealias CopyEventFn     = @convention(c) (UnsafeMutableRawPointer?, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
private typealias GetFloatValueFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double

private let temperatureEventType: Int64 = 15
private let temperatureField = Int32(15 << 16)

final class ThermalSensors {

    struct Reading {
        var cpu: Double?
        var gpu: Double?
        var soc: Double?
    }

    private enum Category {
        case cpu        // performance + efficiency core clusters
        case gpu
        case soc
        case cpuBackup  // die sensors, used only if the core clusters report nothing
    }

    private var services: [(category: Category, ref: UnsafeMutableRawPointer)] = []
    private let copyEvent: CopyEventFn
    private let getFloatValue: GetFloatValueFn

    init?() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            return nil
        }
        func symbol<T>(_ name: String) -> T? {
            guard let pointer = dlsym(iokit, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let create: ClientCreateFn = symbol("IOHIDEventSystemClientCreate"),
              let setMatching: SetMatchingFn = symbol("IOHIDEventSystemClientSetMatching"),
              let copyServices: CopyServicesFn = symbol("IOHIDEventSystemClientCopyServices"),
              let copyProperty: CopyPropertyFn = symbol("IOHIDServiceClientCopyProperty"),
              let copyEvent: CopyEventFn = symbol("IOHIDServiceClientCopyEvent"),
              let getFloatValue: GetFloatValueFn = symbol("IOHIDEventGetFloatValue")
        else { return nil }

        self.copyEvent = copyEvent
        self.getFloatValue = getFloatValue

        // kHIDPage_AppleVendor / kHIDUsage_AppleVendor_TemperatureSensor
        let client = create(kCFAllocatorDefault)
        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)

        guard let matched = copyServices(client) else { return nil }
        for index in 0..<CFArrayGetCount(matched) {
            guard let raw = CFArrayGetValueAtIndex(matched, index) else { continue }
            let ref = UnsafeMutableRawPointer(mutating: raw)
            guard let name = copyProperty(ref, "Product" as CFString) as? String,
                  let category = ThermalSensors.category(for: name) else { continue }
            _ = Unmanaged<AnyObject>.fromOpaque(ref).retain()
            services.append((category, ref))
        }
        if services.isEmpty { return nil }
    }

    private static func category(for name: String) -> Category? {
        if name.hasPrefix("pACC MTR Temp") || name.hasPrefix("eACC MTR Temp") { return .cpu }
        if name.hasPrefix("GPU MTR Temp") { return .gpu }
        if name.hasPrefix("SOC MTR Temp") || name.hasPrefix("PMGR SOC Die Temp") { return .soc }
        if name.hasPrefix("PMU tdie") || name.hasPrefix("PMU2 tdie") { return .cpuBackup }
        return nil
    }

    func read() -> Reading {
        var cpu: [Double] = [], gpu: [Double] = [], soc: [Double] = [], backup: [Double] = []

        for service in services {
            guard let event = copyEvent(service.ref, temperatureEventType, 0, 0) else { continue }
            let celsius = getFloatValue(event, temperatureField)
            Unmanaged<AnyObject>.fromOpaque(event).release()
            // Idle sensors park at implausible values; ignore anything off-scale.
            guard celsius > 5, celsius < 130 else { continue }
            switch service.category {
            case .cpu: cpu.append(celsius)
            case .gpu: gpu.append(celsius)
            case .soc: soc.append(celsius)
            case .cpuBackup: backup.append(celsius)
            }
        }

        return Reading(cpu: average(cpu.isEmpty ? backup : cpu),
                       gpu: average(gpu),
                       soc: average(soc))
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
