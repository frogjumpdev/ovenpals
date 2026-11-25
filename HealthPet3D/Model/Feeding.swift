import Foundation
import PetCore

/// A food bubble on home (PRD v0.2 §4.3, B 轻泡): one credit waiting for a tap.
struct FoodBubble: Identifiable, Equatable {
    enum Kind { case workout, steps, moon, load }

    let credit: Credit
    let kind: Kind
    let icon: String
    /// "32m", "10.2k", "22:48", "11.4"
    let label: String
    /// Fixed place around the pet (see `HomeLayout.slots`).
    let slot: Int
    /// "Run, 32 minutes"
    let spoken: String

    var id: String { credit.id }
}

/// What a tap booked, for the moment after the pet has eaten (PRD v0.2 §4.4).
struct BookingFeedback: Equatable {
    /// Where the little dot flies: this week's workout cells, the night cells, or Memories.
    enum Target: Equatable { case workouts, nights, memories }

    let kind: CreditKind
    let target: Target
    /// "Chili +1", "Chili Lv 16"; nil for a late night or Whoop strain.
    let tag: String?
    /// "yum" (plain), "levelup" / "bigcheer" (a level up; Lv 10 and 20 are big), "proud" (an on-time night).
    let expression: String
    /// 升级 for a new level, 大庆祝 for Lv 10 and 20 (PRD §5.3).
    static func levelMoment(_ level: Int) -> String { level == 10 || level == 20 ? "bigcheer" : "levelup" }
    /// An on-time night: the moon's check in the status area lights up.
    let lightsCheck: Bool
}

/// This week's cells under the status area (and on Today): 3 workouts, 5 nights, no numbers.
struct WeekCells: Equatable {
    enum Night: Equatable { case on, leave, empty }

    /// Filled workout cells, 0...3.
    var workouts: Int
    /// The five night cells, in the order the nights came: on time, the leave night, not yet.
    var nights: [Night]
    /// Counted so far (more than the cells hold still counts, for the ledger and milestones).
    var workoutCount: Int
    var nightCount: Int

    var filledNights: Int { nights.filter { $0 != .empty }.count }

    static let empty = WeekCells(workouts: 0, nights: Array(repeating: .empty, count: 5), workoutCount: 0, nightCount: 0)
}

extension AppModel {
    // MARK: - Food bubbles

    /// Bubbles to show: every pending credit, at most two workouts at a time (the rest queue),
    /// each kind in its own place around the pet.
    var foodBubbles: [FoodBubble] {
        let preferred: [FoodBubble.Kind: [Int]] = [
            .moon: [0, 4, 2, 1, 3], .workout: [1, 3, 4, 0, 2], .steps: [2, 0, 4, 1, 3], .load: [4, 0, 2, 1, 3],
        ]
        // Places are handed out over today's eaten food too, so a bubble stays where it is while
        // the one next to it is eaten (the second workout doesn't slide into the first one's place).
        let waiting = Set(pending.map(\.id))
        var taken = Set<Int>()
        var workouts = 0
        var result: [FoodBubble] = []
        for credit in openCredits {
            let kind = Self.bubbleKind(credit.kind)
            let shown = waiting.contains(credit.id)
            if kind == .workout {
                guard workouts < 2 else { continue }
                if shown { workouts += 1 }
            }
            guard let slot = preferred[kind]?.first(where: { !taken.contains($0) }) else { continue }
            taken.insert(slot)
            guard shown, let day = countedDays.first(where: { $0.day == credit.day }) else { continue }
            result.append(bubble(credit, kind: kind, day: day, slot: slot))
        }
        return result
    }

    private static func bubbleKind(_ kind: CreditKind) -> FoodBubble.Kind {
        switch kind {
        case .workout: .workout
        case .steps: .steps
        case .night: .moon
        case .load: .load
        }
    }

    private func bubble(_ credit: Credit, kind: FoodBubble.Kind, day: HealthSnapshot, slot: Int) -> FoodBubble {
        switch credit.kind {
        case .workout:
            let workout = credit.workout ?? WorkoutSession(name: "Workout", minutes: 0)
            let minutes = Int(workout.minutes.rounded())
            return FoodBubble(credit: credit, kind: kind, icon: workoutIcon(workout.name), label: "\(minutes)m", slot: slot,
                              spoken: "\(workout.name), \(minutes) minutes")
        case .steps:
            let steps = day.steps ?? 0
            return FoodBubble(credit: credit, kind: kind, icon: "shoeprints.fill", label: Format.short(steps), slot: slot,
                              spoken: "\(steps.formatted()) steps")
        case .night:
            // 50 pt: "10:48" without PM even on the 12-hour clock (PRD v0.3 §6, suggestion)
            let onset = day.sleepOnset.map(Format.shortTime) ?? "–"
            let spoken = day.sleepOnset.map(Format.time) ?? "–"
            return FoodBubble(credit: credit, kind: kind, icon: "moon", label: onset, slot: slot, spoken: "Last night, asleep at \(spoken)")
        case .load:
            let strain = String(format: "%.1f", day.strain ?? 0)
            return FoodBubble(credit: credit, kind: kind, icon: "gauge.with.dots.needle.50percent", label: strain, slot: slot,
                              spoken: "Whoop strain \(strain)")
        }
    }

    // MARK: - Booking

    /// The pet a credit feeds (nil: a late night, Whoop strain).
    func beneficiary(of credit: Credit, in days: [HealthSnapshot]) -> Activity? {
        switch credit.kind {
        case .workout: credit.workout.map { Activity(workoutName: $0.name) }
        case .steps: .walking
        case .night: days.first { $0.day == credit.day }.flatMap(discipline.isOnTimeNight) == true ? .onTimeSleep : nil
        case .load: nil
        }
    }

    /// The ledger line for a credit.
    func creditRecord(_ credit: Credit, in days: [HealthSnapshot], auto: Bool, at date: Date) -> CreditRecord {
        let day = days.first { $0.day == credit.day }
        let detail: String = switch credit.kind {
        case .workout: credit.workout.map { "\($0.name) \(Int($0.minutes.rounded())) min" } ?? "Workout"
        case .steps: "\((day?.steps ?? 0).formatted()) steps"
        case .night: "Asleep \(day?.sleepOnset.map(Format.time) ?? "–")"
        case .load: "Strain \(String(format: "%.1f", day?.strain ?? 0))"
        }
        return CreditRecord(id: credit.id, day: credit.day, kind: credit.kind, detail: detail,
                            activity: beneficiary(of: credit, in: days), bookedAt: date, auto: auto)
    }

    /// A tap on a food bubble: the credit is booked (pet experience, this week's cells, a ledger
    /// line) and the home gets what it needs for the moment after the pet has eaten.
    func book(_ credit: Credit) -> BookingFeedback {
        let now = Date()
        let days = countedDays
        let activity = beneficiary(of: credit, in: days)
        let pet = activity.flatMap { a in Pet3D.all.first { $0.activity == a } }
        let before = pet.map { record($0).level } ?? 0
        creditBook.add([creditRecord(credit, in: days, auto: false, at: now)])
        reevaluate(now: now)
        let after = pet.map { record($0).level } ?? 0
        if after > before { creditBook.setLevels(credit.id, from: before, to: after) }
        // a level up of a pet that was already there (a new one gets its 星星眼 instead)
        let levelUp = before > 0 && after > before

        switch credit.kind {
        case .workout, .steps:
            return BookingFeedback(kind: credit.kind, target: .workouts,
                                   tag: pet.map { levelUp ? "\($0.name) Lv \(after)" : "\($0.name) +1" },
                                   expression: levelUp ? BookingFeedback.levelMoment(after) : "yum", lightsCheck: false)
        case .night where pet != nil:
            return BookingFeedback(kind: .night, target: .nights,
                                   tag: pet.map { levelUp ? "\($0.name) Lv \(after)" : "\($0.name) +1" },
                                   expression: levelUp ? BookingFeedback.levelMoment(after) : "proud", lightsCheck: true)
        case .night, .load:
            // a late night or Whoop strain: eaten all the same, kept in Memories, no tag, never a sad look
            return BookingFeedback(kind: credit.kind, target: .memories, tag: nil, expression: "yum", lightsCheck: false)
        }
    }

    /// Test build: give today's taps back, so the bubbles grow again.
    func regrowFood() {
        let rules = creditRules
        let now = Date()
        creditBook.unbook { !$0.auto && rules.autoBookTime(for: $0.day) > now }
        reevaluate(now: now)
    }

    /// The ledger's booking lines, newest first.
    var creditRecords: [CreditRecord] { creditBook.records.reversed() }

    // MARK: - What is booked today

    private func isPending(_ kind: CreditKind, key: String? = nil) -> Bool {
        let today = Calendar.current.startOfDay(for: Date())
        return pending.contains { $0.day == today && $0.kind == kind && (key == nil || $0.key == key) }
    }

    /// Last night's moon was eaten (or collected at 04:00).
    var nightBooked: Bool { !isPending(.night) }
    var stepsBooked: Bool { !isPending(.steps) }

    /// Whether today's longest workout was eaten.
    var mainWorkoutBooked: Bool {
        guard let today, let main = mainWorkout else { return true }
        let workouts = today.allWorkouts
        let keys = creditRules.workoutKeys(workouts)
        guard let index = workouts.firstIndex(of: main), let key = keys[index] else { return true }
        return !isPending(.workout, key: key)
    }

    // MARK: - This week's cells

    var weekCells: WeekCells {
        guard let week else { return .empty }
        let tracker = discipline
        let rules = tracker.rules
        var nights: [WeekCells.Night] = []
        var leaveUsed = 0
        for day in weekDays {
            if tracker.isOnTimeNight(day) == true {
                nights.append(.on)
            } else if leaveDays.contains(day.day), leaveUsed < rules.leaveDaysPerWeek {
                nights.append(.leave)
                leaveUsed += 1
            }
        }
        let shown = Array(nights.prefix(rules.onTimeNightsPerWeek))
        return WeekCells(workouts: min(week.workouts, rules.workoutsPerWeek),
                         nights: shown + Array(repeating: .empty, count: rules.onTimeNightsPerWeek - shown.count),
                         workoutCount: week.workouts, nightCount: week.onTimeNights)
    }

    /// "2 workouts + 2 early nights to go" (Today's only sentence, and it is data).
    var weekToGo: String {
        let rules = discipline.rules
        let cells = weekCells
        let workouts = max(0, rules.workoutsPerWeek - cells.workoutCount)
        let nights = max(0, rules.onTimeNightsPerWeek - cells.nightCount)
        let parts = [workouts > 0 ? (workouts == 1 ? "1 workout" : "\(workouts) workouts") : nil,
                     nights > 0 ? (nights == 1 ? "1 early night" : "\(nights) early nights") : nil].compactMap { $0 }
        return parts.isEmpty ? "A disciplined week ✓" : parts.joined(separator: " + ") + " to go"
    }

    // MARK: - A day in the calendar row

    /// "Mon 3" and "Run 32 min · Asleep 22:48 ✓", for a tap on a day; nil for a day with nothing yet.
    func dayNote(_ day: WeekDay) -> (title: String, body: String)? {
        guard !day.isFuture, let snapshot = weekDays.first(where: { $0.day == day.id }) else { return nil }
        let tracker = discipline
        var parts: [String] = []
        if let workout = snapshot.allWorkouts.filter({ tracker.countsAsWorkout($0) }).max(by: { $0.minutes < $1.minutes }) {
            parts.append("\(workout.name) \(Int(workout.minutes.rounded())) min")
        } else if (snapshot.steps ?? 0) >= tracker.rules.activeDaySteps {
            parts.append("\(Format.short(snapshot.steps ?? 0)) steps")
        }
        if let onset = snapshot.sleepOnset {
            parts.append("Asleep \(Format.time(onset))" + (tracker.isOnTimeNight(snapshot) == true ? " ✓" : ""))
        } else if day.leave {
            parts.append("Leave night")
        }
        guard !parts.isEmpty else { return nil }
        let title = day.id.formatted(.dateTime.weekday(.abbreviated)) + " \(day.number)"
        return (title, parts.joined(separator: " · "))
    }
}
