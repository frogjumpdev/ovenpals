import Foundation

/// Sorts the stretches of sleep Apple Health returns into nights (PRD v0.3 §7.2).
///
/// Apple Health has no "fell asleep at" value, only stretches of sleep (core, deep, REM…) written
/// one after another, often by several sources at once. The app only decides which stretches
/// belong to which night and reads the rest as recorded:
/// - a night is every stretch that starts between 18:00 one day and 18:00 the next, and it counts
///   on the morning you wake up (a night that starts at 22:48 on Sunday is Monday's night);
/// - asleep at = the start of that night's first stretch, naps before the night's sleep left out
///   (decided 2026-11-25): stretches less than 2 hours apart are one sleep, the sleep with the
///   most time asleep is the night's main sleep, and a sleep before it with under 90 minutes
///   asleep is a nap. So a 19:10 nap before a 02:05 night doesn't make the night look on time,
///   while a night broken by waking up for an hour still starts when the user first fell asleep;
/// - hours = the stretches added up, overlaps counted once;
/// - woke at = the end of the last stretch that started before noon, so an afternoon nap does
///   not move it.
/// With Whoop connected the night's times come from Whoop's own main sleep instead (its naps are
/// left out on the server), so the two ways agree.
public enum SleepNights {
    /// Sleep that starts at or after this hour belongs to the next morning's night.
    public static let cutHour = 18
    /// Stretches starting at or after this hour on the wake-up day are naps for the wake time.
    public static let napFromHour = 12
    /// Stretches at least this far apart are two sleeps.
    public static let sleepGap: TimeInterval = 2 * 3600
    /// A sleep before the night's main sleep with less time asleep than this is a nap.
    public static let napLimit: TimeInterval = 90 * 60

    public struct Night: Equatable, Sendable {
        public var hours: Double
        public var onset: Date
        public var wake: Date
        /// Naps before the night's sleep, left out of `onset` (their time still counts in `hours`).
        public var naps: [DateInterval]

        public init(hours: Double, onset: Date, wake: Date, naps: [DateInterval] = []) {
            self.hours = hours
            self.onset = onset
            self.wake = wake
            self.naps = naps
        }
    }

    /// The day (its start) whose morning a stretch of sleep starting at `start` counts on.
    public static func wakeDay(forSleepStartingAt start: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: start)
        guard calendar.component(.hour, from: start) >= cutHour else { return day }
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day
    }

    /// Nights keyed by the day they count on.
    public static func nights(_ stretches: [DateInterval], calendar: Calendar) -> [Date: Night] {
        let byDay = Dictionary(grouping: stretches) { wakeDay(forSleepStartingAt: $0.start, calendar: calendar) }
        return byDay.reduce(into: [:]) { result, entry in
            let (day, night) = entry
            let sleeps = Self.sleeps(night)
            let asleep = sleeps.map(mergedDuration)
            guard let main = asleep.indices.max(by: { asleep[$0] < asleep[$1] }),
                  let first = asleep.indices.first(where: { $0 == main || asleep[$0] >= napLimit }),
                  let onset = sleeps[first].map(\.start).min() else { return }
            let naps = sleeps[..<first].map { DateInterval(start: $0.map(\.start).min()!, end: $0.map(\.end).max()!) }
            let noon = calendar.date(byAdding: .hour, value: napFromHour, to: day) ?? day
            let beforeNoon = night.filter { $0.start < noon }
            let wake = (beforeNoon.isEmpty ? night : beforeNoon).map(\.end).max() ?? onset
            result[day] = Night(hours: mergedDuration(night) / 3600, onset: onset, wake: wake, naps: naps)
        }
    }

    /// The stretches as separate sleeps, in order: a stretch less than `sleepGap` after the end of
    /// the one before is the same sleep.
    public static func sleeps(_ stretches: [DateInterval]) -> [[DateInterval]] {
        var result: [[DateInterval]] = []
        var end = Date.distantPast
        for stretch in stretches.sorted(by: { $0.start < $1.start }) {
            if !result.isEmpty, stretch.start.timeIntervalSince(end) < sleepGap {
                result[result.count - 1].append(stretch)
            } else {
                result.append([stretch])
            }
            end = max(end, stretch.end)
        }
        return result
    }

    /// Total time covered by `intervals`, overlaps counted once.
    public static func mergedDuration(_ intervals: [DateInterval]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let c = current, interval.start <= c.end {
                current = DateInterval(start: c.start, end: max(c.end, interval.end))
            } else {
                if let c = current { total += c.duration }
                current = interval
            }
        }
        if let c = current { total += c.duration }
        return total
    }
}
