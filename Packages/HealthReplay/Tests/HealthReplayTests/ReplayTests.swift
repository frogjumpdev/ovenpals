import Foundation
import XCTest
import PetCore
@testable import ReplayCore

/// A week of export.xml the way the Health app writes it (an Apple Watch, an iPhone, AutoSleep and
/// Strava as sources), replayed in Los Angeles with a 23:00 bedtime.
final class ReplayTests: XCTestCase {
    private let la = TimeZone(identifier: "America/Los_Angeles")!

    private func settings() -> ReplaySettings {
        var settings = ReplaySettings(timeZone: la, days: 7)
        settings.lastDay = day("2026-11-22")
        return settings
    }

    private func day(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = la
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)!
    }

    // MARK: - The week's export

    /// "2026-11-16 23:00" (LA, November = -0800) as the export writes it.
    private func t(_ text: String, offset: String = "-0800") -> String { "\(text):00 \(offset)" }

    private func record(_ type: String, _ source: String, _ start: String, _ end: String, value: String? = nil,
                        offset: String = "-0800") -> String {
        let device = source == "Apple Watch" ? " sourceVersion=\"11.1\" device=\"&lt;&lt;HKDevice&gt;&gt;\"" : ""
        return "<Record type=\"\(type)\" sourceName=\"\(source)\"\(device) unit=\"count\" creationDate=\"\(t(end, offset: offset))\" "
            + "startDate=\"\(t(start, offset: offset))\" endDate=\"\(t(end, offset: offset))\"\(value.map { " value=\"\($0)\"" } ?? "")/>"
    }

    private func steps(_ source: String, _ start: String, _ end: String, _ count: Int) -> String {
        record("HKQuantityTypeIdentifierStepCount", source, start, end, value: String(count))
    }

    private func asleep(_ source: String, _ start: String, _ end: String, _ stage: String = "AsleepCore") -> String {
        record("HKCategoryTypeIdentifierSleepAnalysis", source, start, end, value: "HKCategoryValueSleepAnalysis\(stage)")
    }

    /// A Watch night: 90-minute stretches with 4 minutes awake between them, and the hour in bed before.
    private func watchNight(_ evening: String, _ asleepAt: String, _ morning: String, _ awakeAt: String) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = la
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let start = f.date(from: "\(evening) \(asleepAt)")!, end = f.date(from: "\(morning) \(awakeAt)")!
        var rows = [record("HKCategoryTypeIdentifierSleepAnalysis", "Apple Watch", f.string(from: start.addingTimeInterval(-3600)),
                           f.string(from: end), value: "HKCategoryValueSleepAnalysisInBed")]
        var cursor = start
        var stage = 0
        while cursor < end {
            let stop = min(end, cursor.addingTimeInterval(90 * 60))
            rows.append(asleep("Apple Watch", f.string(from: cursor), f.string(from: stop), ["AsleepCore", "AsleepDeep", "AsleepREM"][stage % 3]))
            rows.append(asleep("Apple Watch", f.string(from: stop), f.string(from: min(end, stop.addingTimeInterval(240))), "Awake"))
            cursor = stop.addingTimeInterval(4 * 60)
            stage += 1
        }
        return rows
    }

    private func workout(_ type: String, _ source: String, _ start: String, _ end: String, minutes: Double,
                         inner: String = "") -> String {
        "<Workout workoutActivityType=\"HKWorkoutActivityType\(type)\" duration=\"\(minutes)\" durationUnit=\"min\" "
            + "sourceName=\"\(source)\" creationDate=\"\(t(end))\" startDate=\"\(t(start))\" endDate=\"\(t(end))\">\(inner)</Workout>"
    }

    private var weekXML: String {
        var rows: [String] = []
        // nights: 23:00 → 06:45, every night but the one ending Thursday
        for (evening, morning) in [("2026-11-15", "2026-11-16"), ("2026-11-19", "2026-11-20"), ("2026-11-20", "2026-11-21"),
                                   ("2026-11-21", "2026-11-22")] {
            rows += watchNight(evening, "23:00", morning, "06:45")
        }
        // Monday evening: a 40-minute nap on the sofa, then to bed at 23:50 (late)
        rows.append(asleep("Apple Watch", "2026-11-16 19:00", "2026-11-16 19:40"))
        rows += watchNight("2026-11-16", "23:50", "2026-11-17", "06:45")
        // Tuesday night: AutoSleep thinks sleep began at 22:50, the Watch says 23:45 (late)
        rows.append(asleep("AutoSleep", "2026-11-17 22:50", "2026-11-17 23:50", "Asleep"))
        rows += watchNight("2026-11-17", "23:45", "2026-11-18", "06:50")

        // Monday: one run, written by the Watch and by Strava
        rows.append(workout("Running", "Apple Watch", "2026-11-16 07:00", "2026-11-16 07:32", minutes: 32, inner:
            "<WorkoutStatistics type=\"HKQuantityTypeIdentifierDistanceWalkingRunning\" startDate=\"\(t("2026-11-16 07:00"))\" "
            + "endDate=\"\(t("2026-11-16 07:32"))\" sum=\"5.1\" unit=\"km\"/>"))
        rows.append(workout("Running", "Strava", "2026-11-16 07:01", "2026-11-16 07:33", minutes: 31))
        // Tuesday: 19.6 minutes
        rows.append(workout("Running", "Apple Watch", "2026-11-17 18:00", "2026-11-17 18:20", minutes: 19.6))
        // Wednesday: 30 minutes of Mind & Body
        rows.append(workout("MindAndBody", "Apple Watch", "2026-11-18 20:00", "2026-11-18 20:30", minutes: 30))
        // Thursday: yoga, recorded in Tokyo's time zone
        rows.append(workout("Yoga", "Apple Watch", "2026-11-19 18:00", "2026-11-19 18:45", minutes: 45, inner:
            "<MetadataEntry key=\"HKTimeZone\" value=\"Asia/Tokyo\"/>"))
        // Friday: 9,000 steps on the Watch, 3,000 on the phone at the same time, 1,200 more on the phone
        // after the Watch went on its charger at 20:00 → Apple Health adds up 10,200
        for hour in 8..<20 {
            let start = String(format: "2026-11-20 %02d:00", hour), end = String(format: "2026-11-20 %02d:59", hour)
            rows.append(steps("Apple Watch", start, end, 750))
            rows.append(steps("iPhone", start, end, 250))
        }
        rows.append(steps("iPhone", "2026-11-20 20:00", "2026-11-20 20:59", 600))
        rows.append(steps("iPhone", "2026-11-20 21:00", "2026-11-20 21:59", 600))
        // Saturday: a walk home across midnight, half each side
        rows.append(steps("Apple Watch", "2026-11-21 23:30", "2026-11-22 00:30", 600))
        // Saturday 03:00 here, written while the phone was on Tokyo time
        rows.append(record("HKCategoryTypeIdentifierMindfulSession", "Mindfulness", "2026-11-21 20:00", "2026-11-21 20:10", offset: "+0900"))

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE HealthData [
        <!ELEMENT HealthData (ExportDate,Me,(Record|Correlation|Workout|ActivitySummary|ClinicalRecord)*)>
        ]>
        <HealthData locale="en_US">
         <ExportDate value="\(t("2026-11-24 09:00"))"/>
         <Me HKCharacteristicTypeIdentifierBiologicalSex="HKBiologicalSexNotSet"/>
         \(rows.joined(separator: "\n "))
        </HealthData>
        """
    }

    // MARK: - Reading

    func testReadsWhatTheAppReads() throws {
        let export = try HealthExport.read(xml: weekXML)
        XCTAssertEqual(export.workouts.count, 5)
        XCTAssertEqual(export.workouts[0].activityType, "Running")
        XCTAssertEqual(export.workouts[0].distanceKm ?? 0, 5.1, accuracy: 0.001)
        XCTAssertEqual(export.workouts[2].minutes, 19.6, accuracy: 0.001)
        XCTAssertEqual(export.steps.count, 27)
        XCTAssertEqual(Set(export.sleep.map(\.source)), ["Apple Watch", "AutoSleep"])
        // in bed and awake are not sleep
        XCTAssertFalse(export.sleep.contains { $0.interval.duration == 240 })
        XCTAssertEqual(export.mindful.count, 1)
        XCTAssertEqual(export.zonesByDate["2026-11-19"], ["Asia/Tokyo"])
        XCTAssertEqual(export.offsetsByDate["2026-11-21"], ["-0800", "+0900"])
        XCTAssertEqual(export.exportDate, ISO8601DateFormatter().date(from: "2026-11-24T17:00:00Z"))
    }

    func testReadsTheFolderOrTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apple_health_export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try weekXML.write(to: folder.appendingPathComponent("export.xml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try HealthExport.read(folder).workouts.count, 5)
        XCTAssertEqual(try HealthExport.read(folder.appendingPathComponent("export.xml")).workouts.count, 5)
        XCTAssertThrowsError(try HealthExport.read(folder.appendingPathComponent("nothing.xml")))
    }

    // MARK: - Replaying

    func testTheWeekCountsAsTheAppCountsIt() throws {
        let result = try XCTUnwrap(Replay.run(try HealthExport.read(xml: weekXML), settings: settings()))
        XCTAssertEqual(result.firstDay, day("2026-11-16"))
        XCTAssertEqual(result.lastDay, day("2026-11-22"))
        XCTAssertEqual(result.weeks.count, 1)
        let week = result.weeks[0]
        XCTAssertTrue(week.isFinished)
        // the run (Mon), 10,200 steps (Fri), the yoga (Thu); not 19.6 minutes (Tue) or Mind & Body (Wed)
        XCTAssertEqual(week.days.map(\.countsAsWorkout), [true, false, false, true, true, false, false])
        XCTAssertEqual(week.progress.workouts, 3)
        // the nap makes Tuesday on time, AutoSleep makes Wednesday on time; Thursday has no data
        XCTAssertEqual(week.days.map(\.onTime), [true, true, true, nil, true, true, true])
        XCTAssertEqual(week.progress.onTimeNights, 6)
        XCTAssertTrue(week.progress.isDisciplined)
        XCTAssertEqual(result.disciplinedWeeks, [day("2026-11-16")])
        XCTAssertEqual(result.monthlyAchievements, 0)
        XCTAssertEqual(result.nightsWithoutSleep, [day("2026-11-19")])
        XCTAssertEqual(result.workoutSources, ["Apple Watch", "Strava"])
    }

    func testStepsAreAddedUpTheWayAppleHealthDoes() throws {
        let result = try XCTUnwrap(Replay.run(try HealthExport.read(xml: weekXML), settings: settings()))
        let friday = result.days[4]
        XCTAssertEqual(friday.snapshot.steps, 10_200)
        XCTAssertEqual(friday.stepsBySource, ["Apple Watch": 9_000, "iPhone": 4_200])
        XCTAssertTrue(friday.activities.contains(.walking))
        // a sample across midnight is split by time
        XCTAssertEqual(result.days[5].snapshot.steps, 300)
        XCTAssertEqual(result.days[6].snapshot.steps, 300)
        XCTAssertNil(result.days[0].snapshot.steps)
    }

    func testPetsGetDoubleExperienceInTheDisciplinedWeek() throws {
        let result = try XCTUnwrap(Replay.run(try HealthExport.read(xml: weekXML), settings: settings()))
        let experience = result.progress.filter { $0.value.isUnlocked }.mapValues(\.experience)
        XCTAssertEqual(experience, [.running: 2, .yoga: 2, .walking: 2, .mindfulness: 4, .onTimeSleep: 12, .earlyRise: 12])
        XCTAssertEqual(result.progress[.onTimeSleep]?.level, 4)
        // two bubbles for the one run on Monday (both apps wrote it), and the night's moon
        XCTAssertEqual(result.days[0].credits.map(\.kind), [.workout, .workout, .night])
    }

    func testFlagsWhatIsWorthALook() throws {
        let result = try XCTUnwrap(Replay.run(try HealthExport.read(xml: weekXML), settings: settings()))
        let byKind = Dictionary(grouping: result.notes, by: \.kind)
        func only(_ kind: ReplayNote.Kind) throws -> ReplayNote {
            let notes = try XCTUnwrap(byKind[kind], "\(kind)")
            XCTAssertEqual(notes.count, 1, "\(kind): \(notes.map(\.text))")
            return notes[0]
        }

        let nap = try only(.eveningNap)
        XCTAssertEqual(nap.day, day("2026-11-17"))
        XCTAssertTrue(nap.matters)
        XCTAssertTrue(nap.text.contains("19:00–19:40") && nap.text.contains("23:50"), nap.text)

        let source = try only(.otherSleepSource)
        XCTAssertEqual(source.day, day("2026-11-18"))
        XCTAssertTrue(source.matters)
        XCTAssertTrue(source.text.contains("AutoSleep") && source.text.contains("23:45"), source.text)

        let twice = try only(.duplicateWorkout)
        XCTAssertEqual(twice.day, day("2026-11-16"))
        XCTAssertTrue(twice.matters)
        XCTAssertTrue(twice.text.contains("Strava"), twice.text)

        let short = try only(.almostTwentyMinutes)
        XCTAssertEqual(short.day, day("2026-11-17"))
        XCTAssertTrue(short.matters)
        XCTAssertTrue(short.text.contains("24 秒") && short.text.contains("20 min"), short.text)

        let mind = try only(.mindWorkout)
        XCTAssertEqual(mind.day, day("2026-11-18"))
        XCTAssertFalse(mind.matters)

        let steps = try only(.stepsNearGoal)
        XCTAssertEqual(steps.day, day("2026-11-20"))
        // the Watch alone is under 10,000, Apple Health's total is over: worth checking on the phone
        XCTAssertTrue(steps.matters)

        let travel = try XCTUnwrap(byKind[.travel])
        XCTAssertEqual(travel.map(\.day), [day("2026-11-19"), day("2026-11-21")])
        XCTAssertTrue(travel[0].text.contains("Asia/Tokyo"), travel[0].text)
        XCTAssertTrue(travel[1].text.contains("UTC+09:00"), travel[1].text)
    }

    func testADaylightSavingChangeIsNotATrip() throws {
        // clocks went back in LA on 2026-11-01: that day has both -0700 and -0800 samples
        let xml = """
        <HealthData>
         \(record("HKQuantityTypeIdentifierStepCount", "iPhone", "2026-11-01 00:30", "2026-11-01 00:40", value: "100", offset: "-0700"))
         \(record("HKQuantityTypeIdentifierStepCount", "iPhone", "2026-11-01 12:00", "2026-11-01 12:10", value: "100"))
        </HealthData>
        """
        var settings = ReplaySettings(timeZone: la, days: 7)
        settings.lastDay = day("2026-11-01")
        let result = try XCTUnwrap(Replay.run(try HealthExport.read(xml: xml), settings: settings))
        XCTAssertEqual(result.notes.filter { $0.kind == .travel }, [])
        XCTAssertEqual(result.days.last?.snapshot.steps, 200)
    }

    func testRangeEndsOnTheLastDayWithDataAndStartsOnAMonday() throws {
        let result = try XCTUnwrap(Replay.run(try HealthExport.read(xml: weekXML), settings: ReplaySettings(timeZone: la, days: 3)))
        // the last night ends Sunday morning, and the export was made on Tuesday
        XCTAssertEqual(result.lastDay, day("2026-11-22"))
        XCTAssertEqual(result.firstDay, day("2026-11-16"))
        XCTAssertNil(Replay.run(HealthExport(), settings: ReplaySettings(timeZone: la)))
    }

    func testWeeksBeforeTheDataStartsAreLeftOut() throws {
        let result = try XCTUnwrap(Replay.run(try HealthExport.read(xml: weekXML), settings: ReplaySettings(timeZone: la, days: 60)))
        XCTAssertEqual(result.firstDay, day("2026-11-16"))
        XCTAssertEqual(result.nightsWithoutSleep, [day("2026-11-19")])
    }

    func testTheHeaderIsLeftOut() throws {
        // a header with attribute lists, one of them broken as some iOS versions wrote it
        let header = "<!ATTLIST HealthData locale CDATA #REQUIRED>\n<!ATTLIST Record type CDATA #REQUIRED type CDATA>\n]>"
        let xml = weekXML.replacingOccurrences(of: "]>", with: header)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).xml")
        try xml.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try HealthExport.read(file).workouts.count, 5)
        XCTAssertEqual(try HealthExport.read(xml: xml).workouts.count, 5)
        let range = try XCTUnwrap(HealthExport.dtdRange(Data(xml.utf8)))
        XCTAssertTrue(String(decoding: Data(xml.utf8)[range], as: UTF8.self).hasPrefix("<!DOCTYPE HealthData ["))
        XCTAssertNil(HealthExport.dtdRange(Data("<HealthData/>".utf8)))
    }

    func testTheDayOfTheExportIsLeftOut() throws {
        // exported at 09:00 on Tuesday: Tuesday has only just begun
        var export = try HealthExport.read(xml: weekXML)
        export.steps.append(.init(source: "iPhone", start: day("2026-11-24").addingTimeInterval(8 * 3600),
                                  end: day("2026-11-24").addingTimeInterval(8.5 * 3600), count: 800))
        let result = try XCTUnwrap(Replay.run(export, settings: ReplaySettings(timeZone: la, days: 3)))
        XCTAssertEqual(result.lastDay, day("2026-11-23"))
        XCTAssertFalse(result.weeks.last!.isFinished)
    }

    func testShortNamesMatchTheApp() {
        XCTAssertEqual(Replay.shortName("Running"), "Run")
        XCTAssertEqual(Replay.shortName("TaiChi"), "Mind")
        XCTAssertEqual(Replay.shortName("HighIntensityIntervalTraining"), "HIIT")
        XCTAssertEqual(Replay.shortName("Fishing"), "Workout")
        XCTAssertEqual(Activity(workoutName: Replay.shortName("Cooldown")), .pilates)
        XCTAssertFalse(Activity(workoutName: Replay.shortName("MindAndBody")).isWorkout)
    }

    func testDatesAreReadAsTheFormatterReadsThem() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        for text in ["2026-11-16 22:48:00 -0800", "2026-03-08 03:00:00 -0700", "2024-02-29 23:59:59 +0900",
                     "2025-12-31 00:00:01 +0530", "1969-12-31 23:00:00 +0000", "2000-03-01 12:00:00 -1000",
                     "2026-01-01 00:00:00 +1300"] {
            XCTAssertEqual(HealthExport.fastDate(text), f.date(from: text), text)
        }
        XCTAssertNil(HealthExport.fastDate("2026-11-16T22:48:00Z"))
        XCTAssertNil(HealthExport.fastDate("2026-13-16 22:48:00 -0800"))
        // another layout still reads, more slowly
        XCTAssertNotNil(HealthExport.date("2026-11-16 22:48:00 -08:00"))
    }

    func testFormat() {
        XCTAssertEqual(ReplayFormat.number(10_200), "10,200")
        XCTAssertEqual(ReplayFormat.number(950), "950")
        XCTAssertEqual(ReplayFormat.minutes(19.6), "19.6")
        XCTAssertEqual(ReplayFormat.minutes(32.4), "32")
        XCTAssertEqual(ReplayFormat.offsetSeconds("+0530"), 19_800)
        XCTAssertEqual(ReplayFormat.offsetText(-28_800), "UTC-08:00")
    }
}
