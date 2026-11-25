import Foundation
import HealthKit
import PetCore

/// Reads Apple Health on device. Raw samples never leave the phone; only daily summaries do.
struct HealthKitProvider: HealthDataProvider {
    let source: DataSource = .healthKit

    private let store = HKHealthStore()
    private let calendar = Calendar.current

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKCategoryType(.sleepAnalysis),
            HKCategoryType(.mindfulSession),
            HKObjectType.workoutType()
        ]
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func snapshots(from start: Date, to end: Date) async throws -> [HealthSnapshot] {
        let firstDay = calendar.startOfDay(for: start)

        async let steps = dailySteps(from: firstDay, to: end)
        async let hrv = daily(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), options: .discreteAverage, from: firstDay, to: end)
        async let rhr = daily(.restingHeartRate, unit: .count().unitDivided(by: .minute()), options: .discreteAverage, from: firstDay, to: end)
        async let sleep = dailySleep(from: firstDay, to: end)
        async let workouts = dailyWorkouts(from: firstDay, to: end)
        async let mindful = dailyMindfulMinutes(from: firstDay, to: end)
        async let energy = daily(.activeEnergyBurned, unit: .kilocalorie(), options: .cumulativeSum, from: firstDay, to: end)
        let (stepsByDay, hrvByDay, rhrByDay, sleepByDay, workoutsByDay) = try await (steps, hrv, rhr, sleep, workouts)
        // Mindfulness and active energy are optional: a refused or failing query must not hide everything else.
        let mindfulByDay = (try? await mindful) ?? [:]
        let energyByDay = (try? await energy) ?? [:]

        var result: [HealthSnapshot] = []
        var day = firstDay
        while day <= end {
            let hrvValue = hrvByDay[day]
            let dayWorkouts = workoutsByDay[day] ?? []
            let longest = dayWorkouts.max { $0.minutes < $1.minutes }
            result.append(HealthSnapshot(
                day: day,
                source: .healthKit,
                steps: stepsByDay[day].map { Int($0) },
                sleepHours: sleepByDay[day]?.hours,
                hrvMs: hrvValue,
                hrvMethod: hrvValue == nil ? nil : .sdnn,
                restingHeartRate: rhrByDay[day],
                sleepOnset: sleepByDay[day]?.onset,
                workoutMinutes: longest?.minutes,
                workoutType: longest?.name,
                workouts: dayWorkouts,
                wakeTime: sleepByDay[day]?.wake,
                mindfulMinutes: mindfulByDay[day],
                activeEnergyKcal: energyByDay[day]
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    // MARK: - Queries

    private func daily(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        options: HKStatisticsOptions,
        from start: Date,
        to end: Date
    ) async throws -> [Date: Double] {
        let predicate = HKSamplePredicate.quantitySample(
            type: HKQuantityType(id),
            predicate: HKQuery.predicateForSamples(withStart: start, end: end)
        )
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: predicate,
            options: options,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)

        var result: [Date: Double] = [:]
        for stats in collection.statistics() {
            let quantity = options.contains(.cumulativeSum) ? stats.sumQuantity() : stats.averageQuantity()
            if let quantity {
                result[calendar.startOfDay(for: stats.startDate)] = quantity.doubleValue(for: unit)
            }
        }
        return result
    }

    /// Steps per day from the one source that counted the most (the iPhone, a Watch, WHOOP…).
    /// Apple Health's own daily total merges sources in the order set in the Health app, and a
    /// source that writes one sample per whole day (WHOOP does, from one sleep to the next) is
    /// added on top of the phone's count when it sits below the phone: the same walk counted twice.
    /// The largest single source never counts a step twice, whatever that order is.
    private func dailySteps(from start: Date, to end: Date) async throws -> [Date: Double] {
        let predicate = HKSamplePredicate.quantitySample(
            type: HKQuantityType(.stepCount),
            predicate: HKQuery.predicateForSamples(withStart: start, end: end)
        )
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: predicate,
            options: [.cumulativeSum, .separateBySource],
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)

        var result: [Date: Double] = [:]
        for stats in collection.statistics() {
            let bySource = (stats.sources ?? []).compactMap { stats.sumQuantity(for: $0)?.doubleValue(for: .count()) }
            if let most = bySource.max() {
                result[calendar.startOfDay(for: stats.startDate)] = most
            }
        }
        return result
    }

    /// Hours asleep, the time of falling asleep and of waking up for the night that counts on each
    /// day. Stretches are sorted into nights with the 18:00 cut (`SleepNights`), and overlapping
    /// stretches from several sources (Watch + phone + third-party apps) are counted once.
    private func dailySleep(from start: Date, to end: Date) async throws -> [Date: SleepNights.Night] {
        // Look back 12h so a night that started the evening before `start` is included.
        let queryStart = start.addingTimeInterval(-12 * 3600)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.sleepAnalysis),
                predicate: HKQuery.predicateForSamples(withStart: queryStart, end: end)
            )],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)

        let asleep = samples.compactMap { sample -> DateInterval? in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                  HKCategoryValueSleepAnalysis.allAsleepValues.contains(value) else { return nil }
            return DateInterval(start: sample.startDate, end: sample.endDate)
        }
        return SleepNights.nights(asleep, calendar: calendar)
    }

    /// Every workout started on each day, each once (`WorkoutJoiner.workouts`): a workout an app
    /// recorded in pieces (WHOOP ends an activity when the heart rate drops between sets) is joined
    /// back into one, and the same workout written by two apps (WHOOP and the Watch, Strava…) is
    /// kept once, WHOOP's record first.
    private func dailyWorkouts(from start: Date, to end: Date) async throws -> [Date: [WorkoutSession]] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let workouts = try await descriptor.result(for: store)

        let recorded = workouts.map { workout in
            let source = workout.sourceRevision.source
            return TimedWorkout(source: source.bundleIdentifier,
                                name: Self.shortName(workout.workoutActivityType),
                                start: workout.startDate, end: workout.endDate,
                                minutes: workout.duration / 60, distanceKm: Self.distanceKm(workout),
                                isWhoop: "\(source.name) \(source.bundleIdentifier)".lowercased().contains("whoop"))
        }
        var result: [Date: [WorkoutSession]] = [:]
        for workout in WorkoutJoiner.workouts(recorded) {
            result[calendar.startOfDay(for: workout.start), default: []].append(workout.session)
        }
        return result
    }

    /// Distance covered, for workouts that have one (Today shows "5.1 km · 6:16").
    private static func distanceKm(_ workout: HKWorkout) -> Double? {
        let types: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming,
                                                 .distanceDownhillSnowSports, .distanceWheelchair]
        for type in types {
            if let meters = workout.statistics(for: HKQuantityType(type))?.sumQuantity()?.doubleValue(for: .meter()), meters > 0 {
                return meters / 1_000
            }
        }
        return nil
    }

    /// Minutes of mindfulness sessions per day (Mindfulness app, Breathe, Headspace…).
    private func dailyMindfulMinutes(from start: Date, to end: Date) async throws -> [Date: Double] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.mindfulSession),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end)
            )],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        var result: [Date: [DateInterval]] = [:]
        for sample in samples {
            result[calendar.startOfDay(for: sample.startDate), default: []]
                .append(DateInterval(start: sample.startDate, end: sample.endDate))
        }
        return result.mapValues { SleepNights.mergedDuration($0) / 60 }
    }

    private static func shortName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "Run"
        case .walking: "Walk"
        case .cycling: "Ride"
        case .swimming: "Swim"
        case .hiking: "Hike"
        case .yoga: "Yoga"
        case .highIntensityIntervalTraining: "HIIT"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength"
        case .dance, .cardioDance, .socialDance: "Dance"
        case .elliptical: "Elliptical"
        case .rowing: "Row"
        case .pilates: "Pilates"
        case .flexibility, .cooldown, .barre: "Stretch"
        case .coreTraining: "Core"
        case .mindAndBody, .taiChi: "Mind"
        case .climbing: "Climb"
        case .downhillSkiing, .crossCountrySkiing: "Ski"
        case .snowboarding: "Snowboard"
        case .surfingSports: "Surf"
        case .skatingSports: "Skate"
        case .basketball: "Basketball"
        case .soccer: "Soccer"
        case .americanFootball, .australianFootball: "Football"
        case .tennis: "Tennis"
        case .badminton: "Badminton"
        case .volleyball: "Volleyball"
        case .tableTennis: "Table tennis"
        case .pickleball: "Pickleball"
        case .squash: "Squash"
        case .baseball, .softball: "Baseball"
        case .rugby: "Rugby"
        case .hockey: "Hockey"
        default: WorkoutSession.plainName
        }
    }
}
