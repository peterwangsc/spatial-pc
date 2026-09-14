import XCTest
@testable import StreamCore

final class StreamWireTests: XCTestCase {
    func testRejectsMalformedAndOversizeHeaders() throws {
        XCTAssertThrowsError(try StreamWire.helloLength(Data("NOPE0000".utf8)))
        XCTAssertThrowsError(try StreamWire.helloLength(Data([83,80,67,49,0,1,0,0])))
        XCTAssertThrowsError(try StreamWire.frameHeader(Data(repeating:255,count:16)))
        XCTAssertThrowsError(try StreamWire.frameHeader(Data(repeating:0,count:16)))
    }
    func testMixedNALPrefixesAndLengthEncoding() throws {
        let units = try StreamWire.annexBUnits(Data([0,0,0,1,0x67,42,0,0,1,0x68,43,0,0,0,1,0x65,44]))
        XCTAssertEqual(units, [Data([0x67,42]),Data([0x68,43]),Data([0x65,44])])
        XCTAssertEqual(StreamWire.avcc(units).prefix(6),Data([0,0,0,2,0x67,42]))
        XCTAssertThrowsError(try StreamWire.annexBUnits(Data([1,2,3])))
        XCTAssertThrowsError(try StreamWire.annexBUnits(Data([0,0,1,0x80])))
        XCTAssertThrowsError(try StreamWire.annexBUnits(Data([0,0,1])))
    }
    func testUnsupportedCapabilities() throws {
        func message(_ version:Int=1,_ codec:String="h264-annexb",_ width:Int=1920)->Data {
            Data("{\"version\":\(version),\"codec\":\"\(codec)\",\"width\":\(width),\"height\":1080,\"fps\":60,\"hardwareEncoder\":true}".utf8)
        }
        XCTAssertEqual(try StreamWire.capabilities(message()).width,1920)
        XCTAssertThrowsError(try StreamWire.capabilities(message(2)))
        XCTAssertThrowsError(try StreamWire.capabilities(message(1,"unknown")))
        XCTAssertThrowsError(try StreamWire.capabilities(message(1,"h264-annexb",Int.max)))
    }
}
