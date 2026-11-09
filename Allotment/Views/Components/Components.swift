import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        if cleaned.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else {
            r = 0.56; g = 0.56; b = 0.58
        }
        self.init(.sRGB, red: r, green: g, blue: b)
    }
}

extension TimeStore {
    func color(for clientID: UUID?) -> Color {
        Color(hex: client(clientID)?.colorHex ?? Palette.internalHex)
    }

    func title(for entry: TimeEntry) -> String {
        client(entry.clientID)?.name ?? (activity(entry.activityID)?.isAdmin == true ? "Internal" : "No client")
    }

    /// "Website redesign · Meeting", leaving out whatever is not set.
    func subtitle(for entry: TimeEntry) -> String {
        [project(entry.projectID)?.name, activity(entry.activityID)?.name]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct ClientDot: View {
    let color: Color
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
    }
}

/// A dot that breathes while a timer is running.
struct PulsingDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 18, height: 18)
                .scaleEffect(pulse ? 1 : 0.55)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(color.gradient)
                .frame(width: 10, height: 10)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

struct StatusPill: View {
    let status: ForecastStatus
    var compact = false

    var body: some View {
        Label(compact ? status.shortTitle : status.title, systemImage: status.symbol)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.13), in: Capsule())
            .fixedSize()
    }
}

extension ForecastStatus {
    /// The colour for hours past an allocation: red once it is clearly over, orange while it is within the tolerance.
    var overrunColor: Color { self == .over ? .red : .orange }
}

/// Progress towards an allocation. Hours within the allocation use the client's colour, hours past it use the over colour,
/// and a small notch marks where you should be by now.
struct AllocationBar: View {
    let actual: Double
    let allocation: Double
    var expected: Double?
    let color: Color
    var status: ForecastStatus = .onTrack
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let scaleMax = max(allocation, actual)
            let x: (Double) -> CGFloat = { scaleMax > 0 ? width * min($0, scaleMax) / scaleMax : 0 }
            let within = min(actual, allocation)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                if actual > allocation {
                    // The whole bar in the over colour, then the part within the allocation drawn on top of it.
                    Capsule()
                        .fill(status.overrunColor.gradient)
                        .frame(width: width)
                    UnevenRoundedRectangle(topLeadingRadius: height / 2, bottomLeadingRadius: height / 2)
                        .fill(color.gradient)
                        .frame(width: max(0, x(within) - 1))
                } else if actual > 0 {
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(height, x(actual)))
                }
                if let expected, expected > 0, expected < allocation, scaleMax > 0 {
                    Capsule()
                        .fill(.primary.opacity(0.75))
                        .frame(width: 2, height: height + 6)
                        .offset(x: x(expected) - 1)
                }
            }
        }
        .frame(height: height)
        .help(helpText)
    }

    private var helpText: String {
        var parts = ["\(Fmt.hours(actual)) of \(Fmt.hours(allocation))"]
        if actual > allocation { parts.append("\(Fmt.hours(actual - allocation)) over") }
        if let expected, expected > 0, expected < allocation { parts.append("the notch shows \(Fmt.hours(expected)), where you should be by now") }
        return parts.joined(separator: ", ")
    }
}

/// The big round stop and play buttons in the menu bar and on the overview.
struct RoundActionButtonStyle: ButtonStyle {
    let tint: Color
    var size: CGFloat = 46

    func makeBody(configuration: Configuration) -> some View {
        RoundBody(configuration: configuration, tint: tint, size: size)
    }

    private struct RoundBody: View {
        let configuration: Configuration
        let tint: Color
        let size: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.37, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(tint.gradient, in: Circle())
                .brightness(hovering ? 0.06 : 0)
                .shadow(color: tint.opacity(0.35), radius: hovering ? 8 : 5, y: 2)
                .scaleEffect(configuration.isPressed ? 0.93 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(Circle())
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var symbol: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground()
    }
}

struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06))
            )
    }
}

extension View {
    func cardBackground(cornerRadius: CGFloat = 14) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

struct ColorSwatchPicker: View {
    @Binding var hex: String

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Palette.colors, id: \.self) { color in
                Button {
                    hex = color
                } label: {
                    Circle()
                        .fill(Color(hex: color).gradient)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if hex == color {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(color)
            }
        }
    }
}

/// Fades a scroll view's content out at the top or bottom while there is more to scroll that way, so rows
/// never stop at a hard line. At rest at the top nothing is faded. For scroll areas without a system bar
/// over them. Scroll areas under the toolbar or a safe area bar use the system's soft scroll edge effect.
struct SoftScrollEdges: ViewModifier {
    var length: CGFloat = 16
    @State private var edges = HiddenEdges()

    private struct HiddenEdges: Equatable {
        var top = false
        var bottom = false
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: HiddenEdges.self) { geometry in
                HiddenEdges(top: geometry.visibleRect.minY > 0.5,
                            bottom: geometry.visibleRect.maxY < geometry.contentSize.height - 0.5)
            } action: { _, newValue in
                withAnimation(.easeOut(duration: 0.15)) { edges = newValue }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(edges.top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: length)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(edges.bottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: length)
                }
            }
    }
}

extension View {
    func softScrollEdges(length: CGFloat = 16) -> some View {
        modifier(SoftScrollEdges(length: length))
    }
}

/// Fades scrolling content out as it passes under the toolbar or a pinned bar, so it never stops at a hard
/// edge. Content is clear under the bar and fades in over `length` points below it. Pages start at least that
/// far below the bar, so nothing is covered at rest. Used in the main window, where the system's soft scroll
/// edge effect does not draw under the toolbar.
///
/// A scroll view's frame stops at the bar while its content keeps drawing underneath, so the bar's height is
/// the gap between the scroll view's frame and the mask, which reaches out to the window's edges.
struct FadeUnderBars: ViewModifier {
    var edges: VerticalEdge.Set = .all
    var length: CGFloat = 12
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .mask {
                GeometryReader { proxy in
                    let outer = proxy.frame(in: .global)
                    let top = edges.contains(.top) ? max(0, frame.minY - outer.minY) : 0
                    let bottom = edges.contains(.bottom) ? max(0, outer.maxY - frame.maxY) : 0
                    VStack(spacing: 0) {
                        Color.clear.frame(height: top)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: top > 0 ? length : 0)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: bottom > 0 ? length : 0)
                        Color.clear.frame(height: bottom)
                    }
                }
                .ignoresSafeArea()
            }
    }
}

extension View {
    func fadeUnderBars(edges: VerticalEdge.Set = .all, length: CGFloat = 12) -> some View {
        modifier(FadeUnderBars(edges: edges, length: length))
    }
}
