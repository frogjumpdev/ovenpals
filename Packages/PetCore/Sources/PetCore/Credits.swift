import Foundation

/// 点击 = 入账 (PRD v0.2 §4.4, decided 2026-11-08). A day's data first waits on home as a food
/// bubble ("pending"); a tap books it into the pet's experience, this week's cells and the ledger.
/// Whatever is not tapped is booked for the user at 04:00 the next day, exactly as if tapped.
/// Booking only decides *when* something is seen to count, never whether or how much: the rules
/// (`DisciplineRules`, `ActivityTracker`) are unchanged.
public enum CreditKind: String, Codable, Sendable, CaseIterable {
    /// One workout of 20 minutes or more: its sport's pet, one workout for the week.
    case workout
    /// A 10k-step day: Onigiri, one workout for the week.
    case steps
    /// Last night (the moon bubble): an on-time night for the week, Mantou and Coffee Bean.
    case night
    /// Whoop's day strain: a ledger line only (Honey and Protein Bar are settled by the day).
    case load
}

/// One thing the pet can eat, i.e. one line the ledger will get.
public struct Credit: Sendable, Equatable, Identifiable {
    /// The day the data belongs to (sleep: the morning the night ended).
    public var day: Date
    public var kind: CreditKind
    /// Stable within its day: "workout:Run:32", "steps", "night", "load".
    public var key: String
    /// The workout, for workout credits.
    public var workout: WorkoutSession?

    public init(day: Date, kind: CreditKind, key: String, workout: WorkoutSession? = nil) {
        self.day = day
        self.kind = kind
        self.key = key
        self.workout = workout
    }

    public var id: String { "\(Int(day.timeIntervalSince1970))/\(key)" }
}

/// A booked credit, as the Memories ledger lists it.
public struct CreditRecord: Codable, Sendable, Equatable, Identifiable {
    /// The credit's id.
    public var id: String
    public var day: Date
    public var kind: CreditKind
    /// What it was, ready to show: "Run 32 min", "10,240 steps", "Asleep 22:48", "Strain 11.4".
    public var detail: String
    /// The pet that got the experience (nil: a late night, Whoop strain).
    public var activity: Activity?
    public var bookedAt: Date
    /// Booked at 04:00 the next day because it wasn't tapped (「自动收下」).
    public var auto: Bool
    /// The pet's level before and after, when it went up.
    public var levelFrom: Int?
    public var levelTo: Int?

    public init(id: String, day: Date, kind: CreditKind, detail: String, activity: Activity?, bookedAt: Date,
                auto: Bool, levelFrom: Int? = nil, levelTo: Int? = nil) {
        self.id = id
        self.day = day
        self.kind = kind
        self.detail = detail
        self.activity = activity
        self.bookedAt = bookedAt
        self.auto = auto
        self.levelFrom = levelFrom
        self.levelTo = levelTo
    }
}

// MARK: - Another time zone

extension CreditRecord {
    /// The same line with its day (and the day in its id) as the start of that calendar date in
    /// `calendar`, so a credit collected in another time zone isn't offered again (see `CalendarDay`).
    public func rekeyed(in calendar: Calendar) -> CreditRecord {
        var line = self
        line.day = CalendarDay.rekey(day, in: calendar)
        line.id = CalendarDay.rekeyID(id, in: calendar)
        return line
    }
}

// MARK: - The iCloud copy (PRD v0.3 §10.3 #19, App Review 5.1.3)

extension CreditRecord {
    /// The lines as iCloud keeps them: the same pet, day, kind, booking time, 「Collected for you」
    /// and levels, but no minutes, steps, times or strain, neither in the id nor in the detail.
    public static func bare(_ records: [CreditRecord]) -> [CreditRecord] {
        zip(records, bareIDs(records.map(\.id))).map { pair in
            var line = pair.0
            line.id = pair.1
            line.detail = pair.0.bareDetail
            return line
        }
    }

    /// A workout's id without its minutes: "1731456000/workout:Run:32" → "1731456000/workout:Run#1",
    /// the day's second run "#2", in the order given. Other ids carry no value and stay as they are,
    /// and so do ids that are bare already.
    public static func bareIDs(_ ids: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return ids.map { id in
            guard id.contains("/workout:"),
                  let minutes = id.range(of: #":\d+(#\d+)?$"#, options: .regularExpression) else { return id }
            let base = String(id[..<minutes.lowerBound])
            let n = seen[base, default: 0] + 1
            seen[base] = n
            return "\(base)#\(n)"
        }
    }

    /// What the line says without numbers: "Run", "10k-step day", "Night's sleep", "Whoop strain".
    public var bareDetail: String {
        switch kind {
        case .workout: detail.replacingOccurrences(of: #" \d+ min$"#, with: "", options: .regularExpression)
        case .steps: "10k-step day"
        case .night: "Night's sleep"
        case .load: "Whoop strain"
        }
    }

    /// A line that came back from iCloud and hasn't got its numbers again yet.
    public var isBare: Bool { detail == bareDetail }
}

/// The rules of the pending layer. Pure functions; the app keeps which credits were booked.
public struct CreditRules: Sendable {
    public var discipline: DisciplineTracker
    /// Untapped credits are booked at this hour of the next day (it is also when a day's bubbles end).
    public var autoBookHour = 4
    /// Whoop strain below this isn't worth a bubble.
    public var minStrain = 0.1

    public init(discipline: DisciplineTracker) {
        self.discipline = discipline
    }

    private var calendar: Calendar { discipline.calendar }

    // MARK: - What a day has to eat

    /// The day's credits: each workout of 20+ minutes (mindfulness is not a bubble, it counts
    /// as it happens), a 10k-step day, last night's sleep, Whoop strain.
    public func credits(on day: HealthSnapshot) -> [Credit] {
        var result: [Credit] = []
        let workouts = day.allWorkouts
        for (workout, key) in zip(workouts, workoutKeys(workouts)) {
            if let key { result.append(Credit(day: day.day, kind: .workout, key: key, workout: workout)) }
        }
        if (day.steps ?? 0) >= discipline.rules.activeDaySteps {
            result.append(Credit(day: day.day, kind: .steps, key: "steps"))
        }
        if day.sleepOnset != nil {
            result.append(Credit(day: day.day, kind: .night, key: "night"))
        }
        if let strain = day.strain, strain >= minStrain {
            result.append(Credit(day: day.day, kind: .load, key: "load"))
        }
        return result
    }

    /// The credit key of each workout, nil for one that isn't a bubble (too short, mindfulness).
    /// The same workout keeps its key as more of the day's data arrives.
    public func workoutKeys(_ workouts: [WorkoutSession]) -> [String?] {
        var seen: [String: Int] = [:]
        return workouts.map { workout in
            guard discipline.countsAsWorkout(workout) else { return nil }
            let base = "workout:\(workout.name):\(Int(workout.minutes.rounded()))"
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return n == 0 ? base : "\(base)#\(n + 1)"
        }
    }

    // MARK: - Pending, booked, booked for you

    /// When an untapped credit of `day` is booked for the user: 04:00 the next day.
    public func autoBookTime(for day: Date) -> Date {
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
        return calendar.date(bySettingHour: autoBookHour, minute: 0, second: 0, of: next) ?? next
    }

    /// Every credit of the days that can still be tapped (before their 04:00), booked or not:
    /// the food bubbles keep their places while the others are eaten.
    public func open(in snapshots: [HealthSnapshot], now: Date) -> [Credit] {
        snapshots.filter { now < autoBookTime(for: $0.day) }
            .sorted { $0.day < $1.day }
            .flatMap(credits(on:))
    }

    /// Credits still waiting for a tap: not booked, and before their 04:00.
    public func pending(in snapshots: [HealthSnapshot], booked: Set<String>, now: Date) -> [Credit] {
        open(in: snapshots, now: now).filter { !booked.contains($0.id) }
    }

    /// Credits whose 04:00 has passed without a tap, from `since` on (earlier days count as booked
    /// without a ledger line: they are the history the first open shows).
    public func due(in snapshots: [HealthSnapshot], booked: Set<String>, now: Date, since: Date) -> [Credit] {
        let first = calendar.startOfDay(for: since)
        return snapshots.filter { $0.day >= first && now >= autoBookTime(for: $0.day) }
            .sorted { $0.day < $1.day }
            .flatMap(credits(on:))
            .filter { !booked.contains($0.id) }
    }

    /// The day as it counts so far: whatever is still pending is taken out (a pending workout is
    /// removed, a pending 10k day stays under 10k, a pending night has no sleep times). Everything
    /// that counts (the week, the calendar, levels, the ledger) is worked out from these.
    public func booked(_ day: HealthSnapshot, pending: [Credit]) -> HealthSnapshot {
        let keys = Set(pending.filter { $0.day == day.day }.map(\.key))
        guard !keys.isEmpty else { return day }
        var result = day
        if keys.contains("steps"), let steps = day.steps {
            result.steps = min(steps, discipline.rules.activeDaySteps - 1)
        }
        if keys.contains("night") {
            result.sleepOnset = nil
            result.wakeTime = nil
        }
        let workouts = day.allWorkouts
        let workoutKeys = workoutKeys(workouts)
        if workoutKeys.contains(where: { $0.map(keys.contains) ?? false }) {
            let kept = zip(workouts, workoutKeys).filter { !($0.1.map(keys.contains) ?? false) }.map(\.0)
            let longest = kept.max { $0.minutes < $1.minutes }
            result.workouts = kept
            result.workoutMinutes = longest?.minutes
            result.workoutType = longest?.name
        }
        return result
    }

    public func booked(_ days: [HealthSnapshot], pending: [Credit]) -> [HealthSnapshot] {
        days.map { booked($0, pending: pending) }
    }
}
