import XCTest
@testable import PetCore

/// The capsule machine's rules (PRD v0.5 §5.4, 2026-11-27; design v5): coins, three capsules,
/// gold capsules and their pity, wish coins, the first visit to Dress up, iCloud merges.
final class CapsuleMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// A wardrobe past the party hat (as after the first visit), with `coins` coins. What it
    /// already `owns` came from an earlier turn: items owned with no turn behind them would be
    /// old draws, paid with 5 points each.
    private func ready(coins: Int, owning ids: [String] = []) -> DressUp {
        var d = DressUp()
        d.welcomeGiven = true
        d.owned = [Decor.welcomeGift]
        for n in 0..<coins { d.coinLog["gift/x\(n)"] = t0 }
        let earlier = ids.filter { $0 != Decor.welcomeGift }
        if !earlier.isEmpty {
            d.owned += earlier
            d.spins["earlier"] = MachineSpin(id: "earlier", at: t0.addingTimeInterval(-86_400), items: earlier,
                                      goldPossible: false, goldShown: false, welcome: false)
            for n in 0..<DressUp.spinCost { d.coinLog["gift/e\(n)"] = t0 }
        }
        return d
    }

    // MARK: - Coins

    func testThreeCoinsADayAtMost() {
        var d = DressUp()
        XCTAssertTrue(d.earn(.opened, on: "2026-11-27", at: at(0)))
        XCTAssertFalse(d.earn(.opened, on: "2026-11-27", at: at(1)), "the first open only")
        XCTAssertTrue(d.earn(.workout, on: "2026-11-27", at: at(2)))
        XCTAssertFalse(d.earn(.workout, on: "2026-11-27", at: at(3)), "two workouts are still one coin")
        XCTAssertFalse(d.earn(.rest, on: "2026-11-27", at: at(4)), "a rest coin takes the workout's place")
        XCTAssertTrue(d.earn(.night, on: "2026-11-27", at: at(5)))
        XCTAssertFalse(d.earn(.gift, on: "2026-11-27", at: at(6)), "gifts come from the first visit only")
        XCTAssertEqual(d.coins, 3)
        XCTAssertEqual(d.coinsEarned(on: "2026-11-27"), [.opened, .workout, .night])
        XCTAssertTrue(d.earn(.opened, on: "2026-11-28", at: at(1440)))
        XCTAssertEqual(d.coins, 4)
    }

    func testARedDayRestCoinComesTheNextDayForTheRedDay() {
        var d = DressUp()
        // booked on the 28th, for the 27th
        XCTAssertTrue(d.earn(.rest, on: "2026-11-27", at: at(1440 + 240)))
        XCTAssertFalse(d.earn(.workout, on: "2026-11-27", at: at(1440 + 300)), "still one coin that day")
        XCTAssertEqual(d.coinsEarned(on: "2026-11-27"), [.rest])
        XCTAssertTrue(d.earn(.workout, on: "2026-11-28", at: at(1440 + 300)))
        XCTAssertEqual(d.coins, 2)
    }

    func testCreditsThatBringCoins() {
        XCTAssertEqual(CoinSource.forCredit(.workout), .workout)
        XCTAssertEqual(CoinSource.forCredit(.steps), .workout)
        XCTAssertEqual(CoinSource.forCredit(.night, nightOnTimeOrLeave: true), .night)
        XCTAssertNil(CoinSource.forCredit(.night, nightOnTimeOrLeave: false), "a late night brings none")
        XCTAssertNil(CoinSource.forCredit(.load))
        XCTAssertEqual(CoinSource.rest.label, "Yesterday’s rest")
    }

    func testNoCapAndNoExpiry() {
        var d = DressUp()
        for day in 1...40 {
            let key = "day-\(day)"
            d.earn(.opened, on: key, at: at(Double(day) * 1440))
            d.earn(.workout, on: key, at: at(Double(day) * 1440 + 1))
            d.earn(.night, on: key, at: at(Double(day) * 1440 + 2))
        }
        XCTAssertEqual(d.coins, 120)
        XCTAssertEqual(d.spinsLeft, 40, "120 coins are 40 turns")
    }

    func testOldPointsBecomeCoinsOneForOne() {
        var d = DressUp()
        for day in 1...12 { d.collectPoint(day: "2026-11-\(10 + day)") }
        _ = d.giveWelcome()
        var generator = SplitMix(seed: 1)
        XCTAssertNotNil(d.draw(using: &generator))
        XCTAssertEqual(d.points, 7)
        XCTAssertEqual(d.coins, 7, "12 points, 5 spent on one draw")
        XCTAssertFalse(d.earn(.opened, on: "2026-11-22"), "a day with a point already has its open coin")
        XCTAssertTrue(d.earn(.workout, on: "2026-11-22"))
        XCTAssertEqual(d.coins, 8)
        XCTAssertEqual(d.draws, 1)
        XCTAssertFalse(d.welcomePending, "the tour's party hat was already given")
    }

    // MARK: - Turns

    func testATurnCostsThreeCoinsAndBringsOneOfThree() {
        var d = ready(coins: 7)
        var generator = SplitMix(seed: 2)
        let offer = d.spin(using: &generator, at: at(0))!
        XCTAssertEqual(offer.capsules.count, 3)
        XCTAssertEqual(Set(offer.capsules.map(\.item)).count, 3)
        XCTAssertTrue(offer.capsules.allSatisfy { !d.owns($0.item) })
        XCTAssertEqual(d.coins, 4, "paid when the capsules come out")
        XCTAssertEqual(d.spin(using: &generator, at: at(1)), offer, "leaving and coming back shows the same three")
        XCTAssertEqual(d.coins, 4)

        XCTAssertNil(d.pick(3, at: at(2)))
        XCTAssertEqual(d.offer, offer, "a wrong index keeps the capsules")
        let gain = d.pick(1, at: at(2))!
        XCTAssertEqual(gain.items.first, offer.capsules[1].item)
        XCTAssertTrue(d.owns(offer.capsules[1].item))
        XCTAssertTrue(d.fresh.contains(offer.capsules[1].item), "a dot until worn")
        for i in [0, 2] where !offer.capsules[1].items.contains(offer.capsules[i].item) {
            XCTAssertFalse(d.owns(offer.capsules[i].item), "the other two go back")
        }
        XCTAssertNil(d.offer)
        XCTAssertEqual(d.spins.count, 1)
        XCTAssertEqual(d.coins, 4)
        XCTAssertNil(d.pick(0), "nothing waiting")

        XCTAssertNotNil(d.spin(using: &generator, at: at(3)))
        XCTAssertEqual(d.coins, 1)
        d.pick(0, at: at(4))
        XCTAssertNil(d.spin(using: &generator, at: at(5)), "one coin is not a turn")
        XCTAssertEqual(d.coinsShort, 2)
    }

    func testTurnsNeverRepeatAndCoinsKeepWhenAllCollected() {
        var d = ready(coins: 3 * 60)
        var generator = SplitMix(seed: 3)
        var turns = 0
        while let offer = d.spin(using: &generator, at: at(Double(turns))) {
            if d.itemsLeft >= 3 { XCTAssertEqual(offer.capsules.count, 3) }
            XCTAssertEqual(offer.capsules.count, min(3, d.itemsLeft))
            if d.itemsLeft < 4 { XCTAssertFalse(offer.goldPossible, "no gold with fewer than four left") }
            let before = d.owned.count
            let gain = d.pick(Int.random(in: 0..<offer.capsules.count, using: &generator), at: at(Double(turns)))!
            XCTAssertEqual(d.owned.count, before + gain.items.count)
            turns += 1
        }
        XCTAssertTrue(d.allCollected)
        XCTAssertEqual(d.owned.count, 51)
        XCTAssertEqual(Set(d.owned).count, 51)
        XCTAssertEqual(d.coins, 3 * 60 - 3 * turns, "the rest wait for new decorations")
        XCTAssertGreaterThan(d.coins, 0)
        XCTAssertEqual(d.spinsLeft, 0)
        XCTAssertFalse(d.canSpin)
        XCTAssertTrue(d.earn(.opened, on: "2026-12-01"), "coins still come in")
    }

    func testLastItemsComeTwoOrOneCapsules() {
        var d = ready(coins: 30, owning: Decor.all.map(\.id).filter { !["crown", "rose", "lei"].contains($0) })
        var generator = SplitMix(seed: 4)
        var offer = d.spin(using: &generator)!
        XCTAssertEqual(offer.capsules.count, 3)
        XCTAssertFalse(offer.goldPossible)
        XCTAssertFalse(offer.hasGold)
        d.pick(0)
        offer = d.spin(using: &generator)!
        XCTAssertEqual(offer.capsules.count, 2)
        d.pick(1)
        offer = d.spin(using: &generator)!
        XCTAssertEqual(offer.capsules.count, 1)
        let gain = d.pick(0)!
        XCTAssertTrue(gain.completedAll)
        XCTAssertNil(d.spin(using: &generator))
    }

    // MARK: - Gold

    func testGoldAboutOneInSixNeverMoreThanSevenMissesAndTwoItems() {
        var golds = 0, turns = 0, longest = 0
        for seed in 0..<300 {
            var d = ready(coins: 3 * 12)
            var generator = SplitMix(seed: UInt64(seed) &+ 1000)
            var misses = 0
            for i in 0..<12 {
                guard let offer = d.spin(using: &generator, at: at(Double(i))) else { break }
                XCTAssertTrue(offer.goldPossible)
                turns += 1
                let gold = offer.capsules.firstIndex(where: \.isGold)
                XCTAssertLessThanOrEqual(offer.capsules.filter(\.isGold).count, 1)
                if let gold {
                    golds += 1
                    misses = 0
                    let capsule = offer.capsules[gold]
                    let bonus = capsule.bonus!
                    XCTAssertFalse(offer.capsules.map(\.item).contains(bonus), "the second item is none of the three")
                    XCTAssertFalse(d.owns(bonus))
                    XCTAssertNotEqual(Decor.with(id: bonus)?.slot, Decor.with(id: capsule.item)?.slot,
                                      "a different place while there is one")
                    let gain = d.pick(gold, at: at(Double(i)))!
                    XCTAssertEqual(gain.items, [capsule.item, bonus])
                    XCTAssertTrue(d.owns(bonus))
                } else {
                    misses += 1
                    longest = max(longest, misses)
                    d.pick(0, at: at(Double(i)))
                }
                XCTAssertEqual(d.goldMisses, misses)
            }
        }
        let rate = Double(golds) / Double(turns)
        // one in six a turn plus the pity: a gold capsule every 4.6 turns on average, 0.217 a turn
        XCTAssertEqual(rate, 0.217, accuracy: 0.025)
        XCTAssertEqual(longest, 7, "the eighth always has one")
    }

    func testPityCountsOnlyTurnsThatCouldBeGold() {
        var d = ready(coins: 0)
        func spin(_ id: String, possible: Bool, gold: Bool, minute: Double) {
            d.spins[id] = MachineSpin(id: id, at: at(minute), items: [], goldPossible: possible, goldShown: gold, welcome: false)
        }
        spin("a", possible: true, gold: true, minute: 0)
        for n in 1...6 { spin("b\(n)", possible: true, gold: false, minute: Double(n)) }
        spin("c", possible: false, gold: false, minute: 7)
        XCTAssertEqual(d.goldMisses, 6)
        spin("d", possible: true, gold: false, minute: 8)
        XCTAssertEqual(d.goldMisses, 7)
        // seven possible turns without gold: the next one has it (coins for the nine turns and one more)
        for n in 0..<(DressUp.spinCost * (d.spins.count + 1)) { d.coinLog["gift/p\(n)"] = t0 }
        var generator = SplitMix(seed: 5)
        XCTAssertTrue(d.spin(using: &generator, at: at(9))!.hasGold)
    }

    // MARK: - Wish coins

    func testAWishCoinForEveryDisciplinedWeek() {
        var d = ready(coins: 0)
        XCTAssertTrue(d.earnWish(week: "2026-11-16", at: at(0)))
        XCTAssertFalse(d.earnWish(week: "2026-11-16", at: at(1)), "once per week")
        XCTAssertTrue(d.earnWish(week: "2026-11-23", at: at(2)))
        XCTAssertEqual(d.wishCoins, 2, "they keep")
        XCTAssertNil(d.useWish(on: Decor.welcomeGift), "only what is not owned yet")
        XCTAssertNil(d.useWish(on: "nope"))
        let gain = d.useWish(on: "crown", at: at(3))!
        XCTAssertEqual(gain.items, ["crown"])
        XCTAssertTrue(d.owns("crown"))
        XCTAssertTrue(d.fresh.contains("crown"))
        XCTAssertEqual(d.wishCoins, 1)
        XCTAssertEqual(d.coins, 0, "wish coins are not coins")
        d.useWish(on: "rose")
        XCTAssertEqual(d.wishCoins, 0)
        XCTAssertNil(d.useWish(on: "lei"))
        XCTAssertEqual(d.draws, 0, "nothing was paid in points")
    }

    // MARK: - The first visit

    func testTheFirstVisitGivesThePartyHatAndFiveCoins() {
        var d = DressUp()
        d.earn(.opened, on: "2026-11-27", at: at(0))
        XCTAssertTrue(d.welcomePending)
        XCTAssertTrue(d.dressUpDot, "the gift is waiting")

        let first = d.visit(at: at(10))
        XCTAssertEqual(first.coins.map(\.source), [.opened, .gift, .gift, .gift])
        XCTAssertEqual(d.coins, 4)
        XCTAssertEqual(d.visit(at: at(11)), CoinArrivals(), "given once")
        XCTAssertEqual(d.coins, 4)

        var generator = SplitMix(seed: 6)
        let offer = d.spin(using: &generator, at: at(12))!
        XCTAssertTrue(offer.welcome)
        XCTAssertEqual(offer.capsules, [MachineCapsule(item: Decor.welcomeGift)], "only one capsule, the party hat")
        XCTAssertFalse(offer.goldPossible)
        XCTAssertEqual(d.coins, 1)
        let gain = d.pick(0, at: at(13))!
        XCTAssertEqual(gain.items, [Decor.welcomeGift])
        XCTAssertTrue(d.welcomeGiven)
        XCTAssertFalse(d.welcomePending)
        XCTAssertEqual(d.coins, 3, "two more back in Dress up")
        XCTAssertEqual(d.draws, 0)

        let back = d.visit(at: at(14))
        XCTAssertEqual(back.coins.map(\.source), [.gift, .gift])
        XCTAssertEqual(d.goldMisses, 0, "the welcome turn is not a miss")
        XCTAssertNotEqual(d.spin(using: &generator, at: at(15))?.welcome, true)
    }

    func testOldUsersWithThePartyHatGetNoWelcomeTurn() {
        var d = DressUp()
        _ = d.giveWelcome()
        d.collectPoint(day: "2026-11-26")
        let arrivals = d.visit(at: at(0))
        XCTAssertTrue(arrivals.isEmpty, "old points never fly in")
        XCTAssertEqual(d.coins, 1)
        XCTAssertNil(d.coinLog["gift/1"])
    }

    // MARK: - Visits and the dot

    func testNewCoinsSinceTheLastVisitAndTheDot() {
        var d = ready(coins: 0)
        d.visit(at: at(0))
        XCTAssertFalse(d.dressUpDot)
        d.earn(.opened, on: "2026-11-27", at: at(10))
        d.earn(.workout, on: "2026-11-27", at: at(20))
        XCTAssertEqual(d.newCoins.count, 2)
        XCTAssertFalse(d.dressUpDot, "new coins but not enough for a turn")
        d.earn(.night, on: "2026-11-27", at: at(30))
        XCTAssertTrue(d.dressUpDot)

        let arrivals = d.visit(at: at(40))
        XCTAssertEqual(arrivals.coins.map(\.source), [.opened, .workout, .night], "in the order they came")
        XCTAssertEqual(arrivals.coins.first?.day, "2026-11-27")
        XCTAssertFalse(d.dressUpDot, "a visit puts it out, turned or not")
        XCTAssertTrue(d.newCoins.isEmpty)
        XCTAssertEqual(d.coins, 3, "saving up is fine")

        d.earn(.opened, on: "2026-11-28", at: at(1500))
        XCTAssertTrue(d.dressUpDot, "a new coin and enough for a turn")
        d.visit(at: at(1501))
        XCTAssertFalse(d.dressUpDot)

        d.earnWish(week: "2026-11-23", at: at(1600))
        XCTAssertTrue(d.dressUpDot, "a wish coin came in")
        XCTAssertEqual(d.visit(at: at(1601)).wishCoins, 1)
        XCTAssertFalse(d.dressUpDot)
        XCTAssertEqual(d.wishCoins, 1, "Later keeps it")
    }

    func testNoDotOnceEverythingIsCollected() {
        var d = ready(coins: 30, owning: Decor.all.map(\.id))
        d.earn(.opened, on: "2026-11-27", at: at(10))
        d.earnWish(week: "2026-11-23", at: at(10))
        XCTAssertFalse(d.dressUpDot)
        XCTAssertEqual(d.coins, 31)
        XCTAssertEqual(d.spinsLeft, 0)
    }

    func testSpinsLeftIsTheSmallerOfCoinsAndItemsLeft() {
        XCTAssertEqual(ready(coins: 14).spinsLeft, 4)
        let d = ready(coins: 14, owning: Decor.all.map(\.id).filter { !["crown", "rose"].contains($0) })
        XCTAssertEqual(d.itemsLeft, 2)
        XCTAssertEqual(d.spinsLeft, 2)
    }

    // MARK: - The Diary

    func testCompletionsAreNotedOnceAndOnlyWhenTheyHappen() {
        // the head was complete before: not noted now
        var d = ready(coins: 0, owning: Decor.of(.head).map(\.id) + Decor.of(.eyes).map(\.id).dropLast())
        d.earnWish(week: "2026-11-23")
        let gain = d.useWish(on: Decor.of(.eyes).last!.id, at: at(5))!
        XCTAssertEqual(gain.completedSlots, [.eyes])
        XCTAssertFalse(gain.completedAll)
        XCTAssertEqual(d.completions.keys.sorted(), ["eyes:10"])
        XCTAssertEqual(d.diaryCompletions.first?.slot, .eyes)
        XCTAssertEqual(d.diaryCompletions.first?.count, 10)

        var generator = SplitMix(seed: 8)
        for n in 0..<(3 * 40) { d.coinLog["gift/z\(n)"] = t0 }
        var minute = 10.0
        while let offer = d.spin(using: &generator, at: at(minute)) {
            d.pick(offer.capsules.count - 1, at: at(minute))
            minute += 1
        }
        XCTAssertTrue(d.allCollected)
        XCTAssertEqual(Set(d.completions.keys), ["eyes:10", "mouth:10", "neck:10", "back:10", "all:51"])
        XCTAssertNil(d.diaryCompletions.last?.slot, "everything last")
    }

    // MARK: - iCloud

    func testTwoIPhonesNeverCountACoinOrATurnTwice() {
        var phone = ready(coins: 0)
        phone.earn(.opened, on: "2026-11-27", at: at(0))
        phone.earn(.workout, on: "2026-11-27", at: at(5))
        var watchSide = phone
        // both open the next day, one gets the workout, the other a rest for the same day
        phone.earn(.opened, on: "2026-11-28", at: at(1440))
        watchSide.earn(.opened, on: "2026-11-28", at: at(1442))
        phone.earn(.workout, on: "2026-11-28", at: at(1450))
        watchSide.earn(.rest, on: "2026-11-28", at: at(2900))
        phone.earn(.night, on: "2026-11-28", at: at(1460))
        watchSide.earnWish(week: "2026-11-23", at: at(1470))
        phone.earnWish(week: "2026-11-23", at: at(1471))

        var generator = SplitMix(seed: 9)
        phone.spin(using: &generator, at: at(1500))
        let got = phone.pick(0, at: at(1501))!.items

        var a = phone
        a.merge(watchSide)
        var b = watchSide
        b.merge(phone)
        XCTAssertEqual(a.earnedCoins, 5, "27th: open, workout; 28th: open, workout or rest, night")
        XCTAssertEqual(a.coins, 2)
        XCTAssertEqual(b.coins, 2)
        XCTAssertEqual(a.wishCoins, 1)
        XCTAssertEqual(b.wishCoins, 1)
        XCTAssertEqual(a.coinsEarned(on: "2026-11-28"), [.opened, .workout, .night])
        XCTAssertTrue(b.owns(got[0]))
        XCTAssertEqual(b.spins.count, 1)

        // merging again changes nothing
        var again = a
        again.merge(watchSide)
        XCTAssertEqual(again, a)
    }

    func testCapsulesWaitingSurviveAMerge() {
        var phone = ready(coins: 6)
        var other = phone
        var generator = SplitMix(seed: 10)
        let waiting = phone.spin(using: &generator, at: at(0))!
        other.merge(phone)
        XCTAssertEqual(other.offer, waiting, "the capsules show on the other iPhone too")
        XCTAssertEqual(other.coins, 3)
        other.pick(2, at: at(1))
        phone.merge(other)
        XCTAssertNil(phone.offer, "picked over there")
        XCTAssertEqual(phone.spins.count, 1)
        XCTAssertEqual(phone.coins, 3)
        XCTAssertTrue(phone.owns(waiting.capsules[2].item))
    }

    func testAPickStillBringsSomethingNewWhenTheOtherIPhoneGotIt() {
        var phone = ready(coins: 3)
        var generator = SplitMix(seed: 11)
        let offer = phone.spin(using: &generator, at: at(0))!
        let wanted = offer.capsules[0].item
        phone.owned.append(wanted)  // came in from the other iPhone meanwhile
        let gain = phone.pick(0, at: at(1))!
        XCTAssertEqual(gain.items.count, 1)
        XCTAssertNotEqual(gain.items[0], wanted)
        XCTAssertEqual(Decor.with(id: gain.items[0])?.slot, Decor.with(id: wanted)?.slot, "the same place")
        XCTAssertEqual(Set(phone.owned).count, phone.owned.count)
    }

    func testOldAndNewVersionsReadEachOther() throws {
        let old = #"{"pointDays":["2026-11-20","2026-11-21"],"owned":["party"],"welcomeGiven":true}"#
        let d = try JSONDecoder().decode(DressUp.self, from: Data(old.utf8))
        XCTAssertEqual(d.coins, 2)
        XCTAssertTrue(d.spins.isEmpty)

        var full = ready(coins: 6)
        full.earn(.night, on: "2026-11-27", at: at(1))
        full.earnWish(week: "2026-11-23", at: at(2))
        var generator = SplitMix(seed: 12)
        full.spin(using: &generator, at: at(3))
        full.pick(0, at: at(4))
        full.spin(using: &generator, at: at(5))
        full.visit(at: at(6))
        full.useWish(on: full.drawPool[0], at: at(7))
        let data = try JSONEncoder().encode(full)
        XCTAssertEqual(try JSONDecoder().decode(DressUp.self, from: data), full)
    }
}

/// SplitMix64: a small generator with good bits, so the gold rate test is about the rules.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
