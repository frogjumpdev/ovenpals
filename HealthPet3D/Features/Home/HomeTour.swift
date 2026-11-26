import SwiftUI

/// The 3-step tour of home, once after the first open (PRD v0.2 §6, v3.4 layer ①): the pet
/// explains, the rest of the screen dims (58% forest, 66% black at night) around one lit-up
/// place with 28 pt corners. Then 「Tap to feed …」 on a real bubble. Skip any time; 「Show me
/// around」 in the 「…」 menu plays it again.
enum TourStep: Int, CaseIterable {
    case bubbles = 1, records, dock, tryIt

    /// Whoop users hear about their recovery, Apple Watch users about how long they slept (PRD v0.3).
    func line(whoop: Bool) -> String {
        switch self {
        case .bubbles: "Today’s snacks. Your walks, workouts and sleep grow them. Tap one and I’ll eat it."
        case .records: "Where it goes: last night’s bedtime, \(whoop ? "how rested you are" : "how long you slept"), and this week’s tally. 3 workouts + 5 early nights make a disciplined week."
        case .dock: "Pets keeps everyone you’ve met. Today has the numbers. Diary keeps what you’ve earned."
        case .tryIt: ""
        }
    }
}

struct TourOverlay: View {
    let step: TourStep
    /// The lit-up place, in the overlay's coordinates.
    let hole: CGRect
    /// The caption sits under the lit place (step 1) or above it (2, 3).
    let captionBelow: Bool
    /// Where the 「…」 button is: Skip takes its place.
    let skipAt: CGRect?
    let petName: String
    /// Whoop user: step 2 talks about recovery instead of sleep length.
    var whoop = false
    let next: () -> Void
    let skip: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size).insetBy(dx: -60, dy: -120))
                    path.addRoundedRect(in: hole, cornerSize: CGSize(width: 28, height: 28), style: .continuous)
                }
                .fill(Jade.scrim, style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture {}   // the screen underneath waits for Next or Skip
                .accessibilityHidden(true)

                caption(width: min(270, geo.size.width - 48))
                    .position(x: min(max(hole.midX, 24 + 135), geo.size.width - 24 - 135),
                              y: captionBelow ? hole.maxY + 14 + captionHeight / 2 : hole.minY - 14 - captionHeight / 2)

                if let skipAt {
                    Button("Skip", action: skip)
                        .scaledFont(14, .bold)
                        .foregroundStyle(Jade.ink)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Capsule().fill(Jade.card))
                        .position(x: skipAt.maxX - 28, y: skipAt.midY)
                }
            }
        }
        .transition(.opacity)
    }

    @State private var captionHeight: CGFloat = 150

    private func caption(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(petName.uppercased())
                .scaledFont(11, .heavy)
                .tracking(0.8)
                .foregroundStyle(Jade.accent)
            Text(step.line(whoop: whoop))
                .scaledFont(15, .semibold)
                .foregroundStyle(Jade.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(step.rawValue) / 3")
                    .scaledFont(12, .semibold)
                    .foregroundStyle(Jade.ink2)
                Spacer()
                Button(action: next) {
                    Text("Next ›").scaledFont(13, .bold).foregroundStyle(Jade.ink)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Jade.card)
                .overlay(alignment: captionBelow ? .top : .bottom) {
                    Tail().fill(Jade.card)
                        .frame(width: 18, height: 9)
                        .rotationEffect(.degrees(captionBelow ? 0 : 180))
                        .offset(y: captionBelow ? -8 : 8)
                }
        )
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .background(GeometryReader { g in Color.clear.onAppear { captionHeight = g.size.height }.onChange(of: g.size.height) { captionHeight = $1 } })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// The small triangle that points from a caption to what it is about (pointing up).
struct Tail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The tour's last step: no dimming, a ring breathes around one real bubble and a dark label
/// says 「Tap to feed Toast」; tapping the bubble feeds it like any other.
struct TryItHint: View {
    let center: CGPoint
    let petName: String
    /// The label goes on the side with more room.
    let labelOnLeft: Bool
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Jade.accent.opacity(0.10))
                .frame(width: 70, height: 70)
                .overlay(Circle().stroke(Jade.accent.opacity(breathe ? 0.35 : 0.9), lineWidth: 2))
                .scaleEffect(breathe ? 1.12 : 0.96)
                .position(center)
            HStack(spacing: 0) {
                if !labelOnLeft { Tail().fill(Jade.primary).frame(width: 12, height: 7).rotationEffect(.degrees(-90)).offset(x: 3) }
                Text("Tap to feed \(petName)")
                    .scaledFont(13, .bold)
                    .foregroundStyle(Jade.onAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Jade.primary))
                if labelOnLeft { Tail().fill(Jade.primary).frame(width: 12, height: 7).rotationEffect(.degrees(90)).offset(x: -3) }
            }
            .fixedSize()
            // a zero-wide frame at the ring's edge: the label grows away from the bubble
            .frame(width: 0, height: 0, alignment: labelOnLeft ? .trailing : .leading)
            .position(x: labelOnLeft ? center.x - 40 : center.x + 40, y: center.y)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}
