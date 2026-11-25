import Foundation

/// One workout as Apple Health has it, with when it happened and which app wrote it.
public struct TimedWorkout: Sendable, Equatable {
    /// The app or device that wrote it (its bundle id, or its name in an export).
    public var source: String
    /// Short name ("Strength"), as `WorkoutSession.name`.
    public var name: String
    public var start: Date
    public var end: Date
    /// Time spent moving (pauses left out), as `HKWorkout.duration`.
    public var minutes: Double
    public var distanceKm: Double?
    /// Written by WHOOP (the app puts WHOOP users first: its record wins over another app's copy).
    public var isWhoop: Bool

    /// `isWhoop` nil: WHOOP when its source says so ("WHOOP" in an export, a com.whoop… bundle id).
    public init(source: String, name: String, start: Date, end: Date, minutes: Double, distanceKm: Double? = nil,
                isWhoop: Bool? = nil) {
        self.source = source
        self.name = name
        self.start = start
        self.end = end
        self.minutes = minutes
        self.distanceKm = distanceKm
        self.isWhoop = isWhoop ?? source.lowercased().contains("whoop")
    }
}

/// Joins a workout recorded in pieces back into one (decided 2026-11-25). WHOOP ends an activity
/// when the heart rate drops between sets, so a 34-minute strength session can arrive as pieces
/// of 8, 11, 7 and 8 minutes, none of which is a 20-minute workout on its own. Pieces of the same
/// kind from the same app, each starting within 10 minutes of the end of the one before, are one
/// workout: their minutes added up, and its day the day the first piece started.
/// Workouts from different apps are never added up: two apps recording the same run overlap in
/// time, and that is one workout written twice (`workouts(_:)` keeps one of them, see there).
public enum WorkoutJoiner {
    /// The longest break between two pieces of one workout.
    public static let maxGap: TimeInterval = 10 * 60

    public struct Joined: Sendable, Equatable {
        /// When the first piece started (the workout counts on that day).
        public var start: Date
        /// When the last piece ended.
        public var end: Date
        public var source: String
        public var isWhoop: Bool
        public var session: WorkoutSession
        /// The same workout as other apps recorded it (see `workouts(_:)`); also in `session.copies`.
        public var copies: [Joined] = []
    }

    /// Every workout once: pieces joined (`join`), then the same workout written by several apps
    /// kept once (decided 2026-11-25, so it grows one bubble, not two). A workout from another
    /// app is a copy when at least half of the shorter one's time overlaps; an app never copies
    /// itself, so two workouts of one app stay two. Of the copies the one shown and counted is:
    /// 1. one that counts as a workout (a sport of 20 minutes), so a copy that started late
    ///    doesn't cost the user the workout;
    /// 2. a named sport over WHOOP's or another app's plain "Workout";
    /// 3. WHOOP's, so a WHOOP user sees the minutes the WHOOP app shows;
    /// 4. the longest.
    /// It keeps a distance a copy of the same sport has when it has none (WHOOP writes none), and
    /// the others go into `session.copies`, so a bubble already eaten for one of them isn't
    /// offered again (`Credit.aliases`).
    public static func workouts(_ recorded: [TimedWorkout], rules: DisciplineRules = .standard) -> [Joined] {
        var groups: [[Joined]] = []
        for workout in join(recorded) {
            if let index = groups.firstIndex(where: { group in
                !group.contains { $0.source == workout.source } && group.contains { isCopy($0, workout) }
            }) {
                groups[index].append(workout)
            } else {
                groups.append([workout])
            }
        }
        return groups.map { group in
            guard group.count > 1 else { return group[0] }
            let ranked = group.sorted { rank($0, rules: rules) > rank($1, rules: rules) }
            var kept = ranked[0]
            let others = Array(ranked.dropFirst())
            if kept.session.distanceKm == nil {
                kept.session.distanceKm = others.first { $0.session.name == kept.session.name && $0.session.distanceKm != nil }?
                    .session.distanceKm
            }
            kept.copies = others
            kept.session.copies = others.map(\.session)
            kept.start = group.map(\.start).min() ?? kept.start
            kept.end = group.map(\.end).max() ?? kept.end
            return kept
        }.sorted { $0.start < $1.start }
    }

    /// At least half of the shorter workout's time is shared.
    static func isCopy(_ a: Joined, _ b: Joined) -> Bool {
        let overlap = min(a.end, b.end).timeIntervalSince(max(a.start, b.start))
        let shorter = min(a.end.timeIntervalSince(a.start), b.end.timeIntervalSince(b.start))
        return overlap > 0 && overlap >= shorter / 2
    }

    /// Which copy wins, compared in order (see `workouts(_:)`).
    private static func rank(_ workout: Joined, rules: DisciplineRules) -> (Int, Int, Int, Double) {
        let session = workout.session
        let counts = Double(session.shownMinutes) >= rules.minWorkoutMinutes && Activity(workoutName: session.name).isWorkout
        return (counts ? 1 : 0, session.name == WorkoutSession.plainName ? 0 : 1, workout.isWhoop ? 1 : 0, session.minutes)
    }

    /// The workouts, joined, in the order their first pieces started.
    public static func join(_ workouts: [TimedWorkout]) -> [Joined] {
        var result: [Joined] = []
        for workout in workouts.sorted(by: { $0.start < $1.start }) {
            if let index = result.lastIndex(where: { $0.source == workout.source && $0.session.name == workout.name }),
               workout.start >= result[index].end, workout.start.timeIntervalSince(result[index].end) <= maxGap {
                var joined = result[index]
                let pieces = (joined.session.pieces ?? [joined.session.minutes]) + [workout.minutes]
                let distances = [joined.session.distanceKm, workout.distanceKm].compactMap { $0 }
                joined.session = WorkoutSession(name: workout.name, minutes: pieces.reduce(0, +),
                                                distanceKm: distances.isEmpty ? nil : distances.reduce(0, +), pieces: pieces)
                joined.end = max(joined.end, workout.end)
                result[index] = joined
            } else {
                result.append(Joined(start: workout.start, end: workout.end, source: workout.source, isWhoop: workout.isWhoop,
                                     session: WorkoutSession(name: workout.name, minutes: workout.minutes,
                                                             distanceKm: workout.distanceKm)))
            }
        }
        return result
    }
}
