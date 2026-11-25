import XCTest
@testable import PetCore

/// Workouts recorded in pieces (WHOOP ends an activity when the heart rate drops between sets)
/// are joined back into one: same kind, same app, each piece within 10 minutes of the last.
final class WorkoutJoinerTests: XCTestCase {
    private let w = World("Asia/Taipei")

    private func piece(_ start: String, _ end: String, _ minutes: Double, _ name: String = "Strength",
                       source: String = "com.whoop.iphone") -> TimedWorkout {
        TimedWorkout(source: source, name: name, start: w.at(start), end: w.at(end), minutes: minutes)
    }

    /// A strength session as WHOOP wrote it into Apple Health on 2026-11-09: four pieces, each
    /// ending one second before its last minute, with breaks of 4, 7 and 8 minutes.
    private var session: [TimedWorkout] {
        [piece("2026-11-09 20:11", "2026-11-09 20:20:08", 8.284),
         piece("2026-11-09 20:24", "2026-11-09 20:34:43", 10.571),
         piece("2026-11-09 20:41", "2026-11-09 20:48:43", 6.811),
         piece("2026-11-09 20:56", "2026-11-09 21:05:15", 8.494)]
    }

    func testPiecesOfOneSessionAreOneWorkout() throws {
        let joined = WorkoutJoiner.join(session)
        XCTAssertEqual(joined.count, 1)
        let workout = try XCTUnwrap(joined.first)
        XCTAssertEqual(workout.session.minutes, 34.16, accuracy: 0.001)
        XCTAssertEqual(workout.session.shownMinutes, 34)
        XCTAssertEqual(workout.session.pieces?.count, 4)
        XCTAssertEqual(workout.start, w.at("2026-11-09 20:11"))
        XCTAssertEqual(workout.end, w.at("2026-11-09 21:05:15"))
        // none of the pieces is a workout on its own, the session is
        let tracker = w.tracker()
        XCTAssertFalse(session.contains { tracker.countsAsWorkout(WorkoutSession(name: $0.name, minutes: $0.minutes)) })
        XCTAssertTrue(tracker.countsAsWorkout(workout.session))
        XCTAssertTrue(w.activities().activities(on: w.appleDay("2026-11-09", workouts: [workout.session])).contains(.strength))
    }

    func testTenMinutesIsTheLongestBreak() {
        let ten = [piece("2026-11-09 20:00", "2026-11-09 20:12", 12), piece("2026-11-09 20:22", "2026-11-09 20:34", 12)]
        XCTAssertEqual(WorkoutJoiner.join(ten).count, 1)
        let eleven = [piece("2026-11-09 20:00", "2026-11-09 20:12", 12), piece("2026-11-09 20:23", "2026-11-09 20:35", 12)]
        XCTAssertEqual(WorkoutJoiner.join(eleven).map(\.session.minutes), [12, 12])
    }

    func testOnlyTheSameKindFromTheSameAppIsJoined() {
        let kinds = [piece("2026-11-09 20:00", "2026-11-09 20:12", 12),
                     piece("2026-11-09 20:15", "2026-11-09 20:27", 12, "Run")]
        XCTAssertEqual(WorkoutJoiner.join(kinds).count, 2)
        // the Watch and Strava recording the same run: overlapping, never added up
        let apps = [piece("2026-11-16 07:00", "2026-11-16 07:32", 32, "Run", source: "com.apple.health"),
                    piece("2026-11-16 07:01", "2026-11-16 07:33", 31, "Run", source: "com.strava.stravaride")]
        XCTAssertEqual(WorkoutJoiner.join(apps).map(\.session.minutes), [32, 31])
        // one app, two overlapping entries: not pieces of one workout either
        let overlap = [piece("2026-11-09 20:00", "2026-11-09 20:30", 30), piece("2026-11-09 20:20", "2026-11-09 20:45", 25)]
        XCTAssertEqual(WorkoutJoiner.join(overlap).count, 2)
    }

    func testAPieceAfterAnotherKindStillJoinsItsSession() {
        let workouts = [piece("2026-11-09 20:00", "2026-11-09 20:12", 12),
                        piece("2026-11-09 20:13", "2026-11-09 20:16", 3, "Walk"),
                        piece("2026-11-09 20:18", "2026-11-09 20:30", 12)]
        XCTAssertEqual(WorkoutJoiner.join(workouts).map(\.session.name), ["Strength", "Walk"])
        XCTAssertEqual(WorkoutJoiner.join(workouts).first?.session.minutes, 24)
    }

    func testASessionAcrossMidnightCountsOnTheDayItStarted() {
        let late = [piece("2026-11-09 23:45", "2026-11-09 23:57", 12), piece("2026-11-10 00:02", "2026-11-10 00:14", 12)]
        let joined = WorkoutJoiner.join(late)
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(w.calendar.startOfDay(for: joined[0].start), w.day("2026-11-09"))
    }

    func testDistancesAddUp() {
        var runs = [piece("2026-11-09 07:00", "2026-11-09 07:15", 15, "Run"), piece("2026-11-09 07:18", "2026-11-09 07:30", 12, "Run")]
        runs[0].distanceKm = 2.5
        runs[1].distanceKm = 2.1
        XCTAssertEqual(WorkoutJoiner.join(runs).first?.session.distanceKm ?? 0, 4.6, accuracy: 0.0001)
    }

    // MARK: - Bubbles while the pieces arrive

    func testTheBubbleKeepsItsKeyWhileMorePiecesArrive() {
        let rules = CreditRules(discipline: w.tracker())
        // WHOOP syncs each piece as it ends: the app sees the session grow
        let keys = (1...4).map { count in
            rules.workoutKeys(WorkoutJoiner.join(Array(session.prefix(count))).map(\.session))
        }
        XCTAssertEqual(keys, [[nil], [nil], ["workout:Strength:26"], ["workout:Strength:26"]])
        // a workout recorded in one go keeps its usual key
        XCTAssertEqual(rules.workoutKeys([WorkoutSession(name: "Strength", minutes: 34.16)]), ["workout:Strength:34"])
    }

    func testATappedSessionIsNotOfferedAgainWhenItGrows() {
        var run = AppRun(world: w, since: "2026-11-09", bed: Bedtime(hour: 1), wake: WakeTime(hour: 10))
        let sofar = WorkoutJoiner.join(Array(session.prefix(3))).map(\.session)
        run.open([w.appleDay("2026-11-09", workouts: sofar)], at: "2026-11-09 20:50")
        XCTAssertEqual(run.pending.map(\.key), ["workout:Strength:26"])
        run.tapAll()

        let all = WorkoutJoiner.join(session).map(\.session)
        run.open([w.appleDay("2026-11-09", workouts: all)], at: "2026-11-09 21:10")
        XCTAssertEqual(run.pending, [], "the fourth piece grows no second bubble")
        run.open([w.appleDay("2026-11-09", workouts: all)], at: "2026-11-10 09:00")
        XCTAssertEqual(run.autoBooked, [], "nothing left to collect at 04:00")
        XCTAssertEqual(run.sessions(.strength), 1)
        XCTAssertEqual(run.week?.workouts, 1)
    }

    func testOldSnapshotsWithoutPiecesStillDecode() throws {
        let old = #"{"name":"Run","minutes":32,"distanceKm":5.1}"#
        let workout = try JSONDecoder().decode(WorkoutSession.self, from: Data(old.utf8))
        XCTAssertNil(workout.pieces)
        XCTAssertEqual(workout.minutes, 32)
    }
}
