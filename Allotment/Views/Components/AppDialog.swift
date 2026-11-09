import AppKit
import SwiftUI

/// A confirmation, warning or prompt drawn in Allotment's own style. Every dialog in the app uses this,
/// never a standard system alert. Cancel is always there, and Escape or a click outside the dialog cancels.
struct AppDialog: Identifiable {
    enum Tone {
        case standard, warning, destructive

        var color: Color {
            switch self {
            case .standard: .accentColor
            case .warning: .orange
            case .destructive: .red
            }
        }
    }

    struct Action: Identifiable {
        let id = UUID()
        let title: String
        var isDestructive = false
        let perform: () -> Void
    }

    let id = UUID()
    var symbol: String
    var tone: Tone = .standard
    var title: String
    var message: String?
    var actions: [Action] = []
    /// Shown on the button that closes the dialog without doing anything, such as "Cancel" or "OK".
    var cancelTitle = "Cancel"
    var onCancel: () -> Void = {}

    /// A problem to report, with one button to close it.
    static func problem(_ title: String, error: Error) -> AppDialog {
        AppDialog(symbol: "exclamationmark.triangle.fill", tone: .warning, title: title,
                  message: error.localizedDescription, cancelTitle: "OK")
    }
}

/// Shows one dialog at a time over the window or sheet it hosts.
@MainActor
@Observable
final class DialogPresenter {
    private(set) var current: AppDialog?

    func present(_ dialog: AppDialog) {
        current = dialog
    }

    func cancel() {
        let dialog = current
        current = nil
        dialog?.onCancel()
    }

    func choose(_ action: AppDialog.Action) {
        current = nil
        action.perform()
    }
}

extension View {
    /// Shows `presenter`'s dialogs over this view. Everything underneath is dimmed, disabled and hidden from
    /// VoiceOver until the dialog closes, so focus stays inside it.
    func appDialogHost(_ presenter: DialogPresenter) -> some View {
        modifier(AppDialogHost(presenter: presenter))
    }
}

private struct AppDialogHost: ViewModifier {
    let presenter: DialogPresenter

    func body(content: Content) -> some View {
        let dialog = presenter.current
        content
            .disabled(dialog != nil)
            .accessibilityHidden(dialog != nil)
            .overlay {
                if let dialog {
                    ZStack {
                        Color.black.opacity(0.38)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { presenter.cancel() }
                            .accessibilityHidden(true)
                        AppDialogCard(dialog: dialog, choose: { presenter.choose($0) }, cancel: { presenter.cancel() })
                            .padding(24)
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.2), value: dialog?.id)
    }
}

/// The dialog itself: an icon, a title, an optional message and the buttons.
struct AppDialogCard: View {
    let dialog: AppDialog
    let choose: (AppDialog.Action) -> Void
    let cancel: () -> Void
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: dialog.symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(dialog.tone.color)
                .frame(width: 48, height: 48)
                .background(dialog.tone.color.opacity(0.15), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(dialog.title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                if let message = dialog.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            buttons
        }
        .padding(24)
        .frame(maxWidth: 380)
        .background(Self.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.primary.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(dialog.title)
        .onAppear {
            titleFocused = true
            AccessibilityNotification.Announcement(dialog.title).post()
        }
    }

    /// One action sits beside Cancel when both fit, otherwise every button gets its own row.
    @ViewBuilder
    private var buttons: some View {
        if dialog.actions.count <= 1 {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    cancelButton
                    actionButtons
                }
                VStack(spacing: 8) {
                    actionButtons
                    cancelButton
                }
            }
        } else {
            VStack(spacing: 8) {
                actionButtons
                cancelButton
            }
        }
    }

    /// The first action is filled in its colour. Any others are tinted, so the main choice stands out.
    private var actionButtons: some View {
        ForEach(Array(dialog.actions.enumerated()), id: \.element.id) { index, action in
            let tint = action.isDestructive ? Color.red : Color.accentColor
            Button(action.title) { choose(action) }
                .buttonStyle(DialogButtonStyle(kind: index == 0 ? .filled(tint) : .tinted(tint)))
                .keyboardShortcut(isDefault(action) ? .defaultAction : nil)
        }
    }

    /// Lifted a little above the dimmed window in dark mode, plain white in light mode.
    private static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : .white
    })

    private var cancelButton: some View {
        Button(dialog.cancelTitle, action: cancel)
            .buttonStyle(DialogButtonStyle(kind: .quiet))
            .keyboardShortcut(.cancelAction)
            .background {
                // With nothing else to choose, Return closes the dialog too.
                if dialog.actions.isEmpty {
                    Button("", action: cancel)
                        .keyboardShortcut(.defaultAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    /// Return picks the only safe choice. A destructive action always needs a click.
    private func isDefault(_ action: AppDialog.Action) -> Bool {
        dialog.actions.count == 1 && !action.isDestructive
    }
}

/// The dialog's buttons: filled for the main choice, tinted for other choices, and quiet for Cancel.
struct DialogButtonStyle: ButtonStyle {
    enum Kind {
        case filled(Color), tinted(Color), quiet
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        @State private var hovering = false

        private var foreground: Color {
            switch kind {
            case .filled: .white
            case .tinted(let tint): tint
            case .quiet: .primary
            }
        }

        private var fill: AnyShapeStyle {
            switch kind {
            case .filled(let tint): AnyShapeStyle(tint.gradient)
            case .tinted(let tint): AnyShapeStyle(tint.opacity(0.16))
            case .quiet: AnyShapeStyle(.primary.opacity(0.08))
            }
        }

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .foregroundStyle(foreground)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(fill, in: Capsule())
                .brightness(hovering ? 0.05 : 0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

/// Shows a dialog in its own small floating window, for prompts that can arrive when no Allotment window
/// is open, such as asking about time spent away from the Mac.
@MainActor
enum FloatingDialog {
    private static var panel: DialogPanel?

    static func present(_ dialog: AppDialog) {
        dismiss()
        // A non-activating panel takes the keyboard without pulling Allotment in front of the app you are using,
        // and stays up even though Allotment itself is not the active app.
        let panel = DialogPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilitySubrole(.dialog)

        let card = AppDialogCard(
            dialog: dialog,
            choose: { action in
                dismiss()
                action.perform()
            },
            cancel: {
                dismiss()
                dialog.onCancel()
            }
        )
        // Room around the card for its shadow.
        let hosting = NSHostingView(rootView: card.padding(36))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        // Clicking anywhere outside the dialog cancels it, like the scrim inside a window.
        panel.onResignKey = {
            dismiss()
            dialog.onCancel()
        }
        Self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    static func dismiss() {
        guard let panel else { return }
        panel.onResignKey = nil
        panel.orderOut(nil)
        Self.panel = nil
    }
}

private final class DialogPanel: NSPanel {
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
