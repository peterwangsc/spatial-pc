import XCTest
@testable import StreamCore

final class InputWireTests: XCTestCase {
    func testKnownWireRecordAndSignedWheel() throws {
        let record = try InputWire.Event.button(2,down:true,x:65535,y:123).encoded(sequence:1)
        XCTAssertEqual(Array(record),[0x53,0x50,0x49,0x31,2,1,0,0,0,0,0,1,0,0,255,255,0,0,0,123,0,0,0,2])
        let wheel = try InputWire.Event(type:3,a:-120,b:240).encoded(sequence:2)
        XCTAssertEqual(Array(wheel[12..<20]),[255,255,255,136,0,0,0,240])
    }
    func testMovementCannotCrossClickAndStopDiscardsPendingInput() throws {
        var box = InputWire.Outbox()
        try box.append(.start)
        try box.append(.position(x:1,y:2));try box.append(.position(x:3,y:4))
        try box.append(.button(1,down:true,x:3,y:4))
        try box.append(.position(x:5,y:6));try box.append(.position(x:7,y:8))
        XCTAssertEqual(box.events.map(\.type),[5,1,2,1])
        XCTAssertEqual(box.events[1].a,3);XCTAssertEqual(box.events[3].a,7)
        XCTAssertEqual(try box.take().count,48);XCTAssertEqual(box.sequence,2)
        try box.append(.stop)
        XCTAssertEqual(box.events,[.stop]);XCTAssertEqual(try box.take().count,24)
        XCTAssertEqual(box.sequence,3)
    }
    func testBoundsAndUnsupportedKeysFailClosed() throws {
        for event in [InputWire.Event.position(x:-1,y:0),.position(x:0,y:65536),
                      .button(4,down:true,x:0,y:0),.init(type:3,a:1201),
                      .key(0x46,down:true),.key(0x04,down:false,repeated:true),.init(type:8)] {
            XCTAssertThrowsError(try event.encoded(sequence:1))
        }
        XCTAssertThrowsError(try InputWire.Event.start.encoded(sequence:0))
        var box = InputWire.Outbox()
        for _ in 0..<128 { try box.append(.heartbeat) }
        XCTAssertThrowsError(try box.append(.heartbeat))
        try box.append(.stop);XCTAssertEqual(box.events,[.stop])
    }
    func testCoordinateClampingAndInvalidGeometry() {
        XCTAssertEqual(InputWire.coordinate(0,extent:100),0)
        XCTAssertEqual(InputWire.coordinate(50,extent:100),32768)
        XCTAssertEqual(InputWire.coordinate(150,extent:100),65535)
        XCTAssertEqual(InputWire.coordinate(-10,extent:100),0)
        XCTAssertNil(InputWire.coordinate(.nan,extent:100))
        XCTAssertNil(InputWire.coordinate(20,extent:0))
    }
    func testInputMustBePositivelyNegotiated() throws {
        let prefix = "{\"version\":1,\"codec\":\"h264-annexb\",\"width\":1920,\"height\":1080,\"fps\":60,\"hardwareEncoder\":true"
        let old = try StreamWire.capabilities(Data((prefix+"}").utf8))
        XCTAssertNil(old.input)
        let future = try StreamWire.capabilities(Data((prefix+",\"input\":{\"version\":2}}").utf8))
        XCTAssertEqual(future.input?.supported,false)
        let current = try StreamWire.capabilities(Data((prefix+",\"input\":{\"version\":1,\"enabled\":true,\"wire\":\"SPI1\",\"recordBytes\":24,\"maxEventsPerSecond\":240,\"heartbeatMS\":500,\"leaseMS\":2000}}").utf8))
        XCTAssertEqual(current.input?.supported,true)
        XCTAssertEqual(current.input?.supportsText,false)
        let textJSON = prefix+",\"input\":{\"version\":1,\"enabled\":true,\"wire\":\"SPI1\",\"recordBytes\":24,\"maxEventsPerSecond\":240,\"heartbeatMS\":500,\"leaseMS\":2000,\"textVersion\":1}}"
        XCTAssertEqual(try StreamWire.capabilities(Data(textJSON.utf8)).input?.supportsText,true)
        XCTAssertEqual(try StreamWire.capabilities(Data(textJSON.replacingOccurrences(of:"\"textVersion\":1",with:"\"textVersion\":99").utf8)).input?.supportsText,false)
    }
    func testModifierHeldBeforeControlIsReleasedByItsPhysicalSide() throws {
        var keyboard = InputWire.KeyboardState()
        XCTAssertEqual(keyboard.reconcile(1),[.key(0xE0,down:true)])
        XCTAssertEqual(try keyboard.change(0xE4,down:false,modifiers:0),[.key(0xE0,down:false)])
        XCTAssertTrue(keyboard.held.isEmpty)
        _ = try keyboard.change(0xE0,down:true,modifiers:0)
        _ = try keyboard.change(0xE4,down:true,modifiers:1)
        XCTAssertEqual(try keyboard.change(0xE4,down:false,modifiers:1),[.key(0xE4,down:false)])
        XCTAssertEqual(keyboard.held,[0xE0])
        keyboard = InputWire.KeyboardState()
        _ = keyboard.reconcile(1)
        _ = try keyboard.change(0xE0,down:true,modifiers:1)
        _ = try keyboard.change(0xE4,down:true,modifiers:1)
        _ = try keyboard.change(0xE4,down:false,modifiers:1)
        XCTAssertEqual(keyboard.held,[0xE0])
    }
    func testKeyRepeatAndHeldKeyBound() throws {
        var keyboard = InputWire.KeyboardState()
        XCTAssertEqual(try keyboard.change(4,down:true,modifiers:2),[.key(0xE1,down:true),.key(4,down:true)])
        XCTAssertEqual(try keyboard.change(4,down:true,modifiers:2),[.key(4,down:true,repeated:true)])
        XCTAssertEqual(try keyboard.change(4,down:false,modifiers:0),[.key(0xE1,down:false),.key(4,down:false)])
        XCTAssertTrue(keyboard.held.isEmpty)
        for key:Int32 in 4..<36 { _ = try keyboard.change(key,down:true,modifiers:0) }
        XCTAssertThrowsError(try keyboard.change(36,down:true,modifiers:0))
    }
    func testCommittedUnicodeAndNewlines() throws {
        let events = try InputWire.textEvents("Aé🙂\r\n\t")
        XCTAssertEqual(events,[.init(type:8,a:65),.init(type:8,a:233),.init(type:8,a:0x1F642),
                               .key(0x28,down:true),.key(0x28,down:false),.key(0x2B,down:true),.key(0x2B,down:false)])
        let bytes = try events[2].encoded(sequence:9)
        XCTAssertEqual(Array(bytes[12..<16]),[0,1,0xF6,0x42])
        XCTAssertEqual(bytes.count,24)
    }
    func testCommittedTextBoundsAndInvalidScalars() throws {
        for scalar:Int32 in [-1,0,0x1F,0x7F,0x85,0x9F,0xD800,0xDFFF,0x110000] {
            XCTAssertThrowsError(try InputWire.Event(type:8,a:scalar).encoded(sequence:1))
        }
        for scalar:Int32 in [0x20,0x7E,0xA0,0xD7FF,0xE000,0x10FFFF] {
            XCTAssertNoThrow(try InputWire.Event(type:8,a:scalar).encoded(sequence:1))
        }
        XCTAssertThrowsError(try InputWire.textEvents("a\u{1B}b"))
        XCTAssertThrowsError(try InputWire.textEvents(String(repeating:"a",count:65)))
        XCTAssertEqual(try InputWire.textEvents(String(repeating:"a",count:64)).count,64)
        XCTAssertThrowsError(try InputWire.textEvents(String(repeating:"\n",count:33)))
    }

}
