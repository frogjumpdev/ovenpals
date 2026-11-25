import Foundation
import Observation
import PetCore

/// The booked credits (点击 = 入账, PRD v0.2 §4.4): which food bubbles were eaten (tapped, or
/// collected for the user at 04:00), each with its ledger line. Live data's book is kept on this
/// phone and, without its numbers, in iCloud's key-value store (PRD v0.3 §9, §10.3 #19): iCloud
/// holds no health values, so a line there says "Run", never "Run 32 min". Demo data gets a
/// fresh book every launch, so the simulator always has food.
@MainActor
@Observable
final class CreditBook {
    /// Newest last.
    private(set) var records: [CreditRecord]
    /// Credits from this day on get a ledger line when collected at 04:00; earlier days are the
    /// history the first open showed, booked without one.
    private(set) var since: Date

    @ObservationIgnored private(set) var bookedIDs: Set<String>
    private let defaults: UserDefaults?
    private let cloud: NSUbiquitousKeyValueStore?
    /// Enough for a year of lines; older ones only fall off the bottom of Memories.
    private static let limit = 1_500

    private enum Keys {
        static let records = "3d.credits"
        static let since = "3d.creditsSince"
    }

    /// `defaults` nil = nothing is saved (demo data). `history` = how many days before today get
    /// ledger lines on a fresh book (demo: 6, so Memories shows this week's collected food).
    init(defaults: UserDefaults?, cloud: NSUbiquitousKeyValueStore? = nil, history: Int = 0) {
        self.defaults = defaults
        self.cloud = defaults == nil ? nil : cloud
        if let defaults, let saved = defaults.object(forKey: Keys.since) as? Date {
            since = saved
        } else {
            let today = Calendar.current.startOfDay(for: Date())
            let start = Calendar.current.date(byAdding: .day, value: -history, to: today) ?? today
            since = start
            defaults?.set(start, forKey: Keys.since)
        }
        let savedRecords = defaults?.data(forKey: Keys.records)
            .flatMap { try? JSONDecoder().decode([CreditRecord].self, from: $0) } ?? []
        records = savedRecords
        bookedIDs = Set(savedRecords.map(\.id))
    }

    func add(_ new: [CreditRecord]) {
        let fresh = new.filter { !bookedIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        records.append(contentsOf: fresh)
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
        bookedIDs = Set(records.map(\.id))
        save()
    }

    /// The pet's level went up with this booking: the ledger line says "Lv 15 → 16".
    func setLevels(_ id: String, from: Int, to: Int) {
        guard let index = records.lastIndex(where: { $0.id == id }) else { return }
        records[index].levelFrom = from
        records[index].levelTo = to
        save()
    }

    /// Test build: taps are given back, so the bubbles grow again. (Live data: a pet's
    /// experience already saved stays; the cells and the ledger lines go.)
    func unbook(where shouldGo: (CreditRecord) -> Bool) {
        records.removeAll(where: shouldGo)
        bookedIDs = Set(records.map(\.id))
        save()
    }

    /// Some lines came back from iCloud without their numbers (see `refill(from:)`).
    var hasBareLines: Bool { records.contains(where: \.isBare) }

    /// Lines that came back from iCloud without their numbers (a reinstall, a new iPhone) get them
    /// again from the days the app has just read: the detail ("Run 32 min") and the full id, so
    /// that food isn't offered a second time. `full` = a line for every credit of those days, in
    /// the days' own order. Days older than what is read keep their bare lines.
    func refill(from full: [CreditRecord]) {
        guard hasBareLines else { return }
        let byBareID = Dictionary(zip(CreditRecord.bareIDs(full.map(\.id)), full), uniquingKeysWith: { first, _ in first })
        var changed = false
        for index in records.indices where records[index].isBare {
            // steps, night and strain lines keep their id in iCloud; a workout's gets its minutes back
            guard let line = byBareID[records[index].id],
                  line.id == records[index].id || !bookedIDs.contains(line.id) else { continue }
            records[index].id = line.id
            records[index].detail = line.detail
            bookedIDs.insert(line.id)
            changed = true
        }
        if changed {
            bookedIDs = Set(records.map(\.id))
            save()
        }
    }

    /// After a time zone change (a flight), each line's day, and the day in its id, is turned back into
    /// its calendar date in the new zone (PetCore `CalendarDay`), so food already eaten isn't offered
    /// or collected again. Called before every evaluation; it saves only when something changed.
    func adopt(_ calendar: Calendar = .current) {
        let rekeyed = records.map { $0.rekeyed(in: calendar) }
        let start = CalendarDay.rekey(since, in: calendar)
        guard rekeyed != records || start != since else { return }
        if start != since {
            since = start
            defaults?.set(start, forKey: Keys.since)
        }
        if rekeyed != records {
            records = rekeyed
            bookedIDs = Set(records.map(\.id))
            save()
        }
    }

    // MARK: - iCloud: the app's own check-in records only (PRD v0.3 §10.3 #19)

    /// Takes in the lines iCloud has that this phone doesn't (after a reinstall, or from another
    /// iPhone), in booking order, and the earlier start. A line this phone has in full is never
    /// replaced by iCloud's bare one. Returns whether anything changed.
    @discardableResult
    func mergeFromCloud() -> Bool {
        guard let cloud else { return false }
        var changed = false
        // lines another iPhone saved in another time zone are read as their dates here
        let calendar = Calendar.current
        if let saved = cloud.object(forKey: Keys.since) as? Date, case let theirs = CalendarDay.rekey(saved, in: calendar),
           theirs < since {
            since = theirs
            defaults?.set(theirs, forKey: Keys.since)
            changed = true
        }
        let theirs = (cloud.data(forKey: Keys.records).flatMap { try? JSONDecoder().decode([CreditRecord].self, from: $0) } ?? [])
            .map { $0.rekeyed(in: calendar) }
        let mine = Set(CreditRecord.bareIDs(records.map(\.id)))
        let new = zip(theirs, CreditRecord.bareIDs(theirs.map(\.id))).filter { !mine.contains($0.1) }.map { $0.0 }
        if !new.isEmpty {
            records = (records + new).sorted { $0.bookedAt < $1.bookedAt }
            if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
            bookedIDs = Set(records.map(\.id))
            save(toCloud: false)
            changed = true
        }
        return changed
    }

    /// Puts the book into iCloud as this phone has it, without its numbers. This also replaces
    /// what older builds put there in full.
    func pushToCloud() {
        guard let cloud, defaults != nil else { return }
        cloud.set(since, forKey: Keys.since)
        cloud.set(try? JSONEncoder().encode(CreditRecord.bare(records)), forKey: Keys.records)
    }

    private func save(toCloud: Bool = true) {
        defaults?.set(try? JSONEncoder().encode(records), forKey: Keys.records)
        if toCloud { cloud?.set(try? JSONEncoder().encode(CreditRecord.bare(records)), forKey: Keys.records) }
    }
}
