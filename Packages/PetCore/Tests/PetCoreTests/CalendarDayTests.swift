import XCTest
@testable import PetCore

/// Saved days after the phone changes time zone (`CalendarDay`): each saved day comes back as the
/// same calendar date in the new zone.
final class CalendarDayTests: XCTestCase {
    private let zones = ["Pacific/Honolulu", "America/Los_Angeles", "America/New_York", "America/Sao_Paulo",
                         "Europe/London", "Europe/Berlin", "Asia/Dubai", "Asia/Kolkata", "Asia/Shanghai",
                         "Asia/Tokyo", "Australia/Sydney", "Pacific/Auckland"]

    func testEveryDateSurvivesEveryFlight() {
        // a summer day, a winter day, both daylight saving changes in the US, Europe and Australia
        let dates = ["2026-01-15", "2026-03-08", "2026-03-29", "2026-04-05", "2026-07-15", "2026-10-04",
                     "2026-10-25", "2026-11-01", "2026-12-31"]
        for from in zones {
            for to in zones {
                let home = World(from), away = World(to)
                for date in dates {
                    XCTAssertEqual(CalendarDay.rekey(home.day(date), in: away.calendar), away.day(date),
                                   "\(date) saved in \(from), read in \(to)")
                }
            }
        }
    }

    func testADayOfTheCurrentZoneStaysAsItIs() {
        for zone in zones + ["Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            let here = World(zone)
            XCTAssertEqual(CalendarDay.rekey(here.day("2026-11-16"), in: here.calendar), here.day("2026-11-16"), zone)
        }
    }

    func testRekeyingTwiceChangesNothing() {
        let la = World(), tokyo = World("Asia/Tokyo")
        let once = CalendarDay.rekey(la.day("2026-11-16"), in: tokyo.calendar)
        XCTAssertEqual(CalendarDay.rekey(once, in: tokyo.calendar), once)
    }

    func testTwoSavedDaysOnOneDateAreJoined() {
        let la = World(), tokyo = World("Asia/Tokyo")
        // the same date saved once in LA and once in Tokyo (a phone and an iPad in iCloud)
        let log: [Date: Set<Activity>] = [la.day("2026-11-16"): [.running], tokyo.day("2026-11-16"): [.yoga]]
        let rekeyed = CalendarDay.rekey(log, in: tokyo.calendar) { $0.union($1) }
        XCTAssertEqual(rekeyed, [tokyo.day("2026-11-16"): [.running, .yoga]])
    }

    func testACreditKeepsItsDayInItsID() {
        let la = World(), tokyo = World("Asia/Tokyo")
        let rules = CreditRules(discipline: la.tracker())
        let credit = rules.credits(on: la.appleDay("2026-11-16", workouts: [WorkoutSession(name: "Run", minutes: 32)]))[0]
        let line = CreditRecord(id: credit.id, day: credit.day, kind: .workout, detail: "Run 32 min", activity: .running,
                                bookedAt: la.at("2026-11-16 12:00"), auto: false)

        let moved = line.rekeyed(in: tokyo.calendar)
        let sameInTokyo = CreditRules(discipline: tokyo.tracker())
            .credits(on: tokyo.appleDay("2026-11-16", workouts: [WorkoutSession(name: "Run", minutes: 32)]))[0]
        XCTAssertEqual(moved.id, sameInTokyo.id)
        XCTAssertEqual(moved.day, tokyo.day("2026-11-16"))
        XCTAssertEqual(moved.detail, "Run 32 min")
        // the bare iCloud id works the same way
        XCTAssertEqual(CalendarDay.rekeyID(CreditRecord.bareIDs([line.id])[0], in: tokyo.calendar),
                       CreditRecord.bareIDs([sameInTokyo.id])[0])
        // ids without a day are left alone
        XCTAssertEqual(CalendarDay.rekeyID("night", in: tokyo.calendar), "night")
    }
}
