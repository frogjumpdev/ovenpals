import SwiftUI
import PetCore

/// A row of this week's cells: 8 pt capsules, filled in the legend's colour, the leave night a
/// short dashed line. A cell fills from the left when it changes inside an animation.
struct CellRow: View {
    enum Cell: Equatable { case filled, leave, empty }

    let cells: [Cell]
    let color: Color
    /// A 1 pt outline on filled cells (lime on the canvas, by day).
    var filledStroke: Color = .clear
    var size = CGSize(width: 16, height: 8)
    var gap: CGFloat = 4
    /// index → bump count: a cell bumps each time its count goes up.
    var pulses: [Int: Int] = [:]

    var body: some View {
        HStack(spacing: gap) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Group {
                    if cell == .leave {
                        HStack(spacing: size.width * 0.18) {
                            Capsule().fill(Jade.ink3)
                            Capsule().fill(Jade.ink3)
                        }
                        .frame(width: size.width * 0.82, height: max(2, size.height * 0.28))
                        .frame(width: size.width, height: size.height)
                    } else {
                        ZStack(alignment: .leading) {
                            // empty: the track with a 1 pt outline so it reads (PRD v0.3 §8.1)
                            Capsule().fill(Jade.fill)
                                .overlay(Capsule().strokeBorder(Jade.cellStroke, lineWidth: 1))
                            Capsule().fill(color)
                                .overlay(Capsule().strokeBorder(filledStroke, lineWidth: 1))
                                .scaleEffect(x: cell == .filled ? 1 : 0.001, anchor: .leading)
                                .opacity(cell == .filled ? 1 : 0)
                        }
                        .frame(width: size.width, height: size.height)
                    }
                }
                .pulse(pulses[index] ?? 0)
            }
        }
        .accessibilityHidden(true)
    }
}

extension WeekCells {
    var workoutRow: [CellRow.Cell] { (0..<3).map { $0 < workouts ? .filled : .empty } }
    var nightRow: [CellRow.Cell] {
        nights.map { night in
            switch night {
            case .on: .filled
            case .leave: .leave
            case .empty: .empty
            }
        }
    }
}

/// The two columns every status row lines up on (v3.4): a 22 pt icon, then a 54 pt grey noun.
enum StatusGrid {
    static let icon: CGFloat = 22
    static let label: CGFloat = 54
    static let lead: CGFloat = icon + 12 + label
}

/// Home status: Asleep (the onset time, a lime check once an on-time night is booked; nothing
/// while its moon still waits), then Slept (last night's sleep as the watch recorded it) or,
/// for Whoop users, Rest (Whoop's recovery as one bar, no number, marked WHOOP). Each row explains
/// itself with a tap. Nothing here is our own estimate (PRD v0.3 「只读原值」).
struct StatusRow<Content: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Jade.ink2)
                .frame(width: StatusGrid.icon)
            Text(label)
                .scaledFont(11, .heavy)
                .foregroundStyle(Jade.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: StatusGrid.label, alignment: .leading)
                .padding(.leading, 12)
            content()
                .padding(.leading, 10)
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
    }
}

struct AsleepRow: View {
    let status: HomeStatus

    var body: some View {
        StatusRow(icon: "moon", label: "Asleep") {
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(status.onset ?? "–")
                        .scaledFont(15, .bold)
                        .foregroundStyle(Jade.ink)
                        .monospacedDigit()
                    if let period = status.onsetPeriod {
                        Text(period)
                            .scaledFont(11, .bold)
                            .foregroundStyle(Jade.ink2)
                    }
                }
                Spacer()
                ZStack {
                    if status.onTime {
                        CheckBadge(color: Jade.sleep, size: 20)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .frame(width: 24, height: 24)
                .animation(.spring(duration: 0.36, bounce: 0.5), value: status.onTime)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.onsetText.map { "Asleep at \($0)\(status.onTime ? ", on time" : "")" } ?? "Asleep, no sleep data")
        .accessibilityHint("Explains this row")
        .accessibilityAddTraits(.isButton)
    }
}

/// Apple Watch users: how long they slept last night, as Apple Health has it.
struct SleptRow: View {
    let status: HomeStatus

    var body: some View {
        StatusRow(icon: "bed.double", label: "Slept") {
            Text(status.slept ?? "–")
                .scaledFont(15, .bold)
                .foregroundStyle(Jade.ink)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.slept.map { "Slept \($0) last night" } ?? "Slept, no sleep data")
        .accessibilityHint("Explains this row")
        .accessibilityAddTraits(.isButton)
    }
}

/// Whoop users: Whoop's recovery as a bar, no number (that is in Today), marked WHOOP.
struct RecoveryRow: View {
    let status: HomeStatus

    var body: some View {
        StatusRow(icon: "battery.75percent", label: "Rest") {
            HStack(spacing: 8) {
                Track(fraction: status.recovery ?? 0, color: Jade.sleep, stroke: Jade.limeStroke)
                Text("WHOOP")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Jade.ink2)
            }
            .padding(.trailing, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.recovery.map { "Whoop recovery \(Int(($0 * 100).rounded())) percent" } ?? "Whoop recovery, not scored yet")
        .accessibilityHint("Explains this row")
        .accessibilityAddTraits(.isButton)
    }
}

/// This week under the status area (PRD v0.2 §4.4): 3 jade workout cells and 5 lime night cells,
/// led by a run and a moon icon that are also the calendar's legend. No numbers.
struct WeekRow: View {
    let cells: WeekCells
    var workoutPulses: [Int: Int] = [:]
    var nightPulses: [Int: Int] = [:]

    var body: some View {
        HStack(spacing: 0) {
            // one word like Asleep and Slept, in their column under them (2026-11-26; was "This week")
            Color.clear.frame(width: StatusGrid.icon, height: 1)
            Text("Week")
                .scaledFont(11, .heavy)
                .foregroundStyle(Jade.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: StatusGrid.label, alignment: .leading)
                .padding(.leading, 12)
            HStack(spacing: 4) {
                Image(systemName: "figure.run").font(.system(size: 11, weight: .bold)).foregroundStyle(Jade.ink2)
                CellRow(cells: cells.workoutRow, color: Jade.accent, pulses: workoutPulses)
                    .background(HomeSpot.marks(prefix: "w", count: 3))
                Image(systemName: "moon").font(.system(size: 11, weight: .bold)).foregroundStyle(Jade.ink2)
                    .padding(.leading, 10)
                CellRow(cells: cells.nightRow, color: Jade.sleep, filledStroke: Jade.limeStroke, pulses: nightPulses)
                    .background(HomeSpot.marks(prefix: "n", count: 5))
            }
            .padding(.leading, 10)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(min(cells.workoutCount, 3)) of 3 workouts, \(min(cells.nightCount, 5)) of 5 early nights")
        .accessibilityHint("Explains this row")
        .accessibilityAddTraits(.isButton)
    }
}

/// The week in the calendar row (v3.4, B): weekday letter, date (today circled), and under it an
/// 11 pt run icon for a workout day and a moon for an on-time night, in the legend's colours; a
/// short dash for the leave night or a past day with nothing. Today's icons wait for its bubbles.
struct WeekStrip: View {
    let days: [WeekDay]
    /// The day whose note is open (a tap on a past day, or today once something is booked).
    @Binding var selected: Date?
    /// "Mon 3" · "Run 32 min · Asleep 22:48 ✓"; nil = nothing to say (future days, empty days).
    var note: (WeekDay) -> (title: String, body: String)? = { _ in nil }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    Text(day.letter)
                        .scaledFont(11, .semibold)
                        .foregroundStyle(Jade.ink2)
                    Text("\(day.number)")
                        .scaledFont(17, .bold)
                        .foregroundStyle(day.isToday ? Jade.onAccent : day.isFuture ? Jade.ink3 : Jade.ink)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(day.isToday ? Jade.accent : Color.clear))
                    marks(day)
                        .frame(height: 12)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .noteHighlight(selected == day.id, radius: 14, inset: 0)
                .contentShape(Rectangle())
                .onTapGesture { if note(day) != nil { selected = day.id } }
                .infoNote(isPresented: Binding(get: { selected == day.id }, set: { if !$0, selected == day.id { selected = nil } })) {
                    if let text = note(day) { InfoNote(text.title, text.body) }
                }
                .background { if day.isToday { HomeSpot.mark("today") } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label(day))
                .accessibilityAddTraits(note(day) != nil ? .isButton : [])
            }
        }
    }

    @ViewBuilder
    private func marks(_ day: WeekDay) -> some View {
        HStack(spacing: 2) {
            if day.workout {
                Image(systemName: "figure.run").font(.system(size: 10, weight: .bold)).foregroundStyle(Jade.accent)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
            if day.night {
                Image(systemName: "moon.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Jade.sleep)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
            if day.dash && !day.workout {
                Capsule().fill(Jade.ink3.opacity(0.7)).frame(width: 8, height: 2)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.5), value: day.workout)
        .animation(.spring(duration: 0.3, bounce: 0.5), value: day.night)
    }

    private func label(_ day: WeekDay) -> String {
        var parts = [day.id.formatted(.dateTime.weekday(.wide).day())]
        if day.workout { parts.append("workout") }
        if day.night { parts.append("on-time night") }
        if day.leave { parts.append("leave night") }
        return parts.joined(separator: ", ")
    }
}

/// Named places on home, measured in its coordinate space: where a dot flies to, what the tour
/// lights up.
enum HomeSpot {
    static let space = "home"

    struct Key: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    /// Reports this view's frame under `name`.
    static func mark(_ name: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: Key.self, value: [name: geo.frame(in: .named(space))])
        }
    }

    /// Splits a row of equal cells (16 pt, 4 pt apart) into named frames: w0, w1, w2 / n0…n4.
    static func marks(prefix: String, count: Int) -> some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(space))
            let cell = (frame.width - CGFloat(count - 1) * 4) / CGFloat(count)
            Color.clear.preference(key: Key.self, value: Dictionary(uniqueKeysWithValues: (0..<count).map { i in
                ("\(prefix)\(i)", CGRect(x: frame.minX + CGFloat(i) * (cell + 4), y: frame.minY, width: cell, height: frame.height))
            }))
        }
    }
}
