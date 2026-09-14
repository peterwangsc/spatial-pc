import SwiftUI

#if DEBUG
struct DesktopKeyboardButton: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    var body: some View {
        Button { model.keyboardRequest += 1 } label: {
            Image(systemName:"keyboard")
                .font(.title3.weight(.semibold))
                .frame(width:52,height:52)
                .background(.thinMaterial,in:Circle())
                .hoverEffect { effect,isActive,_ in
                    effect.opacity(isActive || voiceOverEnabled ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .contentShape([.interaction,.hoverEffect],Rectangle())
        .hoverEffect(.highlight)
        .hoverEffectGroup()
        .accessibilityLabel("Toggle Keyboard")
        .disabled(model.transitionPending)
    }
}
#endif

struct DesktopNavigationButton: View {
    enum Action { case back, focus }
    @Bindable var model: AppModel
    let action: Action
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var closeSpace
    private var label: String { action == .back ? "Back to My Devices" : model.isImmersed ? "Return to Window" : "Enter Focus Mode" }
    private var symbol: String { action == .back ? "chevron.left" : model.isImmersed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right" }
    var body: some View {
        Button { navigate() } label: {
            Image(systemName:symbol)
                .font(.title3.weight(.semibold))
                .frame(width:52,height:52)
                .background(.thinMaterial,in:Circle())
                .hoverEffect { effect, isActive, _ in
                    effect.opacity(isActive || voiceOverEnabled ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .contentShape([.interaction,.hoverEffect],Rectangle())
        .hoverEffect(.highlight)
        .hoverEffectGroup()
        .accessibilityLabel(label)
        .disabled(model.transitionPending)
    }
    private func navigate() {
        Task { @MainActor in
            guard !model.transitionPending else { return }
            model.transitionPending = true
            #if DEBUG
            model.stream.stopControl()
            #endif
            if action == .back {
                #if DEBUG
                model.stream.disconnect()
                #endif
                model.destination = .devices
                openWindow(id:"controls")
            } else if model.isImmersed {
                model.destination = .desktop
                await closeSpace()
                model.transitionPending = false
            } else {
                model.destination = .focus
                switch await openSpace(id:"workspace") {
                case .opened:
                    dismissWindow(id:"controls")
                case .error:
                    model.destination = .desktop
                    model.error = "Could not open Focus Mode."
                case .userCancelled: model.destination = .desktop
                @unknown default: model.destination = .desktop
                }
                model.transitionPending = false
            }
        }
    }
}
