import Foundation

/// The 「自律周」 rules (decided 2026-11-01). A week counts when the user works out at least
/// 3 times and sleeps on time at least 5 nights. Nothing is ever taken away for a missed week.
public struct DisciplineRules: Sendable, Equatable {
    public var workoutsPerWeek = 3
    public var onTimeNightsPerWeek = 5
    /// One workout = a single workout this long, in the whole minutes the app shows
    /// (`WorkoutSession.shownMinutes`)…
    public var minWorkoutMinutes: Double = 20
    /// …or a day with at least this many steps.
    public var activeDaySteps = 10_000
    /// "On time" = asleep no later than the target bedtime plus this. Earlier is always fine.
    public var bedtimeGraceMinutes = 30
    /// Leave days a week; each one counts as an on-time night, no reason needed.
    public var leaveDaysPerWeek = 1
    /// Monthly achievements are settled in blocks of 4 weeks, 3 of which must count.
    public var weeksPerBlock = 4
    public var weeksNeededPerBlock = 3

    public init() {}

    public static let standard = DisciplineRules()
}

/// Target bedtime as wall-clock time, e.g. 23:00. Hours before noon mean "after midnight".
public struct Bedtime: Sendable, Equatable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int = 0) {
        self.hour = hour
        self.minute = minute
    }

    /// The target for the night that ends on the morning of `day`.
    public func target(forNightEnding day: Date, calendar: Calendar = .current) -> Date {
        let morning = calendar.startOfDay(for: day)
        let evening = hour >= 12 ? calendar.date(byAdding: .day, value: -1, to: morning)! : morning
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: evening)!
    }
}

/// How one calendar week is going.
public struct WeekProgress: Sendable, Equatable {
    public var weekStart: Date
    public var workouts: Int
    public var onTimeNights: Int
    public var rules: DisciplineRules

    public var isDisciplined: Bool {
        workouts >= rules.workoutsPerWeek && onTimeNights >= rules.onTimeNightsPerWeek
    }
}

/// Judges days and weeks against `DisciplineRules`.
public struct DisciplineTracker: Sendable {
    public var rules: DisciplineRules
    public var bedtime: Bedtime
    /// Friday and Saturday nights (the nights ending on a weekend morning), when set.
    public var weekendBedtime: Bedtime?
    /// Weeks start on the calendar's first weekday; the 3D app fixes it to Monday.
    public var calendar: Calendar

    public init(rules: DisciplineRules = .standard, bedtime: Bedtime, weekendBedtime: Bedtime? = nil,
                calendar: Calendar = .current) {
        self.rules = rules
        self.bedtime = bedtime
        self.weekendBedtime = weekendBedtime
        self.calendar = calendar
    }

    /// The bedtime that applies to the night ending on the morning of `day`.
    public func bedtime(forNightEnding day: Date) -> Bedtime {
        calendar.isDateInWeekend(day) ? weekendBedtime ?? bedtime : bedtime
    }

    /// The target time to be asleep by, for the night ending on the morning of `day`.
    public func target(forNightEnding day: Date) -> Date {
        bedtime(forNightEnding: day).target(forNightEnding: day, calendar: calendar)
    }

    /// The day had one of the week's workouts: a single sport workout of 20+ minutes, or 10,000+ steps.
    public func countsAsWorkout(_ day: HealthSnapshot) -> Bool {
        day.allWorkouts.contains { countsAsWorkout($0) } || (day.steps ?? 0) >= rules.activeDaySteps
    }

    /// A single workout is one of the week's workouts: 20+ minutes of a sport, counted in the whole
    /// minutes the app shows, so a workout that reads "20 min" counts (WHOOP writes a 20-minute
    /// activity into Apple Health as 19:59). A Mind & Body or
    /// Tai Chi session feeds Matcha (mindfulness), which PRD v0.3 §5.1 lists as a habit, not a sport,
    /// so it grows no workout bubble and fills no workout cell however long it is.
    public func countsAsWorkout(_ workout: WorkoutSession) -> Bool {
        Double(workout.shownMinutes) >= rules.minWorkoutMinutes && Activity(workoutName: workout.name).isWorkout
    }

    /// nil when there is no sleep data for that night.
    public func isOnTimeNight(_ day: HealthSnapshot) -> Bool? {
        guard let onset = day.sleepOnset else { return nil }
        let latest = target(forNightEnding: day.day)
            .addingTimeInterval(TimeInterval(rules.bedtimeGraceMinutes * 60))
        return onset <= latest
    }

    /// Consecutive on-time nights ending with the most recent night that has sleep data.
    public func onTimeStreak(_ snapshots: [HealthSnapshot]) -> Int {
        var streak = 0
        for day in snapshots.sorted(by: { $0.day > $1.day }) {
            guard let onTime = isOnTimeNight(day) else { continue }
            guard onTime else { break }
            streak += 1
        }
        return streak
    }

    public func weekStart(for date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Progress of the week containing `date`. Leave days fill in missed nights, up to the weekly allowance.
    public func week(containing date: Date, snapshots: [HealthSnapshot], leaveDays: Set<Date> = []) -> WeekProgress {
        let start = weekStart(for: date)
        let end = calendar.date(byAdding: .day, value: 7, to: start)!
        let days = snapshots.filter { $0.day >= start && $0.day < end }

        let workouts = days.filter(countsAsWorkout).count
        let nightsOnTime = days.filter { isOnTimeNight($0) == true }
        let leave = leaveDays
            .map { calendar.startOfDay(for: $0) }
            .filter { day in day >= start && day < end && !nightsOnTime.contains { $0.day == day } }
        let nights = nightsOnTime.count + min(Set(leave).count, rules.leaveDaysPerWeek)

        return WeekProgress(weekStart: start, workouts: workouts, onTimeNights: nights, rules: rules)
    }

    /// Starts of the finished weeks before `now` (inside the snapshots' range) that counted.
    public func disciplinedWeeks(in snapshots: [HealthSnapshot], before now: Date, leaveDays: Set<Date> = []) -> [Date] {
        let current = weekStart(for: now)
        let starts = Set(snapshots.map { weekStart(for: $0.day) }).filter { $0 < current }
        return starts.sorted().filter { week(containing: $0, snapshots: snapshots, leaveDays: leaveDays).isDisciplined }
    }
}
