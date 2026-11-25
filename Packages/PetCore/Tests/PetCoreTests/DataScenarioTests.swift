import XCTest
@testable import PetCore

/// Whole weeks of data shaped like what Apple Health and Whoop really send (sleep in stretches with
/// awake gaps, a second sleep app writing over the watch, workouts too short to count, a Whoop band
/// next to the watch, the clocks changing), run through the app's steps from raw samples to the
/// week, the food bubbles, the pets' levels and Toast. Each test is one user's story.
final class DataScenarioTests: XCTestCase {
    private let w = World()

    // MARK: - An Apple Watch user's week in Los Angeles

    /// Sunday 2026-11-15 to Monday 2026-11-23. Four nights on time, one leave night, three workouts,
    /// the last one on Sunday evening and never tapped: the 自律周 only completes when it is
    /// collected at 04:00 on Monday, and Monday's first open still celebrates it (PRD v0.3 §4.4).
    private func appleWatchWeek() -> [HealthSnapshot] {
        var stretches: [DateInterval] = []
        stretches += w.watchNight("2026-11-15 22:48", "2026-11-16 06:40") // Mon ✓
        stretches += w.watchNight("2026-11-16 23:20", "2026-11-17 07:05") // Tue ✓ (20 min after 23:00)
        stretches += w.watchNight("2026-11-17 23:45", "2026-11-18 06:55") // Wed late
        stretches += w.watchNight("2026-11-18 22:30", "2026-11-19 06:30") // Thu ✓
        // a second sleep app (AutoSleep, Pillow…) writes the same night over the watch's
        stretches += [DateInterval(start: w.at("2026-11-18 22:35"), end: w.at("2026-11-19 06:25"))]
        stretches += w.watchNight("2026-11-20 00:20", "2026-11-20 07:30") // Fri late, taken as leave
        stretches += w.watchNight("2026-11-21 01:10", "2026-11-21 09:10") // Sat late
        stretches += w.watchNight("2026-11-21 23:29", "2026-11-22 07:00") // Sun ✓
        stretches += w.watchNight("2026-11-22 22:15", "2026-11-23 06:45") // next Mon ✓
        let nights = SleepNights.nights(stretches, calendar: w.calendar)

        return [
            w.appleDay("2026-11-16", steps: 6_210, nights: nights),
            w.appleDay("2026-11-17", steps: 8_930, workouts: [WorkoutSession(name: "Run", minutes: 32.4, distanceKm: 5.1)],
                       nights: nights),
            w.appleDay("2026-11-18", steps: 4_100, nights: nights, mindful: 6),
            w.appleDay("2026-11-19", steps: 7_420, workouts: [WorkoutSession(name: "Strength", minutes: 18.5)],
                       nights: nights),
            w.appleDay("2026-11-20", steps: 9_999, nights: nights),
            w.appleDay("2026-11-21", steps: 12_400, nights: nights),
            w.appleDay("2026-11-22", steps: 3_050, workouts: [WorkoutSession(name: "Yoga", minutes: 25)], nights: nights,
                       mindful: 12),
            w.appleDay("2026-11-23", steps: 640, nights: nights),
        ]
    }

    /// What Apple Health has by `now`: days up to today.
    private func known(_ days: [HealthSnapshot], at now: String) -> [HealthSnapshot] {
        let today = w.calendar.startOfDay(for: w.at(now))
        return days.filter { $0.day <= today }
    }

    func testTheNightsAreSortedAndJudgedLikeThePRDSays() {
        let days = appleWatchWeek()
        let t = w.tracker()
        let judged = days.map { t.isOnTimeNight($0) }
        XCTAssertEqual(judged, [true, true, false, true, false, false, true, true])
        // the second sleep app doesn't double Thursday's hours: 22:30 → 06:30 is at most 8 hours
        let thursday = days[3]
        XCTAssertEqual(thursday.sleepOnset, w.at("2026-11-18 22:30"))
        XCTAssertLessThanOrEqual(thursday.sleepHours ?? 99, 8)
        XCTAssertGreaterThan(thursday.sleepHours ?? 0, 7.5)
    }

    func testTheWeekCompletesWhenSundaysYogaIsCollectedOnMonday() {
        let days = appleWatchWeek()
        var app = AppRun(world: w, since: "2026-11-16")
        app.leaveDays = [w.day("2026-11-20")]

        // every morning at 08:00 the user opens the app and taps everything…
        for n in 16...21 {
            app.open(known(days, at: "2026-11-\(n) 08:00"), at: "2026-11-\(n) 08:00")
            app.tapAll()
        }
        // …on Sunday only the moon, and in the evening the yoga bubble is left where it is
        app.open(known(days, at: "2026-11-22 08:00"), at: "2026-11-22 08:00")
        app.tapAll { $0.kind == .night }
        app.open(known(days, at: "2026-11-22 20:00"), at: "2026-11-22 20:00")
        XCTAssertEqual(app.pending.map(\.key), ["workout:Yoga:25"])
        XCTAssertEqual(app.week?.workouts, 2) // Tuesday's run, Saturday's 12,400 steps
        XCTAssertEqual(app.week?.onTimeNights, 5) // four on time + the leave night
        XCTAssertEqual(app.week?.isDisciplined, false)

        // Monday 03:30: the yoga is still waiting, last week is not done yet
        app.open(known(days, at: "2026-11-23 03:30"), at: "2026-11-23 03:30")
        XCTAssertEqual(app.previousWeek?.isDisciplined, false)
        XCTAssertTrue(app.disciplinedWeeks.isEmpty)

        // Monday 08:00: collected at 04:00 for the user, so last week counts and gets its celebration
        app.open(known(days, at: "2026-11-23 08:00"), at: "2026-11-23 08:00")
        XCTAssertEqual(app.autoBooked.map(\.key), ["workout:Yoga:25"])
        XCTAssertEqual(app.previousWeek?.workouts, 3)
        XCTAssertEqual(app.previousWeek?.isDisciplined, true)
        XCTAssertEqual(app.disciplinedWeeks, [w.day("2026-11-16")])
        XCTAssertEqual(app.toastLevel, 1)
        // this week starts empty; Monday's moon is today's bubble
        XCTAssertEqual(app.week?.onTimeNights, 0)
        XCTAssertEqual(app.pending.map(\.key), ["night"])
    }

    func testEveryPetGetsDoubleExperienceForTheWeek() {
        let days = appleWatchWeek()
        var app = AppRun(world: w, since: "2026-11-16")
        app.leaveDays = [w.day("2026-11-20")]
        for n in 16...23 {
            app.open(known(days, at: "2026-11-\(n) 08:00"), at: "2026-11-\(n) 08:00")
            if n < 22 { app.tapAll() }
        }
        app.open(known(days, at: "2026-11-23 08:00"), at: "2026-11-23 08:00")

        // one session each, doubled in the 自律周
        XCTAssertEqual(app.experience(.running), 2)   // Tuesday
        XCTAssertEqual(app.experience(.walking), 2)   // Saturday's 12,400 steps (Friday's 9,999 isn't)
        XCTAssertEqual(app.experience(.yoga), 2)      // Sunday, collected at 04:00
        XCTAssertEqual(app.experience(.strength), 0)  // 18.5 minutes is too short
        XCTAssertEqual(app.sessions(.onTimeSleep), 4) // the leave night is a week cell, not Mantou
        XCTAssertEqual(app.experience(.onTimeSleep), 8)
        XCTAssertEqual(app.sessions(.earlyRise), 4)   // up by 07:00 on Mon, Wed, Thu, Sun
        XCTAssertEqual(app.sessions(.mindfulness), 1) // Sunday's 12 minutes, not Wednesday's 6
        // nothing from Monday 23rd until its moon is tapped
        XCTAssertNil(app.log[w.day("2026-11-23")])
    }

    // MARK: - Whoop and an Apple Watch on the same night

    /// Whoop's own sleep start and end win, steps come from the phone, recovery and strain only
    /// from Whoop, and the Whoop pets wait until the day is over.
    func testWhoopAndAppleWatchTogether() {
        let nights = SleepNights.nights(w.watchNight("2026-11-16 23:05", "2026-11-17 06:50"), calendar: w.calendar)
        let apple = w.appleDay("2026-11-17", steps: 9_200, workouts: [WorkoutSession(name: "Run", minutes: 40)],
                               nights: nights)
        let whoop = w.whoopDay("2026-11-17", asleep: "2026-11-16 22:52", awake: "2026-11-17 06:48", recovery: 28,
                               strain: 7.5, sleepPerformance: 88, sleepHours: 7.4)
        let merged = SnapshotMerger.merge([apple, whoop])
        XCTAssertEqual(merged.count, 1)
        let day = merged[0]
        XCTAssertEqual(day.sleepOnset, w.at("2026-11-16 22:52"))
        XCTAssertEqual(day.wakeTime, w.at("2026-11-17 06:48"))
        XCTAssertEqual(day.sleepHours, 7.4)
        XCTAssertEqual(day.steps, 9_200)
        XCTAssertEqual(day.vendorRecovery, 28)
        XCTAssertEqual(day.allWorkouts.map(\.name), ["Run"])

        let a = w.activities()
        XCTAssertEqual(a.activities(on: day, dayIsOver: false),
                       [.running, .onTimeSleep, .earlyRise, .sleepNeedMet])
        // a red day (28%) with strain 7.5: Protein Bar, and Honey too (red and under 10)
        XCTAssertEqual(a.activities(on: day, dayIsOver: true),
                       [.running, .onTimeSleep, .earlyRise, .sleepNeedMet, .redDayRest, .recoveryMatch])

        let credits = CreditRules(discipline: w.tracker()).credits(on: day)
        XCTAssertEqual(credits.map(\.kind), [.workout, .night, .load]) // 9,200 steps: no 10k bubble
    }

    /// The simulator path in the README: Whoop connected, no Apple Health. Nights and the Whoop pets
    /// work; workouts and steps can't, because they only come from Apple Health.
    func testWhoopOnly() {
        let days = [
            w.whoopDay("2026-11-17", asleep: "2026-11-16 22:40", awake: "2026-11-17 06:30", recovery: 71, strain: 12.3,
                       sleepPerformance: 91),
            w.whoopDay("2026-11-18", asleep: "2026-11-18 00:05", awake: "2026-11-18 07:40", recovery: nil, strain: 4.1,
                       sleepPerformance: 70), // still calibrating
        ]
        let t = w.tracker()
        XCTAssertEqual(days.map { t.isOnTimeNight($0) }, [true, false])
        XCTAssertFalse(days.contains(where: t.countsAsWorkout))
        let a = w.activities()
        XCTAssertEqual(a.activities(on: days[0]), [.onTimeSleep, .earlyRise, .sleepNeedMet, .recoveryMatch])
        XCTAssertEqual(a.activities(on: days[1]), []) // no recovery yet: not a red day, not a balanced day
    }

    // MARK: - The clocks change

    /// US daylight saving ends on Sunday 2026-11-01 at 02:00: that week is 7 days and one hour long.
    func testTheWeekTheClocksGoBack() throws {
        var stretches: [DateInterval] = []
        for (start, end) in [("2026-10-25 22:50", "2026-10-26 06:50"), ("2026-10-26 23:10", "2026-10-27 07:00"),
                             ("2026-10-27 22:40", "2026-10-28 06:40"), ("2026-10-28 23:25", "2026-10-29 07:00"),
                             ("2026-10-29 22:55", "2026-10-30 06:55"), ("2026-10-30 23:50", "2026-10-31 08:30"),
                             ("2026-10-31 23:10", "2026-11-01 07:00"), ("2026-11-01 23:00", "2026-11-02 06:30")] {
            stretches += w.watchNight(start, end)
        }
        let nights = SleepNights.nights(stretches, calendar: w.calendar)
        // the night of the change: 23:10 PDT to 07:00 PST is 8h50m asleep (minus the short awake gaps)
        let sunday = try XCTUnwrap(nights[w.day("2026-11-01")])
        XCTAssertEqual(sunday.onset, w.at("2026-10-31 23:10"))
        XCTAssertEqual(sunday.wake, w.at("2026-11-01 07:00"))
        XCTAssertEqual(sunday.hours, 8.5, accuracy: 0.001) // 8h50m minus five 4-minute awake gaps

        let days = ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01",
                    "2026-11-02"].map { w.appleDay($0, steps: 10_500, nights: nights) }
        let t = w.tracker()
        let week = t.week(containing: w.at("2026-11-01 22:00"), snapshots: days)
        XCTAssertEqual(week.weekStart, w.day("2026-10-26"))
        XCTAssertEqual(week.workouts, 7)
        XCTAssertEqual(week.onTimeNights, 6) // all but Friday night (23:50)
        // Sunday night's moon goes to the week starting Monday 2 November
        XCTAssertEqual(t.week(containing: w.day("2026-11-02"), snapshots: days).onTimeNights, 1)
        XCTAssertEqual(t.disciplinedWeeks(in: days, before: w.at("2026-11-02 08:00")), [w.day("2026-10-26")])
    }

    /// Daylight saving starts on Sunday 2026-03-08: 02:00 doesn't exist that night. A 02:00 bedtime
    /// (the latest Settings offers) becomes 03:00, so the wall clock's jump costs nobody the night.
    func testTheNightTheClocksGoForward() {
        let t = w.tracker(bed: Bedtime(hour: 2))
        let morning = w.day("2026-03-08")
        XCTAssertEqual(t.target(forNightEnding: morning), w.at("2026-03-08 03:00"))
        func onTime(_ asleep: String) -> Bool? {
            t.isOnTimeNight(HealthSnapshot(day: morning, source: .healthKit, sleepOnset: w.at(asleep)))
        }
        XCTAssertEqual(onTime("2026-03-08 03:30"), true)
        XCTAssertEqual(onTime("2026-03-08 03:31"), false)
        // a 23:00 bedtime that night is unaffected
        let usual = w.tracker()
        XCTAssertEqual(usual.isOnTimeNight(HealthSnapshot(day: morning, source: .healthKit,
                                                          sleepOnset: w.at("2026-03-07 23:30"))), true)
    }

    // MARK: - Data that looks odd

    /// The same run written into Apple Health twice (the Watch and WHOOP, or Strava): once as
    /// `HealthKitProvider` hands it over (`WorkoutJoiner.workouts` keeps WHOOP's), so one bubble,
    /// one workout for the week, one session for the pet.
    func testTheSameRunFromTwoAppsCountsOnce() {
        let recorded = [
            TimedWorkout(source: "com.apple.health.8A2E1C", name: "Run", start: w.at("2026-11-17 07:00"),
                         end: w.at("2026-11-17 07:32:12"), minutes: 32.2, distanceKm: 5.1),
            TimedWorkout(source: "com.whoop.iphone", name: "Run", start: w.at("2026-11-17 07:00:30"),
                         end: w.at("2026-11-17 07:32:18"), minutes: 31.8),
        ]
        let day = w.appleDay("2026-11-17", workouts: WorkoutJoiner.workouts(recorded).map(\.session))
        let t = w.tracker()
        XCTAssertEqual(day.allWorkouts.count, 1)
        XCTAssertEqual(CreditRules(discipline: t).credits(on: day).map(\.key), ["workout:Run:32"])
        XCTAssertEqual(t.week(containing: day.day, snapshots: [day]).workouts, 1)
        let log = w.activities().log([day])
        let p = ActivityProgress.all(log: log, disciplinedWeeks: [], weekStart: t.weekStart(for:))
        XCTAssertEqual(p[.running]?.experience, 1)
    }

    /// A nap before the night isn't the time of falling asleep (decided 2026-11-25; PRD v0.3 §7.2
    /// took the first sleep after 18:00). WHOOP records naps on its own: a 19:10 nap before a
    /// 02:05 night no longer makes the night look on time.
    func testAnEveningNapIsNotFallingAsleep() throws {
        let nap = DateInterval(start: w.at("2026-11-16 19:10"), end: w.at("2026-11-16 19:35"))
        let stretches = [nap] + w.watchNight("2026-11-17 02:05", "2026-11-17 08:30")
        let nights = SleepNights.nights(stretches, calendar: w.calendar)
        let night = try XCTUnwrap(nights[w.day("2026-11-17")])
        XCTAssertEqual(night.onset, w.at("2026-11-17 02:05"))
        XCTAssertEqual(night.naps, [nap])
        XCTAssertEqual(night.wake, w.at("2026-11-17 08:30"))
        let day = w.appleDay("2026-11-17", nights: nights)
        XCTAssertEqual(w.tracker().isOnTimeNight(day), false)
        // a nap 2 hours before the night is still a nap; one closer is part of the night
        let twoHours = SleepNights.nights([DateInterval(start: w.at("2026-11-16 23:00"), end: w.at("2026-11-17 00:05"))]
            + w.watchNight("2026-11-17 02:05", "2026-11-17 08:30"), calendar: w.calendar)
        XCTAssertEqual(twoHours[w.day("2026-11-17")]?.onset, w.at("2026-11-17 02:05"))
        let closer = SleepNights.nights([DateInterval(start: w.at("2026-11-16 23:00"), end: w.at("2026-11-17 00:06"))]
            + w.watchNight("2026-11-17 02:05", "2026-11-17 08:30"), calendar: w.calendar)
        XCTAssertEqual(closer[w.day("2026-11-17")]?.onset, w.at("2026-11-16 23:00"))
    }

    /// Waking up in the night doesn't move the time of falling asleep: an hour and a half awake
    /// after a short first sleep, or a long first sleep however long the user was up after it.
    func testAWakefulNightStartsWhenTheUserFirstFellAsleep() {
        let t = w.tracker()
        let awakeAnHourAndAHalf = SleepNights.nights(w.watchNight("2026-11-16 22:50", "2026-11-17 00:00")
            + w.watchNight("2026-11-17 01:30", "2026-11-17 07:00"), calendar: w.calendar)
        XCTAssertEqual(awakeAnHourAndAHalf[w.day("2026-11-17")]?.onset, w.at("2026-11-16 22:50"))
        XCTAssertEqual(awakeAnHourAndAHalf[w.day("2026-11-17")]?.naps, [])
        // 90 minutes asleep is no nap, even with three hours awake after it
        let ninety = SleepNights.nights([DateInterval(start: w.at("2026-11-16 23:00"), end: w.at("2026-11-17 00:30"))]
            + w.watchNight("2026-11-17 03:30", "2026-11-17 09:00"), calendar: w.calendar)
        let day = w.appleDay("2026-11-17", nights: ninety)
        XCTAssertEqual(day.sleepOnset, w.at("2026-11-16 23:00"))
        XCTAssertEqual(t.isOnTimeNight(day), true)
        // a short sleep with nothing after it is the night
        let only = SleepNights.nights([DateInterval(start: w.at("2026-11-17 05:00"), end: w.at("2026-11-17 06:10"))],
                                      calendar: w.calendar)
        XCTAssertEqual(only[w.day("2026-11-17")]?.onset, w.at("2026-11-17 05:00"))
    }

    /// A Mind & Body or Tai Chi workout feeds Matcha (mindfulness), which PRD §5.1 lists as a habit,
    /// not a sport: no workout bubble, no workout cell, not a workout in the ledger's milestones.
    func testAMindfulnessWorkoutIsNotOneOfTheWeeksWorkouts() {
        let t = w.tracker()
        let mind = w.appleDay("2026-11-17", steps: 3_000, workouts: [WorkoutSession(name: "Mind", minutes: 30)])
        XCTAssertEqual(w.activities().activities(on: mind), [.mindfulness])
        XCTAssertTrue(CreditRules(discipline: t).credits(on: mind).isEmpty)
        XCTAssertFalse(t.countsAsWorkout(mind))
        // a longer mindfulness session doesn't hide a shorter run that counts
        let both = w.appleDay("2026-11-18", workouts: [WorkoutSession(name: "Mind", minutes: 45),
                                                       WorkoutSession(name: "Run", minutes: 22)])
        XCTAssertTrue(t.countsAsWorkout(both))
        XCTAssertEqual(t.week(containing: mind.day, snapshots: [mind, both]).workouts, 1)
        // nor a run that is too short
        let short = w.appleDay("2026-11-19", workouts: [WorkoutSession(name: "Mind", minutes: 45),
                                                        WorkoutSession(name: "Run", minutes: 15)])
        XCTAssertFalse(t.countsAsWorkout(short))
    }

    // MARK: - Travelling

    /// A user who booked their week in Los Angeles flies to Tokyo. Apple Health gives the same
    /// workouts again, now grouped into Tokyo days; every day starts at a different moment, so a
    /// day the user already collected looks new.
    private func tripToTokyo() -> (la: [HealthSnapshot], tokyo: [HealthSnapshot], tokyoWorld: World) {
        let tokyoWorld = World("Asia/Tokyo")
        // workouts at lunchtime in LA: the same calendar date in Tokyo too
        let dates = ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19"]
        let la = dates.map { w.appleDay($0, steps: 11_000, workouts: [WorkoutSession(name: "Run", minutes: 30)]) }
        let tokyo = dates.map { tokyoWorld.appleDay($0, steps: 11_000, workouts: [WorkoutSession(name: "Run", minutes: 30)]) }
        return (la, tokyo, tokyoWorld)
    }

    func testAfterFlyingCollectedFoodIsNotCollectedAgain() {
        let (la, tokyo, tokyoWorld) = tripToTokyo()
        var app = AppRun(world: w, since: "2026-11-16")
        app.open(la, at: "2026-11-20 09:00") // everything collected at 04:00 in LA
        XCTAssertEqual(app.autoBooked.count, 8)

        // the first open in Tokyo reads the same days again, now as Tokyo days
        app.move(to: tokyoWorld)
        app.open(tokyo, now: tokyoWorld.at("2026-11-21 09:00"))
        XCTAssertEqual(app.autoBooked.count, 8, "no second 「Collected for you」 line for a day already collected")
        XCTAssertTrue(app.pending.isEmpty)
    }

    func testAfterFlyingPetsDoNotLevelUpTwice() {
        let (la, tokyo, tokyoWorld) = tripToTokyo()
        var app = AppRun(world: w, since: "2026-11-16")
        app.open(la, at: "2026-11-20 09:00")
        XCTAssertEqual(app.sessions(.running), 4)
        app.move(to: tokyoWorld)
        app.open(tokyo, now: tokyoWorld.at("2026-11-21 09:00"))
        XCTAssertEqual(app.sessions(.running), 4)
        XCTAssertEqual(app.sessions(.walking), 4)
        XCTAssertEqual(app.log.count, 4)
    }

    /// Days logged in Los Angeles, a 自律周 among them, read on Tokyo's calendar (and the other
    /// way round): each day still falls in its own week and keeps its double experience, and Toast
    /// keeps its level. PRD §3: levels never go down.
    func testAfterFlyingLevelsNeverGoDown() {
        for (home, away) in [(w, World("Asia/Tokyo")), (World("Asia/Tokyo"), w),
                             (World("Europe/Berlin"), World("Pacific/Auckland")), (World("Pacific/Honolulu"), World("Europe/London"))] {
            let log = Dictionary(uniqueKeysWithValues: (14...20).map { (home.day("2026-09-\($0)"), Set([Activity.running])) })
            let weeks: Set<Date> = [home.day("2026-09-14")]
            let atHome = ActivityProgress.all(log: log, disciplinedWeeks: weeks, weekStart: home.tracker().weekStart(for:))
            XCTAssertEqual(atHome[.running]?.experience, 14)

            let c = away.calendar
            let movedLog = CalendarDay.rekey(log, in: c) { $0.union($1) }
            let movedWeeks = CalendarDay.rekey(weeks, in: c)
            let abroad = ActivityProgress.all(log: movedLog, disciplinedWeeks: movedWeeks, weekStart: away.tracker().weekStart(for:))
            let zones = "\(home.calendar.timeZone.identifier) → \(c.timeZone.identifier)"
            XCTAssertEqual(abroad[.running]?.experience, 14, zones)
            XCTAssertEqual(movedWeeks, [away.day("2026-09-14")], zones)
            XCTAssertEqual(Set(movedLog.keys), Set((14...20).map { away.day("2026-09-\($0)") }), zones)
        }
    }
}
