import Foundation
import Observation
import PetCore

/// Everything about the pet that lives on this phone: adoption day, memories, finished 自律周,
/// the activity log, leave days, and the last health snapshots (so the pet shows up instantly, offline too).
/// Backed by UserDefaults (the App Group's, see `AppGroup`). The app's own records (adoption day,
/// memories, weeks, which days counted for which activity, leave days) are also kept in iCloud's
/// key-value store, so a reinstall or a new iPhone gets them back (PRD v0.3 §9). Health values
/// never go there (§10.3 #19, App Review 5.1.3): not the snapshot cache, not the fixed sleep times.
@MainActor
@Observable
final class PetStore {
    /// The earliest adoption day this phone or iCloud knows.
    private(set) var adoptedOn: Date
    private(set) var memories: [MemoryEvent]
    private(set) var cachedSnapshots: [HealthSnapshot]
    /// Starts of every finished 自律周. Kept forever: titles and double experience only go up.
    private(set) var disciplinedWeeks: Set<Date>
    /// Which activities each day counted for. Kept forever (the snapshot cache only holds
    /// 30 days), so pets stay unlocked and levels never go down.
    private(set) var activityLog: [Date: Set<Activity>]
    /// Nights the user took as a leave day (the morning each night ended on). One a week counts
    /// as an on-time night, no reason needed.
    private(set) var leaveDays: Set<Date>
    /// 「手表记错了」 (PRD v0.3 §4.2): when the user says they really fell asleep, by the morning
    /// the night ended on. It only decides whether that night was on time; it is not a ledger line.
    /// A time of falling asleep is a health value, so it stays on this phone (no iCloud copy).
    private(set) var sleepFixes: [Date: Date]

    private let defaults: UserDefaults
    /// iCloud key-value backup; nil = none (tests).
    private let cloud: NSUbiquitousKeyValueStore?

    private enum Keys {
        static let adoptedOn = "adoptedOn"
        static let memories = "memories"
        static let snapshots = "cachedSnapshots"
        static let disciplinedWeeks = "disciplinedWeeks"
        static let activityLog = "activityLog"
        static let leaveDays = "leaveDays"
        static let sleepFixes = "sleepFixes"
    }

    /// What goes to iCloud: the app's own records that can't be read from Apple Health again.
    /// No health values (PRD v0.3 §10.3 #19): `sleepFixes` and the snapshot cache stay on the phone.
    private static let backedUp = [Keys.adoptedOn, Keys.memories, Keys.disciplinedWeeks, Keys.activityLog, Keys.leaveDays]

    init(defaults: UserDefaults = AppGroup.defaults, cloud: NSUbiquitousKeyValueStore? = nil) {
        self.defaults = defaults
        self.cloud = cloud

        if let saved = defaults.object(forKey: Keys.adoptedOn) as? Date {
            adoptedOn = saved
        } else {
            let now = Date()
            adoptedOn = now
            defaults.set(now, forKey: Keys.adoptedOn)
        }
        memories = Self.decode([MemoryEvent].self, defaults.data(forKey: Keys.memories)) ?? []
        cachedSnapshots = Self.decode([HealthSnapshot].self, defaults.data(forKey: Keys.snapshots)) ?? []
        disciplinedWeeks = Self.decode(Set<Date>.self, defaults.data(forKey: Keys.disciplinedWeeks)) ?? []
        // Read activity names one by one, so a renamed activity never wipes the whole log.
        let names = Self.decode([Date: [String]].self, defaults.data(forKey: Keys.activityLog)) ?? [:]
        activityLog = names.compactMapValues { list in
            let known = Set(list.compactMap(Activity.init(rawValue:)))
            return known.isEmpty ? nil : known
        }
        leaveDays = Self.decode(Set<Date>.self, defaults.data(forKey: Keys.leaveDays)) ?? []
        sleepFixes = Self.decode([Date: Date].self, defaults.data(forKey: Keys.sleepFixes)) ?? [:]
    }

    // MARK: - Time zone

    /// Days are saved as the start of a local day. After the phone changes time zone (a flight), each
    /// one is turned back into its calendar date in the new zone (PetCore `CalendarDay`), so a day
    /// isn't logged twice and past 自律周 keep matching their days (levels never go down). Called
    /// before every evaluation; it changes and saves something only when a day was saved elsewhere.
    func adopt(_ calendar: Calendar = .current) {
        let log = CalendarDay.rekey(activityLog, in: calendar) { $0.union($1) }
        if log != activityLog {
            activityLog = log
            save(log, Keys.activityLog)
        }
        let weeks = CalendarDay.rekey(disciplinedWeeks, in: calendar)
        if weeks != disciplinedWeeks {
            disciplinedWeeks = weeks
            save(weeks, Keys.disciplinedWeeks)
        }
        let leave = CalendarDay.rekey(leaveDays, in: calendar)
        if leave != leaveDays {
            leaveDays = leave
            save(leave, Keys.leaveDays)
        }
        let fixes = CalendarDay.rekey(sleepFixes, in: calendar) { first, _ in first }
        if fixes != sleepFixes {
            sleepFixes = fixes
            save(fixes, Keys.sleepFixes)
        }
    }

    // MARK: - Watch got it wrong

    /// A night's real time of falling asleep (nil takes the fix back).
    func setSleepFix(_ onset: Date?, nightEnding day: Date) {
        let morning = Calendar.current.startOfDay(for: day)
        var updated = sleepFixes
        updated[morning] = onset
        guard updated != sleepFixes else { return }
        sleepFixes = updated
        save(updated, Keys.sleepFixes)
    }

    // MARK: - Leave days

    /// Marks (or unmarks) the night ending on the morning of `day` as a leave day.
    func setLeave(_ on: Bool, nightEnding day: Date) {
        let morning = Calendar.current.startOfDay(for: day)
        var updated = leaveDays
        if on { updated.insert(morning) } else { updated.remove(morning) }
        guard updated != leaveDays else { return }
        leaveDays = updated
        save(updated, Keys.leaveDays)
    }

    // MARK: - Days together

    var daysTogether: Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: adoptedOn),
                                           to: calendar.startOfDay(for: Date())).day ?? 0
        return days + 1
    }

    // MARK: - Memories & cache

    func addMemories(_ new: [MemoryEvent]) {
        guard !new.isEmpty else { return }
        memories.append(contentsOf: new)
        save(memories, Keys.memories)
    }

    /// Adds weeks that counted. Weeks are never removed, even if later data looks different.
    func recordDisciplinedWeeks(_ weekStarts: [Date]) {
        let updated = disciplinedWeeks.union(weekStarts)
        guard updated != disciplinedWeeks else { return }
        disciplinedWeeks = updated
        save(updated, Keys.disciplinedWeeks)
    }

    /// Adds days' activities. Nothing is ever removed, even if later data looks different.
    func recordActivities(_ log: [Date: Set<Activity>]) {
        var updated = activityLog
        for (day, activities) in log {
            updated[day, default: []].formUnion(activities)
        }
        guard updated != activityLog else { return }
        activityLog = updated
        save(updated, Keys.activityLog)
    }

    func cache(_ snapshots: [HealthSnapshot]) {
        cachedSnapshots = snapshots
        defaults.set(try? JSONEncoder().encode(snapshots), forKey: Keys.snapshots)
    }

    // MARK: - iCloud

    /// Takes in what iCloud holds that this phone doesn't (after a reinstall, or from another
    /// iPhone): the earlier adoption day, and every week, pet day, leave night and memory either
    /// side has. Nothing is ever taken away. Returns whether anything changed here.
    @discardableResult
    func mergeFromCloud() -> Bool {
        guard let cloud else { return false }
        var changed = false
        if let theirs = cloud.object(forKey: Keys.adoptedOn) as? Date, theirs < adoptedOn {
            adoptedOn = theirs
            defaults.set(theirs, forKey: Keys.adoptedOn)
            changed = true
        }
        if let theirs = Self.decode([MemoryEvent].self, cloud.data(forKey: Keys.memories)) {
            let known = Set(memories.map(\.id))
            let new = theirs.filter { !known.contains($0.id) }
            if !new.isEmpty {
                memories = (memories + new).sorted { $0.day < $1.day }
                save(memories, Keys.memories, toCloud: false)
                changed = true
            }
        }
        // days another iPhone saved in another time zone are read as their dates here
        let calendar = Calendar.current
        if let saved = Self.decode(Set<Date>.self, cloud.data(forKey: Keys.disciplinedWeeks)),
           case let theirs = CalendarDay.rekey(saved, in: calendar), !theirs.isSubset(of: disciplinedWeeks) {
            disciplinedWeeks.formUnion(theirs)
            save(disciplinedWeeks, Keys.disciplinedWeeks, toCloud: false)
            changed = true
        }
        if let names = Self.decode([Date: [String]].self, cloud.data(forKey: Keys.activityLog)) {
            var updated = activityLog
            for (day, list) in names {
                updated[CalendarDay.rekey(day, in: calendar), default: []].formUnion(list.compactMap(Activity.init(rawValue:)))
            }
            updated = updated.filter { !$0.value.isEmpty }
            if updated != activityLog {
                activityLog = updated
                save(updated, Keys.activityLog, toCloud: false)
                changed = true
            }
        }
        if let saved = Self.decode(Set<Date>.self, cloud.data(forKey: Keys.leaveDays)),
           case let theirs = CalendarDay.rekey(saved, in: calendar), !theirs.isSubset(of: leaveDays) {
            leaveDays.formUnion(theirs)
            save(leaveDays, Keys.leaveDays, toCloud: false)
            changed = true
        }
        return changed
    }

    /// Puts everything backed up into iCloud as this phone has it (after a merge, both sides agree).
    func pushToCloud() {
        guard let cloud else { return }
        for key in Self.backedUp {
            cloud.set(defaults.object(forKey: key), forKey: key)
        }
        // older builds backed up the fixed sleep times; take them out of iCloud (the phone keeps them)
        cloud.removeObject(forKey: Keys.sleepFixes)
    }

    // MARK: - Helpers

    /// Saves `value` here and, for the backed-up keys, in iCloud too.
    private func save<T: Encodable>(_ value: T, _ key: String, toCloud: Bool = true) {
        let data = try? JSONEncoder().encode(value)
        defaults.set(data, forKey: key)
        if toCloud, Self.backedUp.contains(key) { cloud?.set(data, forKey: key) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
