import Foundation

// The capsule machine (PRD v0.5 §5.4, 2026-11-27): coins instead of points, three coins a turn,
// three capsules out, pick one, a wish coin for every disciplined week, and the party hat on the
// first visit to Dress up instead of after the tour. (No gold capsules: the user dropped them the
// same day.)
//
// Like the old points, coins are never stored as a number. What is stored is which coins came in
// (by day and source), every turn of the machine and every wish coin used, so two iPhones that
// merge never count a coin, a turn or a week twice. The old points become coins one for one.
//
// This is the rules layer only: the app still runs the old draw until the new pages are built.

/// Where a coin came from (PRD v0.5 §5.4). A day has three places for coins: opening the app, a
/// workout (or 10k steps, or a Whoop red day rested by the rules) and an on-time night.
public enum CoinSource: String, Codable, Sendable, CaseIterable {
    /// The first time the app is opened that day.
    case opened
    /// A workout or a 10k-step day booked that day (one coin however many).
    case workout
    /// A Whoop red day rested by the rules (recovery under 34%, strain at most 10). It comes in
    /// the next day but counts for the red day, and takes the workout's place: still one coin.
    case rest
    /// Last night on time (or a leave day), booked that day.
    case night
    /// The first visit to Dress up: three before the party hat, two after it.
    case gift

    /// The day's place this coin takes: a workout and a rest share one.
    var place: String { self == .rest ? CoinSource.workout.rawValue : rawValue }

    /// What the coin says as it flies in (design v5).
    public var label: String {
        switch self {
        case .opened: "Opened today"
        case .workout: "Workout"
        case .rest: "Yesterday’s rest"
        case .night: "On-time night"
        case .gift: "Welcome gift"
        }
    }

    /// The coin a booked credit brings, if any: a workout or a 10k-step day brings the workout
    /// coin; a night only when it was on time or a leave day; Whoop's strain line brings none.
    public static func forCredit(_ kind: CreditKind, nightOnTimeOrLeave: Bool = false) -> CoinSource? {
        switch kind {
        case .workout, .steps: .workout
        case .night: nightOnTimeOrLeave ? .night : nil
        case .load: nil
        }
    }
}

/// One capsule out of the machine: the item inside (its shell shows the place).
public struct MachineCapsule: Codable, Equatable, Sendable {
    public var item: String

    public init(item: String) { self.item = item }
}

/// Capsules out of the machine, waiting for one to be picked. Its three coins are already spent,
/// so leaving the page and coming back shows the same capsules instead of new ones.
public struct CapsuleOffer: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var at: Date
    /// Three, or two or one when fewer items are left.
    public var capsules: [MachineCapsule]
    /// The first visit's turn: one capsule, the party hat.
    public var welcome: Bool
}

/// One finished turn of the machine.
public struct MachineSpin: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// When the coins went in.
    public var at: Date
    /// What it brought.
    public var item: String
    public var welcome: Bool
}

/// One wish coin used on an item.
public struct WishUse: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var item: String
    public var at: Date
}

/// One coin that came in since the last visit to Dress up.
public struct CoinArrival: Equatable, Sendable {
    public var source: CoinSource
    /// The day it counts for ("2026-11-27"); nil for the welcome gift.
    public var day: String?
    public var at: Date
}

/// What came in since the last visit to Dress up: the coins fly in from above the pet (the first
/// three one by one, the rest as one stack), a wish coin asks Pick an item / Later.
public struct CoinArrivals: Equatable, Sendable {
    /// Oldest first.
    public var coins: [CoinArrival] = []
    public var wishCoins = 0

    public var isEmpty: Bool { coins.isEmpty && wishCoins == 0 }
}

/// What a turn or a wish coin brought.
public struct DecorGain: Equatable, Sendable {
    public var item: String
    /// Places that this made complete (for the Diary).
    public var completedSlots: [DecorSlot]
    /// Everything this version knows is collected now: the big celebration.
    public var completedAll: Bool
}

extension DressUp {
    public static let spinCost = 3

    // MARK: - Coins

    /// Every coin that came in: one per day and place, the welcome gifts, and the old points.
    public var earnedCoins: Int { coinPlaces.count }

    /// Coins gone: the old draws at 5 points, every turn at 3, and the capsules waiting.
    public var coinsSpent: Int {
        var spent = Self.drawCost * draws + Self.spinCost * spins.count
        if let offer, spins[offer.id] == nil { spent += Self.spinCost }
        return spent
    }

    /// The coins there are now. No cap, no expiry (PRD v0.5 §5.4).
    public var coins: Int { max(0, earnedCoins - coinsSpent) }

    /// Coins still missing for the next turn (0 = it can turn).
    public var coinsShort: Int { max(0, Self.spinCost - coins) }

    /// Books a coin for `day` ("2026-11-27"). False when that day already has a coin from this
    /// place (a second workout, a rest after a workout, a second open).
    @discardableResult
    public mutating func earn(_ source: CoinSource, on day: String, at now: Date = Date()) -> Bool {
        guard source != .gift else { return false }
        let place = "\(day)/\(source.place)"
        guard !coinPlaces.contains(place) else { return false }
        coinLog["\(day)/\(source.rawValue)"] = now
        return true
    }

    /// The coins `day` has so far, in the day's order (opened, workout or rest, night).
    public func coinsEarned(on day: String) -> [CoinSource] {
        var sources: [CoinSource] = []
        if pointDays.contains(day) || coinLog["\(day)/opened"] != nil { sources.append(.opened) }
        if coinLog["\(day)/workout"] != nil { sources.append(.workout) }
        else if coinLog["\(day)/rest"] != nil { sources.append(.rest) }
        if coinLog["\(day)/night"] != nil { sources.append(.night) }
        return sources
    }

    /// "2026-11-27/workout" and "2026-11-27/rest" take the same place; the old point days are
    /// opened-the-app coins.
    private var coinPlaces: Set<String> {
        var places = Set(coinLog.keys.map(Self.place(ofKey:)))
        for day in pointDays { places.insert("\(day)/opened") }
        return places
    }

    private static func place(ofKey key: String) -> String {
        guard let cut = key.lastIndex(of: "/"),
              let source = CoinSource(rawValue: String(key[key.index(after: cut)...])) else { return key }
        return "\(key[..<cut])/\(source.place)"
    }

    private static func parse(_ key: String) -> (day: String?, source: CoinSource)? {
        guard let cut = key.lastIndex(of: "/") else { return nil }
        let head = String(key[..<cut])
        let tail = String(key[key.index(after: cut)...])
        if head == "gift" { return (nil, .gift) }
        guard let source = CoinSource(rawValue: tail) else { return nil }
        return (head, source)
    }

    // MARK: - Wish coins

    /// Wish coins not used yet. They keep (PRD v0.5 §5.4).
    public var wishCoins: Int { max(0, wishWeeks.count - wishes.count) }

    /// The wish coin of a disciplined week (its first day, "2026-11-23"); once per week.
    @discardableResult
    public mutating func earnWish(week: String, at now: Date = Date()) -> Bool {
        guard wishWeeks[week] == nil else { return false }
        wishWeeks[week] = now
        return true
    }

    /// Spends a wish coin on `id`, any item not owned yet: no luck involved.
    @discardableResult
    public mutating func useWish(on id: String, at now: Date = Date()) -> DecorGain? {
        guard wishCoins > 0, drawPool.contains(id) else { return nil }
        let wish = WishUse(id: UUID().uuidString, item: id, at: now)
        wishes[wish.id] = wish
        return receive(id, at: now)
    }

    // MARK: - The first visit

    /// The party hat is still to come: it now comes from the first turn in Dress up.
    public var welcomePending: Bool { !welcomeGiven && !owned.contains(Decor.welcomeGift) }

    // MARK: - Visiting Dress up

    /// Coins that came in after the last visit (all of them before the first). The old points
    /// have no time and never fly in.
    public var newCoins: [CoinArrival] {
        var byPlace: [String: CoinArrival] = [:]
        for (key, at) in coinLog where lastVisit.map({ at > $0 }) ?? true {
            guard let (day, source) = Self.parse(key) else { continue }
            let place = Self.place(ofKey: key)
            let arrival = CoinArrival(source: source, day: day, at: at)
            if let other = byPlace[place], other.at <= at { continue }
            byPlace[place] = arrival
        }
        return byPlace.values.sorted {
            $0.at != $1.at ? $0.at < $1.at : ($0.day ?? "", $0.source.rawValue) < ($1.day ?? "", $1.source.rawValue)
        }
    }

    /// Wish coins that came in after the last visit.
    public var newWishCoins: Int {
        min(wishCoins, wishWeeks.values.filter { at in lastVisit.map { at > $0 } ?? true }.count)
    }

    /// The dot on Dress up in the pet page (PRD v0.5 §5.4): new coins and enough for a turn, or a
    /// wish coin came in, or the first visit's gift is waiting. Never once everything is collected.
    public var dressUpDot: Bool {
        guard !allCollected, !drawPool.isEmpty else { return false }
        if welcomePending { return true }
        return (!newCoins.isEmpty && coins >= Self.spinCost) || newWishCoins > 0
    }

    /// Dress up opened: on the first visit three coins are given for the party hat's turn. Returns
    /// what came in since the last visit, and the dot goes out.
    @discardableResult
    public mutating func visit(at now: Date = Date()) -> CoinArrivals {
        if welcomePending, coinLog["gift/1"] == nil {
            for n in 1...3 { coinLog["gift/\(n)"] = now }
        }
        let arrivals = CoinArrivals(coins: newCoins, wishCoins: newWishCoins)
        lastVisit = max(lastVisit ?? .distantPast, now)
        return arrivals
    }

    // MARK: - The machine

    /// Items still to come: what the capsules can hold.
    public var itemsLeft: Int { drawPool.count }

    /// How many turns in a row the coins allow (Spin again): no more than there are items left.
    public var spinsLeft: Int { min(coins / Self.spinCost, itemsLeft) }

    public var canSpin: Bool { offer != nil || (coins >= Self.spinCost && !drawPool.isEmpty) }

    /// Puts three coins in: out come three capsules of items not owned yet (two or one when fewer
    /// are left). The first turn in Dress up is the party hat alone. Capsules still waiting come
    /// out again without paying twice. Nil when there aren't enough coins or nothing is left.
    @discardableResult
    public mutating func spin<R: RandomNumberGenerator>(using generator: inout R, at now: Date = Date()) -> CapsuleOffer? {
        if let offer, spins[offer.id] == nil { return offer }
        offer = nil
        guard coins >= Self.spinCost else { return nil }
        let welcome = welcomePending
        let pool = welcome ? [Decor.welcomeGift] : drawPool
        guard !pool.isEmpty else { return nil }
        let capsules = pool.shuffled(using: &generator).prefix(3).map { MachineCapsule(item: $0) }
        let made = CapsuleOffer(id: Self.id(using: &generator), at: now, capsules: capsules, welcome: welcome)
        offer = made
        return made
    }

    public mutating func spin(at now: Date = Date()) -> CapsuleOffer? {
        var generator = SystemRandomNumberGenerator()
        return spin(using: &generator, at: now)
    }

    /// Opens the capsule at `index`; the others go back into the machine. What it holds is the
    /// user's, new (a dot until worn). After the party hat's turn two more coins come.
    @discardableResult
    public mutating func pick(_ index: Int, at now: Date = Date()) -> DecorGain? {
        guard let offer else { return nil }
        guard spins[offer.id] == nil else {
            self.offer = nil  // picked on the other iPhone
            return nil
        }
        guard offer.capsules.indices.contains(index) else { return nil }
        // another iPhone may have brought it in meanwhile: still one not owned yet, of the same place
        var item = offer.capsules[index].item
        if owned.contains(item) {
            let slot = Decor.with(id: item)?.slot
            guard let stand = drawPool.first(where: { Decor.with(id: $0)?.slot == slot }) ?? drawPool.first else {
                self.offer = nil
                return nil
            }
            item = stand
        }
        spins[offer.id] = MachineSpin(id: offer.id, at: offer.at, item: item, welcome: offer.welcome)
        self.offer = nil
        if offer.welcome {
            welcomeGiven = true
            for n in 4...5 where coinLog["gift/\(n)"] == nil { coinLog["gift/\(n)"] = now }
        }
        return receive(item, at: now)
    }

    /// Adds an item to the wardrobe and notes the place, or the whole wardrobe, it completes.
    private mutating func receive(_ item: String, at now: Date) -> DecorGain {
        if !owned.contains(item) {
            owned.append(item)
            fresh.insert(item)
        }
        lookChangedAt = now
        var slots: [DecorSlot] = []
        if let slot = Decor.with(id: item)?.slot {
            let all = Decor.of(slot)
            let key = "\(slot.rawValue):\(all.count)"
            if all.allSatisfy({ owned.contains($0.id) }), completions[key] == nil {
                completions[key] = now
                slots.append(slot)
            }
        }
        var everything = false
        if allCollected {
            let key = "all:\(Decor.all.count)"
            if completions[key] == nil {
                completions[key] = now
                everything = true
            }
        }
        return DecorGain(item: item, completedSlots: slots, completedAll: everything)
    }

    private static func id<R: RandomNumberGenerator>(using generator: inout R) -> String {
        String(generator.next(), radix: 36) + String(generator.next(), radix: 36)
    }

    // MARK: - The Diary

    /// What the Diary keeps from the wardrobe (suggested in the PRD, not decided): a place
    /// complete, or everything, never each item. Oldest first; `slot` nil is everything.
    public var diaryCompletions: [(slot: DecorSlot?, count: Int, at: Date)] {
        completions.compactMap { key, at -> (slot: DecorSlot?, count: Int, at: Date)? in
            let parts = key.split(separator: ":")
            guard parts.count == 2, let count = Int(parts[1]) else { return nil }
            if parts[0] == "all" { return (nil, count, at) }
            guard let slot = DecorSlot(rawValue: String(parts[0])) else { return nil }
            return (slot, count, at)
        }
        .sorted { $0.at != $1.at ? $0.at < $1.at : ($0.slot?.rawValue ?? "~") < ($1.slot?.rawValue ?? "~") }
    }

    // MARK: - iCloud

    /// Coins, turns, wish coins and completions add up and are never counted twice; the later
    /// visit wins; capsules waiting on either iPhone stay until one is picked.
    mutating func mergeMachine(_ theirs: DressUp) {
        coinLog.merge(theirs.coinLog) { min($0, $1) }
        spins.merge(theirs.spins) { mine, _ in mine }
        wishWeeks.merge(theirs.wishWeeks) { min($0, $1) }
        wishes.merge(theirs.wishes) { mine, _ in mine }
        completions.merge(theirs.completions) { min($0, $1) }
        if let there = theirs.lastVisit { lastVisit = max(lastVisit ?? there, there) }
        if let mine = offer, spins[mine.id] == nil {
            // keep the capsules this iPhone shows
        } else if let there = theirs.offer, spins[there.id] == nil {
            offer = there
        } else {
            offer = nil
        }
    }
}
