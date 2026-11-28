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
