import Foundation
import Observation
import PetCore

/// Live = the phone's Apple Health data plus Whoop (when linked), merged per day.
/// Demo = generated data, for the simulator and previews.
enum DataMode: String, CaseIterable, Identifiable {
    case live, demo
    var id: String { rawValue }
}

enum WhoopStatus: Equatable {
    case unavailable   // this build has no backend configured
    case notConnected
    case connected
}

/// App-wide state: gathers health data from every source, books it, works out the weeks and
/// the pets' levels, and exposes the pet store to the views. It only reads what Apple Health and
/// Whoop recorded and never makes up a health score of its own (PRD v0.3 「只读原值」).
@MainActor
@Observable
final class AppModel {
    /// How many days back every refresh reads.
    static let historyDays = 30

    private(set) var today: HealthSnapshot?
    /// It is bedtime: the pet sleeps (worked out on every refresh).
    private(set) var isPetAsleep = false
    /// This calendar week's 自律周 progress.
    private(set) var week: WeekProgress?
    /// Last week's, as it finally counts (its last bubbles are collected on Monday at 04:00), so a
    /// 自律周 completed that way is still celebrated on the next open (PRD v0.3 §4.4).
    private(set) var previousWeek: WeekProgress?
    /// Any night with sleep data in the last 30 days (none: the pet says how to get the moon).
    private(set) var hasSleepData = true
    /// The days since the last day with any data from Apple Health or Whoop (0 = today has some).
    private(set) var daysWithoutData = 0
    /// This calendar week's days so far (Monday first), oldest first, as they count so far:
    /// what still waits as a food bubble is left out (点击 = 入账).
    private(set) var weekDays: [HealthSnapshot] = []
    /// Today as it counts so far (booked), next to `today` as the data has it.
    private(set) var bookedToday: HealthSnapshot?
    /// Credits waiting on home as food bubbles, oldest day first.
    private(set) var pending: [Credit] = []
    /// The days that can still be tapped, every credit, eaten or not (where the bubbles sit).
    private(set) var openCredits: [Credit] = []
    /// On-time nights in a row, up to last night.
    private(set) var onTimeStreak = 0
    /// Each activity's sessions, experience and unlock day; one entry per activity.
    private(set) var activityProgress: [Activity: ActivityProgress] = [:]
    /// Every day's activities so far (live: everything ever recorded; demo: the generated days).
    private(set) var activityLog: [Date: Set<Activity>] = [:]
    /// Starts of the finished weeks that counted as 自律周 (live: kept forever).
    private(set) var disciplinedWeekStarts: Set<Date> = []
    /// The pet's slow condition from the last 7 days (PRD v0.2 §5.5).
    private(set) var energy: PetEnergy = .normal
    private(set) var isLoading = false
    /// The last time a refresh brought days in (Settings: 「Read at 21:02」).
    private(set) var lastReadAt: Date?
    private(set) var whoopStatus: WhoopStatus
    /// HealthKit never reveals whether read access was granted, so this only records that
    /// the user went through the permission sheet.
    private(set) var appleHealthConnected: Bool
    var errorMessage: String?

    var dataMode: DataMode {
        didSet { defaults.set(dataMode.rawValue, forKey: Keys.dataMode) }
    }
    /// Saved on this phone; changing it re-judges past nights on the next refresh.
    var sleepSchedule: SleepSchedule {
        didSet { defaults.set(try? JSONEncoder().encode(sleepSchedule), forKey: Keys.sleepSchedule) }
    }

    let store: PetStore
    /// The wardrobe: points, draws and each pet's outfit (PRD v0.3 §5.4).
    let dressUp: DressUpStore
    /// Which food bubbles were eaten (PRD v0.2 §4.4). Live data's book is saved; demo data
    /// starts a fresh one every launch.
    private let liveBook: CreditBook
    private let demoBook: CreditBook
    var creditBook: CreditBook { dataMode == .live ? liveBook : demoBook }

    private let memoryDetector = MemoryDetector()
    private let healthKit = HealthKitProvider()
    private let whoop: WhoopProvider
    private let whoopConnector = WhoopConnector()
    private let backend: Backend?
    private let defaults: UserDefaults
    @ObservationIgnored private var cloudObserver: NSObjectProtocol?

    private enum Keys {
        static let dataMode = "dataMode"
        static let whoopConnected = "whoopConnected"
        static let appleHealthConnected = "appleHealthConnected"
        static let mainPetID = "mainPetID"
        static let sleepSchedule = "sleepSchedule"
    }

    /// `defaults`: the App Group's (the widget reads them later). `cloud`: the iCloud key-value
    /// backup of what Apple Health can't give back (PRD v0.3 §9); nil = none.
    init(defaults: UserDefaults = AppGroup.defaults, cloud: NSUbiquitousKeyValueStore? = NSUbiquitousKeyValueStore.default,
         backend: Backend? = Backend.shared) {
        self.defaults = defaults
        self.backend = backend
        store = PetStore(defaults: defaults, cloud: cloud)
        dressUp = DressUpStore(defaults: defaults, cloud: cloud)
        liveBook = CreditBook(defaults: defaults, cloud: cloud)
        demoBook = CreditBook(defaults: nil, history: 6)
        whoop = WhoopProvider(backend: backend)

        #if targetEnvironment(simulator)
        let fallback = DataMode.demo
        #else
        let fallback = DataMode.live
        #endif
        dataMode = defaults.string(forKey: Keys.dataMode).flatMap(DataMode.init) ?? fallback
        appleHealthConnected = defaults.bool(forKey: Keys.appleHealthConnected)
        mainPetID = defaults.string(forKey: Keys.mainPetID) ?? RosterPet.toast.id
        sleepSchedule = defaults.data(forKey: Keys.sleepSchedule)
            .flatMap { try? JSONDecoder().decode(SleepSchedule.self, from: $0) } ?? SleepSchedule()

        if backend == nil {
            whoopStatus = .unavailable
        } else {
            whoopStatus = defaults.bool(forKey: Keys.whoopConnected) ? .connected : .notConnected
        }

        // Show yesterday's pet straight away; refresh() replaces it with fresh data.
        evaluate(store.cachedSnapshots, now: Date(), recordMemories: false)
        if !store.cachedSnapshots.isEmpty { recentMode = .live }

        if let cloud {
            // the first download after an install, another iPhone, another iCloud account
            cloudObserver = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncCloud() }
            }
            cloud.synchronize()
            syncCloud()
        }
    }

    /// Takes in what iCloud has and this phone doesn't (nothing is ever taken away), then puts
    /// the whole lot back, so both sides agree. Without iCloud nothing happens.
    func syncCloud() {
        let petsChanged = store.mergeFromCloud()
        let bookChanged = liveBook.mergeFromCloud()
        dressUp.mergeFromCloud()
        store.pushToCloud()
        liveBook.pushToCloud()
        dressUp.pushToCloud()
        if petsChanged || bookChanged { reevaluate() }
    }

    // MARK: - Pets and progress (forwarded so views only talk to the model)

    var memories: [MemoryEvent] { store.memories }
    var daysTogether: Int { store.daysTogether }

    func progress(for activity: Activity) -> ActivityProgress {
        activityProgress[activity] ?? ActivityProgress(activity: activity, sessions: 0, experience: 0, unlockedOn: nil)
    }

    /// The pet on the home stage and in the middle of share cards.
    var mainPetID: String {
        didSet { defaults.set(mainPetID, forKey: Keys.mainPetID) }
    }

    /// Weeks always start on Monday (PRD v0.2), whatever the phone's region says.
    static var weekCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    var discipline: DisciplineTracker {
        DisciplineTracker(bedtime: sleepSchedule.bedtime, weekendBedtime: sleepSchedule.weekendBedtime,
                          calendar: Self.weekCalendar)
    }

    var creditRules: CreditRules { CreditRules(discipline: discipline) }

    var activityTracker: ActivityTracker {
        ActivityTracker(discipline: discipline, wakeTarget: sleepSchedule.wake, weekendWakeTarget: sleepSchedule.weekendWake)
    }

    /// Nights taken as a leave day (one a week counts as on time).
    var leaveDays: Set<Date> { store.leaveDays }

    /// Takes (or gives back) the night ending on the morning of `day` as this week's leave day.
    func setLeave(_ on: Bool, nightEnding day: Date) {
        store.setLeave(on, nightEnding: day)
        reevaluate()
    }

    /// Works everything out again from the days already fetched (a booking, a leave day).
    func reevaluate(now: Date = Date()) {
        evaluate(recentDays, now: now, recordMemories: false)
    }

    // MARK: - Sources

    func connectAppleHealth() async {
        do {
            try await healthKit.requestAuthorization()
            appleHealthConnected = true
            defaults.set(true, forKey: Keys.appleHealthConnected)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connectWhoop() async {
        guard let backend else { return }
        do {
            try await whoopConnector.connect(backend: backend)
            setWhoopConnected(true)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectWhoop() async {
        do {
            try await whoop.disconnect()
            setWhoopConnected(false)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setWhoopConnected(_ connected: Bool) {
        guard backend != nil else { return }
        whoopStatus = connected ? .connected : .notConnected
        defaults.set(connected, forKey: Keys.whoopConnected)
    }

    // MARK: - Refresh

    /// Pulls the last 30 days from every source, merges them per day and works everything out again.
    /// Called on launch and whenever the app comes to the foreground.
    func refresh(now: Date = Date()) async {
        isLoading = true
        defer { isLoading = false }

        let start = Calendar.current.date(byAdding: .day, value: -Self.historyDays, to: now)!
        var collected: [HealthSnapshot] = []
        var failures: [Error] = []

        switch dataMode {
        case .demo:
            collected = (try? await DemoHealthProvider().snapshots(from: start, to: now)) ?? []

        case .live:
            // Asks only for types added since the user first connected (e.g. workouts); no sheet otherwise.
            if appleHealthConnected { try? await healthKit.requestAuthorization() }
            let healthKit = healthKit, whoop = whoop
            // Unconnected sources are skipped rather than reported as errors.
            let phoneLinked = appleHealthConnected
            let whoopLinked = whoopStatus == .connected
            async let phone = phoneLinked ? Self.fetch(healthKit, from: start, to: now) : .success([])
            async let band = whoopLinked ? Self.fetch(whoop, from: start, to: now) : .success([])

            for result in await [phone, band] {
                switch result {
                case .success(let snapshots): collected += snapshots
                case .failure(WhoopError.notConnected): setWhoopConnected(false)
                case .failure(let error): failures.append(error)
                }
            }
        }

        let merged = SnapshotMerger.merge(collected)
        // A fetch that brings nothing (offline) keeps the days on screen, but never the other
        // mode's: after switching Demo → Real data the demo days go even if nothing came in
        // (Real data then falls back to the days saved on this phone).
        let fallback = recentMode == dataMode ? recentDays : (dataMode == .live ? store.cachedSnapshots : [])
        let days = merged.isEmpty ? fallback : merged
        recentDays = days
        recentMode = dataMode
        if dataMode == .live && !merged.isEmpty { store.cache(merged) }
        if !merged.isEmpty { lastReadAt = now }
        evaluate(days, now: now, recordMemories: !merged.isEmpty)
        // Only complain when nothing worked; a single failing source just falls back to the others.
        errorMessage = merged.isEmpty ? failures.first?.localizedDescription : nil
    }

    nonisolated private static func fetch(_ provider: any HealthDataProvider, from start: Date, to end: Date) async -> Result<[HealthSnapshot], Error> {
        do {
            return .success(try await provider.snapshots(from: start, to: end))
        } catch {
            return .failure(error)
        }
    }

    /// The days last evaluated (up to 30), so a leave day can be applied without fetching again.
    @ObservationIgnored private(set) var recentDays: [HealthSnapshot] = []
    /// Which mode `recentDays` came from (nil = none yet).
    @ObservationIgnored private var recentMode: DataMode?
    /// `recentDays` as they count: with the nights the user fixed (「手表记错了」).
    @ObservationIgnored private(set) var countedDays: [HealthSnapshot] = []

    private func evaluate(_ read: [HealthSnapshot], now: Date, recordMemories: Bool) {
        // After a flight, days saved in the old time zone count as their dates here (PetCore
        // `CalendarDay`): nothing is logged or collected twice and past weeks keep their bonus.
        let calendar = Calendar.current
        store.adopt(calendar)
        liveBook.adopt(calendar)
        let raw = read.map { day -> HealthSnapshot in
            var day = day
            day.day = CalendarDay.rekey(day.day, in: calendar)
            return day
        }
        if recentDays.isEmpty { recentDays = raw }
        // 「手表记错了」: a night the user fixed counts with the time they gave (PRD v0.3 §4.2)
        let fixes = store.sleepFixes
        var snapshots = fixes.isEmpty ? raw : raw.map { day in
            guard let onset = fixes[day.day] else { return day }
            var fixed = day
            fixed.sleepOnset = onset
            return fixed
        }
        let todayStart = Calendar.current.startOfDay(for: now)
        // No data for today yet (a Whoop-only user before last night is scored, a first launch)
        // is still today, an empty one: stopping here would leave the last day shown on screen.
        let todaySnapshot = snapshots.first(where: { $0.day == todayStart }) ?? HealthSnapshot(day: todayStart, source: .combined)
        if !snapshots.contains(where: { $0.day == todayStart }) { snapshots.append(todaySnapshot) }
        countedDays = snapshots
        let history = snapshots.filter { $0.day < todayStart }

        today = todaySnapshot
        isPetAsleep = sleepSchedule.isBedtime(at: now)
        hasSleepData = snapshots.contains { $0.sleepOnset != nil || $0.sleepHours != nil }
        let lastDataDay = snapshots.filter(\.hasAnyData).map(\.day).max()
        daysWithoutData = lastDataDay.flatMap { Calendar.current.dateComponents([.day], from: $0, to: todayStart).day }
            ?? Self.historyDays

        let tracker = discipline
        let leave = store.leaveDays

        // 点击 = 入账 (PRD v0.2 §4.4): what wasn't tapped by 04:00 the next day is collected for the
        // user; what still waits as a food bubble doesn't count yet. Everything that counts (the
        // week, the calendar, levels, the ledger) is worked out from the booked days.
        let credits = CreditRules(discipline: tracker)
        let book = creditBook
        // lines that came back from iCloud without numbers get them again (and aren't offered twice)
        if book.hasBareLines {
            book.refill(from: snapshots.flatMap { day in
                credits.credits(on: day).map { creditRecord($0, in: snapshots, auto: false, at: now) }
            })
        }
        let due = credits.due(in: snapshots, booked: book.bookedIDs, now: now, since: book.since)
        if !due.isEmpty {
            book.add(due.map { creditRecord($0, in: snapshots, auto: true, at: credits.autoBookTime(for: $0.day)) })
        }
        openCredits = credits.open(in: snapshots, now: now)
        pending = openCredits.filter { !book.bookedIDs.contains($0.id) }
        let booked = credits.booked(snapshots, pending: pending)
        bookedToday = booked.first { $0.day == todayStart }

        week = tracker.week(containing: now, snapshots: booked, leaveDays: leave)
        let weekStart = tracker.weekStart(for: now)
        previousWeek = tracker.calendar.date(byAdding: .day, value: -7, to: weekStart)
            .map { tracker.week(containing: $0, snapshots: booked, leaveDays: leave) }
        weekDays = booked.filter { $0.day >= weekStart && $0.day <= todayStart }.sorted { $0.day < $1.day }
        onTimeStreak = tracker.onTimeStreak(booked)
        // the pet's slow condition is about how the days went, booked or not
        energy = EnergyMeter.energy(snapshots: snapshots, today: now, tracker: tracker, leaveDays: leave)
        let finishedWeeks = tracker.disciplinedWeeks(in: booked, before: now, leaveDays: leave)
        let activities = activityTracker
        let log = activities.log(booked, today: todayStart)
        // only ever adds, so a booking is saved the moment it happens
        if dataMode == .live {
            store.recordDisciplinedWeeks(finishedWeeks)
            store.recordActivities(log)
        }
        // Live: everything ever recorded. Demo: only the generated days, never saved.
        let (allLog, allWeeks) = dataMode == .live
            ? (store.activityLog.merging(log) { $0.union($1) }, store.disciplinedWeeks.union(finishedWeeks))
            : (log, Set(finishedWeeks))
        activityLog = allLog
        disciplinedWeekStarts = allWeeks
        activityProgress = ActivityProgress.all(log: allLog, disciplinedWeeks: allWeeks, weekStart: tracker.weekStart(for:))

        if recordMemories {
            store.addMemories(memoryDetector.newMemories(today: todaySnapshot, history: history,
                                                         adoptedOn: store.adoptedOn, existing: store.memories))
        }
    }
}

/// The user's sleep targets, in half-hour steps, with an optional weekend pair (PRD v0.2).
/// "Weekend" = Friday and Saturday nights, i.e. the nights ending on Saturday and Sunday
/// mornings, and those two mornings for waking up.
/// The pet falls asleep on its own at bedtime; no "sleep together" tap for wearable users.
/// TODO: learn bedtime from the user's real sleep onset, and also require the phone to be idle.
struct SleepSchedule: Codable, Equatable {
    /// Minutes after midnight: 23:00 = 1380, 00:30 = 30 (before noon = after midnight).
    var bedtimeMinutes = 23 * 60
    var wakeMinutes = 7 * 60
    /// nil = the same as on weekdays.
    var weekendBedtimeMinutes: Int?
    var weekendWakeMinutes: Int?

    var bedtime: Bedtime { Bedtime(hour: bedtimeMinutes / 60, minute: bedtimeMinutes % 60) }
    var weekendBedtime: Bedtime? { weekendBedtimeMinutes.map { Bedtime(hour: $0 / 60, minute: $0 % 60) } }
    var wake: WakeTime { WakeTime(hour: wakeMinutes / 60, minute: wakeMinutes % 60) }
    var weekendWake: WakeTime? { weekendWakeMinutes.map { WakeTime(hour: $0 / 60, minute: $0 % 60) } }

    /// Targets for the night ending on the morning of `morning`.
    func targets(nightEnding morning: Date, calendar: Calendar = .current) -> (bed: Int, wake: Int) {
        let weekend = calendar.isDateInWeekend(morning)
        return ((weekend ? weekendBedtimeMinutes : nil) ?? bedtimeMinutes,
                (weekend ? weekendWakeMinutes : nil) ?? wakeMinutes)
    }

    func isBedtime(at date: Date, calendar: Calendar = .current) -> Bool {
        let now = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        // Before noon the night ends this morning, otherwise the next one.
        let today = calendar.startOfDay(for: date)
        let morning = now < 12 * 60 ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let (bed, wake) = targets(nightEnding: morning, calendar: calendar)
        return bed > wake ? (now >= bed || now < wake) : (now >= bed && now < wake)
    }

    /// The hour before the target bedtime (the pet looks at the moon, PRD §5.3); bedtime itself is not.
    func isHourBeforeBed(at date: Date, calendar: Calendar = .current) -> Bool {
        let now = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let today = calendar.startOfDay(for: date)
        let morning = now < 12 * 60 ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let bed = targets(nightEnding: morning, calendar: calendar).bed
        let untilBed = ((bed - now) % 1440 + 1440) % 1440
        return untilBed > 0 && untilBed <= 60 && !isBedtime(at: date, calendar: calendar)
    }

    /// "23:00" / "11:00 PM", "00:30" / "12:30 AM", in the clock style chosen in Settings.
    static func clock(_ minutes: Int) -> String { Format.time(minutes: minutes) }
}
