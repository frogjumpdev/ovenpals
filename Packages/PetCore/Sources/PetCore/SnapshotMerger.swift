import Foundation

/// Combines per-day snapshots from several sources into one snapshot per day.
///
/// A wearable is better at sleep and recovery; steps come from Apple Health (the Whoop API sends
/// none, though a WHOOP band writes its own daily steps into Apple Health, where
/// `HealthKitProvider` keeps only the source that counted most). HRV and its method always come from the same
/// snapshot so SDNN and RMSSD are never mixed within one day.
public enum SnapshotMerger {
    /// Earlier sources win for sleep, HRV, resting heart rate and recovery.
    public static let recoveryPriority: [DataSource] = [.whoop, .healthKit, .mock]
    /// Earlier sources win for steps.
    public static let stepsPriority: [DataSource] = [.healthKit, .mock, .whoop]

    public static func merge(_ snapshots: [HealthSnapshot]) -> [HealthSnapshot] {
        Dictionary(grouping: snapshots, by: \.day)
            .map { day, sameDay in mergeDay(day: day, sameDay) }
            .sorted { $0.day < $1.day }
    }

    static func mergeDay(day: Date, _ sameDay: [HealthSnapshot]) -> HealthSnapshot {
        if sameDay.count == 1 { return sameDay[0] }

        func ordered(_ priority: [DataSource]) -> [HealthSnapshot] {
            sameDay.sorted { rank($0.source, in: priority) < rank($1.source, in: priority) }
        }
        let byRecovery = ordered(recoveryPriority)
        let bySteps = ordered(stepsPriority)
        let hrvSource = byRecovery.first { $0.hrvMs != nil }
        // Sources see different workouts, so take the longest one any of them recorded.
        let workout = sameDay.filter { $0.workoutMinutes != nil }.max { $0.workoutMinutes! < $1.workoutMinutes! }

        let sources = Set(sameDay.map(\.source))
        return HealthSnapshot(
            day: day,
            source: sources.count == 1 ? sameDay[0].source : .combined,
            steps: bySteps.lazy.compactMap(\.steps).first,
            sleepHours: byRecovery.lazy.compactMap(\.sleepHours).first,
            hrvMs: hrvSource?.hrvMs,
            hrvMethod: hrvSource?.hrvMethod,
            restingHeartRate: byRecovery.lazy.compactMap(\.restingHeartRate).first,
            vendorRecovery: byRecovery.lazy.compactMap(\.vendorRecovery).first,
            sleepOnset: byRecovery.lazy.compactMap(\.sleepOnset).first,
            workoutMinutes: workout?.workoutMinutes,
            workoutType: workout?.workoutType,
            // Each source sees its own workouts; a duplicate is harmless since a day counts once per activity.
            workouts: sameDay.contains { $0.workouts != nil } ? sameDay.flatMap(\.allWorkouts) : nil,
            wakeTime: byRecovery.lazy.compactMap(\.wakeTime).first,
            mindfulMinutes: sameDay.compactMap(\.mindfulMinutes).max(),
            strain: byRecovery.lazy.compactMap(\.strain).first,
            sleepPerformance: byRecovery.lazy.compactMap(\.sleepPerformance).first,
            // Carried all day like steps; a Whoop also writes its energy into Apple Health.
            activeEnergyKcal: bySteps.lazy.compactMap(\.activeEnergyKcal).first
        )
    }

    private static func rank(_ source: DataSource, in priority: [DataSource]) -> Int {
        priority.firstIndex(of: source) ?? priority.count
    }
}
