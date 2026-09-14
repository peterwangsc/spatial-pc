import Foundation

enum StreamWire {
    static let maximumFrameBytes = 16 * 1024 * 1024
    enum Invalid: Error { case header, length, version, codec, dimensions, nalUnit }
    struct Capabilities: Decodable {
        let version: Int
        let codec: String
        let width: Int
        let height: Int
        let fps: Int
        let hardwareEncoder: Bool
        let input: InputCapability?
    }
    struct InputCapability: Decodable {
        let version: Int?
        let enabled: Bool?
        let wire: String?
        let recordBytes: Int?
        let maxEventsPerSecond: Int?
        let heartbeatMS: Int?
        let leaseMS: Int?
        var supported: Bool {
            version == 1 && enabled == true && wire == "SPI1" && recordBytes == 24 &&
            maxEventsPerSecond == 240 && heartbeatMS == 500 && leaseMS == 2000
        }
    }
    static func unsigned(_ bytes: Data) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
    static func helloLength(_ data: Data) throws -> Int {
        guard data.count == 8, data.prefix(4) == Data("SPC1".utf8) else { throw Invalid.header }
        let size = Int(unsigned(data.suffix(4)))
        guard (1...4096).contains(size) else { throw Invalid.length }
        return size
    }
    static func capabilities(_ data: Data) throws -> Capabilities {
        let value = try JSONDecoder().decode(Capabilities.self, from: data)
        guard value.version == 1 else { throw Invalid.version }
        guard value.codec == "h264-annexb", value.hardwareEncoder else { throw Invalid.codec }
        guard value.width > 0, value.height > 0, value.width <= 8192, value.height <= 8192,
              value.width * value.height <= 16_777_216, (1...240).contains(value.fps) else { throw Invalid.dimensions }
        return value
    }
    static func frameHeader(_ data: Data) throws -> (length: Int, timestamp: Int64) {
        guard data.count == 16 else { throw Invalid.header }
        let size = Int(unsigned(data.prefix(4)))
        let timestamp = unsigned(data.dropFirst(4).prefix(8))
        guard size > 0, size <= maximumFrameBytes, timestamp <= UInt64(Int64.max) else { throw Invalid.length }
        return (size, Int64(timestamp))
    }
    static func annexBUnits(_ data: Data) throws -> [Data] {
        guard !data.isEmpty, data.count <= maximumFrameBytes else { throw Invalid.length }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var starts: [(start: Int, payload: Int)] = []
            var i = 0
            while i + 2 < bytes.count {
                if bytes[i] == 0 && bytes[i+1] == 0 {
                    if bytes[i+2] == 1 { starts.append((i,i+3)); i += 3; continue }
                    if i+3 < bytes.count && bytes[i+2] == 0 && bytes[i+3] == 1 {
                        starts.append((i,i+4)); i += 4; continue
                    }
                }
                i += 1
            }
            guard let first = starts.first, bytes[..<first.start].allSatisfy({ $0 == 0 }) else { throw Invalid.nalUnit }
            var units: [Data] = []
            for index in starts.indices {
                let end = index+1 < starts.count ? starts[index+1].start : bytes.count
                guard starts[index].payload < end else { throw Invalid.nalUnit }
                let unit = Data(bytes[starts[index].payload..<end])
                guard let byte = unit.first, byte & 0x80 == 0, (1...23).contains(byte & 31) else { throw Invalid.nalUnit }
                units.append(unit)
            }
            return units
        }
    }
    static func avcc(_ units: [Data]) -> Data {
        var result = Data()
        result.reserveCapacity(units.reduce(0) { $0 + 4 + $1.count })
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(unit)
        }
        return result
    }
}
