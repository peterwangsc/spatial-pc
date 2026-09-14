import UIKit

#if DEBUG
/// Input is scoped to this desktop view and positively negotiated by the host.
/// Hover alone never acquires control. No coordinates or key contents are logged.
@MainActor final class DesktopInputController: NSObject {
    private weak var view: UIView?
    private let stream: LabStreamClient
    private var keyboard = InputWire.KeyboardState()
    private var buttons = Set<Int32>()
    private var wheelRemainder = CGPoint.zero
    var available: Bool { stream.inputAvailable && stream.hasFrames }
    var textAvailable: Bool { stream.textAvailable && available }
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
        keyboard = InputWire.KeyboardState(); buttons.removeAll(); wheelRemainder = .zero
        stream.stopControl()
    }
    private func start() -> Bool {
        guard available else { return false }
        if !stream.controlling { keyboard = InputWire.KeyboardState(); buttons.removeAll(); wheelRemainder = .zero }
        guard stream.startControl() else { return false }
        view?.becomeFirstResponder(); return true
    }
    func keyboardFocusChanged(_ focused:Bool) { stream.recordKeyboardFocus(focused) }
    func keyboardPresentationChanged(_ requested:Bool) { stream.recordKeyboardPresentation(requested) }
    func activateKeyboard() -> Bool { start() }
    func insertText(_ text:String) {
        stream.recordTextCallback()
        guard textAvailable,view?.isFirstResponder == true,start() else { return }
        do { for event in try InputWire.textEvents(text) { stream.sendInput(event) } }
        catch { stop() }
    }
    func deleteBackward() {
        stream.recordTextCallback()
        guard textAvailable,view?.isFirstResponder == true,start() else { return }
        stream.sendInput(.key(0x2A,down:true)); stream.sendInput(.key(0x2A,down:false))
    }
    @objc private func hovered(_ gesture:UIHoverGestureRecognizer) {
        guard let view else { return }
        if gesture.state == .ended || gesture.state == .cancelled {
            // Release remote holds on pointer exit, but keep the native text
            // responder available to its separate system keyboard window.
            stop(); return
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
        wheelRemainder.x = min(1200,max(-1200,wheelRemainder.x-delta.x))
        wheelRemainder.y = min(1200,max(-1200,wheelRemainder.y+delta.y))
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
        if let event { for change in keyboard.reconcile(Self.modifiers(event.modifierFlags)) { stream.sendInput(change) } }
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
    private static func modifiers(_ flags:UIKeyModifierFlags) -> UInt8 {
        var result: UInt8 = 0
        for (index,flag) in [UIKeyModifierFlags.control,.shift,.alternate,.command].enumerated() {
            if flags.contains(flag) { result |= 1 << index }
        }
        return result
    }
    func navigationKeyCommand(_ command:UIKeyCommand) {
        guard view?.isFirstResponder == true, available,
              command.input == " " || command.input == "\t", start() else { return }
        stream.recordNavigationKeyCommand()
        let usage:Int32 = command.input == " " ? 0x2C : 0x2B
        let flags = Self.modifiers(command.modifierFlags)
        do {
            // A command has no key-up callback; send one balanced HID tap.
            for event in try keyboard.change(usage,down:true,modifiers:flags)
                + keyboard.change(usage,down:false,modifiers:flags) { stream.sendInput(event) }
        } catch { stop() }
    }
    func presses(_ presses:Set<UIPress>,down:Bool) -> Bool {
        stream.recordKeyPresses(presses.count)
        guard view?.isFirstResponder == true else { return false }
        // Modifiers first when UIKit delivers a set of simultaneous presses.
        let ordered = presses.compactMap(\.key).sorted { a,b in
            let am = a.keyCode.rawValue >= 0xE0,bm = b.keyCode.rawValue >= 0xE0
            return am != bm ? am : a.keyCode.rawValue < b.keyCode.rawValue
        }
        // Events without physical HID information must continue through UIKit's
        // text system, which can deliver a committed insertText callback.
        guard !ordered.isEmpty else { return false }
        if down { guard start() else { return false } }
        guard stream.controlling else { return true }
        for key in ordered {
            let usage = Int32(key.keyCode.rawValue)
            do {
                for change in try keyboard.change(usage,down:down,modifiers:Self.modifiers(key.modifierFlags)) {
                    stream.sendInput(change)
                }
            } catch { stop(); return true }
        }
        return true
    }
}
#endif
