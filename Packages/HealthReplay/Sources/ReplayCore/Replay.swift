import Foundation
import PetCore

/// What the user set in the app (Settings → sleep targets), and which days to replay.
public struct ReplaySettings: Sendable {
    public var timeZone: TimeZone
    public var bedtime: Bedtime
    /// Friday and Saturday nights (nil = same as weekdays).
    public var weekendBedtime: Bedtime?
    public var wake: WakeTime
    public var weekendWake: WakeTime?
    /// First day replayed (moved back to its Monday, so every week is whole). nil = `days` before `lastDay`.
    public var firstDay: Date?
    /// Last day replayed. nil = the last day the export has data for, before the day it was made.
    public var lastDay: Date?
    public var days: Int

    public init(timeZone: TimeZone = .current, bedtime: Bedtime = Bedtime(hour: 23), weekendBedtime: Bedtime? = nil,
                wake: WakeTime = WakeTime(hour: 7), weekendWake: WakeTime? = nil,
                firstDay: Date? = nil, lastDay: Date? = nil, days: Int = 56) {
        self.timeZone = timeZone
        self.bedtime = bedtime
        self.weekendBedtime = weekendBedtime
        self.wake = wake
        self.weekendWake = weekendWake
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.days = days
    }

    /// Weeks start on Monday, as `AppModel.weekCalendar` fixes them in the app.
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }
}

/// One workout of a day, with where it came from.
public struct ReplayWorkout: Sendable, Equatable {
    public var source: String
    public var start: Date
    public var end: Date
    public var session: WorkoutSession
    /// One of the week's workouts: a sport of 20+ minutes.
    public var counts: Bool
}

/// One day as the app would see it on the morning after (everything collected at 04:00).
public struct ReplayDay: Sendable {
    /// The day as `HealthKitProvider.snapshots` builds it.
    public var snapshot: HealthSnapshot
    public var stepsBySource: [String: Int]
    public var workouts: [ReplayWorkout]
    /// Every app or device that wrote sleep for the night ending this morning.
    public var sleepSources: [String]
    public var countsAsWorkout: Bool
    /// nil = no sleep data for the night ending this morning.
    public var onTime: Bool?
    /// Latest on-time sleep: the bedtime target + 30 minutes.
    public var latestOnTime: Date
    public var activities: Set<Activity>
    /// The food bubbles the day grows.
    public var credits: [Credit]

    public var day: Date { snapshot.day }
}

public struct ReplayWeek: Sendable {
    public var progress: WeekProgress
    /// The week's Sunday is inside the replay (an unfinished week can't be a 自律周 yet).
    public var isFinished: Bool
    public var days: [ReplayDay]
    public var start: Date { progress.weekStart }
}

/// Something in the data worth a look: where the app's reading may not be what the user expects.
public struct ReplayNote: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// A short sleep in the evening was taken as the time of falling asleep.
        case eveningNap
        /// The time of falling asleep came from another app than the one that recorded most of the night.
        case otherSleepSource
        /// Two workouts at the same time: likely one workout written by two apps.
        case duplicateWorkout
        /// A sport that reads "19 min": short of the 19:30 that shows (and counts) as 20.
        case almostTwentyMinutes
        /// A Mind & Body / Tai Chi workout of 20+ minutes: Matcha only, not one of the week's workouts.
        case mindWorkout
        /// Steps close to 10,000.
        case stepsNearGoal
        /// Data recorded in another time zone.
        case travel
    }

    public var kind: Kind
    public var day: Date
    /// The app shows or counts something differently because of it (else it's for information).
    public var matters: Bool
    public var text: String
}

public struct ReplayResult: Sendable {
    public var settings: ReplaySettings
    public var firstDay: Date
    public var lastDay: Date
    public var weeks: [ReplayWeek]
    /// Finished weeks that counted (their sessions earn double).
    public var disciplinedWeeks: Set<Date>
    /// 3 自律周 in a block of 4 weeks, counted from the first week replayed.
    public var monthlyAchievements: Int
    public var progress: [Activity: ActivityProgress]
    public var notes: [ReplayNote]
    public var nightsWithoutSleep: [Date]
    public var stepSources: [String]
    public var sleepSourceNames: [String]
    public var workoutSources: [String]

    public var days: [ReplayDay] { weeks.flatMap(\.days) }
}

/// Runs an export through PetCore's rules the way `AppModel.evaluate` does, for days that are
/// over: every food bubble was collected by 04:00, no leave days, no 「手表记错了」.
public enum Replay {
    public static func run(_ export: HealthExport, settings: ReplaySettings) -> ReplayResult? {
        let calendar = settings.calendar
        guard let last = settings.lastDay.map(calendar.startOfDay(for:)) ?? lastDataDay(export, calendar: calendar) else {
            return nil
        }
        let tracker = DisciplineTracker(bedtime: settings.bedtime, weekendBedtime: settings.weekendBedtime, calendar: calendar)
        let activities = ActivityTracker(discipline: tracker, wakeTarget: settings.wake, weekendWakeTarget: settings.weekendWake)
        let rules = CreditRules(discipline: tracker)

        let wantedFirst = settings.firstDay.map(calendar.startOfDay(for:))
            ?? calendar.date(byAdding: .day, value: -(max(settings.days, 1) - 1), to: last)!
        // not before the week the data starts in
        let dataStart = firstDataDay(export, calendar: calendar).map { tracker.weekStart(for: $0) } ?? wantedFirst
        let first = tracker.weekStart(for: max(wantedFirst, min(dataStart, last)))
        var dayStarts: [Date] = []
        var cursor = first
        while cursor <= last {
            dayStarts.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        let end = calendar.date(byAdding: .day, value: 1, to: last)!

        // the samples, read as HealthKitProvider reads them
        let steps = DailySteps(export.steps, from: first, to: end, calendar: calendar)
        let asleep = export.sleep.filter { $0.interval.end > first.addingTimeInterval(-12 * 3600) && $0.interval.start < end }
        let nights = SleepNights.nights(asleep.map(\.interval), calendar: calendar)
        let sleepByNight = Dictionary(grouping: asleep) {
            SleepNights.wakeDay(forSleepStartingAt: $0.interval.start, calendar: calendar)
        }
        let workouts = export.workouts.filter { $0.start >= first && $0.start < end }.sorted { $0.start < $1.start }
        let workoutsByDay = Dictionary(grouping: workouts) { calendar.startOfDay(for: $0.start) }
        let mindfulByDay = Dictionary(grouping: export.mindful.filter { $0.start >= first && $0.start < end }) {
            calendar.startOfDay(for: $0.start)
        }.mapValues { SleepNights.mergedDuration($0) / 60 }

        var notes: [ReplayNote] = []
        let format = ReplayFormat(calendar: calendar)
        var days: [ReplayDay] = []
        for day in dayStarts {
            let dayWorkouts = (workoutsByDay[day] ?? []).map { workout in
                let session = WorkoutSession(name: shortName(workout.activityType), minutes: workout.minutes,
                                             distanceKm: workout.distanceKm)
                return ReplayWorkout(source: workout.source, start: workout.start, end: workout.end, session: session,
                                     counts: tracker.countsAsWorkout(session))
            }
            let sessions = dayWorkouts.map(\.session)
            let longest = sessions.max { $0.minutes < $1.minutes }
            let night = nights[day]
            let snapshot = HealthSnapshot(day: day, source: .healthKit, steps: steps.counted[day].map { Int($0) },
                                          sleepHours: night?.hours, sleepOnset: night?.onset,
                                          workoutMinutes: longest?.minutes, workoutType: longest?.name, workouts: sessions,
                                          wakeTime: night?.wake, mindfulMinutes: mindfulByDay[day])
            let latest = tracker.target(forNightEnding: day).addingTimeInterval(TimeInterval(tracker.rules.bedtimeGraceMinutes * 60))
            let replayDay = ReplayDay(snapshot: snapshot,
                                      stepsBySource: (steps.bySource[day] ?? [:]).mapValues { Int($0) },
                                      workouts: dayWorkouts,
                                      sleepSources: Set((sleepByNight[day] ?? []).map(\.source)).sorted(),
                                      countsAsWorkout: tracker.countsAsWorkout(snapshot),
                                      onTime: tracker.isOnTimeNight(snapshot),
                                      latestOnTime: latest,
                                      activities: activities.activities(on: snapshot),
                                      credits: rules.credits(on: snapshot))
            days.append(replayDay)
            notes += sleepNotes(replayDay, stretches: sleepByNight[day] ?? [], format: format)
            notes += workoutNotes(replayDay, format: format)
            notes += stepNotes(replayDay)
            notes += travelNotes(day, export: export, calendar: calendar, format: format)
        }

        // the morning after the last day, once its bubbles were collected
        let now = rules.autoBookTime(for: last)
        let snapshots = days.map(\.snapshot)
        let finished = Set(tracker.disciplinedWeeks(in: snapshots, before: now))
        let log = activities.log(snapshots, today: calendar.startOfDay(for: now))
        let progress = ActivityProgress.all(log: log, disciplinedWeeks: finished, weekStart: tracker.weekStart(for:))

        let weekStarts = Set(dayStarts.map(tracker.weekStart(for:))).sorted()
        let weeks = weekStarts.map { start in
            let next = calendar.date(byAdding: .day, value: 7, to: start)!
            return ReplayWeek(progress: tracker.week(containing: start, snapshots: snapshots),
                              isFinished: next <= end,
                              days: days.filter { $0.day >= start && $0.day < next })
        }

        return ReplayResult(settings: settings, firstDay: first, lastDay: last, weeks: weeks, disciplinedWeeks: finished,
                            monthlyAchievements: monthlyAchievements(finished, from: first, calendar: calendar),
                            progress: progress, notes: notes,
                            nightsWithoutSleep: days.filter { $0.onTime == nil }.map(\.day),
                            stepSources: Set(export.steps.filter { $0.end > first && $0.start < end }.map(\.source)).sorted(),
                            sleepSourceNames: Set(asleep.map(\.source)).sorted(),
                            workoutSources: Set(workouts.map(\.source)).sorted())
    }

    /// The last local day anything was recorded on, before the day of the export (which had only
    /// just begun, so its steps and workouts would look short).
    static func lastDataDay(_ export: HealthExport, calendar: Calendar) -> Date? {
        let latest = [export.steps.map(\.start).max(), export.sleep.map(\.interval.start).max(),
                      export.workouts.map(\.start).max(), export.mindful.map(\.start).max()].compactMap { $0 }.max()
        guard let latest else { return nil }
        let last = calendar.startOfDay(for: latest)
        guard let exported = export.exportDate.map(calendar.startOfDay(for:)), last >= exported else { return last }
        return calendar.date(byAdding: .day, value: -1, to: exported)
    }

    /// The first local day anything was recorded on.
    static func firstDataDay(_ export: HealthExport, calendar: Calendar) -> Date? {
        [export.steps.map(\.start).min(), export.sleep.map(\.interval.end).min(),
         export.workouts.map(\.start).min(), export.mindful.map(\.start).min()].compactMap { $0 }.min()
            .map(calendar.startOfDay(for:))
    }

    /// Like Memories' ledger: blocks of 4 weeks from the first week, a month when a block has 3.
    static func monthlyAchievements(_ weeks: Set<Date>, from first: Date, calendar: Calendar) -> Int {
        var perBlock: [Int: Int] = [:]
        var months = 0
        for week in weeks.sorted() {
            let offset = calendar.dateComponents([.weekOfYear], from: first, to: week).weekOfYear ?? 0
            let block = offset / DisciplineRules.standard.weeksPerBlock
            perBlock[block, default: 0] += 1
            if perBlock[block] == DisciplineRules.standard.weeksNeededPerBlock { months += 1 }
        }
        return months
    }

    // MARK: - Notes

    /// Sleep stretches more than this far apart are two sleeps.
    static let sleepGap: TimeInterval = 60 * 60
    /// A first sleep this short, followed by a gap, is an evening nap.
    static let napLength: TimeInterval = 90 * 60

    static func sleepNotes(_ day: ReplayDay, stretches: [HealthExport.Sleep], format: ReplayFormat) -> [ReplayNote] {
        guard let onset = day.snapshot.sleepOnset, !stretches.isEmpty else { return [] }
        var notes: [ReplayNote] = []
        let onTime: (Date) -> Bool = { $0 <= day.latestOnTime }

        // a short sleep in the evening, then a long gap, then the night
        var clusters: [DateInterval] = []
        for stretch in stretches.map(\.interval).sorted(by: { $0.start < $1.start }) {
            if let last = clusters.last, stretch.start.timeIntervalSince(last.end) < sleepGap {
                clusters[clusters.count - 1] = DateInterval(start: last.start, end: max(last.end, stretch.end))
            } else {
                clusters.append(stretch)
            }
        }
        if clusters.count >= 2, clusters[0].duration <= napLength {
            let nap = clusters[0], main = clusters[1]
            let changes = onTime(nap.start) != onTime(main.start)
            notes.append(ReplayNote(
                kind: .eveningNap, day: day.day, matters: changes,
                text: "\(format.time(nap.start))–\(format.time(nap.end)) 的小睡被当成入睡时间，之后 \(format.time(main.start)) 才睡下"
                    + (changes ? "；按小睡算\(onTime(nap.start) ? "准时" : "晚睡")，按正式入睡算\(onTime(main.start) ? "准时" : "晚睡")" : "；准不准时结果一样")))
        }

        // the time of falling asleep came from an app that didn't record most of the night
        let bySource = Dictionary(grouping: stretches, by: \.source)
        if bySource.count > 1, let first = stretches.min(by: { $0.interval.start < $1.interval.start }),
           let main = bySource.max(by: { SleepNights.mergedDuration($0.value.map(\.interval)) < SleepNights.mergedDuration($1.value.map(\.interval)) }),
           first.source != main.key, let mainOnset = main.value.map(\.interval.start).min(),
           mainOnset.timeIntervalSince(onset) > 10 * 60 {
            let changes = onTime(onset) != onTime(mainOnset)
            notes.append(ReplayNote(
                kind: .otherSleepSource, day: day.day, matters: changes,
                text: "入睡 \(format.time(onset)) 来自「\(first.source)」，记了大半夜的「\(main.key)」写的是 \(format.time(mainOnset))"
                    + (changes ? "；按后者算是\(onTime(mainOnset) ? "准时" : "晚睡")" : "")))
        }
        return notes
    }

    static func workoutNotes(_ day: ReplayDay, format: ReplayFormat) -> [ReplayNote] {
        var notes: [ReplayNote] = []
        let workouts = day.workouts
        for (i, a) in workouts.enumerated() {
            for b in workouts[(i + 1)...] {
                let overlap = min(a.end, b.end).timeIntervalSince(max(a.start, b.start))
                let shorter = min(a.end.timeIntervalSince(a.start), b.end.timeIntervalSince(b.start))
                guard shorter > 0, overlap >= shorter / 2 else { continue }
                let both = a.counts && b.counts
                notes.append(ReplayNote(
                    kind: .duplicateWorkout, day: day.day, matters: both,
                    text: "可能是同一次运动记了两次：「\(a.source)」\(format.workout(a))和「\(b.source)」\(format.workout(b))"
                        + (both ? "；两次都会长泡泡、记两行账（一周的运动次数和宠物经验不受影响）" : "")))
            }
        }
        for workout in workouts {
            let minutes = workout.session.minutes
            let activity = Activity(workoutName: workout.session.name)
            // counted in the whole minutes shown: from 19:30 on a workout reads "20 min" and counts
            if activity.isWorkout, minutes >= 19, workout.session.shownMinutes < 20 {
                let seconds = Int(((19.5 - minutes) * 60).rounded())
                notes.append(ReplayNote(
                    kind: .almostTwentyMinutes, day: day.day, matters: !day.countsAsWorkout,
                    text: "\(format.workout(workout))显示「19 min」，不算运动；再多 \(seconds) 秒就按 20 分钟算"
                        + (day.countsAsWorkout ? "" : "；这天因此没有运动")))
            }
            if activity == .mindfulness, minutes >= 20 {
                notes.append(ReplayNote(kind: .mindWorkout, day: day.day, matters: false,
                                        text: "\(format.workout(workout))算正念（Matcha），不算一周的运动"))
            }
        }
        return notes
    }

    static func stepNotes(_ day: ReplayDay) -> [ReplayNote] {
        guard let steps = day.snapshot.steps, abs(steps - DisciplineRules.standard.activeDaySteps) < 300 else { return [] }
        let sources = day.stepsBySource.sorted { $0.value > $1.value }
            .map { "\($0.key) \(ReplayFormat.number($0.value))" }.joined(separator: "，")
        return [ReplayNote(kind: .stepsNearGoal, day: day.day, matters: false,
                           text: "步数 \(ReplayFormat.number(steps))，离 1 万很近（各来源：\(sources)；App 取记得最多的那个）")]
    }

    static func travelNotes(_ day: Date, export: HealthExport, calendar: Calendar, format: ReplayFormat) -> [ReplayNote] {
        let key = format.dateKey(day)
        let zone = calendar.timeZone
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        let home: Set<Int> = [zone.secondsFromGMT(for: day), zone.secondsFromGMT(for: next.addingTimeInterval(-1))]
        let offsets = (export.offsetsByDate[key] ?? []).compactMap(ReplayFormat.offsetSeconds).filter { !home.contains($0) }
        let zones = (export.zonesByDate[key] ?? []).filter { name in
            guard let other = TimeZone(identifier: name) else { return false }
            return !home.contains(other.secondsFromGMT(for: day.addingTimeInterval(12 * 3600)))
        }
        guard !offsets.isEmpty || !zones.isEmpty else { return [] }
        let away = (Set(offsets).sorted().map(ReplayFormat.offsetText) + zones.sorted()).joined(separator: "，")
        return [ReplayNote(kind: .travel, day: day, matters: true,
                           text: "有数据记在 \(away)（可能在外地）；回放按 \(zone.identifier) 算，App 按手机当时的时区算")]
    }

    // MARK: - Names

    /// `HealthKitProvider.shortName`, for the export's activity type names.
    public static func shortName(_ activityType: String) -> String {
        switch activityType {
        case "Running": "Run"
        case "Walking": "Walk"
        case "Cycling": "Ride"
        case "Swimming": "Swim"
        case "Hiking": "Hike"
        case "Yoga": "Yoga"
        case "HighIntensityIntervalTraining": "HIIT"
        case "TraditionalStrengthTraining", "FunctionalStrengthTraining": "Strength"
        case "Dance", "CardioDance", "SocialDance", "DanceInspiredTraining": "Dance"
        case "Elliptical": "Elliptical"
        case "Rowing": "Row"
        case "Pilates": "Pilates"
        case "Flexibility", "Cooldown", "Barre": "Stretch"
        case "CoreTraining": "Core"
        case "MindAndBody", "TaiChi": "Mind"
        case "Climbing": "Climb"
        case "DownhillSkiing", "CrossCountrySkiing": "Ski"
        case "Snowboarding": "Snowboard"
        case "SurfingSports": "Surf"
        case "SkatingSports": "Skate"
        case "Basketball": "Basketball"
        case "Soccer": "Soccer"
        case "AmericanFootball", "AustralianFootball": "Football"
        case "Tennis": "Tennis"
        case "Badminton": "Badminton"
        case "Volleyball": "Volleyball"
        case "TableTennis": "Table tennis"
        case "Pickleball": "Pickleball"
        case "Squash": "Squash"
        case "Baseball", "Softball": "Baseball"
        case "Rugby": "Rugby"
        case "Hockey": "Hockey"
        default: "Workout"
        }
    }
}

/// Steps per day as the app counts them (`HealthKitProvider.dailySteps`): each source's samples
/// split over the days they span by time, as Apple Health's daily statistics split them, and the
/// day's count is the source that counted the most. Sources are never added together, so a WHOOP
/// day sample on top of the iPhone's count doesn't count a walk twice.
struct DailySteps {
    var counted: [Date: Double] = [:]
    var bySource: [Date: [String: Double]] = [:]

    init(_ samples: [HealthExport.Steps], from first: Date, to end: Date, calendar: Calendar) {
        let inRange = samples.filter { $0.end > first && $0.start < end || ($0.start == $0.end && $0.start >= first && $0.start < end) }
        for sample in inRange {
            Self.spread(sample, count: sample.count, calendar: calendar) { day, part in
                bySource[day, default: [:]][sample.source, default: 0] += part
            }
        }
        counted = bySource.compactMapValues { $0.values.max() }
    }

    /// Splits a sample over the days it spans, by time (as Apple Health's daily totals do).
    private static func spread(_ sample: HealthExport.Steps, count: Double, calendar: Calendar, _ add: (Date, Double) -> Void) {
        let length = sample.end.timeIntervalSince(sample.start)
        guard length > 0 else { return add(calendar.startOfDay(for: sample.start), count) }
        var start = sample.start
        while start < sample.end {
            let day = calendar.startOfDay(for: start)
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let stop = min(next, sample.end)
            add(day, count * stop.timeIntervalSince(start) / length)
            start = stop
        }
    }
}

/// Times and numbers as the replay prints them.
public struct ReplayFormat {
    private let time: DateFormatter
    private let key: DateFormatter

    public init(calendar: Calendar) {
        time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        key = DateFormatter()
        key.calendar = calendar
        key.timeZone = calendar.timeZone
        key.locale = Locale(identifier: "en_US_POSIX")
        key.dateFormat = "yyyy-MM-dd"
    }

    public func time(_ date: Date) -> String { time.string(from: date) }
    public func dateKey(_ date: Date) -> String { key.string(from: date) }

    /// "Run 32 分（07:01–07:33）".
    func workout(_ workout: ReplayWorkout) -> String {
        "\(workout.session.name) \(Self.minutes(workout.session.minutes)) 分（\(time(workout.start))–\(time(workout.end))）"
    }

    /// 32, or 19.6 when the decimals decide something.
    public static func minutes(_ value: Double) -> String {
        value >= 19 && value < 21 || value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }

    public static func number(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (i, c) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { result.append(",") }
            result.append(c)
        }
        return String(result.reversed())
    }

    /// "-0800" → -28800.
    static func offsetSeconds(_ text: String) -> Int? {
        guard text.count == 5, let sign = text.first, sign == "+" || sign == "-",
              let hours = Int(text.dropFirst().prefix(2)), let minutes = Int(text.suffix(2)) else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }

    /// -28800 → "UTC-08:00".
    static func offsetText(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let value = abs(seconds)
        return String(format: "UTC%@%02d:%02d", sign, value / 3600, value % 3600 / 60)
    }
}
