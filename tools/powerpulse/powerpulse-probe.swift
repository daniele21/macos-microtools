// PowerPulse hardware discovery: read-only, no dependencies or privileged helper.
import Foundation
#if os(macOS)
import Darwin
import IOKit
import CoreFoundation
#endif

struct EnergyReading: Codable {
    let name: String
    let subgroup: String
    let unit: String
    let delta: Int64
    let watts: Double?
    let status: String
}
struct SensorReading: Codable {
    let key: String
    let type: String?
    let value: Double?
    let unit: String
    let status: String
}
struct Sample: Codable {
    let elapsedSeconds: Double
    let energyStatus: String
    let channels: [EnergyReading]
    let sensors: [SensorReading]
}
struct Report: Codable {
    let schemaVersion: Int
    let model: String
    let osVersion: String
    let intervalSeconds: Double
    let samples: [Sample]
    let notes: [String]
}

func watts(_ delta: Int64, _ unit: String, _ seconds: Double) -> Double? {
    guard delta >= 0, seconds.isFinite, seconds > 0 else { return nil }
    let factor: Double
    switch unit.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "J": factor = 1
    case "mJ": factor = 1e-3
    case "uJ", "µJ", "μJ": factor = 1e-6
    case "nJ": factor = 1e-9
    case "pJ": factor = 1e-12
    default: return nil
    }
    let result = Double(delta) * factor / seconds
    return result.isFinite ? result : nil
}
func readLE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << ($1 * 8)) }
}
func writeLE(_ value: UInt32, _ bytes: inout [UInt8], _ offset: Int) {
    for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
}
func fourCC(_ string: String) -> UInt32 {
    string.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}
func fourCCString(_ value: UInt32) -> String {
    String(decoding: [24,16,8,0].map { UInt8(truncatingIfNeeded: value >> $0) }, as: UTF8.self)
}
func decodeSMC(_ bytes: [UInt8], _ type: String) -> Double? {
    let value: Double
    switch type {
    case "flt " where bytes.count == 4:
        value = Double(Float(bitPattern: readLE(bytes, 0)))
    case "sp78" where bytes.count == 2:
        value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
    case "fpe2" where bytes.count == 2:
        value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
    case "ui8 " where bytes.count == 1: value = Double(bytes[0])
    case "ui16" where bytes.count == 2: value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    default: return nil
    }
    return value.isFinite ? value : nil
}

#if os(macOS)
// The private ABI is resolved lazily; no hard link to an unsupported framework.
// All CF objects from Create/Copy are owned; channel accessor values are borrowed.
private final class EnergyProbe {
    typealias Copy = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UInt64, UInt64, UInt64) -> UnsafeRawPointer?
    typealias Subscribe = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>?, UInt64, UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias Samples = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias Delta = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias Label = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias Integer = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Int64
    private var subscription: UnsafeRawPointer?
    private var subscribed: UnsafeRawPointer?
    private var sampleFn: Samples?
    private var deltaFn: Delta?
    private var nameFn: Label?
    private var subgroupFn: Label?
    private var unitFn: Label?
    private var integerFn: Integer?
    private var previous: UnsafeRawPointer?
    private(set) var status = "library_unavailable"

    init() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL)
            ?? dlopen("/System/Library/PrivateFrameworks/IOReport.framework/IOReport", RTLD_LAZY | RTLD_LOCAL)
        else { return }
        // Keep the handle alive for this short-lived CLI to avoid invalidating CF callbacks.
        func load<T>(_ name: String, _: T.Type) -> T? {
            guard let symbol = dlsym(library, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
        status = "symbols_unavailable"
        guard let copy = load("IOReportCopyChannelsInGroup", Copy.self),
              let subscribe = load("IOReportCreateSubscription", Subscribe.self),
              let sample = load("IOReportCreateSamples", Samples.self),
              let delta = load("IOReportCreateSamplesDelta", Delta.self),
              let name = load("IOReportChannelGetChannelName", Label.self),
              let unit = load("IOReportChannelGetUnitLabel", Label.self),
              let integer = load("IOReportSimpleGetIntegerValue", Integer.self)
        else { return }
        sampleFn = sample; deltaFn = delta; nameFn = name; unitFn = unit; integerFn = integer
        subgroupFn = load("IOReportChannelGetSubGroup", Label.self)
        let group = "Energy Model" as CFString
        status = "channels_unavailable"
        guard let raw = copy(Unmanaged.passUnretained(group).toOpaque(), nil, 0, 0, 0) else { return }
        let dictionary = Unmanaged<CFDictionary>.fromOpaque(raw).takeRetainedValue()
        guard let mutable = CFDictionaryCreateMutableCopy(nil, 0, dictionary) else { return }
        status = "subscription_unavailable"
        var selected: UnsafeRawPointer?
        subscription = subscribe(nil, Unmanaged.passUnretained(mutable).toOpaque(), &selected, 0, nil)
        subscribed = selected
        guard subscription != nil, subscribed != nil else { return }
        status = "ready"
    }
    private func release(_ pointer: UnsafeRawPointer?) {
        if let pointer = pointer { Unmanaged<AnyObject>.fromOpaque(pointer).release() }
    }
    deinit { release(previous); release(subscribed); release(subscription) }
    private func label(_ fn: Label?, _ row: UnsafeRawPointer) -> String {
        guard let raw = fn?(row) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
    func baseline() -> Bool {
        guard status == "ready", let next = sampleFn?(subscription, subscribed, nil) else { return false }
        release(previous); previous = next
        return true
    }
    func read(_ elapsed: Double) -> (String, [EnergyReading]) {
        guard status == "ready" else { return (status, []) }
        guard let next = sampleFn?(subscription, subscribed, nil) else {
            release(previous); previous = nil; return ("sample_failed", [])
        }
        let old = previous
        previous = next
        defer { release(old) }
        guard let old = old, let raw = deltaFn?(old, next, nil) else { return ("delta_unavailable", []) }
        let report = Unmanaged<CFDictionary>.fromOpaque(raw).takeRetainedValue()
        guard let dict = report as? [String: Any], let items = dict["IOReportChannels"] as? NSArray else {
            return ("unexpected_report_format", [])
        }
        let array = items as CFArray
        var rows: [EnergyReading] = []
        for i in 0..<CFArrayGetCount(array) {
            guard let row = CFArrayGetValueAtIndex(array, i) else { continue }
            let name = label(nameFn, row), unit = label(unitFn, row)
            guard !name.isEmpty, let value = integerFn?(row, nil) else { continue }
            let w = watts(value, unit, elapsed)
            let state = value < 0 ? "invalid_delta" : w == nil ? "unsupported_unit" : value == 0 ? "zero_unverified" : "positive_delta"
            rows.append(EnergyReading(name: name, subgroup: label(subgroupFn, row), unit: unit, delta: value, watts: w, status: state))
        }
        return (rows.isEmpty ? "empty_report" : "sampled", rows)
    }
}

// AppleSMC read-only commands: selector 2, key-info (9), read (5).
// Explicit wire layout (80 bytes) avoids Swift struct padding differences.
private final class SMCProbe {
    private var connection: io_connect_t = 0
    private(set) var status = "service_unavailable"
    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        status = result == KERN_SUCCESS ? "ready" : "open_failed_\(result)"
        if result != KERN_SUCCESS { connection = 0 }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    private func call(_ input: [UInt8]) -> ([UInt8]?, String) {
        var output = [UInt8](repeating: 0, count: 80)
        var size = 80
        let result = input.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                IOConnectCallStructMethod(connection, 2, src.baseAddress, src.count, dst.baseAddress, &size)
            }
        }
        guard result == KERN_SUCCESS else { return (nil, "io_error_\(result)") }
        guard size == 80 else { return (nil, "unexpected_size_\(size)") }
        guard output[40] == 0 else { return (nil, "smc_result_\(output[40])") }
        return (output, "ok")
    }
    func read(_ key: String, unit: String) -> SensorReading {
        func missing(_ state: String, _ type: String? = nil) -> SensorReading {
            SensorReading(key: key, type: type, value: nil, unit: unit, status: state)
        }
        guard connection != 0 else { return missing(status) }
        var input = [UInt8](repeating: 0, count: 80)
        writeLE(fourCC(key), &input, 0); input[42] = 9
        let (info, infoStatus) = call(input)
        guard let info = info else { return missing(infoStatus) }
        let size = Int(readLE(info, 28)), type = fourCCString(readLE(info, 32))
        guard (1...32).contains(size) else { return missing("invalid_data_size", type) }
        input[42] = 5; writeLE(UInt32(size), &input, 28)
        let (data, dataStatus) = call(input)
        guard let data = data else { return missing(dataStatus, type) }
        guard let value = decodeSMC(Array(data[48..<(48 + size)]), type) else { return missing("unsupported_or_invalid_encoding", type) }
        let state = value == 0 && unit == "W" ? "zero_unverified" : value < 0 && unit != "C" ? "signed_unverified" : "sampled"
        return SensorReading(key: key, type: type, value: value, unit: unit, status: state)
    }
}
private func modelIdentifier() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    let result = buffer.withUnsafeMutableBufferPointer { sysctlbyname("hw.model", $0.baseAddress, &size, nil, 0) }
    return result == 0 ? String(cString: buffer) : "unknown"
}
private func runProbe(count: Int, interval: Double) -> Report {
    let energy = EnergyProbe(), smc = SMCProbe()
    var samples: [Sample] = []
    _ = energy.baseline()
    var last = ProcessInfo.processInfo.systemUptime
    for _ in 0..<count {
        Thread.sleep(forTimeInterval: interval)
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - last; last = now
        let (status, rows) = energy.read(elapsed)
        let candidates = [("PSTR","W"),("PDTR","W"),("FNum","count"),("F0Ac","rpm"),("F1Ac","rpm"),
                          ("TC0P","C"),("TG0P","C"),("Tp01","C"),("Tp05","C"),("Tg05","C")]
        let sensors = candidates.map { smc.read($0.0, unit: $0.1) }
        samples.append(Sample(elapsedSeconds: elapsed, energyStatus: status, channels: rows, sensors: sensors))
    }
    return Report(schemaVersion: 1, model: modelIdentifier(), osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                  intervalSeconds: interval, samples: samples, notes: [
                    "PSTR and PDTR are separate internal SMC candidates, not wall power and not additive.",
                    "Energy Model channels can overlap. Do not sum indiscriminately.",
                    "Zero counters may be idle, frozen or restricted; compare idle and active runs.",
                    "Temperature keys are candidates only; their locations and availability vary.",
                    "No fan, LED, power-management or sensor writes are performed."
                  ])
}
#endif

func selfTest() -> Bool {
    let epsilon = 1e-10
    func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < epsilon } ?? false }
    var bytes = [UInt8](repeating: 0, count: 80)
    writeLE(fourCC("PSTR"), &bytes, 0)
    return close(watts(2000, "mJ", 2), 1)
        && close(watts(1_000_000, "µJ", 2), 0.5)
        && close(watts(1_000_000_000, "nJ", 1), 1)
        && watts(-1, "mJ", 1) == nil && watts(1, "bogus", 1) == nil && watts(1, "J", 0) == nil
        && close(watts(0, "J", 1), 0)
        && fourCCString(readLE(bytes, 0)) == "PSTR"
        && close(decodeSMC([0,0,72,65], "flt "), 12.5)
        && close(decodeSMC([255,128], "sp78"), -0.5)
        && close(decodeSMC([0,20], "fpe2"), 5)
        && decodeSMC([0,0,128,127], "flt ") == nil
        && decodeSMC([1], "flt ") == nil
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
let args = Array(CommandLine.arguments.dropFirst())
if args == ["--self-test"] {
    guard selfTest() else { fail("PowerPulse self-test failed") }
    print("PowerPulse self-test passed")
} else if args == ["--help"] {
    print("Usage: powerpulse-probe [--samples 1...60] [--interval 0.25...10] | --self-test")
} else {
    var count = 3, interval = 1.0, index = 0
    while index < args.count {
        guard index + 1 < args.count else { fail("Missing argument value") }
        switch args[index] {
        case "--samples":
            guard let n = Int(args[index+1]), (1...60).contains(n) else { fail("Invalid sample count") }; count = n
        case "--interval":
            guard let s = Double(args[index+1]), s.isFinite, (0.25...10).contains(s) else { fail("Invalid interval") }; interval = s
        default: fail("Unknown argument: \(args[index])")
        }
        index += 2
    }
    #if os(macOS) && arch(arm64)
    let report = runProbe(count: count, interval: interval)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do { let data = try encoder.encode(report); FileHandle.standardOutput.write(data); print("") }
    catch { fail("JSON encoding failed: \(error)") }
    #else
    fail("Hardware probe requires native Apple Silicon macOS; --self-test is portable.")
    #endif
}
