import XCTest
@testable import PetCore

/// Every check-in rule of PRD v0.3 at its edges: one minute, one step, one percent either side of
/// each number the user decided. Times are local to Los Angeles (daylight saving included), the
/// way an overseas user's phone has them. The week is 2026-11-16 (Mon) to 2026-11-22 (Sun).
final class PRDv03BoundaryTests: XCTestCase {
    private let w = World()
    private lazy var tracker = w.tracker()

    private func day(_ d: String, steps: Int? = nil, workouts: [WorkoutSession] = [], asleep: String? = nil,
                     awake: String? = nil, mindful: Double? = nil) -> HealthSnapshot {
        let longest = workouts.max { $0.minutes < $1.minutes }
        return HealthSnapshot(day: w.day(d), source: .healthKit, steps: steps, sleepOnset: asleep.map(w.at),
                              workoutMinutes: longest?.minutes, workoutType: longest?.name, workouts: workouts,
                              wakeTime: awake.map(w.at), mindfulMinutes: mindful)
    }

    private func run(_ minutes: Double, _ name: String = "Run") -> WorkoutSession {
        WorkoutSession(name: name, minutes: minutes)
    }

    // MARK: - §4.1 One workout: a single workout of 20+ minutes, or 10,000+ steps that day

    func testWorkoutNeedsTwentyMinutesInOneGo() {
        XCTAssertFalse(tracker.countsAsWorkout(day("2026-11-17", workouts: [run(19.9)])))
        XCTAssertTrue(tracker.countsAsWorkout(day("2026-11-17", workouts: [run(20)])))
        // two short ones don't add up: 「单次」 ≥ 20 minutes
        XCTAssertFalse(tracker.countsAsWorkout(day("2026-11-17", workouts: [run(15), run(15, "Ride")])))
    }

    func testTenThousandStepsIsAWorkout() {
        XCTAssertFalse(tracker.countsAsWorkout(day("2026-11-17", steps: 9_999)))
        XCTAssertTrue(tracker.countsAsWorkout(day("2026-11-17", steps: 10_000)))
    }

    func testAShortWorkoutGrowsNoBubble() {
        let rules = CreditRules(discipline: tracker)
        XCTAssertEqual(rules.workoutKeys([run(19.9), run(20)]), [nil, "workout:Run:20"])
    }

    func testTwoWorkoutsOnOneDayAreOneForTheWeek() {
        let week = tracker.week(containing: w.day("2026-11-18"), snapshots: [
            day("2026-11-17", steps: 14_000, workouts: [run(35), run(25, "Strength")])
        ])
        XCTAssertEqual(week.workouts, 1)
    }

    // MARK: - §4.1 On-time night: asleep by the target bedtime + 30 minutes; earlier always counts

    func testThirtyMinutesGraceToTheMinute() {
        // the night ending Tuesday morning, target 23:00 on Monday
        XCTAssertEqual(tracker.isOnTimeNight(day("2026-11-17", asleep: "2026-11-16 23:30")), true)
        XCTAssertEqual(tracker.isOnTimeNight(day("2026-11-17", asleep: "2026-11-16 23:30:01")), false)
        XCTAssertEqual(tracker.isOnTimeNight(day("2026-11-17", asleep: "2026-11-16 23:31")), false)
        XCTAssertEqual(tracker.isOnTimeNight(day("2026-11-17", asleep: "2026-11-17 00:10")), false)
    }

    func testEarlierIsAlwaysOnTime() {
        XCTAssertEqual(tracker.isOnTimeNight(day("2026-11-17", asleep: "2026-11-16 20:05")), true)
        XCTAssertEqual(tracker.isOnTimeNight(day("2026-11-17", asleep: "2026-11-16 18:00")), true)
    }

    func testNoSleepDataIsNeitherOnTimeNorLate() {
        XCTAssertNil(tracker.isOnTimeNight(day("2026-11-17", steps: 8_000)))
    }

    /// Settings offers 20:00 to 02:00 in half-hour steps (PRD §4.1, PR #12).
    func testEveryBedtimeInSettingsFromEightPMToTwoAM() {
        for minutes in stride(from: 20 * 60, through: 26 * 60, by: 30) {
            let bed = Bedtime(hour: (minutes / 60) % 24, minute: minutes % 60)
            let t = w.tracker(bed: bed)
            let target = t.target(forNightEnding: w.day("2026-11-17"))
            let last = target.addingTimeInterval(30 * 60)
            let label = clock(minutes)
            XCTAssertEqual(t.isOnTimeNight(HealthSnapshot(day: w.day("2026-11-17"), source: .healthKit, sleepOnset: last)),
                           true, "asleep at bedtime \(label) + 30 min")
            XCTAssertEqual(t.isOnTimeNight(HealthSnapshot(day: w.day("2026-11-17"), source: .healthKit,
                                                          sleepOnset: last.addingTimeInterval(60))),
                           false, "asleep at bedtime \(label) + 31 min")
            // the target falls on the evening before (or, after midnight, on) the wake-up morning
            XCTAssertTrue(target > w.at("2026-11-16 19:59") && target < w.at("2026-11-17 02:01"), label)
        }
    }

    func testAfterMidnightBedtimeIsTheSameNight() {
        let t = w.tracker(bed: Bedtime(hour: 0, minute: 30))
        XCTAssertEqual(t.isOnTimeNight(day("2026-11-17", asleep: "2026-11-17 01:00")), true)
        XCTAssertEqual(t.isOnTimeNight(day("2026-11-17", asleep: "2026-11-17 01:01")), false)
        XCTAssertEqual(t.isOnTimeNight(day("2026-11-17", asleep: "2026-11-16 23:15")), true)
    }

    func testWeekendBedtimeIsForFridayAndSaturdayNights() {
        let t = w.tracker(bed: Bedtime(hour: 23), weekendBed: Bedtime(hour: 0, minute: 30))
        // Friday night (ends Saturday morning) and Saturday night: 00:30 + 30
        XCTAssertEqual(t.isOnTimeNight(day("2026-11-21", asleep: "2026-11-21 00:55")), true)
        XCTAssertEqual(t.isOnTimeNight(day("2026-11-22", asleep: "2026-11-22 00:55")), true)
        // Sunday night (ends Monday morning) and Thursday night are weekday nights again
        XCTAssertEqual(t.isOnTimeNight(day("2026-11-23", asleep: "2026-11-23 00:55")), false)
        XCTAssertEqual(t.isOnTimeNight(day("2026-11-20", asleep: "2026-11-20 00:55")), false)
    }

    // MARK: - §4.1 / §7.2 Which night, which week: the 18:00 cut, the morning you wake up

    func testEighteenHundredCutsTheNights() {
        let nights = SleepNights.nights([
            DateInterval(start: w.at("2026-11-15 17:59"), end: w.at("2026-11-15 18:20")),
            DateInterval(start: w.at("2026-11-15 18:00"), end: w.at("2026-11-15 18:30")),
        ], calendar: w.calendar)
        XCTAssertEqual(nights[w.day("2026-11-15")]?.onset, w.at("2026-11-15 17:59"))
        XCTAssertEqual(nights[w.day("2026-11-16")]?.onset, w.at("2026-11-15 18:00"))
    }

    func testANightStartingBeforeMidnightCountsOnTheMorningAfter() {
        let nights = SleepNights.nights(w.watchNight("2026-11-16 22:48", "2026-11-17 06:40"), calendar: w.calendar)
        XCTAssertEqual(Array(nights.keys), [w.day("2026-11-17")])
        XCTAssertEqual(nights[w.day("2026-11-17")]?.onset, w.at("2026-11-16 22:48"))
        XCTAssertEqual(nights[w.day("2026-11-17")]?.wake, w.at("2026-11-17 06:40"))
    }

    func testTheWeekHoldsSundayNightToSaturdayNight() {
        // seven on-time nights: Sunday 15th … Saturday 21st, each counted on the morning after
        var days = (16...22).map { day("2026-11-\($0)", asleep: "2026-11-\($0 - 1) 22:30") }
        // Sunday 22nd's night counts on Monday 23rd: next week's first cell
        days.append(day("2026-11-23", asleep: "2026-11-22 22:30"))
        XCTAssertEqual(tracker.week(containing: w.day("2026-11-19"), snapshots: days).onTimeNights, 7)
        XCTAssertEqual(tracker.week(containing: w.day("2026-11-23"), snapshots: days).onTimeNights, 1)
    }

    func testSundayWorkoutIsThisWeekMondayIsNext() {
        let days = [day("2026-11-22", workouts: [run(30)]), day("2026-11-23", workouts: [run(30)])]
        XCTAssertEqual(tracker.week(containing: w.day("2026-11-18"), snapshots: days).workouts, 1)
        XCTAssertEqual(tracker.weekStart(for: w.at("2026-11-22 23:59")), w.day("2026-11-16"))
        XCTAssertEqual(tracker.weekStart(for: w.at("2026-11-23 00:00")), w.day("2026-11-23"))
    }

    // MARK: - §4.2 自律周: 3 workouts + 5 on-time nights; one leave day a week

    private func week(workouts: Int, nights: Int, leave: [String] = []) -> WeekProgress {
        let days = (16...22).map { n -> HealthSnapshot in
            let i = n - 16
            return day("2026-11-\(n)", workouts: i < workouts ? [run(25)] : [],
                       asleep: i < nights ? "2026-11-\(n - 1) 22:45" : nil)
        }
        return tracker.week(containing: w.day("2026-11-18"), snapshots: days, leaveDays: Set(leave.map(w.day)))
    }

    func testThreeWorkoutsAndFiveNightsMakeTheWeek() {
        XCTAssertTrue(week(workouts: 3, nights: 5).isDisciplined)
        XCTAssertFalse(week(workouts: 2, nights: 7).isDisciplined)
        XCTAssertFalse(week(workouts: 7, nights: 4).isDisciplined)
    }

    func testOneLeaveDayAWeekCountsAsAnOnTimeNight() {
        // nights 16–19 on time; Saturday 21st's night taken as leave
        XCTAssertTrue(week(workouts: 3, nights: 4, leave: ["2026-11-21"]).isDisciplined)
        // a second leave day in the same week doesn't count
        XCTAssertEqual(week(workouts: 3, nights: 3, leave: ["2026-11-20", "2026-11-21"]).onTimeNights, 4)
        // leave on a night that was on time anyway adds nothing
        XCTAssertEqual(week(workouts: 3, nights: 4, leave: ["2026-11-17"]).onTimeNights, 4)
        // last week's leave day doesn't count this week
        XCTAssertEqual(week(workouts: 3, nights: 4, leave: ["2026-11-15"]).onTimeNights, 4)
    }

    func testMoreThanEnoughKeepsCounting() {
        let full = week(workouts: 6, nights: 7)
        XCTAssertEqual(full.workouts, 6)
        XCTAssertEqual(full.onTimeNights, 7)
    }

    func testMonthlyAchievementIsThreeOfFourWeeksAndNothingIsTakenAway() {
        // adopted Monday 2026-11-02: blocks 11-02…11-23, 11-30…12-21
        let weeks = Set(["2026-11-02", "2026-11-09", "2026-11-30", "2026-12-14", "2026-12-21"].map(w.day))
        let entries = Ledger.entries(log: [:], disciplinedWeeks: weeks, currentWeekDone: false,
                                     adoptedOn: w.at("2026-11-02 09:00"), today: w.day("2027-01-04"), memories: [],
                                     tracker: tracker)
        let months = entries.compactMap { e -> Date? in
            if case .monthlyAchievement = e.kind { return e.day }
            return nil
        }
        // the first block only had 2 weeks: no achievement, and the missed weeks take nothing away
        XCTAssertEqual(months, [w.day("2026-12-27")])
        XCTAssertEqual(entries.filter { if case .disciplinedWeek = $0.kind { true } else { false } }.count, 5)
    }

    // MARK: - §4.4 Untapped bubbles are collected at 04:00 the next day, exactly as if tapped

    func testFourAMIsTheLine() {
        let rules = CreditRules(discipline: tracker)
        let days = [day("2026-11-17", steps: 12_000)]
        XCTAssertEqual(rules.pending(in: days, booked: [], now: w.at("2026-11-18 03:59")).count, 1)
        XCTAssertEqual(rules.due(in: days, booked: [], now: w.at("2026-11-18 03:59"), since: w.day("2026-11-01")).count, 0)
        XCTAssertEqual(rules.pending(in: days, booked: [], now: w.at("2026-11-18 04:00")).count, 0)
        XCTAssertEqual(rules.due(in: days, booked: [], now: w.at("2026-11-18 04:00"), since: w.day("2026-11-01")).count, 1)
    }

    func testFourAMOnTheNightTheClocksGoBack() {
        // US daylight saving ends Sunday 2026-11-01 at 02:00; Saturday's food is collected at 04:00 PST
        let rules = CreditRules(discipline: tracker)
        XCTAssertEqual(rules.autoBookTime(for: w.day("2026-10-31")), w.at("2026-11-01 04:00"))
        XCTAssertEqual(rules.autoBookTime(for: w.day("2026-03-07")), w.at("2026-03-08 04:00"))
    }

    func testCollectedAtFourCountsExactlyLikeATap() {
        let days = [day("2026-11-17", steps: 11_000, workouts: [run(32)], asleep: "2026-11-16 22:40", awake: "2026-11-17 06:30")]
        var tapped = AppRun(world: w, since: "2026-11-01")
        tapped.open(days, at: "2026-11-17 12:00")
        tapped.tapAll()
        tapped.open(days, at: "2026-11-18 09:00")

        var untapped = AppRun(world: w, since: "2026-11-01")
        untapped.open(days, at: "2026-11-17 12:00")
        untapped.open(days, at: "2026-11-18 09:00")

        XCTAssertEqual(tapped.progress, untapped.progress)
        XCTAssertEqual(tapped.week, untapped.week)
        XCTAssertEqual(untapped.autoBooked.count, 3) // run, 10k steps, the night
        XCTAssertTrue(tapped.autoBooked.isEmpty)
    }

    func testNothingCountsWhileItWaitsAsABubble() {
        let days = [day("2026-11-17", steps: 12_000, asleep: "2026-11-16 22:40")]
        var app = AppRun(world: w, since: "2026-11-01")
        app.open(days, at: "2026-11-17 12:00")
        XCTAssertEqual(app.week?.workouts, 0)
        XCTAssertEqual(app.week?.onTimeNights, 0)
        XCTAssertEqual(app.experience(.walking), 0)
        app.tapAll()
        app.open(days, at: "2026-11-17 12:01")
        XCTAssertEqual(app.week?.workouts, 1)
        XCTAssertEqual(app.week?.onTimeNights, 1)
        XCTAssertEqual(app.experience(.walking), 1)
        XCTAssertEqual(app.experience(.onTimeSleep), 1)
    }

    // MARK: - §5.2 Levels: L×(L+1)/2, ×2 in a 自律周, one session per activity per day

    func testLevelCurve() {
        XCTAssertEqual(PetLevel.level(forExperience: 0), 0)
        XCTAssertEqual(PetLevel.level(forExperience: 1), 1)
        XCTAssertEqual(PetLevel.level(forExperience: 2), 1)
        XCTAssertEqual(PetLevel.level(forExperience: 3), 2)
        XCTAssertEqual(PetLevel.level(forExperience: 14), 4)
        XCTAssertEqual(PetLevel.level(forExperience: 15), 5)
        XCTAssertEqual(PetLevel.level(forExperience: 54), 9)
        XCTAssertEqual(PetLevel.level(forExperience: 55), 10)
        XCTAssertEqual(PetLevel.level(forExperience: 209), 19)
        XCTAssertEqual(PetLevel.level(forExperience: 210), 20)
    }

    func testTwoRunsOnOneDayAreOneSession() {
        let a = w.activities()
        let log = a.log([day("2026-11-17", workouts: [run(30), run(40)])])
        let p = ActivityProgress.all(log: log, disciplinedWeeks: [], weekStart: tracker.weekStart(for:))
        XCTAssertEqual(p[.running]?.sessions, 1)
        XCTAssertEqual(p[.running]?.experience, 1)
    }

    func testOnlyTheDisciplinedWeekDoubles() {
        let log: [Date: Set<Activity>] = [
            w.day("2026-11-15"): [.running], // Sunday: the week before
            w.day("2026-11-16"): [.running], // Monday: the 自律周
            w.day("2026-11-22"): [.running], // Sunday: still the 自律周
            w.day("2026-11-23"): [.running], // Monday: the week after
        ]
        let p = ActivityProgress.all(log: log, disciplinedWeeks: [w.day("2026-11-16")], weekStart: tracker.weekStart(for:))
        XCTAssertEqual(p[.running]?.sessions, 4)
        XCTAssertEqual(p[.running]?.experience, 1 + 2 + 2 + 1)
    }

    // MARK: - §5.1 Habit pets

    func testMatchaNeedsTenMindfulMinutes() {
        let a = w.activities()
        XCTAssertFalse(a.activities(on: day("2026-11-17", mindful: 9.9)).contains(.mindfulness))
        XCTAssertTrue(a.activities(on: day("2026-11-17", mindful: 10)).contains(.mindfulness))
        // a Mind & Body / Tai Chi workout counts for Matcha from 10 minutes
        XCTAssertTrue(a.activities(on: day("2026-11-17", workouts: [run(10, "Mind")])).contains(.mindfulness))
    }

    func testCoffeeBeanIsUpByTheWakeTarget() {
        let a = w.activities()
        XCTAssertTrue(a.activities(on: day("2026-11-17", awake: "2026-11-17 07:00")).contains(.earlyRise))
        XCTAssertFalse(a.activities(on: day("2026-11-17", awake: "2026-11-17 07:01")).contains(.earlyRise))
    }

    func testOnigiriIsTenThousandSteps() {
        let a = w.activities()
        XCTAssertFalse(a.activities(on: day("2026-11-17", steps: 9_999)).contains(.walking))
        XCTAssertTrue(a.activities(on: day("2026-11-17", steps: 10_000)).contains(.walking))
    }

    // MARK: - §5.1 Whoop pets

    private func whoop(_ recovery: Double?, _ strain: Double?, performance: Double? = nil) -> HealthSnapshot {
        w.whoopDay("2026-11-17", recovery: recovery, strain: strain, sleepPerformance: performance)
    }

    /// Honey: green ≥ 67% and strain ≥ 10; yellow 34–66% and 8–14; red < 34% and < 10.
    func testHoneyAtEveryEdge() {
        let a = w.activities()
        let cases: [(Double, Double, Bool)] = [
            (67, 10, true), (67, 9.9, false), (100, 21, true),
            (66, 7.9, false), (66, 8, true), (66, 14, true), (66, 14.1, false), (66, 10, true),
            (34, 8, true), (34, 14, true), (34, 7.9, false), (34, 3, false),
            (33, 9.9, true), (33, 10, false), (0, 0, true), (1, 12, false),
        ]
        for (recovery, strain, expected) in cases {
            XCTAssertEqual(a.activities(on: whoop(recovery, strain)).contains(.recoveryMatch), expected,
                           "recovery \(recovery)%, strain \(strain)")
        }
    }

    /// Protein Bar: recovery under 34% and strain 10 or less, settled once the day is over.
    func testProteinBarAtEveryEdge() {
        let a = w.activities()
        let cases: [(Double?, Double?, Bool)] = [
            (33, 10, true), (33, 10.1, false), (33, 0, true), (33.9, 5, true),
            (34, 5, false), (80, 2, false),
            (nil, 2, false),  // Whoop still calibrating: no red day
            (20, nil, false), // no strain yet
        ]
        for (recovery, strain, expected) in cases {
            XCTAssertEqual(a.activities(on: whoop(recovery, strain)).contains(.redDayRest), expected,
                           "recovery \(recovery.map { "\($0)" } ?? "none")%, strain \(strain.map { "\($0)" } ?? "none")")
        }
        // today isn't over: neither Protein Bar nor Honey yet
        let today = a.activities(on: whoop(20, 3), dayIsOver: false)
        XCTAssertFalse(today.contains(.redDayRest))
        XCTAssertFalse(today.contains(.recoveryMatch))
    }

    func testWarmMilkIsEightyFivePercentSleepPerformance() {
        let a = w.activities()
        XCTAssertFalse(a.activities(on: whoop(nil, nil, performance: 84.9)).contains(.sleepNeedMet))
        XCTAssertTrue(a.activities(on: whoop(nil, nil, performance: 85)).contains(.sleepNeedMet))
        XCTAssertFalse(a.activities(on: whoop(nil, nil)).contains(.sleepNeedMet))
    }

    func testWhoopStrainBubble() {
        let rules = CreditRules(discipline: tracker)
        XCTAssertEqual(rules.credits(on: whoop(50, 0.05)).map(\.kind), [])
        XCTAssertEqual(rules.credits(on: whoop(50, 0.1)).map(\.kind), [.load])
        XCTAssertEqual(rules.credits(on: whoop(50, nil)).map(\.kind), [])
    }

    func testWhoopPetsNeverComeFromAppleHealthAlone() {
        let a = w.activities()
        let apple = day("2026-11-17", steps: 15_000, workouts: [run(60)], asleep: "2026-11-16 22:00",
                        awake: "2026-11-17 06:00", mindful: 20)
        XCTAssertTrue(a.activities(on: apple).filter(\.isWhoopOnly).isEmpty)
    }

    /// Settings' clock text, "23:00" / "00:30".
    private func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }
}
