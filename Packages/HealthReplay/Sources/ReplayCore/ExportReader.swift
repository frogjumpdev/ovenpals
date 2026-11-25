import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The samples of an Apple Health export (`apple_health_export/export.xml`) that the app reads:
/// steps, sleep, mindfulness and workouts, each with the app (or device) that wrote it.
public struct HealthExport: Sendable {
    public struct Steps: Sendable, Equatable {
        public var source: String
        public var start: Date
        public var end: Date
        public var count: Double
    }

    public struct Sleep: Sendable, Equatable {
        public var source: String
        public var interval: DateInterval
    }

    public struct Workout: Sendable, Equatable {
        public var source: String
        /// The HealthKit activity type without its prefix: "Running", "MindAndBody".
        public var activityType: String
        public var start: Date
        public var end: Date
        public var minutes: Double
        public var distanceKm: Double?
    }

    public var steps: [Steps] = []
    /// Only the stretches that are sleep (core, deep, REM, unspecified); in bed and awake are left out,
    /// as `HKCategoryValueSleepAnalysis.allAsleepValues` leaves them out in the app.
    public var sleep: [Sleep] = []
    public var mindful: [DateInterval] = []
    public var workouts: [Workout] = []
    /// The UTC offsets the samples were recorded with, by local date ("2026-11-16" → ["-0800"]):
    /// a second offset on a date that isn't a daylight saving change means the phone was elsewhere.
    public var offsetsByDate: [String: Set<String>] = [:]
    /// The time zones the Watch noted on samples (`HKTimeZone` metadata, on sleep and workouts), by
    /// the local date the sample started on: "Asia/Tokyo" on a date at home means a trip.
    public var zonesByDate: [String: Set<String>] = [:]
    /// When the export was made: that day had only just begun.
    public var exportDate: Date?

    public init() {}

    /// Reads `export.xml` (or the `apple_health_export` folder holding it).
    public static func read(_ url: URL) throws -> HealthExport {
        var file = url
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            file = url.appendingPathComponent("export.xml")
        }
        guard FileManager.default.isReadableFile(atPath: file.path), let handle = try? FileHandle(forReadingFrom: file) else {
            throw ReadError.cannotOpen(file.path)
        }
        let head = handle.readData(ofLength: headLength)
        try? handle.close()
        // The header (the DTD) is read from a copy without it: nothing in it is needed, some iOS versions
        // wrote one that strict parsers refuse, and Linux's XMLParser crashes on its attribute lists.
        if let dtd = dtdRange(head) {
            let stripped = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).xml")
            defer { try? FileManager.default.removeItem(at: stripped) }
            try copy(file, to: stripped, leavingOut: dtd)
            return try stream(stripped)
        }
        return try stream(file)
    }

    /// The DTD is in the first part of the file.
    private static let headLength = 1 << 20

    /// Reads as a stream: an export of a few years is a file of several GB.
    private static func stream(_ file: URL) throws -> HealthExport {
        guard let input = InputStream(url: file) else { throw ReadError.cannotOpen(file.path) }
        let parser = XMLParser(stream: input)
        let reader = Reader()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw ReadError.invalid(parser.parserError?.localizedDescription ?? "unknown") }
        return reader.export
    }

    /// Where `<!DOCTYPE HealthData [ … ]>` is in the start of the file.
    static func dtdRange(_ head: Data) -> Range<Data.Index>? {
        guard let start = head.range(of: Data("<!DOCTYPE".utf8)),
              let end = head.range(of: Data("]>".utf8), in: start.upperBound..<head.endIndex) else { return nil }
        return start.lowerBound..<end.upperBound
    }

    /// Copies the export in chunks, without the bytes in `range` (which lie in the first chunk).
    private static func copy(_ file: URL, to copy: URL, leavingOut range: Range<Data.Index>) throws {
        guard FileManager.default.createFile(atPath: copy.path, contents: nil),
              let input = try? FileHandle(forReadingFrom: file), let output = try? FileHandle(forWritingTo: copy) else {
            throw ReadError.cannotOpen(copy.path)
        }
        defer { try? input.close(); try? output.close() }
        let chunk = 8 << 20
        let first = input.readData(ofLength: max(chunk, headLength))
        output.write(first[first.startIndex..<range.lowerBound])
        output.write(first[range.upperBound...])
        while true {
            let data = input.readData(ofLength: chunk)
            if data.isEmpty { break }
            output.write(data)
        }
    }

    private static func read(data: Data) throws -> HealthExport {
        let parser = XMLParser(data: data)
        let reader = Reader()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw ReadError.invalid(parser.parserError?.localizedDescription ?? "unknown") }
        return reader.export
    }

    /// Reads export XML given as text (tests).
    public static func read(xml: String) throws -> HealthExport {
        var data = Data(xml.utf8)
        if let dtd = dtdRange(data.prefix(headLength)) { data.removeSubrange(dtd) }
        return try read(data: data)
    }

    public enum ReadError: Error, CustomStringConvertible {
        case cannotOpen(String)
        case invalid(String)

        public var description: String {
            switch self {
            case .cannotOpen(let path): "Can't open \(path). Give the export.xml inside the unzipped apple_health_export folder."
            case .invalid(let reason): "export.xml couldn't be read: \(reason)"
            }
        }
    }

    static let asleepValues: Set<String> = [
        "HKCategoryValueSleepAnalysisAsleep", // before iOS 16
        "HKCategoryValueSleepAnalysisAsleepUnspecified",
        "HKCategoryValueSleepAnalysisAsleepCore",
        "HKCategoryValueSleepAnalysisAsleepDeep",
        "HKCategoryValueSleepAnalysisAsleepREM",
    ]

    /// "2026-11-16 22:48:00 -0800", the format of every date in the export.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return fastDate(text) ?? dateFormatter.date(from: text)
    }

    /// The same, read by position: many times faster than a DateFormatter over a few million samples.
    static func fastDate(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { u -> Date? in
            guard u.count == 25, u[4] == 45, u[7] == 45, u[10] == 32, u[13] == 58, u[16] == 58, u[19] == 32,
                  u[20] == 43 || u[20] == 45 else { return nil }
            func number(_ from: Int, _ count: Int) -> Int? {
                var value = 0
                for i in from..<(from + count) {
                    let digit = Int(u[i]) - 48
                    guard (0...9).contains(digit) else { return nil }
                    value = value * 10 + digit
                }
                return value
            }
            guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2), let hour = number(11, 2),
                  let minute = number(14, 2), let second = number(17, 2), let offsetHours = number(21, 2),
                  let offsetMinutes = number(23, 2), (1...12).contains(month), (1...31).contains(day) else { return nil }
            // days since 1970-01-01 of a calendar date (H. Hinnant's days_from_civil)
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yearOfEra = y - era * 400
            let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let days = era * 146_097 + dayOfEra - 719_468
            let offset = (u[20] == 45 ? -1 : 1) * (offsetHours * 3600 + offsetMinutes * 60)
            return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + hour * 3600 + minute * 60 + second - offset))
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    private final class Reader: NSObject, XMLParserDelegate {
        var export = HealthExport()
        /// The workout being read, until its closing tag (its distance comes in child elements).
        private var workout: Workout?
        /// The start date text of the record or workout being read (for its metadata).
        private var startText: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            switch name {
            case "Record":
                startText = a["startDate"]
                // most of an export is heart rate and the like: only the kinds the app reads are taken apart
                let type = a["type"]
                guard type == "HKQuantityTypeIdentifierStepCount" || type == "HKCategoryTypeIdentifierSleepAnalysis"
                        || type == "HKCategoryTypeIdentifierMindfulSession",
                      let start = HealthExport.date(a["startDate"]), let end = HealthExport.date(a["endDate"]) else { return }
                noteOffset(a["startDate"])
                let source = a["sourceName"] ?? "?"
                switch type {
                case "HKQuantityTypeIdentifierStepCount":
                    if let value = a["value"].flatMap(Double.init) {
                        export.steps.append(Steps(source: source, start: start, end: end, count: value))
                    }
                case "HKCategoryTypeIdentifierSleepAnalysis":
                    if let value = a["value"], HealthExport.asleepValues.contains(value), end > start {
                        export.sleep.append(Sleep(source: source, interval: DateInterval(start: start, end: end)))
                    }
                default:
                    if end > start { export.mindful.append(DateInterval(start: start, end: end)) }
                }
            case "Workout":
                startText = a["startDate"]
                guard let start = HealthExport.date(a["startDate"]), let end = HealthExport.date(a["endDate"]) else { return }
                noteOffset(a["startDate"])
                let type = (a["workoutActivityType"] ?? "Other").replacingOccurrences(of: "HKWorkoutActivityType", with: "")
                var minutes = end.timeIntervalSince(start) / 60
                if let duration = a["duration"].flatMap(Double.init) {
                    switch a["durationUnit"] {
                    case "s", "sec": minutes = duration / 60
                    case "hr", "h": minutes = duration * 60
                    default: minutes = duration
                    }
                }
                workout = Workout(source: a["sourceName"] ?? "?", activityType: type, start: start, end: end, minutes: minutes)
                if let distance = a["totalDistance"].flatMap(Double.init), distance > 0 {
                    workout?.distanceKm = Self.km(distance, unit: a["totalDistanceUnit"])
                }
            case "WorkoutStatistics":
                guard workout != nil, workout?.distanceKm == nil, let type = a["type"], type.contains("Distance"),
                      let sum = a["sum"].flatMap(Double.init), sum > 0 else { return }
                workout?.distanceKm = Self.km(sum, unit: a["unit"])
            case "ExportDate":
                export.exportDate = HealthExport.date(a["value"])
            case "MetadataEntry":
                guard a["key"] == "HKTimeZone", let zone = a["value"], !zone.isEmpty,
                      let text = startText, text.count >= 10 else { return }
                export.zonesByDate[String(text.prefix(10)), default: []].insert(zone)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Workout", let workout {
                export.workouts.append(workout)
                self.workout = nil
            }
            if name == "Workout" || name == "Record" { startText = nil }
        }

        /// "2026-11-16 22:48:00 -0800": the date and the offset at the ends of the text.
        private func noteOffset(_ text: String?) {
            guard let text, text.count >= 25 else { return }
            export.offsetsByDate[String(text.prefix(10)), default: []].insert(String(text.suffix(5)))
        }

        private static func km(_ value: Double, unit: String?) -> Double {
            switch unit {
            case "mi": value * 1.609_344
            case "m": value / 1_000
            case "yd": value * 0.000_914_4
            default: value
            }
        }
    }
}
