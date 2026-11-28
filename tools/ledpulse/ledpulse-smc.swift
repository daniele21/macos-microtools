// SPDX-License-Identifier: MIT
// AppleSMC read-only discovery. No firmware write command is implemented.
import Foundation
#if os(macOS)
import IOKit
import Darwin
#else
import Glibc
#endif

enum SMCError: Error, CustomStringConvertible {
    case invalid(String), transport(String), firmware(UInt8, UInt8), unsupported
    var description: String {
        switch self {
        case .invalid(let s): return s
        case .transport(let s): return s
        case .firmware(let result, let status):
            return String(format: "SMC result=0x%02x status=0x%02x", result, status)
        case .unsupported: return "AppleSMC transport requires macOS"
        }
    }
}

struct FourCC {
    static func encode(_ s: String) throws -> UInt32 {
        let bytes = Array(s.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ (32...126).contains($0) }) else {
            throw SMCError.invalid("SMC keys must be exactly four printable ASCII bytes")
        }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    static func decode(_ n: UInt32) -> String {
        String(decoding: [24,16,8,0].map { UInt8(truncatingIfNeeded: n >> $0) }, as: UTF8.self)
    }
}

// Explicit offsets avoid relying on Swift struct padding for this private C ABI.
struct Packet {
    static let size = 80
    var bytes = [UInt8](repeating: 0, count: size)
    mutating func put(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { bytes[offset+i] = UInt8(truncatingIfNeeded: value >> (8*i)) }
    }
    func get(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset+$1]) << (8*$1)) }
    }
    static func request(command: UInt8, key: UInt32 = 0, size: UInt32 = 0, index: UInt32 = 0) -> Packet {
        var p = Packet()
        p.put(key, at: 0)
        p.put(size, at: 28)
        p.bytes[42] = command
        p.put(index, at: 44)
        return p
    }
    func check() throws {
        guard bytes[40] == 0 else { throw SMCError.firmware(bytes[40], bytes[41]) }
    }
}

protocol SMCTransport {
    func exchange(_ request: Packet) throws -> Packet
}

#if os(macOS)
final class AppleSMCTransport: SMCTransport {
    private let connection: io_connect_t
    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.transport("AppleSMC service not found") }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &c)
        guard result == KERN_SUCCESS else {
            throw SMCError.transport(String(format: "IOServiceOpen: 0x%08x", UInt32(bitPattern: result)))
        }
        connection = c
    }
    deinit { IOServiceClose(connection) }
    func exchange(_ request: Packet) throws -> Packet {
        // Defense in depth: no raw commands, even if a future caller constructs a packet.
        guard [UInt8(5), 8, 9].contains(request.bytes[42]) else {
            throw SMCError.invalid("Only read, index and metadata commands are permitted")
        }
        var response = Packet()
        var responseSize = Packet.size
        let result = request.bytes.withUnsafeBytes { input in
            response.bytes.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count,
                                          output.baseAddress, &responseSize)
            }
        }
        guard result == KERN_SUCCESS else {
            throw SMCError.transport(String(format: "IOConnectCallStructMethod: 0x%08x", UInt32(bitPattern: result)))
        }
        guard responseSize == Packet.size else { throw SMCError.invalid("Unexpected SMC response length: \(responseSize)") }
        try response.check()
        return response
    }
}
#endif

struct KeyInfo: Codable {
    let key: String
    let type: String
    let size: Int
    let attributes: UInt8
}
struct Reading: Codable {
    let info: KeyInfo
    let hex: String
    let numeric: Double?
}
struct Candidate: Codable {
    let key: String
    let info: KeyInfo?
    let error: String?
}
struct Discovery: Codable {
    let model: String
    let os: String
    let keyCount: Int
    let candidates: [Candidate]
    let indexErrors: Int
}
struct SMC {
    let transport: SMCTransport
    func info(_ key: String) throws -> KeyInfo {
        let response = try transport.exchange(.request(command: 9, key: FourCC.encode(key)))
        try response.check()
        let n = response.get(28)
        guard n <= 32 else { throw SMCError.invalid("Unsupported payload length \(n)") }
        return KeyInfo(key: key, type: FourCC.decode(response.get(32)), size: Int(n), attributes: response.bytes[36])
    }
    func raw(_ info: KeyInfo) throws -> [UInt8] {
        guard (1...32).contains(info.size) else { throw SMCError.invalid("Unsupported payload size") }
        let response = try transport.exchange(.request(command: 5, key: FourCC.encode(info.key), size: UInt32(info.size)))
        try response.check()
        return Array(response.bytes[48..<(48+info.size)])
    }
    func read(_ key: String) throws -> Reading {
        let metadata = try info(key)
        let bytes = try raw(metadata)
        return Reading(info: metadata, hex: bytes.map { String(format: "%02x", $0) }.joined(),
                       numeric: Self.number(type: metadata.type, bytes: bytes))
    }
    func count() throws -> Int {
        let metadata = try info("#KEY")
        guard metadata.size == 4 else { throw SMCError.invalid("Unexpected #KEY size") }
        let bytes = try raw(metadata)
        let value = Int(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard (1...16384).contains(value) else { throw SMCError.invalid("Unexpected key count \(value)") }
        return value
    }
    func key(at index: Int) throws -> String {
        guard (0..<16384).contains(index) else { throw SMCError.invalid("Index out of bounds") }
        let response = try transport.exchange(.request(command: 8, index: UInt32(index)))
        try response.check()
        let key = FourCC.decode(response.get(0))
        _ = try FourCC.encode(key)
        return key
    }
    static func number(type: String, bytes: [UInt8]) -> Double? {
        let n = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        switch (type, bytes.count) {
        case ("ui8 ", 1), ("flag", 1), ("ui16", 2), ("ui32", 4): return Double(n)
        case ("si8 ", 1): return Double(Int8(bitPattern: UInt8(n)))
        case ("si16", 2): return Double(Int16(bitPattern: UInt16(n)))
        case ("si32", 4): return Double(Int32(bitPattern: n))
        case ("sp78", 2): return Double(Int16(bitPattern: UInt16(n))) / 256
        case ("fpe2", 2): return Double(n) / 4
        case ("flt ", 4):
            let f = Float(bitPattern: n.byteSwapped)
            return f.isFinite ? Double(f) : nil
        default: return nil
        }
    }
    // Heuristics only. A matching name is NOT proof a key controls the status LED.
    static func candidate(_ key: String) -> Bool {
        let s = key.uppercased()
        return s.hasPrefix("L") || s.hasPrefix("MSL") || s.contains("LED") || s.contains("SIL")
    }
    func discover(model: String, os: String) throws -> Discovery {
        let total = try count()
        var keys = Set<String>()
        var errors = 0
        for index in 0..<total {
            do {
                let name = try key(at: index)
                if Self.candidate(name) { keys.insert(name) }
            } catch { errors += 1 }
        }
        let candidates = keys.sorted().map { key -> Candidate in
            do { return Candidate(key: key, info: try info(key), error: nil) }
            catch { return Candidate(key: key, info: nil, error: String(describing: error)) }
        }
        return Discovery(model: model, os: os, keyCount: total, candidates: candidates, indexErrors: errors)
    }
}

struct MockTransport: SMCTransport {
    func exchange(_ request: Packet) throws -> Packet {
        var response = Packet()
        switch request.bytes[42] {
        case 9:
            let key = FourCC.decode(request.get(0))
            guard key == "#KEY" || key == "Labc" else { throw SMCError.firmware(0x84, 0) }
            response.put(key == "#KEY" ? 4 : 1, at: 28)
            response.put(try FourCC.encode(key == "#KEY" ? "ui32" : "ui8 "), at: 32)
            response.bytes[36] = 0x80
        case 5:
            if FourCC.decode(request.get(0)) == "#KEY" && request.get(28) == 4 {
                response.bytes[51] = 1
            } else if FourCC.decode(request.get(0)) == "Labc" && request.get(28) == 1 {
                response.bytes[48] = 42
            } else { throw SMCError.invalid("Bad mock request") }
        case 8:
            guard request.get(44) == 0 else { throw SMCError.invalid("Bad mock index") }
            response.put(try FourCC.encode("Labc"), at: 0)
        default: throw SMCError.invalid("Unexpected mock command")
        }
        return response
    }
}

func selfTest() throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw SMCError.invalid("Test failed: \(message)") }
    }
    let key = try FourCC.encode("Labc")
    try require(key == 0x4c616263 && FourCC.decode(key) == "Labc", "FourCC")
    let p = Packet.request(command: 9, key: key, size: 4, index: 123)
    try require(p.bytes.count == 80 && Array(p.bytes[0..<4]) == [0x63,0x62,0x61,0x4c] &&
                p.bytes[42] == 9 && p.get(28) == 4 && p.get(44) == 123, "ABI")
    let smc = SMC(transport: MockTransport())
    let reading = try smc.read("Labc")
    try require(reading.numeric == 42 && reading.hex == "2a" && reading.info.attributes == 0x80, "Read")
    let scan = try smc.discover(model: "mock", os: "mock")
    try require(scan.keyCount == 1 && scan.candidates.first?.key == "Labc" && scan.indexErrors == 0, "Discovery")
    try require(SMC.number(type: "sp78", bytes: [0xff,0x80]) == -0.5, "Signed fixed point")
    try require(SMC.number(type: "flt ", bytes: [0,0,0x80,0x3f]) == 1, "Float")
    try require(SMC.number(type: "flt ", bytes: [0,0,0x80,0x7f]) == nil, "Nonfinite float")
    do {
        _ = try smc.info("MISS")
        throw SMCError.invalid("Missing key should fail")
    } catch SMCError.firmware(let result, _) {
        try require(result == 0x84, "Missing key")
    }
    print("SMC protocol self-tests passed (mock transport; no hardware access)")
}

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

#if os(macOS)
func hardwareModel() -> String {
    var count = 0
    guard sysctlbyname("hw.model", nil, &count, nil, 0) == 0, (1...256).contains(count) else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: count)
    let result = buffer.withUnsafeMutableBytes { sysctlbyname("hw.model", $0.baseAddress, &count, nil, 0) }
    guard result == 0, buffer.contains(0) else { return "unknown" }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
#endif

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["self-test"] { try selfTest(); return }
    if args.isEmpty || args == ["help"] || args == ["--help"] {
        print("Usage: ledpulse-smc self-test | discover | info KEY | read KEY")
        return
    }
    guard args == ["discover"] || (args.count == 2 && ["info", "read"].contains(args[0])) else {
        throw SMCError.invalid("Invalid command. Run ledpulse-smc --help. Writes are not implemented.")
    }
    #if os(macOS)
    let smc = SMC(transport: try AppleSMCTransport())
    switch args[0] {
    case "discover": try emit(smc.discover(model: hardwareModel(), os: ProcessInfo.processInfo.operatingSystemVersionString))
    case "info": try emit(smc.info(args[1]))
    case "read": try emit(smc.read(args[1]))
    default: throw SMCError.invalid("Invalid command")
    }
    #else
    throw SMCError.unsupported
    #endif
}
do { try run() } catch {
    FileHandle.standardError.write(Data(("ledpulse-smc: \(error)\n").utf8))
    exit(1)
}
