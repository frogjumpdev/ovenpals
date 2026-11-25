import Foundation
import PetCore

/// The status area under the pet: the sleep onset time with a check when it was on time (never a
/// cross), then what the wearable recorded (PRD v0.3 「只读原值」): last night's sleep for Apple
/// Watch users ("Slept 7h 30m"), Whoop's recovery as a bar without a number for Whoop users.
struct HomeStatus {
    /// "22:48" (or "10:48" on the 12-hour clock), nil without sleep data.
    let onset: String?
    /// "PM" on the 12-hour clock, shown smaller after the time.
    let onsetPeriod: String?
    /// On time, and the moon was eaten: the lime check is lit. Until then the place stays empty
    /// (no hollow ring, PRD v0.3), and the check pops in when the moon is eaten.
    let onTime: Bool
    /// Whoop user: the second row is Whoop's recovery bar (with a small WHOOP mark).
    let whoop: Bool
    /// "7h 30m" asleep last night, as the watch recorded it; nil without sleep data.
    let slept: String?
    /// Whoop's recovery today, 0...1; nil = not scored yet (the bar stays empty).
    let recovery: Double?

    /// "22:48" / "10:48 PM", for sentences and VoiceOver.
    var onsetText: String? { onset.map { time in onsetPeriod.map { "\(time) \($0)" } ?? time } }
}

/// One day in the week row on home.
struct WeekDay: Identifiable {
    let id: Date
    let letter: String
    let number: Int
    let isToday: Bool
    let isFuture: Bool
    /// A workout (or a 10k-step day) was booked: a small run icon.
    let workout: Bool
    /// An on-time night was booked: a small moon.
    let night: Bool
    /// The night was this week's leave night.
    let leave: Bool
    /// A short dash: the leave night, or a past day with nothing logged.
    var dash: Bool { leave || (!isFuture && !isToday && !workout && !night) }
}

extension AppModel {
    // MARK: - Home: status (v3.2)

    /// Every other number lives in Today; the home shows the onset time and one more row.
    var homeStatus: HomeStatus {
        let onset = today?.sleepOnset.map(Format.timeParts)
        return HomeStatus(onset: onset?.clock, onsetPeriod: onset?.period, onTime: sleptOnTime && nightBooked, whoop: isWhoopUser,
                   slept: today?.sleepHours.map { Format.duration(hours: $0) },
                   recovery: whoopRecovery.map { $0 / 100 })
    }

    // MARK: - Week

    var weekStrip: [WeekDay] {
        let tracker = discipline
        let calendar = tracker.calendar
        let todayStart = calendar.startOfDay(for: Date())
        let start = tracker.weekStart(for: todayStart)
        return (0..<7).compactMap { offset -> WeekDay? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let snapshot = weekDays.first { $0.day == day }
            let weekday = calendar.component(.weekday, from: day)
            return WeekDay(id: day,
                           letter: calendar.veryShortStandaloneWeekdaySymbols[weekday - 1],
                           number: calendar.component(.day, from: day),
                           isToday: day == todayStart,
                           isFuture: day > todayStart,
                           // booked days only: today's icons wait until its bubbles are eaten
                           workout: snapshot.map(tracker.countsAsWorkout) ?? false,
                           night: snapshot.flatMap(tracker.isOnTimeNight) ?? false,
                           leave: leaveDays.contains(day) && snapshot.flatMap(tracker.isOnTimeNight) != true)
        }
    }

    // MARK: - Today

    /// Last night was on time, as the data has it (booked or not).
    var sleptOnTime: Bool { today.flatMap(discipline.isOnTimeNight) ?? false }
    /// Today has a workout or a 10k-step day, as the data has it (booked or not).
    var workedOut: Bool { today.map(discipline.countsAsWorkout) ?? false }

    /// A workout (or a 10k day) of today is booked: the pet gets 呼呼 among its idle moves (PRD §5.3).
    var workoutBookedToday: Bool {
        let today = Calendar.current.startOfDay(for: Date())
        return creditBook.records.contains { ($0.kind == .workout || $0.kind == .steps) && $0.day == today }
    }

    /// Today's base state for the pet (PRD §5.3): "bedtime" in the hour before the target bedtime
    /// (看月亮), "rest" (放假) on a leave day or while a Whoop red day is being taken easy
    /// (Protein Bar's rule: recovery under 34%, strain 10 or less so far), otherwise "normal".
    func petMood(at date: Date = Date()) -> String {
        if sleepSchedule.isHourBeforeBed(at: date) { return "bedtime" }
        return lastNightIsLeave || restingOnRedDay ? "rest" : "normal"
    }

    /// Today is a Whoop red day and the strain is still 10 or less: the pet takes the day off too.
    var restingOnRedDay: Bool { today.map(activityTracker.isRestingOnRedDay) ?? false }

    /// Today's booked check-ins: an on-time night and a workout (or a 10k-step day).
    var checkInsToday: Int {
        ((bookedToday.flatMap(discipline.isOnTimeNight) ?? false) ? 1 : 0) + ((bookedToday.map(discipline.countsAsWorkout) ?? false) ? 1 : 0)
    }

    /// Today's workout to show: the longest one that counts (a sport, 20+ minutes), else the longest
    /// of any kind. A long Mind & Body session never hides a run that counts.
    var mainWorkout: WorkoutSession? {
        let workouts = today?.allWorkouts ?? []
        let tracker = discipline
        return workouts.filter { tracker.countsAsWorkout($0) }.max { $0.minutes < $1.minutes }
            ?? workouts.max { $0.minutes < $1.minutes }
    }

    /// The day's line after the morning wake-up (早上揭晓), and the expression that goes with it.
    /// Only good news: a level-up (collected overnight) gets 升级 (大庆祝 at Lv 10 and 20); an
    /// on-time night is said, and the proud look comes when its moon is eaten (§4.4). Otherwise
    /// nothing is said.
    func morningReveal(levelUps: [Pet3D]) -> (expression: String?, line: String)? {
        if let pet = levelUps.first {
            let level = record(pet).level
            return (BookingFeedback.levelMoment(level), "\(pet.name) is Lv \(level) now!")
        }
        if sleptOnTime { return (nil, nightBooked ? "On time last night ✓" : "On time last night!") }
        return nil
    }

    /// One short line from the pet, shown for a moment after a tap or a check-in. Besides the
    /// day's news it only follows the pet's energy (PRD v0.3: no daily mood of its own).
    func petLine(afterCheckIn: Bool = false, energy: PetEnergy? = nil) -> String {
        if isPetAsleep { return "Zzz… see you in the morning." }
        if afterCheckIn || Bool.random() {
            if let workout = mainWorkout, discipline.countsAsWorkout(workout) {
                return "\(workout.name) logged. Proud of you!"
            }
            if workedOut { return "10k steps! Nice walking." }
            if onTimeStreak >= 2 { return "On time \(onTimeStreak) nights in a row!" }
            if sleptOnTime { return "In bed on time. Proud of you!" }
        }
        switch energy ?? self.energy {
        case .lively: return ["Fully charged today!", "Good to see you!"].randomElement()!
        case .normal: return ["Good to see you!", "Hi! I missed you.", "What shall we do today?"].randomElement()!
        case .low: return ["Let's take it easy today.", "Early night together?"].randomElement()!
        }
    }

    // MARK: - Weeks with the pet

    /// 1 in the week the pet was adopted, 2 the week after, …
    var weekNumber: Int {
        let tracker = discipline
        let weeks = tracker.calendar.dateComponents([.weekOfYear], from: tracker.weekStart(for: store.adoptedOn),
                                                    to: tracker.weekStart(for: Date())).weekOfYear ?? 0
        return weeks + 1
    }

    /// Monday to Sunday of the week starting `weekStart` (nil = this week).
    func weekRange(starting weekStart: Date?) -> (start: Date, end: Date) {
        let tracker = discipline
        let start = weekStart ?? tracker.weekStart(for: Date())
        return (start, tracker.calendar.date(byAdding: .day, value: 6, to: start) ?? start)
    }
}

enum Format {
    /// 820 → "820", 8,214 → "8.2k", 12,400 → "12.4k", 64,213 → "64k".
    static func short(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        let k = Double(n) / 1_000
        if k >= 20 { return "\(Int(k.rounded()))k" }
        let text = String(format: "%.1f", k)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "k"
    }

    // MARK: Clock times: the one place that knows 24-hour from 12-hour (PRD v0.3 §6)

    /// "22:48" or "10:48 PM": sentences, notes, the ledger, the share card.
    static func time(_ date: Date) -> String {
        let parts = timeParts(date)
        return parts.period.map { "\(parts.clock) \($0)" } ?? parts.clock
    }

    /// "22:48" / ("10:48", "PM"): where the time is the big number (home's Asleep row, Today's
    /// Asleep card) the period follows in a smaller, secondary grey.
    static func timeParts(_ date: Date) -> (clock: String, period: String?) {
        guard ClockStyle.shared.twelveHour else { return (clock24.string(from: date), nil) }
        return (clock12.string(from: date), period.string(from: date))
    }

    /// The moon bubble has room for "10:48" only; its moon already says it was last night.
    static func shortTime(_ date: Date) -> String { timeParts(date).clock }

    /// A target in minutes after midnight: 1380 → "23:00" or "11:00 PM", 30 → "00:30" or "12:30 AM".
    static func time(minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        let (hour, minute) = (m / 60, m % 60)
        guard ClockStyle.shared.twelveHour else { return String(format: "%02d:%02d", hour, minute) }
        return String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour < 12 ? "AM" : "PM")
    }

    /// A target as a big number and its period: 1380 → ("23:00", nil) or ("11:00", "PM").
    static func timeParts(minutes: Int) -> (clock: String, period: String?) {
        let m = ((minutes % 1440) + 1440) % 1440
        let (hour, minute) = (m / 60, m % 60)
        guard ClockStyle.shared.twelveHour else { return (String(format: "%02d:%02d", hour, minute), nil) }
        return (String(format: "%d:%02d", hour % 12 == 0 ? 12 : hour % 12, minute), hour < 12 ? "AM" : "PM")
    }

    /// The night bar's hour marks: "00:00", or "12 AM" with the 12-hour clock.
    static func hourMark(minutes: Int) -> String {
        let hour = (((minutes % 1440) + 1440) % 1440) / 60
        guard ClockStyle.shared.twelveHour else { return String(format: "%02d:00", hour) }
        return "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static let clock24 = formatter("HH:mm")
    /// No leading zero; AM / PM in capitals after a space (design 2026-11-10).
    private static let clock12 = formatter("h:mm")
    private static let period = formatter("a")

    /// 7.7 → "7h 42m"
    static func duration(hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "Oct 27 – Nov 2"
    static func range(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
    }
}
