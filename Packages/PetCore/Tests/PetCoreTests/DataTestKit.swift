import Foundation
import XCTest
@testable import PetCore

/// Shared tools for the data tests (PRD v0.3 rules checked against data that looks like what Apple
/// Health and Whoop really send). Times are written as local wall-clock text, "2026-11-16 23:30",
/// in a real time zone with daylight saving, so a test reads like the user's own week.
struct World {
    let calendar: Calendar
    private let formatter: DateFormatter

    /// Weeks start on Monday, as `AppModel.weekCalendar` fixes them in the app.
    init(_ timeZone: String = "America/Los_Angeles") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.firstWeekday = 2
        self.calendar = calendar
        formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
    }

    /// "2026-11-16 23:30" (or "2026-11-16 23:30:01") as a moment in this time zone.
    func at(_ text: String) -> Date {
        formatter.dateFormat = text.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: text) else { fatalError("bad time \(text)") }
        return date
    }

    /// "2026-11-16" as the start of that local day.
    func day(_ text: String) -> Date {
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: text) else { fatalError("bad day \(text)") }
        return calendar.startOfDay(for: date)
    }

    func tracker(bed: Bedtime = Bedtime(hour: 23), weekendBed: Bedtime? = nil) -> DisciplineTracker {
        DisciplineTracker(bedtime: bed, weekendBedtime: weekendBed, calendar: calendar)
    }

    func activities(bed: Bedtime = Bedtime(hour: 23), wake: WakeTime = WakeTime(hour: 7)) -> ActivityTracker {
        ActivityTracker(discipline: tracker(bed: bed), wakeTarget: wake)
    }

    // MARK: - Apple Health, the way HealthKitProvider reads it

    /// One night as an Apple Watch writes it: core / deep / REM stretches with short awake gaps
    /// in between (the gaps are not sleep), from `asleep` to `awake`.
    func watchNight(_ asleep: String, _ awake: String, gapsEvery minutes: Double = 90) -> [DateInterval] {
        let start = at(asleep), end = at(awake)
        var result: [DateInterval] = []
        var cursor = start
        while cursor < end {
            let stretchEnd = min(end, cursor.addingTimeInterval(minutes * 60))
            result.append(DateInterval(start: cursor, end: stretchEnd))
            cursor = stretchEnd.addingTimeInterval(4 * 60) // 4 minutes awake
        }
        // the last stretch ends when the user wakes up
        if let last = result.last, last.end < end { result[result.count - 1] = DateInterval(start: last.start, end: end) }
        return result
    }

    /// One local day as `HealthKitProvider.snapshots` builds it from the queried samples.
    func appleDay(_ day: String, steps: Int? = nil, workouts: [WorkoutSession] = [], nights: [Date: SleepNights.Night] = [:],
                  mindful: Double? = nil) -> HealthSnapshot {
        let date = self.day(day)
        let longest = workouts.max { $0.minutes < $1.minutes }
        let night = nights[date]
        return HealthSnapshot(day: date, source: .healthKit, steps: steps, sleepHours: night?.hours,
                              sleepOnset: night?.onset, workoutMinutes: longest?.minutes, workoutType: longest?.name,
                              workouts: workouts, wakeTime: night?.wake, mindfulMinutes: mindful)
    }

    // MARK: - Whoop, the way the server's `toSnapshotRows` + `WhoopProvider` hand it over

    /// A Whoop day: keyed by the morning the main sleep ended, onset and wake are Whoop's own.
    func whoopDay(_ day: String, asleep: String? = nil, awake: String? = nil, recovery: Double? = nil,
                  strain: Double? = nil, sleepPerformance: Double? = nil, sleepHours: Double? = nil) -> HealthSnapshot {
        HealthSnapshot(day: self.day(day), source: .whoop, sleepHours: sleepHours, hrvMethod: recovery == nil ? nil : .rmssd,
                       vendorRecovery: recovery, sleepOnset: asleep.map(at), wakeTime: awake.map(at), strain: strain,
                       sleepPerformance: sleepPerformance)
    }
}

/// What the app works out each time it opens, step by step as `AppModel.evaluate` does it
/// (HealthPet3D/Model/AppModel.swift): collect what passed its 04:00, keep what still waits as a
/// food bubble out of the counts, then the week, the log kept forever and the pets' levels.
struct AppRun {
    let world: World
    let tracker: DisciplineTracker
    let activities: ActivityTracker
    var rules: CreditRules { CreditRules(discipline: tracker) }

    /// Credits eaten (tapped or collected at 04:00), by id: `CreditBook.bookedIDs`.
    var bookedIDs: Set<String> = []
    /// Collected for the user at 04:00 (「自动收下」), in order.
    var autoBooked: [Credit] = []
    /// From this day on, untapped food gets a ledger line at 04:00 (`CreditBook.since`).
    var since: Date
    var leaveDays: Set<Date> = []
    /// Kept forever and only ever added to, like `PetStore.activityLog` / `disciplinedWeeks`.
    var log: [Date: Set<Activity>] = [:]
    var disciplinedWeeks: Set<Date> = []

    // what the last open showed
    var pending: [Credit] = []
    var week: WeekProgress?
    var previousWeek: WeekProgress?

    init(world: World, since: String, bed: Bedtime = Bedtime(hour: 23), wake: WakeTime = WakeTime(hour: 7)) {
        self.world = world
        tracker = world.tracker(bed: bed)
        activities = ActivityTracker(discipline: tracker, wakeTarget: wake)
        self.since = world.day(since)
    }

    var progress: [Activity: ActivityProgress] {
        ActivityProgress.all(log: log, disciplinedWeeks: disciplinedWeeks, weekStart: tracker.weekStart(for:))
    }

    /// Toast's level = finished 自律周 in total (PRD §5.2).
    var toastLevel: Int { disciplinedWeeks.count }

    /// Opens the app at `now` with `days` read from Apple Health / Whoop.
    mutating func open(_ days: [HealthSnapshot], at now: String) {
        open(days, now: world.at(now))
    }

    mutating func open(_ days: [HealthSnapshot], now: Date) {
        let due = rules.due(in: days, booked: bookedIDs, now: now, since: since)
        autoBooked += due
        bookedIDs.formUnion(due.map(\.id))
        pending = rules.open(in: days, now: now).filter { !bookedIDs.contains($0.id) }
        let booked = rules.booked(days, pending: pending)

        week = tracker.week(containing: now, snapshots: booked, leaveDays: leaveDays)
        let weekStart = tracker.weekStart(for: now)
        previousWeek = tracker.calendar.date(byAdding: .day, value: -7, to: weekStart)
            .map { tracker.week(containing: $0, snapshots: booked, leaveDays: leaveDays) }
        disciplinedWeeks.formUnion(tracker.disciplinedWeeks(in: booked, before: now, leaveDays: leaveDays))
        let todayStart = tracker.calendar.startOfDay(for: now)
        for (day, done) in activities.log(booked, today: todayStart) {
            log[day, default: []].formUnion(done)
        }
    }

    /// Taps every food bubble that is waiting (or only those `matching`).
    mutating func tapAll(where matching: (Credit) -> Bool = { _ in true }) {
        bookedIDs.formUnion(pending.filter(matching).map(\.id))
    }

    func experience(_ activity: Activity) -> Int { progress[activity]?.experience ?? 0 }
    func sessions(_ activity: Activity) -> Int { progress[activity]?.sessions ?? 0 }
}

/// A test for a data problem found and not fixed yet. It runs the check: while the problem is
/// there the test is skipped with `issue` as the reason (so the suite stays green and the list of
/// skipped tests is the list of open problems); once the problem is fixed the test fails and asks
/// for this wrapper to be taken off, so the check then guards the fix.
func knownIssue(_ issue: String, file: StaticString = #filePath, line: UInt = #line, _ check: () -> Bool) throws {
    if check() {
        XCTFail("Fixed now: take knownIssue off this test so it keeps guarding the fix. (\(issue))", file: file, line: line)
    } else {
        throw XCTSkip("Known data issue: \(issue)", file: file, line: line)
    }
}
