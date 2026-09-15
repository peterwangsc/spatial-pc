import Foundation

/// Focus control v1 records. Socket ownership, request ordering, and endpoint
/// equality belong to the transport; this codec validates individual records.
enum FocusControlWire {
    static let maximumMessageBytes = 8_192
    enum Failure: Error, Equatable { case invalidMessage, oversized }
    enum Operation: String, CaseIterable {
        case capabilities, heartbeat
        case requestPermission = "focus.requestPermission"
        case prepare = "focus.prepare"
        case stop = "focus.stop"
    }

    static func request(id: Int, operation: Operation, parameters: [String: Any] = [:]) throws -> Data {
        try request(id: id, operation: operation.rawValue, parameters: parameters)
    }

    /// Returns the complete big-endian length-prefixed request.
    static func request(id: Int, operation: String, parameters: [String: Any] = [:]) throws -> Data {
        guard (1...4096).contains(id), let operation = Operation(rawValue: operation),
              JSONSerialization.isValidJSONObject(parameters) else { throw Failure.invalidMessage }
        let encoded = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
        guard case .object(let values) = try parse(encoded) else { throw Failure.invalidMessage }
        switch operation {
        case .capabilities, .heartbeat, .requestPermission:
            try fields(values, [])
        case .prepare:
            try fields(values, ["intent"])
            guard ["setup", "enter"].contains(try string(values["intent"])) else { throw Failure.invalidMessage }
        case .stop:
            try fields(values, ["sessionId", "returnToDesktop"])
            try sessionID(values["sessionId"], nullable: true)
            _ = try boolean(values["returnToDesktop"])
        }
        return try frame(JSONSerialization.data(withJSONObject: ["version": 1, "type": "request", "id": id,
            "operation": operation.rawValue, "parameters": parameters], options: [.sortedKeys]))
    }

    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumMessageBytes else { throw Failure.oversized }
        let count = UInt32(payload.count)
        var result = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        result.append(payload)
        return result
    }

    static func payloadLength(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw Failure.invalidMessage }
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= maximumMessageBytes else { throw Failure.oversized }
        return Int(count)
    }

    /// Decodes one unframed payload. Pass the correlated operation to reject a
    /// valid reply shape or progress state belonging to another operation.
    static func decode(_ payload: Data, expectedOperation: String? = nil) throws -> [String: Any] {
        let expected: Operation?
        if let expectedOperation {
            guard let operation = Operation(rawValue: expectedOperation) else { throw Failure.invalidMessage }
            expected = operation
        } else { expected = nil }
        guard case .object(let object) = try parse(payload),
              try integer(object["version"]) == 1,
              (1...4096).contains(try integer(object["id"])) else { throw Failure.invalidMessage }
        switch try string(object["type"]) {
        case "result":
            try fields(object, ["version", "type", "id", "result"])
            guard case .object(let result) = object["result"] else { throw Failure.invalidMessage }
            let operation = try validateResult(result)
            guard expected == nil || expected == operation else { throw Failure.invalidMessage }
        case "error":
            try fields(object, ["version", "type", "id", "code"])
            guard errorCodes.contains(try string(object["code"])) else { throw Failure.invalidMessage }
        case "progress":
            try fields(object, ["version", "type", "id", "sessionId", "state"])
            try sessionID(object["sessionId"], nullable: true)
            let state = try string(object["state"])
            guard progressStates.contains(state) else { throw Failure.invalidMessage }
            if state == "awaitingPermission" || expected == .requestPermission {
                guard object["sessionId"] == .null,
                      ["awaitingPermission", "stopping", "stopped", "failed"].contains(state) else { throw Failure.invalidMessage }
            }
            if let expected {
                guard expected == .requestPermission || expected == .prepare,
                      expected != .prepare || state != "awaitingPermission" else { throw Failure.invalidMessage }
            }
        default: throw Failure.invalidMessage
        }
        return object.mapValues { $0.foundation }
    }

    private static let errorCodes: Set<String> = ["unsupported", "accessDisabled", "permissionRequired", "busy", "rateLimited",
        "wrongOwner", "invalidState", "desktopStopTimeout", "setupTimeout", "runtimeStartFailed", "cleanupFailed",
        "interfaceChanged", "expired", "canceled"]
    private static let progressStates: Set<String> = ["awaitingPermission", "waitingForDesktop", "waitingForSystem",
        "qrPresented", "startingMedia", "mediaReady", "stopping", "stopped", "failed"]

    private static func validateResult(_ result: [String: Value]) throws -> Operation {
        switch Set(result.keys) {
        case Set(["granted", "reason"]):
            let granted = try boolean(result["granted"]), reason = try string(result["reason"])
            guard ["none", "denied", "timeout", "canceled"].contains(reason), granted == (reason == "none") else { throw Failure.invalidMessage }
            return .requestPermission
        case Set(["sessionId", "endpoint", "setupRemainingSeconds"]):
            try sessionID(result["sessionId"], nullable: false)
            guard case .object(let endpoint) = result["endpoint"] else { throw Failure.invalidMessage }
            try fields(endpoint, ["address", "port"])
            guard !(try string(endpoint["address"])).isEmpty, try integer(endpoint["port"]) == 55000,
                  (0...180).contains(try integer(result["setupRemainingSeconds"])) else { throw Failure.invalidMessage }
            return .prepare
        case Set(["stopped", "desktopAllowed"]):
            guard try boolean(result["stopped"]) else { throw Failure.invalidMessage }
            _ = try boolean(result["desktopAllowed"])
            return .stop
        case Set(["idleRemainingSeconds", "sessionRemainingSeconds"]):
            guard try integer(result["idleRemainingSeconds"]) == 15,
                  (0...600).contains(try integer(result["sessionRemainingSeconds"])) else { throw Failure.invalidMessage }
            return .heartbeat
        default:
            let booleans = ["focusCompiled", "runtimeConfigured", "hardwareValidated", "consumerReady", "focusAllowed", "accessEnabled", "available"]
            try fields(result, booleans + ["mediaMode", "content", "systemTrust", "systemTrustPersistence", "mediaSecurity", "setupWindowSeconds", "sessionLimitSeconds"])
            for key in booleans { _ = try boolean(result[key]) }
            guard ["idle", "desktop", "focus", "failed"].contains(try string(result["mediaMode"])),
                  try string(result["content"]) == "plain-scene-development",
                  try string(result["systemTrust"]) == "apple-qr-separate",
                  try string(result["systemTrustPersistence"]) == "unverified",
                  try string(result["mediaSecurity"]) == "development-only",
                  try integer(result["setupWindowSeconds"]) == 180,
                  try integer(result["sessionLimitSeconds"]) == 600 else { throw Failure.invalidMessage }
            return .capabilities
        }
    }

    private static func fields(_ object: [String: Value], _ names: [String]) throws {
        guard Set(object.keys) == Set(names) else { throw Failure.invalidMessage }
    }
    private static func string(_ value: Value?) throws -> String {
        guard case .string(let value) = value else { throw Failure.invalidMessage }; return value
    }
    private static func integer(_ value: Value?) throws -> Int {
        guard case .integer(let value) = value else { throw Failure.invalidMessage }; return value
    }
    private static func boolean(_ value: Value?) throws -> Bool {
        guard case .boolean(let value) = value else { throw Failure.invalidMessage }; return value
    }
    private static func sessionID(_ value: Value?, nullable: Bool) throws {
        if nullable && value == .null { return }
        let text = try string(value)
        guard text.utf8.count == 32, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidMessage }
    }

    private static func parse(_ data: Data) throws -> Value {
        guard !data.isEmpty, data.count <= maximumMessageBytes else { throw Failure.oversized }
        guard String(data: data, encoding: .utf8) != nil else { throw Failure.invalidMessage }
        var parser = Parser(bytes: Array(data))
        return try parser.parse()
    }

    private indirect enum Value: Equatable {
        case object([String: Value]), array([Value]), string(String), integer(Int), boolean(Bool), null
        var foundation: Any {
            switch self {
            case .object(let values): return values.mapValues { $0.foundation }
            case .array(let values): return values.map { $0.foundation }
            case .string(let value): return value
            case .integer(let value): return value
            case .boolean(let value): return value
            case .null: return NSNull()
            }
        }
    }

    /// Parse before dictionary conversion so escaped duplicate keys, numeric
    /// spelling, and the depth bound cannot be lost by Foundation decoding.
    private struct Parser {
        let bytes: [UInt8]
        var position = 0
        mutating func parse() throws -> Value {
            let result = try value(depth: 0)
            whitespace()
            guard position == bytes.count else { throw Failure.invalidMessage }
            return result
        }
        mutating func whitespace() {
            while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
        }
        mutating func consume(_ byte: UInt8) throws {
            whitespace()
            guard position < bytes.count, bytes[position] == byte else { throw Failure.invalidMessage }
            position += 1
        }
        mutating func string() throws -> String {
            whitespace()
            let start = position
            try consume(34)
            while position < bytes.count {
                let byte = bytes[position]; position += 1
                if byte == 34 {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) }
                    catch { throw Failure.invalidMessage }
                }
                if byte == 92 {
                    guard position < bytes.count else { throw Failure.invalidMessage }
                    position += 1
                }
            }
            throw Failure.invalidMessage
        }
        mutating func value(depth: Int) throws -> Value {
            guard depth <= 6 else { throw Failure.invalidMessage }
            whitespace()
            guard position < bytes.count else { throw Failure.invalidMessage }
            switch bytes[position] {
            case 34: return .string(try string())
            case 123:
                position += 1; whitespace()
                var object: [String: Value] = [:]
                if position < bytes.count, bytes[position] == 125 { position += 1; return .object(object) }
                while true {
                    let key = try string()
                    guard object[key] == nil else { throw Failure.invalidMessage }
                    try consume(58)
                    object[key] = try value(depth: depth + 1)
                    whitespace()
                    guard position < bytes.count else { throw Failure.invalidMessage }
                    if bytes[position] == 125 { position += 1; return .object(object) }
                    try consume(44)
                }
            case 91:
                position += 1; whitespace()
                var array: [Value] = []
                if position < bytes.count, bytes[position] == 93 { position += 1; return .array(array) }
                while true {
                    array.append(try value(depth: depth + 1)); whitespace()
                    guard position < bytes.count else { throw Failure.invalidMessage }
                    if bytes[position] == 93 { position += 1; return .array(array) }
                    try consume(44)
                }
            default:
                let start = position
                while position < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) { position += 1 }
                let token = Array(bytes[start..<position])
                guard !token.isEmpty else { throw Failure.invalidMessage }
                let text = String(decoding: token, as: UTF8.self)
                if text == "true" { return .boolean(true) }
                if text == "false" { return .boolean(false) }
                if text == "null" { return .null }
                let digits = token.first == 45 ? Array(token.dropFirst()) : token
                guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
                      digits.count == 1 || digits.first != 48,
                      let number = Int(text) else { throw Failure.invalidMessage }
                return .integer(number)
            }
        }
    }
}
