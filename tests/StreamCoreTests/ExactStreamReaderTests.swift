import XCTest
@testable import StreamCore

final class ExactStreamReaderTests: XCTestCase {
    private func read(_ size:Int,next:(Int) async throws -> Data) async throws -> Data {
        var buffer = try ExactStreamReader(size)
        while buffer.remaining > 0 { try buffer.append(await next(buffer.remaining)) }
        return buffer.data
    }
    func testCompleteDeliveryAndRecordBoundary() async throws {
        let payload = Data(repeating:0xAB,count:32768)
        var calls = 0
        let result = try await read(payload.count) { requested in
            XCTAssertEqual(requested,payload.count); calls += 1; return payload
        }
        XCTAssertEqual(result,payload); XCTAssertEqual(calls,1)
    }
    func testEveryFragmentationBoundary() async throws {
        let payload = Data(0..<64)
        for split in 1..<payload.count {
            var parts = [Data(payload.prefix(split)),Data(payload.dropFirst(split))]
            var requests = [Int]()
            let result = try await read(payload.count) { count in
                requests.append(count); return parts.removeFirst()
            }
            XCTAssertEqual(result,payload)
            XCTAssertEqual(requests,[64,64-split])
        }
    }
    func testSingleByteFragments() async throws {
        var next:UInt8 = 0
        let result = try await read(64) { count in
            XCTAssertEqual(count,64-Int(next)); defer { next += 1 }; return Data([next])
        }
        XCTAssertEqual(result,Data(0..<64))
    }
    func testEOFDoesNotReturnTruncatedRecord() async {
        var calls = 0
        do {
            _ = try await read(8) { _ in calls += 1; return calls == 1 ? Data([1,2]) : Data() }
            XCTFail("Truncated record accepted")
        } catch is ExactStreamReader.Failure {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls,2)
    }
    func testRejectsInvalidSizeBeforeReadAndExcessDelivery() async {
        for size in [0,-1,StreamWire.maximumFrameBytes+1] {
            do { _ = try await read(size) { _ in XCTFail("Invalid read issued"); return Data() }; XCTFail("Invalid size accepted") }
            catch is StreamWire.Invalid {} catch { XCTFail("Unexpected error") }
        }
        do { _ = try await read(2) { _ in Data([1,2,3]) }; XCTFail("Overflow accepted") }
        catch is StreamWire.Invalid {} catch { XCTFail("Unexpected error") }
    }
    func testTransportErrorPreserved() async {
        enum TransportError:Error { case injected }
        do { _ = try await read(8) { _ in throw TransportError.injected }; XCTFail("Error swallowed") }
        catch TransportError.injected {} catch { XCTFail("Unexpected error") }
    }
}
