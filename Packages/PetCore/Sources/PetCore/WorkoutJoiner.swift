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

    public init(source: String, name: String, start: Date, end: Date, minutes: Double, distanceKm: Double? = nil) {
        self.source = source
        self.name = name
        self.start = start
        self.end = end
        self.minutes = minutes
        self.distanceKm = distanceKm
    }
}

/// Joins a workout recorded in pieces back into one (decided 2026-11-25). WHOOP ends an activity
/// when the heart rate drops between sets, so a 34-minute strength session can arrive as pieces
/// of 8, 11, 7 and 8 minutes, none of which is a 20-minute workout on its own. Pieces of the same
/// kind from the same app, each starting within 10 minutes of the end of the one before, are one
/// workout: their minutes added up, and its day the day the first piece started.
/// Workouts from different apps are never joined: two apps recording the same run overlap in time
/// and would otherwise be counted twice.
public enum WorkoutJoiner {
    /// The longest break between two pieces of one workout.
    public static let maxGap: TimeInterval = 10 * 60

    public struct Joined: Sendable, Equatable {
        /// When the first piece started (the workout counts on that day).
        public var start: Date
        /// When the last piece ended.
        public var end: Date
        public var source: String
        public var session: WorkoutSession
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
                result.append(Joined(start: workout.start, end: workout.end, source: workout.source,
                                     session: WorkoutSession(name: workout.name, minutes: workout.minutes,
                                                             distanceKm: workout.distanceKm)))
            }
        }
        return result
    }
}
