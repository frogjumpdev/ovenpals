import SwiftUI

/// A page = a title + a stack of cards. This is the card.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 18
    var radius: CGFloat = Metrics.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Jade.card))
    }
}

extension View {
    func card(padding: CGFloat = 18, radius: CGFloat = Metrics.card) -> some View {
        modifier(CardBackground(padding: padding, radius: radius))
    }

    /// The soft lift under round buttons and food bubbles.
    func softShadow(_ strength: Double = 1) -> some View {
        shadow(color: Jade.shadow.opacity(0.07 * strength), radius: 10, y: 4)
    }
}

/// A round card-coloured surface holding an icon.
struct RoundSurface<Content: View>: View {
    var size: CGFloat = 40
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: size, height: size)
            .background(Circle().fill(Jade.card))
            .softShadow(0.6)
            .contentShape(Circle())
    }
}

/// A 40 pt round icon button face (back, share, more, options).
struct RoundIcon: View {
    let systemName: String
    var size: CGFloat = 40

    var body: some View {
        RoundSurface(size: size) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Jade.ink)
        }
    }
}

struct RoundButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { RoundIcon(systemName: systemName) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

/// Back button on the left, an optional button on the right, the page title underneath.
struct PageHeader<Trailing: View>: View {
    let title: String
    var count: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                RoundButton(systemName: "chevron.left", label: "Back") { dismiss() }
                Spacer()
                trailing()
            }
            if !title.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).scaledFont(32, .bold).foregroundStyle(Jade.ink)
                    if let count { Text(count).scaledFont(20, .semibold).foregroundStyle(Jade.ink2) }
                }
            }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, count: String? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Full-width capsule button. Primary = forest/lime; secondary = the grey fill.
struct PillButtonStyle: ButtonStyle {
    var primary = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(16, .bold)
            .foregroundStyle(primary ? Jade.onPrimary : Jade.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(primary ? Jade.primary : Jade.fill))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A thin rounded progress track.
struct Track: View {
    let fraction: Double
    var color: Color = Jade.accent
    var height: CGFloat = 6
    /// A 1 pt outline on the filled part (lime on the canvas, by day).
    var stroke: Color = .clear

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Jade.fill)
                Capsule().fill(color)
                    .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// The round check in a card's corner: done.
struct CheckBadge: View {
    var color: Color = Jade.accent
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(Jade.onAccent)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .accessibilityLabel("Done")
    }
}

/// The dock's pet icon: a rounded face with two eyes.
struct PetFaceIcon: View {
    var size: CGFloat = 22
    var color: Color = Jade.ink

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .stroke(color, lineWidth: size * 0.09)
                .frame(width: size * 0.8, height: size * 0.68)
            HStack(spacing: size * 0.16) {
                Capsule().fill(color).frame(width: size * 0.09, height: size * 0.16)
                Capsule().fill(color).frame(width: size * 0.09, height: size * 0.16)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The Diary button's icon (2026-11-26, option A): a little notebook that smiles. A cover with
/// its spine on the left, two eyes and a smile on it, drawn like PetFaceIcon (round 2 pt lines,
/// one colour), so the two read as one family.
struct DiaryIcon: View {
    var size: CGFloat = 22
    var color: Color = Jade.ink

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 3.8 / 24, style: .continuous)
                .stroke(color, lineWidth: size * 2.1 / 24)
                .frame(width: size * 15.2 / 24, height: size * 18 / 24)
            DiarySpine().stroke(color, style: StrokeStyle(lineWidth: size * 2.1 / 24, lineCap: .round))
            DiaryEyes().fill(color)
            DiarySmile().stroke(color, style: StrokeStyle(lineWidth: size * 1.8 / 24, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

/// Points on a 24 × 24 grid, scaled into `rect` (the grid the icon was drawn on).
private func iconGrid(_ rect: CGRect) -> (CGFloat, CGFloat) -> CGPoint {
    let s = min(rect.width, rect.height) / 24
    return { x, y in CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
}

/// The spine: one line down the cover, near its left edge.
private struct DiarySpine: Shape {
    func path(in rect: CGRect) -> Path {
        let p = iconGrid(rect)
        var path = Path()
        path.move(to: p(8.4, 3.6)); path.addLine(to: p(8.4, 20.4))
        return path
    }
}

/// Two upright eyes, the same shape as PetFaceIcon's and about as far apart, centred on the cover
/// right of the spine.
private struct DiaryEyes: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var path = Path()
        for x in [10.8, 15.2] {
            path.addRoundedRect(in: CGRect(x: rect.minX + x * s, y: rect.minY + 9.1 * s, width: 2.1 * s, height: 3.5 * s),
                                cornerSize: CGSize(width: 1.05 * s, height: 1.05 * s))
        }
        return path
    }
}

/// A smile under the eyes, curved enough to read as one at 22 pt.
private struct DiarySmile: Shape {
    func path(in rect: CGRect) -> Path {
        let p = iconGrid(rect)
        var path = Path()
        path.move(to: p(12.3, 15.1))
        path.addQuadCurve(to: p(15.8, 15.1), control: p(14.05, 17.7))
        return path
    }
}

/// Page background + side gutters, shared by the inner pages.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) { content() }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        #if DEBUG
        // For screenshots on the simulator: -hp3dScrollEnd YES opens every page scrolled to the end.
        .defaultScrollAnchor(UserDefaults.standard.bool(forKey: "hp3dScrollEnd") ? .bottom : nil)
        #endif
        .background(Jade.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
