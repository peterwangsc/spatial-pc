import UIKit

#if DEBUG
/// Input is scoped to this desktop view and positively negotiated by the host.
/// Hover alone never acquires control. No coordinates or key contents are logged.
@MainActor final class DesktopInputController: NSObject {
    private weak var view: UIView?
    private let stream: LabStreamClient
    private var keys = Set<Int32>()
    private var buttons = Set<Int32>()
    private var wheelRemainder = CGPoint.zero
    var available: Bool { stream.inputAvailable && stream.hasFrames }
    init(view:UIView,stream:LabStreamClient) {
        self.view = view; self.stream = stream
        super.init()
        let hover = UIHoverGestureRecognizer(target:self,action:#selector(hovered))
        view.addGestureRecognizer(hover)
        let scroll = UIPanGestureRecognizer(target:self,action:#selector(scrolled))
        scroll.allowedScrollTypesMask = [.continuous,.discrete]
        scroll.allowedTouchTypes = []; scroll.cancelsTouchesInView = false
        view.addGestureRecognizer(scroll)
    }
    private func position(_ point:CGPoint) -> (Int32,Int32)? {
        guard let view,
              let x = InputWire.coordinate(Double(point.x-view.bounds.minX),extent:Double(view.bounds.width)),
              let y = InputWire.coordinate(Double(point.y-view.bounds.minY),extent:Double(view.bounds.height)) else { return nil }
        return (x,y)
    }
    func stop() {
        keys.removeAll(); buttons.removeAll(); wheelRemainder = .zero
        stream.stopControl()
    }
    private func start() -> Bool {
        guard available else { return false }
        if !stream.controlling { keys.removeAll(); buttons.removeAll(); wheelRemainder = .zero }
        guard stream.startControl() else { return false }
        view?.becomeFirstResponder(); return true
    }
    @objc private func hovered(_ gesture:UIHoverGestureRecognizer) {
        guard let view else { return }
        if gesture.state == .ended || gesture.state == .cancelled {
            stop(); view.resignFirstResponder(); return
        }
        guard stream.controlling,let (x,y) = position(gesture.location(in:view)) else { return }
        stream.sendInput(.position(x:x,y:y))
    }
    @objc private func scrolled(_ gesture:UIPanGestureRecognizer) {
        guard let view,stream.controlling else { return }
        let delta = gesture.translation(in:view); gesture.setTranslation(.zero,in:view)
        guard delta.x.isFinite,delta.y.isFinite else { stop(); return }
        // UIKit translations follow content movement: down is wheel-up, left is
        // wheel-right. Preserve fractional trackpad movement between events.
        wheelRemainder.x -= delta.x; wheelRemainder.y += delta.y
        let horizontal = Int32(min(1200,max(-1200,wheelRemainder.x.rounded(.towardZero))))
        let vertical = Int32(min(1200,max(-1200,wheelRemainder.y.rounded(.towardZero))))
        wheelRemainder.x -= CGFloat(horizontal); wheelRemainder.y -= CGFloat(vertical)
        if horizontal != 0 || vertical != 0 { stream.sendInput(.init(type:3,a:vertical,b:horizontal)) }
    }
    func touches(_ touches:Set<UITouch>,event:UIEvent?,phase:UITouch.Phase) {
        guard let view,let touch = touches.first,let (x,y) = position(touch.location(in:view)) else { return }
        if phase == .cancelled { stop(); return }
        if phase == .began { guard start() else { return } }
        guard stream.controlling else { return }
        if let event { reconcileModifiers(event.modifierFlags) }
        if phase == .moved { stream.sendInput(.position(x:x,y:y)) }
        var wanted = Set<Int32>()
        if touch.type == .indirectPointer {
            let mask = event?.buttonMask ?? []
            if mask.contains(.primary) { wanted.insert(1) }
            if mask.contains(.secondary) { wanted.insert(2) }
            if mask.rawValue & 4 != 0 { wanted.insert(3) }
        } else if phase != .ended { wanted.insert(1) }
        // Only this view's tracked buttons are released; never synthesize global ups.
        for button in buttons.subtracting(wanted).sorted() { stream.sendInput(.button(button,down:false,x:x,y:y)) }
        for button in wanted.subtracting(buttons).sorted() { stream.sendInput(.button(button,down:true,x:x,y:y)) }
        buttons = wanted
    }
    private func reconcileModifiers(_ flags:UIKeyModifierFlags) {
        let groups:[(UIKeyModifierFlags,Int32,Int32)] = [(.control,0xE0,0xE4),(.shift,0xE1,0xE5),(.alternate,0xE2,0xE6),(.command,0xE3,0xE7)]
        for (flag,left,right) in groups {
            if flags.contains(flag) {
                if !keys.contains(left),!keys.contains(right) { keys.insert(left); stream.sendInput(.key(left,down:true)) }
            } else {
                for key in [left,right] where keys.remove(key) != nil { stream.sendInput(.key(key,down:false)) }
            }
        }
    }
    func presses(_ presses:Set<UIPress>,down:Bool) -> Bool {
        guard stream.controlling,view?.isFirstResponder == true else { return false }
        // Modifiers first when UIKit delivers a set of simultaneous presses.
        let ordered = presses.compactMap(\.key).sorted { a,b in
            let am = a.keyCode.rawValue >= 0xE0,bm = b.keyCode.rawValue >= 0xE0
            return am != bm ? am : a.keyCode.rawValue < b.keyCode.rawValue
        }
        for key in ordered {
            let usage = Int32(key.keyCode.rawValue)
            guard InputWire.allowedKey(usage) else { continue }
            if !(0xE0...0xE7).contains(usage) { reconcileModifiers(key.modifierFlags) }
            let held = keys.contains(usage)
            if down {
                let ordinaryCount = keys.filter { $0 < 0xE0 }.count
                guard held || ((usage >= 0xE0 || ordinaryCount < 32) && keys.count < 40) else { stop(); return true }
                keys.insert(usage); stream.sendInput(.key(usage,down:true,repeated:held))
            } else if keys.remove(usage) != nil { stream.sendInput(.key(usage,down:false)) }
        }
        return true
    }
}
#endif
