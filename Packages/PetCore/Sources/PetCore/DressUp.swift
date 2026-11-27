import Foundation

/// Where a decoration is worn (PRD v0.3 §5.4): five places, one decoration on each at a time.
public enum DecorSlot: String, Codable, Sendable, CaseIterable, Identifiable {
    case head, eyes, mouth, neck, back

    public var id: String { rawValue }
    /// "Head", "Eyes"…
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// One wearable decoration. The ids are the ones in the pet page's decor.js (`DECOR`); the page
/// draws them, the app only keeps which ones the user has and who wears what.
public struct Decor: Identifiable, Hashable, Sendable {
    public let id: String
    public let slot: DecorSlot
    public let name: String

    /// The wardrobe picture in the asset catalogue.
    public var icon: String { "decor_\(id)" }

    /// The 51 decorations of 2026-11-11 (round 11), slot by slot in the wardrobe's fixed order.
    public static let all: [Decor] = {
        let list: [(DecorSlot, [(String, String)])] = [
            (.head, [("santa", "Santa hat"), ("halo", "Halo"), ("rain", "Rainy day"), ("bulb", "Bright idea"),
                     ("butterfly", "Butterfly"), ("crown", "Crown"), ("horns", "Devil horns"), ("party", "Party hat"),
                     ("tophat", "Top hat"), ("chef", "Chef hat"), ("cowboy", "Cowboy hat")]),
            (.eyes, [("glasses", "Round glasses"), ("wildshades", "Wild shades"), ("starglasses", "Star glasses"),
                     ("sunglasses", "Cool shades"), ("snorkel", "Snorkel mask"), ("skigoggles", "Ski goggles"),
                     ("monocle", "Monocle"), ("glasses3d", "3D glasses"), ("nerdglasses", "Nerd glasses"),
                     ("sportglasses", "Sport shades")]),
            (.mouth, [("beard", "White beard"), ("mustache", "Mustache"), ("thermometer", "Thermometer"),
                      ("toothbrush", "Toothbrush"), ("bubblegum", "Bubble gum"), ("rose", "Rose"), ("whiskers", "Whiskers"),
                      ("fangs", "Fangs"), ("pacifier", "Pacifier"), ("lollipop", "Lollipop")]),
            (.neck, [("bowtie", "Bow tie"), ("medal", "Gold medal"), ("scarf", "Scarf"), ("bellcollar", "Bell collar"),
                     ("pearls", "Pearls"), ("necktie", "Necktie"), ("lei", "Lei"), ("locket", "Locket"),
                     ("towel", "Gym towel"), ("bandana", "Bandana")]),
            (.back, [("wings", "Angel wings"), ("tail", "Devil tail"), ("backpack", "Backpack"), ("cape", "Hero cape"),
                     ("vampcape", "Vampire cape"), ("fairywings", "Fairy wings"), ("jetpack", "Jetpack"),
                     ("surfboard", "Surfboard"), ("barbell", "Barbell"), ("pinwheel", "Pinwheel")]),
        ]
        return list.flatMap { slot, items in items.map { Decor(id: $0.0, slot: slot, name: $0.1) } }
    }()

    public static let byID: [String: Decor] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func with(id: String) -> Decor? { byID[id] }

    public static func of(_ slot: DecorSlot) -> [Decor] { all.filter { $0.slot == slot } }

    /// The first decoration, given when the tour of home ends (decided 2026-11-12: the party hat).
    public static let welcomeGift = "party"
}

/// The wardrobe (PRD v0.3 §5.4): one point the first time the app is opened each day, five points
/// a draw, every draw an item the user doesn't have yet (no duplicates, so no pity counter). The
/// wardrobe is shared by all pets; each pet keeps its own outfit, at most one item per slot.
///
/// Points are not stored as a number but worked out from the days a point was collected and the
/// draws made, so two iPhones that open on the same day count it once, a draw on one is paid on
/// both, and a reinstall that collects today's point before iCloud arrives loses nothing.
public struct DressUp: Codable, Equatable, Sendable {
    public static let drawCost = 5

    /// The local days ("2026-11-12") a point was collected.
    public var pointDays: Set<String> = []
    /// What the user has, in the order it came.
    public var owned: [String] = []
    /// Drawn but not worn yet: a lime dot on the wardrobe tile until it is worn once.
    public var fresh: Set<String> = []
    /// Pet id (the 3D pet's) → the decorations it wears, in slot order.
    public var outfits: [String: [String]] = [:]
    /// The party hat after the tour was given (new users, and once to those who were already here).
    public var welcomeGiven = false
    /// When an outfit or a new dot last changed; across iPhones the newer look wins.
    public var lookChangedAt: Date?

    // The capsule machine (PRD v0.5 §5.4, 2026-11-27): the rules are in CapsuleMachine.swift.

    /// Coins by "2026-11-27/workout" (day/source, or "gift/1"…"gift/5") → when each came in. The
    /// days in `pointDays` are opened-the-app coins too: the old points become coins 1 for 1.
    public var coinLog: [String: Date] = [:]
    /// Every turn of the capsule machine, by its id. Three coins each.
    public var spins: [String: MachineSpin] = [:]
    /// Capsules out of the machine, waiting to be picked: their three coins are already spent.
    public var offer: CapsuleOffer?
    /// Wish coins: the disciplined week (its first day, "2026-11-23") → when the coin came in.
    public var wishWeeks: [String: Date] = [:]
    /// Wish coins used, by id.
    public var wishes: [String: WishUse] = [:]
    /// The last time Dress up was opened: coins that came in after it fly in, and light the dot.
    public var lastVisit: Date?
    /// A place, or the whole wardrobe, collected: "head:11", "all:51" (how many it had then) → when.
    public var completions: [String: Date] = [:]

    public init() {}

    // MARK: - What there is

    /// Draws made with the old points, 5 each: what is owned that no turn of the capsule machine
    /// or wish coin brought (the welcome gift was free).
    public var draws: Int {
        let fromMachine = Set(spins.values.map(\.item)).union(wishes.values.map(\.item))
        return Set(owned).subtracting(fromMachine)
            .filter { !(welcomeGiven && $0 == Decor.welcomeGift) }
            .count
    }

    public var points: Int { max(0, pointDays.count - Self.drawCost * draws) }

    /// Decorations this version of the app knows that the user has.
    public var collected: Int { Set(owned).intersection(Decor.byID.keys).count }

    public var allCollected: Bool { collected >= Decor.all.count }

    public var canDraw: Bool { points >= Self.drawCost && !allCollected && !drawPool.isEmpty }

    /// Points still missing for the next draw (0 = one can be drawn).
    public var pointsShort: Int { max(0, Self.drawCost - points) }

    public func owns(_ id: String) -> Bool { owned.contains(id) }

    public func gotPoint(on day: String) -> Bool { pointDays.contains(day) }

    /// What `pet` wears, in slot order, only decorations this version knows.
    public func outfit(for pet: String) -> [String] {
        let ids = outfits[pet] ?? []
        return DecorSlot.allCases.compactMap { slot in ids.first { Decor.with(id: $0)?.slot == slot } }
    }

    public func worn(_ slot: DecorSlot, on pet: String) -> String? {
        outfit(for: pet).first { Decor.with(id: $0)?.slot == slot }
    }

    /// Everything a draw can bring: not owned yet (the party hat waits for the welcome gift).
    public var drawPool: [String] {
        Decor.all.map(\.id).filter { !owned.contains($0) && (welcomeGiven || $0 != Decor.welcomeGift) }
    }

    // MARK: - Changes

    /// Today's point; false when it was already collected, or everything is (points stop then).
    @discardableResult
    public mutating func collectPoint(day: String) -> Bool {
        guard !allCollected, !pointDays.contains(day) else { return false }
        pointDays.insert(day)
        return true
    }

    /// Spends 5 points on one item not owned yet, picked evenly; nil when there aren't enough.
    public mutating func draw<R: RandomNumberGenerator>(using generator: inout R, at now: Date = Date()) -> String? {
        guard canDraw, let id = drawPool.randomElement(using: &generator) else { return nil }
        owned.append(id)
        fresh.insert(id)
        lookChangedAt = now
        return id
    }

    public mutating func draw(at now: Date = Date()) -> String? {
        var generator = SystemRandomNumberGenerator()
        return draw(using: &generator, at: now)
    }

    /// The welcome gift, once: the party hat, free. Nil when it was already given.
    public mutating func giveWelcome(at now: Date = Date()) -> String? {
        guard !welcomeGiven else { return nil }
        welcomeGiven = true
        let id = Decor.welcomeGift
        guard !owned.contains(id) else { return nil }
        owned.append(id)
        fresh.insert(id)
        lookChangedAt = now
        return id
    }

    /// Puts `id` on `pet`; whatever it wore in that slot comes off. Its new dot goes.
    public mutating func wear(_ id: String, on pet: String, at now: Date = Date()) {
        guard let decor = Decor.with(id: id), owns(id) else { return }
        var items = outfit(for: pet).filter { Decor.with(id: $0)?.slot != decor.slot }
        items.append(id)
        outfits[pet] = DecorSlot.allCases.compactMap { slot in items.first { Decor.with(id: $0)?.slot == slot } }
        fresh.remove(id)
        lookChangedAt = now
    }

    public mutating func takeOff(_ slot: DecorSlot, from pet: String, at now: Date = Date()) {
        let items = outfit(for: pet)
        let kept = items.filter { Decor.with(id: $0)?.slot != slot }
        guard kept != items else { return }
        outfits[pet] = kept.isEmpty ? nil : kept
        lookChangedAt = now
    }

    // MARK: - iCloud

    /// Takes in another iPhone's wardrobe: days and items add up (nothing is lost), the newer
    /// outfits win, and new dots from either side stay.
    public mutating func merge(_ theirs: DressUp) {
        let ownedHere = Set(owned)
        let ownedThere = Set(theirs.owned)
        pointDays.formUnion(theirs.pointDays)
        for id in theirs.owned where !owned.contains(id) { owned.append(id) }
        welcomeGiven = welcomeGiven || theirs.welcomeGiven
        if (theirs.lookChangedAt ?? .distantPast) > (lookChangedAt ?? .distantPast) {
            // what was drawn here and isn't known there keeps its dot
            fresh = theirs.fresh.union(fresh.subtracting(ownedThere))
            outfits = theirs.outfits
            lookChangedAt = theirs.lookChangedAt
        } else {
            fresh.formUnion(theirs.fresh.subtracting(ownedHere))
        }
        mergeMachine(theirs)
    }

    // MARK: - Days

    /// "2026-11-12" for the local calendar day of `date`.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Codable (every field optional, so older and newer versions read each other)

    private enum CodingKeys: String, CodingKey {
        case pointDays, owned, fresh, outfits, welcomeGiven, lookChangedAt
        case coinLog, spins, offer, wishWeeks, wishes, lastVisit, completions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pointDays = try c.decodeIfPresent(Set<String>.self, forKey: .pointDays) ?? []
        owned = try c.decodeIfPresent([String].self, forKey: .owned) ?? []
        fresh = try c.decodeIfPresent(Set<String>.self, forKey: .fresh) ?? []
        outfits = try c.decodeIfPresent([String: [String]].self, forKey: .outfits) ?? [:]
        welcomeGiven = try c.decodeIfPresent(Bool.self, forKey: .welcomeGiven) ?? false
        lookChangedAt = try c.decodeIfPresent(Date.self, forKey: .lookChangedAt)
        coinLog = try c.decodeIfPresent([String: Date].self, forKey: .coinLog) ?? [:]
        spins = try c.decodeIfPresent([String: MachineSpin].self, forKey: .spins) ?? [:]
        offer = try c.decodeIfPresent(CapsuleOffer.self, forKey: .offer)
        wishWeeks = try c.decodeIfPresent([String: Date].self, forKey: .wishWeeks) ?? [:]
        wishes = try c.decodeIfPresent([String: WishUse].self, forKey: .wishes) ?? [:]
        lastVisit = try c.decodeIfPresent(Date.self, forKey: .lastVisit)
        completions = try c.decodeIfPresent([String: Date].self, forKey: .completions) ?? [:]
    }
}
