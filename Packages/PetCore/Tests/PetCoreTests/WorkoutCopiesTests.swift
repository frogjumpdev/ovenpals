import XCTest
@testable import PetCore

/// The same workout written into Apple Health by two apps (WHOOP and the Watch, Strava…) is one
/// workout and grows one bubble. WHOOP's record wins, so a WHOOP user sees what the WHOOP app shows.
final class WorkoutCopiesTests: XCTestCase {
    private let w = World("Asia/Taipei")
    private static let whoop = "com.whoop.iphone"
    private static let watch = "com.apple.health.8A2E1C"
    private static let strava = "com.strava.stravaride"

    private func workout(_ start: String, _ end: String, _ minutes: Double, _ name: String = "Run",
                         source: String = whoop, km: Double? = nil) -> TimedWorkout {
        TimedWorkout(source: source, name: name, start: w.at(start), end: w.at(end), minutes: minutes, distanceKm: km)
    }

    /// A morning run with WHOOP and the Watch both on: WHOOP writes 19:59-style minutes and no distance.
    private var run: [TimedWorkout] {
        [workout("2026-11-17 07:00", "2026-11-17 07:32:10", 32.17, source: Self.watch, km: 5.1),
         workout("2026-11-17 07:00:40", "2026-11-17 07:32:39", 31.98)]
    }

    func testTheSameRunFromTwoAppsIsOneWorkout() throws {
        let workouts = WorkoutJoiner.workouts(run)
        XCTAssertEqual(workouts.count, 1)
        let kept = try XCTUnwrap(workouts.first)
        XCTAssertTrue(kept.isWhoop, "WHOOP's record is the one shown")
        XCTAssertEqual(kept.session.shownMinutes, 32)
        XCTAssertEqual(kept.session.distanceKm, 5.1, "the Watch's distance fills in what WHOOP has none of")
        XCTAssertEqual(kept.session.copies?.map(\.minutes), [32.17])
        XCTAssertEqual(kept.copies.map(\.source), [Self.watch])
        XCTAssertEqual(kept.start, w.at("2026-11-17 07:00"))

        let day = w.appleDay("2026-11-17", workouts: workouts.map(\.session))
        let credits = CreditRules(discipline: w.tracker()).credits(on: day)
        XCTAssertEqual(credits.map(\.key), ["workout:Run:32"], "one bubble, one ledger line")
        XCTAssertEqual(w.tracker().week(containing: day.day, snapshots: [day]).workouts, 1)
        // each app on its own: WHOOP is detected from an export's "WHOOP" too
        XCTAssertTrue(TimedWorkout(source: "WHOOP", name: "Run", start: Date(), end: Date(), minutes: 1).isWhoop)
        XCTAssertFalse(run[0].isWhoop)
    }

    func testANamedSportWinsOverAPlainWorkout() {
        // WHOOP auto-detected the activity without a sport; Strava knows it was a run
        let workouts = WorkoutJoiner.workouts([
            workout("2026-11-17 18:00", "2026-11-17 18:46", 45, WorkoutSession.plainName),
            workout("2026-11-17 18:03", "2026-11-17 18:44", 40, source: Self.strava, km: 7.2),
        ])
        XCTAssertEqual(workouts.map(\.session.name), ["Run"])
        XCTAssertEqual(workouts.first?.session.shownMinutes, 40)
        XCTAssertEqual(workouts.first?.session.copies?.map(\.name), [WorkoutSession.plainName])
    }

    func testTheCopyThatCountsWins() {
        // Strava was started late: on its own the run is 18 minutes, too short to count
        let workouts = WorkoutJoiner.workouts([
            workout("2026-11-17 18:00", "2026-11-17 18:25", 25, WorkoutSession.plainName),
            workout("2026-11-17 18:07", "2026-11-17 18:25", 18, source: Self.strava),
        ])
        XCTAssertEqual(workouts.map(\.session.name), [WorkoutSession.plainName])
        XCTAssertTrue(w.tracker().countsAsWorkout(workouts[0].session), "the user keeps the workout")
    }

    func testWorkoutsThatOnlyTouchAreTwo() {
        // a run, then strength that WHOOP started 5 minutes before the Watch stopped the run
        let workouts = WorkoutJoiner.workouts([
            workout("2026-11-17 07:00", "2026-11-17 07:30", 30, source: Self.watch),
            workout("2026-11-17 07:25", "2026-11-17 08:00", 35, "Strength"),
        ])
        XCTAssertEqual(workouts.map(\.session.name), ["Run", "Strength"])
    }

    func testAnAppNeverCopiesItself() {
        // WHOOP kept one activity for the whole gym hour; the Watch recorded its two parts
        let workouts = WorkoutJoiner.workouts([
            workout("2026-11-17 18:00", "2026-11-17 19:00", 60, WorkoutSession.plainName),
            workout("2026-11-17 18:05", "2026-11-17 18:30", 25, "Strength", source: Self.watch),
            workout("2026-11-17 18:32", "2026-11-17 18:57", 25, "HIIT", source: Self.watch),
        ])
        XCTAssertEqual(workouts.map(\.session.name), ["Strength", "HIIT"])
        // two workouts of one app at the same time stay two as well
        XCTAssertEqual(WorkoutJoiner.workouts([
            workout("2026-11-17 18:00", "2026-11-17 18:30", 30, source: Self.watch),
            workout("2026-11-17 18:01", "2026-11-17 18:31", 30, source: Self.watch),
        ]).count, 2)
    }

    func testPiecesAreJoinedBeforeCopiesAreFound() throws {
        // WHOOP's four strength pieces of 2026-11-09, and the Watch's one recording of the session
        let workouts = WorkoutJoiner.workouts([
            workout("2026-11-09 20:11", "2026-11-09 20:20:08", 8.284, "Strength"),
            workout("2026-11-09 20:24", "2026-11-09 20:34:43", 10.571, "Strength"),
            workout("2026-11-09 20:41", "2026-11-09 20:48:43", 6.811, "Strength"),
            workout("2026-11-09 20:56", "2026-11-09 21:05:15", 8.494, "Strength"),
            workout("2026-11-09 20:10", "2026-11-09 21:06", 56, "Strength", source: Self.watch),
        ])
        XCTAssertEqual(workouts.count, 1)
        let kept = try XCTUnwrap(workouts.first)
        XCTAssertTrue(kept.isWhoop)
        XCTAssertEqual(kept.session.shownMinutes, 34)
        XCTAssertEqual(kept.session.pieces?.count, 4)
        XCTAssertEqual(kept.session.copies?.map(\.minutes), [56])
    }

    // MARK: - Bubbles while the copies arrive

    /// The Watch saves the run the moment it ends; WHOOP syncs its copy later. A bubble eaten
    /// in between isn't offered again when WHOOP's copy arrives and is the one kept.
    func testABubbleEatenBeforeTheCopyArrivedIsNotOfferedAgain() {
        var app = AppRun(world: w, since: "2026-11-17")
        let watchOnly = WorkoutJoiner.workouts([run[0]]).map(\.session)
        app.open([w.appleDay("2026-11-17", workouts: watchOnly)], at: "2026-11-17 07:40")
        XCTAssertEqual(app.pending.map(\.key), ["workout:Run:32"])
        app.tapAll()

        let both = WorkoutJoiner.workouts(run).map(\.session)
        let day = w.appleDay("2026-11-17", workouts: both)
        let credits = CreditRules(discipline: w.tracker()).credits(on: day)
        XCTAssertEqual(credits.first?.aliases, [], "both copies are 32 minutes: the key doesn't even change")
        app.open([day], at: "2026-11-17 09:00")
        XCTAssertEqual(app.pending, [])
        app.open([day], at: "2026-11-18 09:00")
        XCTAssertEqual(app.autoBooked, [], "nothing left to collect at 04:00")
        XCTAssertEqual(app.sessions(.running), 1)
    }

    func testABubbleEatenUnderAnotherNameIsNotOfferedAgain() {
        // WHOOP's plain activity came first and was eaten; Strava's run arrives and is kept
        let whoop = workout("2026-11-17 18:00", "2026-11-17 18:46", 45, WorkoutSession.plainName)
        let strava = workout("2026-11-17 18:03", "2026-11-17 18:44", 40, source: Self.strava)
        var app = AppRun(world: w, since: "2026-11-17")
        app.open([w.appleDay("2026-11-17", workouts: WorkoutJoiner.workouts([whoop]).map(\.session))], at: "2026-11-17 18:50")
        XCTAssertEqual(app.pending.map(\.key), ["workout:Workout:45"])
        app.tapAll()

        let day = w.appleDay("2026-11-17", workouts: WorkoutJoiner.workouts([whoop, strava]).map(\.session))
        let credit = CreditRules(discipline: w.tracker()).credits(on: day).first
        XCTAssertEqual(credit?.key, "workout:Run:40")
        XCTAssertEqual(credit?.aliases, ["workout:Workout:45"])
        app.open([day], at: "2026-11-17 19:30")
        XCTAssertEqual(app.pending, [], "no second bubble for the same workout")
        app.open([day], at: "2026-11-18 09:00")
        XCTAssertEqual(app.autoBooked, [])
        XCTAssertEqual(app.week?.workouts, 1)
    }

    func testOldSnapshotsWithoutCopiesStillDecode() throws {
        let old = #"{"name":"Strength","minutes":34.16,"pieces":[8.284,10.571,6.811,8.494]}"#
        let workout = try JSONDecoder().decode(WorkoutSession.self, from: Data(old.utf8))
        XCTAssertNil(workout.copies)
        XCTAssertEqual(workout.pieces?.count, 4)
    }
}
