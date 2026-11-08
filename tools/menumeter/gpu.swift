import Foundation
import IOKit

// Read-only, unprivileged GPU statistics exposed by macOS graphics drivers.
// GPU core load is a device-level percentage; core counts are metadata, not
// individual GPU-core utilization counters.
struct GPUStatistics {
    let utilization: Double?
    let renderer: Double?
    let tiler: Double?
    let memoryInUse: Double?
    let memoryAllocated: Double?
}

enum GPUStatisticsParser {
    private static func number(_ value: Any?) -> Double? {
        let parsed: Double
        if let value = value as? NSNumber {
            parsed = value.doubleValue
        } else if let value = value as? String,
                  let n = Double(value.replacingOccurrences(of: "%", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)) {
            parsed = n
        } else {
            return nil
        }
        return parsed.isFinite && parsed >= 0 ? parsed : nil
    }

    private static func percentage(_ keys: [String], from stats: [String: Any]) -> Double? {
        for key in keys {
            if let value = number(stats[key]), value <= 100 { return value }
        }
        return nil
    }

    private static func bytes(_ keys: [String], from stats: [String: Any]) -> Double? {
        for key in keys {
            if let value = number(stats[key]) { return value }
        }
        return nil
    }

    static func parse(_ stats: [String: Any]) -> GPUStatistics {
        GPUStatistics(
            utilization: percentage([
                "Device Utilization %", "GPU Activity(%)", "GPU Activity %",
                "GPU Utilization %", "GPU Busy %"
            ], from: stats),
            renderer: percentage(["Renderer Utilization %"], from: stats),
            tiler: percentage(["Tiler Utilization %"], from: stats),
            memoryInUse: bytes(["In use system memory", "In Use System Memory"], from: stats),
            memoryAllocated: bytes(["Alloc system memory", "Allocated system memory"], from: stats)
        )
    }
}

struct GPUDeviceSample {
    let id: UInt64
    let utilization: Double?
    let renderer: Double?
    let tiler: Double?
    let memoryInUse: Double?
    let memoryAllocated: Double?
    let coreCount: Int?
}

enum GPUReader {
    // Prefer AGX on Apple Silicon. Using *either* driver class (rather than
    // combining their results) avoids double-counting the same device.
    static func snapshot() -> [GPUDeviceSample] {
        let agx = readDevices(driverClass: "AGXAccelerator")
        return agx.isEmpty ? readDevices(driverClass: "IOAccelerator") : agx
    }

    private static func readDevices(driverClass: String) -> [GPUDeviceSample] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(driverClass),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [GPUDeviceSample] = []
        var seen = Set<UInt64>()
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS,
                  !seen.contains(id) else { continue }
            seen.insert(id)

            guard let raw = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            let stats = GPUStatisticsParser.parse(raw)
            guard stats.utilization != nil || stats.renderer != nil || stats.tiler != nil ||
                    stats.memoryInUse != nil || stats.memoryAllocated != nil else { continue }

            let coreProperty = IORegistryEntryCreateCFProperty(
                service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue()
            let reportedCores = (coreProperty as? NSNumber)?.intValue
            devices.append(GPUDeviceSample(
                id: id,
                utilization: stats.utilization,
                renderer: stats.renderer,
                tiler: stats.tiler,
                memoryInUse: stats.memoryInUse,
                memoryAllocated: stats.memoryAllocated,
                coreCount: reportedCores.flatMap { $0 > 0 ? $0 : nil }
            ))
        }
        return devices.sorted { $0.id < $1.id }
    }
}