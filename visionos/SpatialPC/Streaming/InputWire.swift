import Foundation

/// Fixed-size, versioned input records. No text, commands, or device paths.
enum InputWire {
    enum Failure: Error { case invalid, overflow }
    struct Event: Equatable, Sendable {
        let type: UInt8
        var flags: UInt8 = 0
        var a: Int32 = 0
        var b: Int32 = 0
        var c: Int32 = 0
        static let start = Event(type:5), stop = Event(type:6), heartbeat = Event(type:7)
        static func position(x:Int32,y:Int32) -> Event { Event(type:1,a:x,b:y) }
        static func button(_ button:Int32,down:Bool,x:Int32,y:Int32) -> Event {
            Event(type:2,flags:down ? 1 : 0,a:x,b:y,c:button)
        }
        static func key(_ usage:Int32,down:Bool,repeated:Bool = false) -> Event {
            Event(type:4,flags:(down ? 1 : 0) | (repeated ? 2 : 0),a:usage)
        }
        func validate() throws {
            let point = (0...65535).contains(a) && (0...65535).contains(b)
            switch type {
            case 1: guard flags == 0,point,c == 0 else { throw Failure.invalid }
            case 2: guard flags <= 1,point,(1...3).contains(c) else { throw Failure.invalid }
            case 3: guard flags == 0,(-1200...1200).contains(a),(-1200...1200).contains(b),c == 0 else { throw Failure.invalid }
            case 4: guard [UInt8(0),1,3].contains(flags),allowedKey(a),b == 0,c == 0 else { throw Failure.invalid }
            case 5...7: guard flags == 0,a == 0,b == 0,c == 0 else { throw Failure.invalid }
            default: throw Failure.invalid
            }
        }
        func encoded(sequence:UInt32) throws -> Data {
            try validate(); guard sequence > 0 else { throw Failure.invalid }
            var result = Data([0x53,0x50,0x49,0x31,type,flags,0,0])
            for value in [sequence,UInt32(bitPattern:a),UInt32(bitPattern:b),UInt32(bitPattern:c)] {
                var network = value.bigEndian
                withUnsafeBytes(of:&network) { result.append(contentsOf:$0) }
            }
            return result
        }
    }
    static func allowedKey(_ key:Int32) -> Bool {
        (0x04...0x45).contains(key) || (0x49...0x65).contains(key) || (0xE0...0xE7).contains(key)
    }
    static func coordinate(_ value:Double,extent:Double) -> Int32? {
        guard value.isFinite,extent.isFinite,extent > 0 else { return nil }
        return Int32((min(1,max(0,value/extent))*65535).rounded())
    }
    struct Outbox {
        private(set) var events = [Event]()
        private(set) var sequence: UInt32 = 0
        mutating func append(_ event:Event) throws {
            try event.validate()
            if event.type == 6 { events = [event]; return }
            if event.type == 1,events.last?.type == 1 { events[events.count-1] = event; return }
            guard events.count < 128 else { throw Failure.overflow }
            events.append(event)
        }
        mutating func take(_ count:Int = 2) throws -> Data {
            var data = Data()
            for _ in 0..<min(count,events.count) {
                guard sequence < UInt32.max else { throw Failure.overflow }
                sequence += 1; data.append(try events.removeFirst().encoded(sequence:sequence))
            }
            return data
        }
    }
}
