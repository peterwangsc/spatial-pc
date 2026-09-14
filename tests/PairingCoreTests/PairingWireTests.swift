import XCTest
import CryptoKit
@testable import PairingCore

final class PairingWireTests: XCTestCase {
    func testWindowsReferenceVector() throws {
        let data = try Data(contentsOf:Bundle.module.url(forResource:"pairing-v1-test-vector",withExtension:"json")!)
        let vector = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        func b64(_ key:String) -> Data { Data(base64Encoded:vector[key] as! String)! }
        let challenge = PairingWire.Challenge(hostID:vector["hostId"] as! String,windowID:b64("windowId"),serverNonce:b64("serverNonce"))
        let transcript = try PairingWire.transcript(challenge:challenge,leafSHA256:PairingWire.hexBytes(vector["serverLeafSHA256"] as! String,count:32),clientNonce:b64("clientNonce"),publicKey:b64("publicKey"),name:vector["name"] as! String)
        XCTAssertEqual(transcript.map { String(format:"%02x",$0) }.joined(),vector["transcriptHex"] as? String)
        let secret = try PairingWire.code(vector["code"] as! String)
        XCTAssertEqual(try PairingWire.proof(secret:secret,transcript:transcript,server:false),b64("clientProof"))
        XCTAssertNoThrow(try PairingWire.verifyServer(b64("serverProof"),secret:secret,transcript:transcript))
        let publicKey = try P256.Signing.PublicKey(x963Representation:b64("publicKey"))
        let signature = try P256.Signing.ECDSASignature(derRepresentation:b64("signature"))
        XCTAssertTrue(publicKey.isValidSignature(signature,for:PairingWire.signatureMessage(transcript)))
    }
    func testCanonicalCode() throws {
        XCTAssertEqual(try PairingWire.code("AAAQEAYEAUDAOCAJBIFQYDIOB4"),Data(0..<16))
        XCTAssertEqual(try PairingWire.code("aaaqea-yeauda ocajbi-fqydio-b4"),Data(0..<16))
        for invalid in [String(repeating:" ",count:81)+"AAAQEAYEAUDAOCAJBIFQYDIOB4", "123456", "AAAQEAYEAUDAOCAJBIFQYDIOB5", "AAAQEAYEAUDAOCAJBIFQYDIOB4=", "AAAQEAYEAUDAOCAJBIFQYDIOB4\n"] {
            XCTAssertThrowsError(try PairingWire.code(invalid))
        }
    }
    func testFramingBounds() throws {
        let message = Data("{}".utf8), framed = try PairingWire.frame(message)
        XCTAssertEqual(framed,Data([83,80,80,49,0,0,0,2,123,125]))
        XCTAssertEqual(try PairingWire.payloadLength(framed.prefix(8)),2)
        XCTAssertThrowsError(try PairingWire.frame(Data()))
        XCTAssertThrowsError(try PairingWire.frame(Data(repeating:0,count:16_385)))
        XCTAssertThrowsError(try PairingWire.payloadLength(Data([83,80,80,49,0,0,0,0])))
    }
    func testStrictJSONRejectsAmbiguity() throws {
        let invalid = [
            #"{"version":1,"version":1,"type":"rejected"}"#,
            #"{"version":1,"\u0076ersion":1,"type":"rejected"}"#,
            #"{"version":true,"type":"rejected"}"#,
            #"{"version":1.0,"type":"rejected"}"#,
            #"{"version":1e0,"type":"rejected"}"#,
            #"{"version":1,"type":"rejected","extra":0}"#,
            #"{"version":1,"type":"rejected",}"#,
            #"{"version":1,"type":"rejected"}{}"#,
            #"{"version":1,"type":"rejected","x":{"a":0,"a":1}}"#
        ]
        for json in invalid { XCTAssertThrowsError(try PairingWire.decode(Data(json.utf8)),json) }
        if case .rejected = try PairingWire.decode(Data(#"{"version":1,"type":"rejected"}"#.utf8)) {} else { XCTFail() }
    }
    func testRoleAndTranscriptBinding() throws {
        let key = P256.Signing.PrivateKey()
        let challenge = PairingWire.Challenge(hostID:String(repeating:"ab",count:16),windowID:Data(repeating:1,count:16),serverNonce:Data(repeating:2,count:32))
        let transcript = try PairingWire.transcript(challenge:challenge,leafSHA256:Data(repeating:3,count:32),clientNonce:Data(repeating:4,count:32),publicKey:key.publicKey.x963Representation,name:"Vision Pro")
        let secret = Data(0..<16)
        let proof = try PairingWire.proof(secret:secret,transcript:transcript,server:true)
        XCTAssertNoThrow(try PairingWire.verifyServer(proof,secret:secret,transcript:transcript))
        XCTAssertThrowsError(try PairingWire.verifyServer(try PairingWire.proof(secret:secret,transcript:transcript,server:false),secret:secret,transcript:transcript))
        var changed = transcript; changed[24] ^= 1
        XCTAssertThrowsError(try PairingWire.verifyServer(proof,secret:secret,transcript:changed))
        XCTAssertThrowsError(try PairingWire.verifyServer(proof,secret:Data(repeating:0,count:16),transcript:transcript))
        let signature = try key.signature(for:PairingWire.signatureMessage(transcript))
        XCTAssertTrue(key.publicKey.isValidSignature(signature,for:PairingWire.signatureMessage(transcript)))
        XCTAssertFalse(key.publicKey.isValidSignature(signature,for:transcript))
    }
    func testChallengeAndIdentityBounds() throws {
        let json:[String:Any] = ["version":1,"type":"challenge","hostId":String(repeating:"ab",count:16),"windowId":Data(repeating:1,count:16).base64EncodedString(),"serverNonce":Data(repeating:2,count:32).base64EncodedString()]
        if case .challenge(let challenge) = try PairingWire.decode(JSONSerialization.data(withJSONObject:json)) { XCTAssertEqual(challenge.windowID.count,16) } else { XCTFail() }
        var invalid = json; invalid["windowId"] = "AA=="
        XCTAssertThrowsError(try PairingWire.decode(JSONSerialization.data(withJSONObject:invalid)))
        XCTAssertThrowsError(try PairingWire.validateName("bad\nname"))
        XCTAssertThrowsError(try PairingWire.validateName(String(repeating:"界",count:22)))
        XCTAssertThrowsError(try PairingWire.hexBytes("AB",count:1))
    }
}
