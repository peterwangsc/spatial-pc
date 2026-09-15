import XCTest
import CryptoKit
@testable import PairingCore

final class PairingV2Tests:XCTestCase {
    func testIndependentWindowsTranscriptHKDFAndSignatureVector() throws {
        let data = try Data(contentsOf:Bundle.module.url(forResource:"pairing-v2-test-vector",withExtension:"json")!)
        let v = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        func bytes(_ key:String) -> Data { Data(base64Encoded:v[key] as! String)! }
        let context = try PairingV2Wire.hexBytes(v["contextHex"] as! String,count:96)
        let t = try PairingV2Wire.transcript(context:context,clientNonce:bytes("clientNonce"),publicKey:bytes("publicKey"),
            name:v["name"] as! String,clientMessage:bytes("clientMessage"),serverMessage:bytes("serverMessage"))
        XCTAssertEqual(t.map { String(format:"%02x",$0) }.joined(),v["transcriptHex"] as? String)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial:SymmetricKey(data:try PairingV2Wire.hexBytes(v["fixtureSharedKeyHex"] as! String,count:64)),
            salt:Data(SHA256.hash(data:t)),info:Data("SpatialPC-Pair-v2/confirm\0".utf8),outputByteCount:32)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) },try PairingV2Wire.hexBytes(v["confirmationKeyHex"] as! String,count:32))
        XCTAssertEqual(PairingV2Wire.proof(key:key,transcript:t,server:false),bytes("clientProof"))
        XCTAssertNoThrow(try PairingV2Wire.verifyServer(bytes("serverProof"),key:key,transcript:t))
        let point = try P256.Signing.PublicKey(x963Representation:bytes("publicKey"))
        let signature = try P256.Signing.ECDSASignature(derRepresentation:bytes("signature"))
        XCTAssertTrue(point.isValidSignature(signature,for:PairingV2Wire.signatureMessage(t)))
    }
    func testFourDigitCodeIncludingLeadingZeros() throws {
        for value in ["0000","0042","9999"] { XCTAssertEqual(try PairingV2Wire.code(value),Data(value.utf8)) }
        for value in ["", "123", "12345", "12-34", " 1234", "１２３４", "12a4", "1234\n"] {
            XCTAssertThrowsError(try PairingV2Wire.code(value))
        }
    }
    func testBudgetCannotResetOnPeerChangesOrRetyping() throws {
        var budget = PairingAttemptBudget()
        try budget.consume(now:10); try budget.consume(now:11); try budget.consume(now:12)
        XCTAssertThrowsError(try budget.consume(now:13))
        XCTAssertThrowsError(try budget.consume(now:189.99))
        XCTAssertNoThrow(try budget.consume(now:190))
    }
    func testMutualConfirmationAndTerminalContext() throws {
        let names = try PairingV2Wire.names(context:Data(repeating:7,count:96))
        let a = try PairingPAKE(pin:Data("0042".utf8),clientName:names.client,serverName:names.server)
        let b = try PairingPAKE(pin:Data("0042".utf8),clientName:names.client,serverName:names.server,client:false)
        let t = Data("public test transcript".utf8)
        let ak = try a.confirmationKey(peerMessage:b.message,transcript:t)
        let bk = try b.confirmationKey(peerMessage:a.message,transcript:t)
        XCTAssertNoThrow(try PairingV2Wire.verifyServer(PairingV2Wire.proof(key:bk,transcript:t,server:true),key:ak,transcript:t))
        XCTAssertThrowsError(try PairingV2Wire.verifyServer(PairingV2Wire.proof(key:bk,transcript:t,server:false),key:ak,transcript:t))
        XCTAssertThrowsError(try a.confirmationKey(peerMessage:b.message,transcript:t))
    }
    func testWrongPINAndTerminatingProxyCannotConfirm() throws {
        for alteredPIN in [false,true] {
            let c = Data(repeating:7,count:96)
            var other = c
            if !alteredPIN { other[0] ^= 1 } // Actual TLS leaf hash differs at proxy.
            let an = try PairingV2Wire.names(context:c), bn = try PairingV2Wire.names(context:other)
            let a = try PairingPAKE(pin:Data("0042".utf8),clientName:an.client,serverName:an.server)
            let b = try PairingPAKE(pin:Data((alteredPIN ? "0043" : "0042").utf8),clientName:bn.client,serverName:bn.server,client:false)
            let ak = try a.confirmationKey(peerMessage:b.message,transcript:c)
            let bk = try b.confirmationKey(peerMessage:a.message,transcript:other)
            XCTAssertThrowsError(try PairingV2Wire.verifyServer(PairingV2Wire.proof(key:bk,transcript:other,server:true),key:ak,transcript:c))
        }
    }
    func testProofBindsEnrollmentFields() throws {
        let k = P256.Signing.PrivateKey()
        let c = Data(repeating:7,count:96)
        let t = try PairingV2Wire.transcript(context:c,clientNonce:Data(repeating:8,count:32),publicKey:k.publicKey.x963Representation,
            name:"Vision Pro",clientMessage:Data(repeating:9,count:32),serverMessage:Data(repeating:10,count:32))
        let key = SymmetricKey(data:Data(0..<32))
        let proof = PairingV2Wire.proof(key:key,transcript:t,server:true)
        for offset in [20,115,150,t.count-1] {
            var changed = t; changed[offset] ^= 1
            XCTAssertThrowsError(try PairingV2Wire.verifyServer(proof,key:key,transcript:changed))
        }
        let signature = try k.signature(for:PairingV2Wire.signatureMessage(t))
        XCTAssertTrue(k.publicKey.isValidSignature(signature,for:PairingV2Wire.signatureMessage(t)))
        XCTAssertFalse(k.publicKey.isValidSignature(signature,for:t))
    }
    func testV1DowngradeAndMalformedMessagesReject() throws {
        XCTAssertThrowsError(try PairingV2Wire.payloadLength(Data([83,80,80,49,0,0,0,2])))
        XCTAssertEqual(try PairingV2Wire.payloadLength(Data([83,80,80,50,0,0,0,2])),2)
        for json in [#"{"version":1,"type":"rejected"}"#, #"{"version":2,"version":2,"type":"rejected"}"#,
                     #"{"version":2.0,"type":"rejected"}"#, #"{"version":2,"type":"pending","serverProof":"AA=="}"#] {
            XCTAssertThrowsError(try PairingV2Wire.decode(Data(json.utf8)))
        }
    }
}
