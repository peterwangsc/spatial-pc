import Foundation
import CryptoKit

/// Enrollment uses a 128-bit one-time secret, never a short human PIN.
/// No private key or pairing secret is transmitted or written to diagnostics.
enum PairingWire {
    static let maximumMessageBytes = 16_384
    enum Failure: Error, Equatable { case invalidCode, invalidMessage, oversized, authentication }
    struct Challenge: Equatable {
        let hostID: String
        let windowID: Data
        let serverNonce: Data
    }
    struct Credentials {
        let hostID: String
        let deviceID: String
        let serverCertificate: Data
        let clientCertificate: Data
        let caCertificate: Data
        let serverName: String
        let streamPort: UInt16
    }
    enum Message {
        case challenge(Challenge)
        case pending(Data)
        case paired(Credentials)
        case rejected
    }
    static func code(_ value: String) throws -> Data {
        guard value.utf8.count <= 80 else { throw Failure.invalidCode }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        let clean = value.utf8.filter { $0 != 32 && $0 != 45 }.map { (97...122).contains($0) ? $0 - 32 : $0 }
        guard clean.count == 26 else { throw Failure.invalidCode }
        var accumulator: UInt32 = 0, bits = 0, output = Data()
        for character in clean {
            guard let index = alphabet.firstIndex(of:character) else { throw Failure.invalidCode }
            accumulator = (accumulator << 5) | UInt32(index); bits += 5
            if bits >= 8 {
                bits -= 8; output.append(UInt8((accumulator >> bits) & 255))
                accumulator &= (1 << bits) - 1
            }
        }
        guard output.count == 16, bits == 2, accumulator == 0 else { throw Failure.invalidCode }
        return output
    }
    static func validateName(_ name:String) throws -> Data {
        let bytes = Data(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 64,
              !name.unicodeScalars.contains(where: {
                  // Match the host's Unicode category C exclusion. Swift strings
                  // cannot contain surrogate scalars, but reject every category
                  // explicitly so future editable names use the same wire rules.
                  switch $0.properties.generalCategory {
                  case .control, .format, .surrogate, .privateUse, .unassigned: true
                  default: false
                  }
              }) else { throw Failure.invalidMessage }
        return bytes
    }
    static func hexBytes(_ text:String, count:Int) throws -> Data {
        guard text.utf8.count == count * 2, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidMessage }
        var result = Data(), offset = text.startIndex
        while offset < text.endIndex {
            let next = text.index(offset,offsetBy:2)
            guard let byte = UInt8(text[offset..<next],radix:16) else { throw Failure.invalidMessage }
            result.append(byte); offset = next
        }
        return result
    }
    static func transcript(challenge:Challenge, leafSHA256:Data, clientNonce:Data, publicKey:Data, name:String) throws -> Data {
        guard leafSHA256.count == 32, challenge.windowID.count == 16, challenge.serverNonce.count == 32,
              clientNonce.count == 32, publicKey.count == 65, publicKey.first == 4 else { throw Failure.invalidMessage }
        let nameBytes = try validateName(name)
        var result = Data("SpatialPC-Pair-v1\0".utf8)
        result.append(leafSHA256); result.append(try hexBytes(challenge.hostID,count:16))
        result.append(challenge.windowID); result.append(challenge.serverNonce); result.append(clientNonce); result.append(publicKey)
        result.append(UInt8(nameBytes.count >> 8)); result.append(UInt8(nameBytes.count & 255)); result.append(nameBytes)
        return result
    }
    static func proof(secret:Data, transcript:Data, server:Bool) throws -> Data {
        guard secret.count == 16 else { throw Failure.invalidCode }
        return Data(HMAC<SHA256>.authenticationCode(for:Data((server ? "server\0" : "client\0").utf8) + transcript,using:SymmetricKey(data:secret)))
    }
    static func verifyServer(_ proof:Data, secret:Data, transcript:Data) throws {
        guard secret.count == 16, proof.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(proof,authenticating:Data("server\0".utf8)+transcript,using:SymmetricKey(data:secret)) else { throw Failure.authentication }
    }
    static func signatureMessage(_ transcript:Data) -> Data { Data("client-key\0".utf8) + transcript }
    static func encodeProof(clientNonce:Data, publicKey:Data, name:String, proof:Data, signature:Data) throws -> Data {
        guard clientNonce.count == 32, publicKey.count == 65, proof.count == 32, (8...80).contains(signature.count) else { throw Failure.invalidMessage }
        _ = try validateName(name)
        return try frame(JSONSerialization.data(withJSONObject:["version":1,"type":"proof","clientNonce":clientNonce.base64EncodedString(),"publicKey":publicKey.base64EncodedString(),"name":name,"proof":proof.base64EncodedString(),"signature":signature.base64EncodedString()]))
    }
    static func frame(_ payload:Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumMessageBytes else { throw Failure.oversized }
        var result = Data("SPP1".utf8)
        let size = UInt32(payload.count)
        for shift in [24,16,8,0] { result.append(UInt8((size >> shift) & 255)) }
        result.append(payload); return result
    }
    static func payloadLength(_ header:Data) throws -> Int {
        guard header.count == 8, header.prefix(4) == Data("SPP1".utf8) else { throw Failure.invalidMessage }
        let count = header.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= maximumMessageBytes else { throw Failure.oversized }
        return Int(count)
    }
    static func decode(_ payload:Data) throws -> Message {
        guard !payload.isEmpty, payload.count <= maximumMessageBytes else { throw Failure.oversized }
        var parser = StrictJSON(payload)
        guard case .object(let object) = try parser.parse(), object["version"] == .number("1"), case .string(let type) = object["type"] else { throw Failure.invalidMessage }
        func fields(_ names:[String]) throws {
            guard Set(object.keys) == Set(names + ["version","type"]) else { throw Failure.invalidMessage }
        }
        func string(_ name:String) throws -> String {
            guard case .string(let value) = object[name] else { throw Failure.invalidMessage }; return value
        }
        func bytes(_ name:String, count:Int? = nil) throws -> Data {
            let text = try string(name)
            guard let data = Data(base64Encoded:text), data.base64EncodedString() == text,
                  count.map({ data.count == $0 }) ?? (!data.isEmpty && data.count <= 8192) else { throw Failure.invalidMessage }
            return data
        }
        switch type {
        case "challenge":
            try fields(["hostId","windowId","serverNonce"])
            let host = try string("hostId"); _ = try hexBytes(host,count:16)
            return .challenge(Challenge(hostID:host,windowID:try bytes("windowId",count:16),serverNonce:try bytes("serverNonce",count:32)))
        case "pending":
            try fields(["serverProof"]); return .pending(try bytes("serverProof",count:32))
        case "paired":
            try fields(["hostId","deviceId","serverCertificate","clientCertificate","caCertificate","serverName","streamPort"])
            let host = try string("hostId"), device = try string("deviceId"), server = try string("serverName")
            _ = try hexBytes(host,count:16); _ = try hexBytes(device,count:16)
            guard case .number(let portText) = object["streamPort"], let port = UInt16(portText), port > 0,
                  !server.isEmpty, server.utf8.count <= 253,
                  server.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else { throw Failure.invalidMessage }
            return .paired(Credentials(hostID:host,deviceID:device,serverCertificate:try bytes("serverCertificate"),clientCertificate:try bytes("clientCertificate"),caCertificate:try bytes("caCertificate"),serverName:server,streamPort:port))
        case "rejected":
            try fields([]); return .rejected
        default: throw Failure.invalidMessage
        }
    }
}

/// Small bounded JSON parser preserves number spelling and rejects duplicate keys,
/// including escaped aliases. Foundation's dictionary decoding loses those details.
struct StrictJSON {
    indirect enum Value: Equatable {
        case object([String:Value]), array([Value]), string(String), number(String), literal(String)
    }
    let bytes:[UInt8]
    var position = 0
    init(_ data:Data) { bytes = Array(data) }
    mutating func parse() throws -> Value {
        let result = try value(depth:0); whitespace()
        guard position == bytes.count else { throw PairingWire.Failure.invalidMessage }; return result
    }
    mutating func whitespace() { while position < bytes.count, [9,10,13,32].contains(bytes[position]) { position += 1 } }
    mutating func consume(_ byte:UInt8) throws {
        whitespace(); guard position < bytes.count, bytes[position] == byte else { throw PairingWire.Failure.invalidMessage }; position += 1
    }
    mutating func string() throws -> String {
        whitespace(); let start = position; try consume(34)
        while position < bytes.count {
            let byte = bytes[position]; position += 1
            if byte == 34 { return try JSONDecoder().decode(String.self,from:Data(bytes[start..<position])) }
            if byte == 92 { guard position < bytes.count else { break }; position += 1 }
        }
        throw PairingWire.Failure.invalidMessage
    }
    mutating func value(depth:Int) throws -> Value {
        guard depth <= 12 else { throw PairingWire.Failure.invalidMessage }
        whitespace(); guard position < bytes.count else { throw PairingWire.Failure.invalidMessage }
        switch bytes[position] {
        case 34: return .string(try string())
        case 123:
            position += 1; whitespace(); var object = [String:Value]()
            if position < bytes.count, bytes[position] == 125 { position += 1; return .object(object) }
            while true {
                let key = try string(); guard object[key] == nil else { throw PairingWire.Failure.invalidMessage }
                try consume(58); object[key] = try value(depth:depth+1); whitespace()
                guard position < bytes.count else { throw PairingWire.Failure.invalidMessage }
                if bytes[position] == 125 { position += 1; return .object(object) }
                try consume(44)
            }
        case 91:
            position += 1; whitespace(); var array = [Value]()
            if position < bytes.count, bytes[position] == 93 { position += 1; return .array(array) }
            while true {
                array.append(try value(depth:depth+1)); whitespace()
                guard position < bytes.count else { throw PairingWire.Failure.invalidMessage }
                if bytes[position] == 93 { position += 1; return .array(array) }; try consume(44)
            }
        default:
            let start = position
            while position < bytes.count, ![9,10,13,32,44,93,125].contains(bytes[position]) { position += 1 }
            guard start != position else { throw PairingWire.Failure.invalidMessage }
            let token = Data(bytes[start..<position])
            guard let text = String(data:token,encoding:.utf8) else { throw PairingWire.Failure.invalidMessage }
            if ["true","false","null"].contains(text) { return .literal(text) }
            _ = try JSONSerialization.jsonObject(with:token,options:.fragmentsAllowed)
            guard text.first == "-" || text.first?.isNumber == true else { throw PairingWire.Failure.invalidMessage }
            return .number(text)
        }
    }
}
