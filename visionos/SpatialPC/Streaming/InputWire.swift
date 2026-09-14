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
            case 8: guard flags == 0,allowedScalar(a),b == 0,c == 0 else { throw Failure.invalid }
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
    static func allowedScalar(_ value:Int32) -> Bool {
        (0x20...0x10FFFF).contains(value) && !(0x7F...0x9F).contains(value) && !(0xD800...0xDFFF).contains(value)
    }
    /// Committed text only, with a bounded batch. Never infer a Windows layout.
    static func textEvents(_ text:String) throws -> [Event] {
        var events = [Event]()
        var carriageReturn = false
        for scalar in text.unicodeScalars {
            let value = Int32(scalar.value)
            if value == 10 && carriageReturn { carriageReturn = false; continue }
            carriageReturn = value == 13
            if value == 10 || value == 13 || value == 9 {
                let key:Int32 = value == 9 ? 0x2B : 0x28
                events += [.key(key,down:true),.key(key,down:false)]
            } else {
                guard allowedScalar(value) else { throw Failure.invalid }
                events.append(Event(type:8,a:value))
            }
            guard events.count <= 64 else { throw Failure.overflow }
        }
        return events
    }
    static func coordinate(_ value:Double,extent:Double) -> Int32? {
        guard value.isFinite,extent.isFinite,extent > 0 else { return nil }
        return Int32((min(1,max(0,value/extent))*65535).rounded())
    }
    struct KeyboardState {
        private(set) var held = Set<Int32>()
        private var inferred = Set<Int32>()
        // Portable bits: control, shift, alt, GUI. Explicit HID events preserve sides.
        mutating func reconcile(_ mask:UInt8) -> [Event] {
            var result = [Event]()
            for bit in 0..<4 {
                let left = Int32(0xE0+bit),right = left+4
                if mask & (1 << bit) != 0 {
                    if !held.contains(left),!held.contains(right) {
                        held.insert(left); inferred.insert(left); result.append(.key(left,down:true))
                    }
                } else {
                    for key in [left,right] where held.remove(key) != nil {
                        inferred.remove(key); result.append(.key(key,down:false))
                    }
                }
            }
            return result
        }
        mutating func change(_ usage:Int32,down:Bool,modifiers:UInt8) throws -> [Event] {
            guard allowedKey(usage) else { return [] }
            let modifier = usage >= 0xE0
            var result = modifier ? [] : reconcile(modifiers)
            let alreadyHeld = held.contains(usage)
            if down {
                if alreadyHeld {
                    if modifier { inferred.remove(usage) }
                    if !modifier { result.append(.key(usage,down:true,repeated:true)) }
                    return result
                }
                guard held.count < 40,modifier || held.filter({ $0 < 0xE0 }).count < 32 else { throw Failure.overflow }
                held.insert(usage); inferred.remove(usage); result.append(.key(usage,down:true))
            } else if held.remove(usage) != nil {
                inferred.remove(usage); result.append(.key(usage,down:false))
            }
            if modifier {
                // A modifier held before control started has an inferred left side.
                // Its later explicit right-side release must also release that fallback.
                let group = (usage-0xE0)%4
                for key in inferred.sorted() where (key-0xE0)%4 == group {
                    held.remove(key); inferred.remove(key); result.append(.key(key,down:false))
                }
            }
            return result
        }
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
