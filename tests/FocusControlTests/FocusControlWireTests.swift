import Foundation
import XCTest
@testable import FocusControlCore

final class FocusControlWireTests: XCTestCase {
    private let session = String(repeating: "ab", count: 16)

    private func payload(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func result(_ value: [String: Any], id: Int = 1) throws -> Data {
        try payload(["version": 1, "type": "result", "id": id, "result": value])
    }
    private func progress(_ state: String, sessionID: Any = NSNull()) throws -> Data {
        try payload(["version": 1, "type": "progress", "id": 1, "state": state, "sessionId": sessionID])
    }
    private var capabilities: [String: Any] {
        ["focusCompiled": true, "runtimeConfigured": true, "hardwareValidated": false,
         "consumerReady": false, "focusAllowed": true, "accessEnabled": true, "available": true,
         "mediaMode": "idle", "content": "plain-scene-development", "systemTrust": "apple-qr-separate",
         "systemTrustPersistence": "unverified", "mediaSecurity": "development-only",
         "setupWindowSeconds": 180, "sessionLimitSeconds": 600]
    }
    private var prepare: [String: Any] {
        ["sessionId": session, "endpoint": ["address": "192.168.1.2", "port": 55000], "setupRemainingSeconds": 179]
    }

    func testBigEndianFrameAndBounds() throws {
        XCTAssertEqual(try FocusControlWire.frame(Data("{}".utf8)), Data([0, 0, 0, 2, 123, 125]))
        let maximum = try FocusControlWire.frame(Data(repeating: 32, count: 8192))
        XCTAssertEqual(Array(maximum.prefix(4)), [0, 0, 32, 0])
        XCTAssertEqual(try FocusControlWire.payloadLength(maximum.prefix(4)), 8192)
        for invalid in [Data(), Data([0, 0, 1]), Data([0, 0, 0, 0]), Data([0, 0, 32, 1]), Data([255, 255, 255, 255])] {
            XCTAssertThrowsError(try FocusControlWire.payloadLength(invalid))
        }
        XCTAssertThrowsError(try FocusControlWire.frame(Data()))
        XCTAssertThrowsError(try FocusControlWire.frame(Data(repeating: 0, count: 8193)))
        XCTAssertThrowsError(try FocusControlWire.decode(Data(repeating: 32, count: 8193)))
        let valid = try result(["granted": true, "reason": "none"])
        XCTAssertNoThrow(try FocusControlWire.decode(valid + Data(repeating: 32, count: 8192 - valid.count)))
    }

    func testOutgoingOperationsAndExactParameters() throws {
        let cases: [(FocusControlWire.Operation, [String: Any])] = [
            (.capabilities, [:]), (.heartbeat, [:]), (.requestPermission, [:]),
            (.prepare, ["intent": "setup"]), (.prepare, ["intent": "enter"]),
            (.stop, ["sessionId": NSNull(), "returnToDesktop": false]),
            (.stop, ["sessionId": session, "returnToDesktop": true])]
        for (operation, parameters) in cases {
            let framed = try FocusControlWire.request(id: 4096, operation: operation, parameters: parameters)
            XCTAssertEqual(try FocusControlWire.payloadLength(framed.prefix(4)), framed.count - 4)
            let object = try JSONSerialization.jsonObject(with: framed.dropFirst(4)) as! [String: Any]
            XCTAssertEqual(Set(object.keys), Set(["version", "type", "id", "operation", "parameters"]))
            XCTAssertEqual(object["operation"] as? String, operation.rawValue)
            XCTAssertEqual(object["id"] as? Int, 4096)
        }
        for id in [0, -1, 4097, Int.max] {
            XCTAssertThrowsError(try FocusControlWire.request(id: id, operation: .heartbeat))
        }
        XCTAssertThrowsError(try FocusControlWire.request(id: 1, operation: "unknown"))
        XCTAssertThrowsError(try FocusControlWire.request(id: 1, operation: .capabilities, parameters: ["extra": true]))
        XCTAssertThrowsError(try FocusControlWire.request(id: 1, operation: .prepare))
        XCTAssertThrowsError(try FocusControlWire.request(id: 1, operation: .prepare, parameters: ["intent": "resume"]))
        XCTAssertThrowsError(try FocusControlWire.request(id: 1, operation: .stop, parameters: ["sessionId": session, "returnToDesktop": 1]))
        XCTAssertThrowsError(try FocusControlWire.request(id: 1, operation: .stop, parameters: ["sessionId": session.uppercased(), "returnToDesktop": true]))
        XCTAssertThrowsError(try FocusControlWire.request(id: 1, operation: .stop, parameters: ["sessionId": NSNull(), "returnToDesktop": Date()]))
    }

    func testEveryResultShapeAndCorrelation() throws {
        let cases: [(FocusControlWire.Operation, [String: Any])] = [
            (.capabilities, capabilities), (.requestPermission, ["granted": true, "reason": "none"]),
            (.prepare, prepare), (.stop, ["stopped": true, "desktopAllowed": false]),
            (.heartbeat, ["idleRemainingSeconds": 15, "sessionRemainingSeconds": 600])]
        for (operation, value) in cases {
            let data = try result(value)
            let decoded = try FocusControlWire.decode(data, expectedOperation: operation.rawValue)
            XCTAssertEqual(decoded["type"] as? String, "result")
            XCTAssertNoThrow(try FocusControlWire.decode(data))
            for other in FocusControlWire.Operation.allCases where other != operation {
                XCTAssertThrowsError(try FocusControlWire.decode(data, expectedOperation: other.rawValue))
            }
            var extra = value; extra["secret"] = "unexpected"
            XCTAssertThrowsError(try FocusControlWire.decode(result(extra)))
            for field in value.keys {
                var missing = value; missing.removeValue(forKey: field)
                XCTAssertThrowsError(try FocusControlWire.decode(result(missing)))
            }
        }
        for reason in ["denied", "timeout", "canceled"] {
            XCTAssertNoThrow(try FocusControlWire.decode(result(["granted": false, "reason": reason])))
        }
        XCTAssertThrowsError(try FocusControlWire.decode(result(["granted": true, "reason": "denied"])))
        XCTAssertThrowsError(try FocusControlWire.decode(result(["granted": false, "reason": "none"])))
        XCTAssertThrowsError(try FocusControlWire.decode(result(["stopped": false, "desktopAllowed": true])))
    }

    func testErrorsAndExactEnvelope() throws {
        for code in ["unsupported", "accessDisabled", "permissionRequired", "busy", "rateLimited", "wrongOwner", "invalidState",
                     "desktopStopTimeout", "setupTimeout", "runtimeStartFailed", "cleanupFailed", "interfaceChanged", "expired", "canceled"] {
            XCTAssertNoThrow(try FocusControlWire.decode(payload(["version": 1, "type": "error", "id": 4096, "code": code])))
        }
        let good: [String: Any] = ["version": 1, "type": "error", "id": 1, "code": "canceled"]
        for (key, value) in [("version", 2 as Any), ("version", true), ("id", false), ("id", 0), ("id", 4097),
                             ("type", "request"), ("code", "exception details"), ("extra", 1)] {
            var object = good; object[key] = value
            XCTAssertThrowsError(try FocusControlWire.decode(payload(object)))
        }
        XCTAssertThrowsError(try FocusControlWire.decode(payload(good), expectedOperation: "unknown"))
    }

    func testProgressOperationsAndSessionID() throws {
        for state in ["waitingForDesktop", "waitingForSystem", "qrPresented", "startingMedia", "mediaReady", "stopping", "stopped", "failed"] {
            XCTAssertNoThrow(try FocusControlWire.decode(progress(state, sessionID: session), expectedOperation: "focus.prepare"))
        }
        for state in ["awaitingPermission", "stopping", "stopped", "failed"] {
            let decoded = try FocusControlWire.decode(progress(state), expectedOperation: "focus.requestPermission")
            XCTAssertTrue(decoded["sessionId"] is NSNull)
        }
        XCTAssertNoThrow(try FocusControlWire.decode(progress("waitingForDesktop"), expectedOperation: "focus.prepare"))
        XCTAssertThrowsError(try FocusControlWire.decode(progress("awaitingPermission", sessionID: session)))
        XCTAssertThrowsError(try FocusControlWire.decode(progress("awaitingPermission"), expectedOperation: "focus.prepare"))
        XCTAssertThrowsError(try FocusControlWire.decode(progress("mediaReady"), expectedOperation: "focus.requestPermission"))
        XCTAssertThrowsError(try FocusControlWire.decode(progress("stopped"), expectedOperation: "focus.stop"))
        XCTAssertThrowsError(try FocusControlWire.decode(progress("connected")))
        for id: Any in ["", String(repeating: "A", count: 32), String(repeating: "a", count: 31), 123] {
            XCTAssertThrowsError(try FocusControlWire.decode(progress("stopped", sessionID: id)))
        }
    }

    func testStrictJSONRejectsDuplicateKeysIncludingEscapedAliases() {
        let invalid = [
            #"{"version":1,"version":1,"type":"error","id":1,"code":"busy"}"#,
            #"{"version":1,"\u0076ersion":1,"type":"error","id":1,"code":"busy"}"#,
            #"{"version":1,"type":"result","id":1,"result":{"granted":true,"granted":false,"reason":"none"}}"#,
            #"{"version":1,"type":"result","id":1,"result":{"granted":true,"\u0067ranted":true,"reason":"none"}}"#,
            #"{"version":1,"type":"result","id":1,"result":{"sessionId":"abababababababababababababababab","setupRemainingSeconds":1,"endpoint":{"address":"127.0.0.1","port":55000,"port":55000}}}"#]
        for json in invalid { XCTAssertThrowsError(try FocusControlWire.decode(Data(json.utf8)), json) }
    }

    func testStrictJSONRejectsNumericSpellingAndIntegerBooleans() throws {
        for token in ["true", "false", "1.0", "1e0", "NaN", "Infinity", "01", "+1", "9223372036854775808", "null", "\"1\""] {
            let json = "{\"version\":1,\"type\":\"error\",\"id\":\(token),\"code\":\"busy\"}"
            XCTAssertThrowsError(try FocusControlWire.decode(Data(json.utf8)), token)
        }
        XCTAssertThrowsError(try FocusControlWire.decode(result(["granted": 1, "reason": "none"])))
        for json in [
            #"{"version":1.0,"type":"error","id":1,"code":"busy"}"#,
            #"{"version":1,"type":"result","id":1,"result":{"idleRemainingSeconds":15,"sessionRemainingSeconds":1.0}}"#,
            #"{"version":1,"type":"result","id":1,"result":{"idleRemainingSeconds":15,"sessionRemainingSeconds":true}}"#] {
            XCTAssertThrowsError(try FocusControlWire.decode(Data(json.utf8)))
        }
    }

    func testMalformedUTF8SyntaxAndDeepInput() {
        for json in ["", "null", "[]", "{}", "{", #"{"version":1,"type":"error","id":1,"code":"busy",}"#,
                     #"{"version":1,"type":"error","id":1,"code":"busy"}{}"#,
                     #"{"version":1,"type":"error","id":1,"code":"\uD800"}"#,
                     String(repeating: "[", count: 3000) + "0" + String(repeating: "]", count: 3000)] {
            XCTAssertThrowsError(try FocusControlWire.decode(Data(json.utf8)))
        }
        var invalidUTF8 = Data(#"{"version":1,"type":"error","id":1,"code":""#.utf8)
        invalidUTF8.append(255); invalidUTF8.append(contentsOf: [34, 125])
        XCTAssertThrowsError(try FocusControlWire.decode(invalidUTF8))
        var embeddedNUL = Data(#"{"version":1,"type":"error","id":1,"code":"bu"#.utf8)
        embeddedNUL.append(0); embeddedNUL.append(contentsOf: Data(#"sy"}"#.utf8))
        XCTAssertThrowsError(try FocusControlWire.decode(embeddedNUL))
    }

    func testCapabilityAndPrepareFieldConstraints() throws {
        for (key, value) in [("focusAllowed", 1 as Any), ("mediaMode", "ready"), ("content", "desktop"),
                             ("systemTrust", "custom"), ("systemTrustPersistence", "persistent"),
                             ("mediaSecurity", "protected"), ("setupWindowSeconds", 181), ("sessionLimitSeconds", 601)] {
            var invalid = capabilities; invalid[key] = value
            XCTAssertThrowsError(try FocusControlWire.decode(result(invalid)))
        }
        for value: Any in [-1, 181, true, NSNull()] {
            var invalid = prepare; invalid["setupRemainingSeconds"] = value
            XCTAssertThrowsError(try FocusControlWire.decode(result(invalid)))
        }
        for endpoint: [String: Any] in [["address": "127.0.0.1", "port": 47991], ["address": "", "port": 55000],
                                       ["address": "127.0.0.1", "port": 55000, "token": "no"], ["port": 55000]] {
            var invalid = prepare; invalid["endpoint"] = endpoint
            XCTAssertThrowsError(try FocusControlWire.decode(result(invalid)))
        }
        for remaining in [-1, 601] {
            XCTAssertThrowsError(try FocusControlWire.decode(result(["idleRemainingSeconds": 15, "sessionRemainingSeconds": remaining])))
        }
    }
}
