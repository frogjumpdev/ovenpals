import SwiftUI
import PetCore

/// Today (v3.4, decided 2026-11-09): the numbers. Under the title, the date; Asleep with its time,
/// target and hours; the longest workout with distance and pace; steps of 10k; this week's cells
/// with what is left; for Whoop users, Whoop's recovery with its bar and percentage (Apple Watch
/// users have no such row: nothing is estimated, PRD v0.3). A tag says which tally a record went
/// into (✓ Early night, ✓ Workout), grey until its bubble on home is eaten (点击 = 入账). Every card
/// explains itself with a tap. Share sits top right; last night can be taken as the leave night,
/// or fixed when the watch got it wrong (two a month, PRD v0.3 §4.2).
struct TodayScreen: View {
    @Environment(AppModel.self) private var model
    @State private var note: Note?
    @State private var fixing = false

    private enum Note: Hashable { case asleep, workout, steps, week, recovery }

    var body: some View {
        PageScroll {
            PageHeader(title: "Today") {
                NavigationLink(value: Route.share) { RoundIcon(systemName: "square.and.arrow.up") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share")
            }
            Text(Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .scaledFont(13, .semibold)
                .foregroundStyle(Jade.ink2)
                .padding(.top, -10)
                .padding(.bottom, 4)
            sleepCard
                .explains(.asleep, $note) { asleepNote }
            HStack(alignment: .top, spacing: Metrics.gap) {
                workoutCard
                    .explains(.workout, $note) { InfoNote("Workout", "Any workout of 20 minutes or more counts, one per day.") }
                stepsCard
                    .explains(.steps, $note) {
                        InfoNote("Steps", "Your watch counts them all day. A 10k-step day counts as one workout, even without a run.")
                    }
            }
            .fixedSize(horizontal: false, vertical: true)
            weekCard
                .explains(.week, $note) {
                    WeekNote(cells: model.weekCells, bedtime: SleepSchedule.clock(model.sleepSchedule.bedtimeMinutes))
                }
            // Whoop users only: Apple Watch has no recovery an app can read, and last night's
            // sleep is already in the Asleep card (PRD v0.3 「只读原值」).
            if model.isWhoopUser {
                recoveryCard
                    .explains(.recovery, $note) {
                        InfoNote("Recovery · WHOOP", "Your WHOOP recovery today, as WHOOP scored it.")
                    }
            }
        }
        #if DEBUG
        // For screenshots: -hp3dBookAll YES eats today's food, to show the tags once booked;
        // -hp3dFixSheet YES opens 「Watch got it wrong?」.
        .task {
            if UserDefaults.standard.bool(forKey: "hp3dFixSheet") {
                try? await Task.sleep(for: .seconds(1))
                fixing = true
            }
            guard UserDefaults.standard.bool(forKey: "hp3dBookAll") else { return }
            try? await Task.sleep(for: .seconds(1.5))
            for bubble in model.foodBubbles { _ = model.book(bubble.credit) }
        }
        #endif
    }

    private var day: HealthSnapshot? { model.today }
    private var target: String { SleepSchedule.clock(model.sleepSchedule.targets(nightEnding: Date()).bed) }

    // MARK: - Asleep

    private var sleepCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(icon: "moon", title: "Asleep") {
                if model.lastNightIsLeave {
                    Tally(text: "Leave night", color: Jade.sleep, on: Jade.onSleep, check: false)
                } else if model.sleptOnTime {
                    Tally(text: "Early night", color: Jade.sleep, on: Jade.onSleep, booked: model.nightBooked)
                }
            }
            let onset = day?.sleepOnset.map(Format.timeParts)
            BigNumber(onset?.clock ?? "–", period: onset?.period)
            Text(sleepLine)
                .scaledFont(13, .semibold)
                .foregroundStyle(Jade.ink2)
            leaveButton
            fixLine
        }
        .card()
        .sheet(isPresented: $fixing) {
            SleepFixSheet(start: model.lastNightRecordedOnset ?? model.discipline.target(forNightEnding: Date()))
                .environment(model)
        }
    }

    /// "Target 23:00 · slept 7h 30m"
    private var sleepLine: String {
        ["Target \(target)", day?.sleepHours.map { "slept \(Format.duration(hours: $0))" }].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var asleepNote: some View {
        if !model.hasSleepData && day?.sleepOnset == nil {
            InfoNote("Asleep", AppModel.noSleepLine)
        } else if model.sleptOnTime, let onset = day?.sleepOnset {
            InfoNote("Early night", "Asleep within 30 minutes of your \(target) target. \(Format.time(onset)) counts. Five a week fill the moon row below.")
        } else {
            InfoNote("Asleep", "When your watch saw you fall asleep. Within 30 minutes of your \(target) target counts as an early night.")
        }
    }

    /// 「用请假」: one night a week counts as on time, no reason needed. Tap again to give it back.
    /// Only on a late night's card.
    @ViewBuilder
    private var leaveButton: some View {
        if model.lastNightIsLeave {
            Button { model.setLeave(false, nightEnding: Date()) } label: {
                Label("Leave night", systemImage: "checkmark")
                    .scaledFont(14, .bold)
                    .foregroundStyle(Jade.onSleep)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(Jade.sleep))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityHint("Gives the leave night back")
        } else if model.canTakeLeaveLastNight {
            Button {
                model.setLeave(true, nightEnding: Date())
                // 点点头 (PRD §5.3): the pet nods when it is next on screen
                PetStage.shared.react("nod")
            } label: {
                Label("Use leave night", systemImage: "moon.zzz")
                    .scaledFont(14, .bold)
                    .foregroundStyle(Jade.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(Jade.fill))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityHint("Counts last night as on time. One a week.")
        }
    }

    /// 「手表记错了」: under a late (or empty) night, a quiet link to say when you really fell
    /// asleep; once fixed, what the watch said and Undo. Not a ledger line.
    @ViewBuilder
    private var fixLine: some View {
        if model.lastNightFix != nil {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "pencil").font(.system(size: 11, weight: .bold))
                Text(model.lastNightRecordedOnset.map { "Fixed by you · watch said \(Format.time($0))" } ?? "Added by you")
                    .scaledFont(13, .semibold)
                Spacer(minLength: 6)
                Button("Undo") { model.fixLastNight(nil) }
                    .scaledFont(13, .bold)
                    .foregroundStyle(Jade.ink)
                    .buttonStyle(.plain)
                    .accessibilityHint("Goes back to what the watch said")
            }
            .foregroundStyle(Jade.ink2)
            .padding(.top, 2)
        } else if model.canFixLastNight {
            Button { fixing = true } label: {
                Text("Watch got it wrong?")
                    .scaledFont(13, .semibold)
                    .underline()
                    .foregroundStyle(Jade.ink2)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Tell it when you really fell asleep. \(model.sleepFixesLeft) left this month.")
        }
    }

    // MARK: - Workout, steps

    private var workoutCard: some View {
        let workout = model.mainWorkout
        let counts = workout.map { model.discipline.countsAsWorkout($0) } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            CardTitle(icon: workoutIcon(workout?.name), title: workout?.name ?? "Workout") {
                if counts { Tally(text: "Workout", color: Jade.accent, booked: model.mainWorkoutBooked) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                BigNumber(workout.map { "\(Int($0.minutes.rounded()))" } ?? "–", size: 34)
                if workout != nil {
                    Text("min").scaledFont(15, .semibold).foregroundStyle(Jade.ink2)
                }
            }
            if let distance = workout.flatMap(Self.distanceLine) {
                Text(distance)
                    .scaledFont(13, .semibold)
                    .foregroundStyle(Jade.ink2)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    /// "5.1 km · 7:12" (distance · pace per km or mile), for workouts that cover a distance.
    static func distanceLine(_ workout: WorkoutSession) -> String? {
        guard let km = workout.distanceKm, km >= 0.1 else { return nil }
        let miles = Locale.current.measurementSystem == .us
        let distance = miles ? km / 1.609_344 : km
        let pace = workout.minutes / distance
        let paceText = pace.isFinite && pace < 60 ? String(format: " · %d:%02d", Int(pace), Int(((pace - floor(pace)) * 60).rounded()) % 60) : ""
        return String(format: "%.1f %@", distance, miles ? "mi" : "km") + paceText
    }

    private var stepsCard: some View {
        let steps = day?.steps ?? 0
        let goal = model.discipline.rules.activeDaySteps
        return VStack(alignment: .leading, spacing: 10) {
            CardTitle(icon: "shoeprints.fill", title: "Steps") {
                if steps >= goal { Tally(text: "Workout", color: Jade.accent, booked: model.stepsBooked) }
            }
            BigNumber(day?.steps.map(Format.short) ?? "–", size: 34)
            VStack(alignment: .leading, spacing: 6) {
                Track(fraction: Double(steps) / Double(goal), color: Jade.ink)
                Text("of \(Format.short(goal))")
                    .scaledFont(12, .semibold)
                    .foregroundStyle(Jade.ink2)
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    // MARK: - This week, Whoop recovery

    private var weekCard: some View {
        let cells = model.weekCells
        return VStack(alignment: .leading, spacing: 12) {
            Text("This week").scaledFont(15, .semibold).foregroundStyle(Jade.ink)
            weekLine(icon: "figure.run", name: "Workouts", row: CellRow(cells: cells.workoutRow, color: Jade.accent, size: CGSize(width: 22, height: 8), gap: 6),
                     count: "\(min(cells.workoutCount, 3)) of 3")
            weekLine(icon: "moon", name: "Early nights", row: CellRow(cells: cells.nightRow, color: Jade.sleep, size: CGSize(width: 22, height: 8), gap: 6),
                     count: "\(min(cells.nightCount, 5)) of 5")
            Text(model.weekToGo)
                .scaledFont(14, .bold)
                .foregroundStyle(Jade.ink)
                .padding(.top, 6)
        }
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(min(cells.workoutCount, 3)) of 3 workouts, \(min(cells.nightCount, 5)) of 5 early nights. \(model.weekToGo)")
    }

    private func weekLine(icon: String, name: String, row: CellRow, count: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Jade.ink2).frame(width: 16)
            Text(name).scaledFont(13, .semibold).foregroundStyle(Jade.ink2)
            Spacer(minLength: 6)
            row
            Text(count)
                .scaledFont(13, .semibold)
                .foregroundStyle(Jade.ink2)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    /// Whoop's recovery as Whoop scored it, marked WHOOP.
    private var recoveryCard: some View {
        let recovery = model.whoopRecovery
        return HStack(spacing: 12) {
            Label { Text("Recovery") } icon: { Image(systemName: "battery.75percent") }
                .scaledFont(15, .semibold)
                .foregroundStyle(Jade.ink)
                .fixedSize()
            Text("WHOOP")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Jade.ink2)
            Track(fraction: (recovery ?? 0) / 100, color: Jade.sleep)
            Text(recovery.map { "\(Int($0.rounded()))%" } ?? "–")
                .scaledFont(17, .bold)
                .foregroundStyle(Jade.ink)
                .monospacedDigit()
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// 「手表记错了」 (PRD v0.3 §4.2): when the user really fell asleep last night. It only decides
/// whether the night was on time, so Save waits for a time that counts. Two a month, apart from
/// the weekly leave night.
private struct SleepFixSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The picked hour and minute, in minutes after midnight.
    @State private var minutes: Int

    init(start: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: start)
        _minutes = State(initialValue: (parts.hour ?? 23) * 60 + (parts.minute ?? 0))
    }

    /// The picked time, as last night (evening times on the day before).
    private var moment: Date { model.lastNightMoment(minutes: minutes) }

    var body: some View {
        let counts = moment <= model.lastNightDeadline
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("When did you fall asleep?")
                    .scaledFont(20, .heavy)
                    .foregroundStyle(Jade.ink)
                Text(model.lastNightRecordedOnset.map { "Your watch saw \(Format.time($0)). This only changes whether last night counts as an early night." }
                     ?? "Your watch didn’t see you fall asleep. This only changes whether last night counts as an early night.")
                    .scaledFont(14, .medium)
                    .foregroundStyle(Jade.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                // the app's own wheel, in the clock chosen in Settings; its band turns grey while
                // the time wouldn't count
                ClockWheel(minutes: $minutes, counts: counts)
                Text(counts ? "That counts as an early night." : "Still after \(Format.time(model.lastNightDeadline)), so it wouldn’t count.")
                    .scaledFont(14, .semibold)
                    .foregroundStyle(counts ? Jade.ink : Jade.ink2)
                    .frame(maxWidth: .infinity)
                    .animation(.easeOut(duration: 0.15), value: counts)
                Button("Save") {
                    model.fixLastNight(moment)
                    PetStage.shared.react("nod")
                    dismiss()
                }
                .buttonStyle(PillButtonStyle(primary: true))
                .disabled(!counts)
                .opacity(counts ? 1 : 0.45)
                .animation(.easeOut(duration: 0.15), value: counts)
                Text("\(model.sleepFixesLeft) of \(AppModel.sleepFixesPerMonth) left this month, apart from your leave night.")
                    .scaledFont(12, .medium)
                    .foregroundStyle(Jade.ink2)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Metrics.gutter + 4)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(440), .large])
        .jadeSheet()
    }
}

/// Which tally a record went into: 「✓ Early night」 (lime), 「✓ Workout」 (jade). Grey and
/// without the check while its bubble on home still waits.
struct Tally: View {
    let text: String
    let color: Color
    /// Text on `color`.
    var on: Color = Jade.onAccent
    var booked = true
    var check = true

    var body: some View {
        HStack(spacing: 3) {
            if booked && check { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)) }
            Text(text).scaledFont(12, .bold)
        }
        .foregroundStyle(booked ? on : Jade.ink2)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(booked ? color : Jade.fill))
        .fixedSize()
        .accessibilityLabel(booked ? "\(text), counted" : "\(text), not counted yet")
    }
}

/// Icon + name, with an optional tag on the right.
struct CardTitle<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        // A half-width card has about 142 pt for the icon, the name and "✓ Workout": tighten up,
        // then let the icon go (the name may shrink a little), so it never reads "Ste…".
        ViewThatFits(in: .horizontal) {
            row(spacing: 6, showIcon: true)
            row(spacing: 3, showIcon: true)
            row(spacing: 3, showIcon: false)
        }
        .frame(minHeight: 22)
    }

    private func row(spacing: CGFloat, showIcon: Bool) -> some View {
        HStack(spacing: spacing) {
            if showIcon {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Jade.ink2)
            }
            Text(title).scaledFont(15, .semibold).foregroundStyle(Jade.ink).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: spacing == 6 ? 4 : 2)
            trailing()
        }
    }
}

extension CardTitle where Trailing == EmptyView {
    init(icon: String, title: String) {
        self.init(icon: icon, title: title) { EmptyView() }
    }
}

struct BigNumber: View {
    let text: String
    var size: CGFloat = 46
    /// "PM" after a 12-hour time, smaller and grey.
    var period: String?

    init(_ text: String, size: CGFloat = 46, period: String? = nil) {
        self.text = text
        self.size = size
        self.period = period
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text)
                .scaledFont(size, .bold)
                .foregroundStyle(Jade.ink)
                .monospacedDigit()
            if let period {
                Text(period)
                    .scaledFont(size * 0.4, .bold)
                    .foregroundStyle(Jade.ink2)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

private extension View {
    /// A card that opens its note with a tap (and is shaded while it is open).
    func explains<Key: Hashable, Note: View>(_ key: Key, _ open: Binding<Key?>, @ViewBuilder note: @escaping () -> Note) -> some View {
        self
            .overlay(RoundedRectangle(cornerRadius: Metrics.card, style: .continuous).fill(Jade.ink.opacity(open.wrappedValue == key ? 0.05 : 0)).allowsHitTesting(false))
            .contentShape(Rectangle())
            .onTapGesture { open.wrappedValue = key }
            .infoNote(isPresented: Binding(get: { open.wrappedValue == key }, set: { if !$0, open.wrappedValue == key { open.wrappedValue = nil } }), note: note)
            .accessibilityAction(named: "Explain") { open.wrappedValue = key }
    }
}
