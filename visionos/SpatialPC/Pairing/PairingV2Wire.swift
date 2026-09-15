import Foundation
import CryptoKit

/// Four-digit enrollment uses PAKE-derived keys, never PIN-keyed HMAC.
/// No private key or pairing secret is transmitted or written to diagnostics.
enum PairingV2Wire {
    static let maximumMessageBytes = 16_384
    typealias Failure = PairingWire.Failure
    struct Challenge: Equatable {
        let hostID: String
        let windowID: Data
        let serverNonce: Data
        let serverMessage: Data
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
        let bytes = Data(value.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ (48...57).contains($0) }) else { throw Failure.invalidCode }
        return bytes
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
    static func context(challenge:Challenge, leafSHA256:Data) throws -> Data {
        guard leafSHA256.count == 32, challenge.windowID.count == 16,
              challenge.serverNonce.count == 32, challenge.serverMessage.count == 32 else { throw Failure.invalidMessage }
        return leafSHA256 + (try hexBytes(challenge.hostID,count:16)) + challenge.windowID + challenge.serverNonce
    }
    static func names(context:Data) throws -> (client:Data,server:Data) {
        guard context.count == 96 else { throw Failure.invalidMessage }
        return (Data("SpatialPC-Pair-v2/client\0".utf8)+context,Data("SpatialPC-Pair-v2/server\0".utf8)+context)
    }
    static func transcript(context:Data, clientNonce:Data, publicKey:Data, name:String,
                           clientMessage:Data, serverMessage:Data) throws -> Data {
        guard context.count == 96, clientNonce.count == 32, publicKey.count == 65, publicKey.first == 4,
              clientMessage.count == 32, serverMessage.count == 32 else { throw Failure.invalidMessage }
        let nameBytes = try validateName(name)
        var result = Data("SpatialPC-Pair-v2\0".utf8)
        result.append(context); result.append(clientNonce); result.append(publicKey)
        result.append(UInt8(nameBytes.count >> 8)); result.append(UInt8(nameBytes.count & 255)); result.append(nameBytes)
        result.append(clientMessage); result.append(serverMessage)
        return result
    }
    static func proof(key:SymmetricKey, transcript:Data, server:Bool) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for:Data((server ? "server\0" : "client\0").utf8)+transcript,using:key))
    }
    static func verifyServer(_ proof:Data, key:SymmetricKey, transcript:Data) throws {
        guard proof.count == 32, HMAC<SHA256>.isValidAuthenticationCode(proof,
            authenticating:Data("server\0".utf8)+transcript,using:key) else { throw Failure.authentication }
    }
    static func signatureMessage(_ transcript:Data) -> Data { Data("client-key\0".utf8)+transcript }
    static func encodeProof(clientNonce:Data, publicKey:Data, name:String, clientMessage:Data, proof:Data, signature:Data) throws -> Data {
        guard clientNonce.count == 32, publicKey.count == 65, clientMessage.count == 32,
              proof.count == 32, (8...80).contains(signature.count) else { throw Failure.invalidMessage }
        _ = try validateName(name)
        return try frame(JSONSerialization.data(withJSONObject:["version":2,"type":"proof","clientNonce":clientNonce.base64EncodedString(),
            "publicKey":publicKey.base64EncodedString(),"name":name,"clientMessage":clientMessage.base64EncodedString(),
            "proof":proof.base64EncodedString(),"signature":signature.base64EncodedString()]))
    }
    static func frame(_ payload:Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumMessageBytes else { throw Failure.oversized }
        var result = Data("SPP2".utf8)
        let size = UInt32(payload.count)
        for shift in [24,16,8,0] { result.append(UInt8((size >> shift) & 255)) }
        result.append(payload); return result
    }
    static func payloadLength(_ header:Data) throws -> Int {
        guard header.count == 8, header.prefix(4) == Data("SPP2".utf8) else { throw Failure.invalidMessage }
        let count = header.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= maximumMessageBytes else { throw Failure.oversized }
        return Int(count)
    }
    static func decode(_ payload:Data) throws -> Message {
        guard !payload.isEmpty, payload.count <= maximumMessageBytes else { throw Failure.oversized }
        var parser = StrictJSON(payload)
        guard case .object(let object) = try parser.parse(), object["version"] == .number("2"), case .string(let type) = object["type"] else { throw Failure.invalidMessage }
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
            try fields(["hostId","windowId","serverNonce","serverMessage"])
            let host = try string("hostId"); _ = try hexBytes(host,count:16)
            return .challenge(Challenge(hostID:host,windowID:try bytes("windowId",count:16),serverNonce:try bytes("serverNonce",count:32),serverMessage:try bytes("serverMessage",count:32)))
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
