import SwiftUI
import PetCore

/// Home (v3.4): pet name, the week (Monday first, run / moon icons), the living pet on its flat
/// oval with today's food bubbles around it (B 轻泡), the status area (Asleep, Slept or Whoop's
/// recovery) and this
/// week's cells, and the dock (Pets · Today · Memories, with their names).
/// A tap on a bubble books it (点击 = 入账, PRD v0.2 §4.4); rows and days explain themselves with
/// a tap; the first time, the pet shows the user around.
struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(HomeState.self) private var home
    @Environment(Router.self) private var router
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stage: PetStage { PetStage.shared }
    @State private var line: String?
    /// The line's small icon (a moon, a workout) and whether the pet says it in its sleep.
    @State private var lineIcon: BubbleIcon?
    @State private var lineAsleep = false
    /// Where the line is on the stage: the food bubbles under it step back while it is said.
    @State private var lineFrame: CGRect = .null
    @State private var lineTask: Task<Void, Never>?
    /// The pet switcher or the 「…」 card, popped up under its button.
    @State private var pop: HomePop?
    @State private var momentsTask: Task<Void, Never>?
    @State private var bites = 0
    @State private var onScreen = false
    /// The 自律周 share card, offered the moment the week counts.
    @State private var weekCard = false
    /// The week on that card: this one, or last week when it only counted on Monday at 04:00.
    @State private var cardWeek: WeekProgress?
    /// During the wake-up the bubbles wait, then grow.
    @State private var foodHidden = false
    /// The pet asks whether to yawn 30 minutes before bed (once ever, after the first on-time moon).
    @State private var askingBedtime = false
    /// Now, every half minute: the hour before bed brings 看月亮 without a refresh.
    @State private var clock = Date()
    /// The last bite: 眼巴巴 waits a while after a meal.
    @State private var lastBite = Date.distantPast
    /// 等一下 is on while a refresh takes long (the watch's data on its way).
    @State private var waitingForData = false
    @State private var dataTask: Task<Void, Never>?

    // feeding
    /// Bubbles popping right now (the model already booked them).
    @State private var eating: [String: FoodBubble] = [:]
    @State private var feeds: [Feed] = []
    @State private var inFlight = 0
    /// What the rows showed before a booking, kept until its dot lands.
    @State private var held: Shown?
    @State private var workoutPulses: [Int: Int] = [:]
    @State private var nightPulses: [Int: Int] = [:]
    @State private var memoriesPulse = 0
    /// Named places on screen (cells, rows, dock…), in home coordinates.
    @State private var spots: [String: CGRect] = [:]

    // explaining
    @State private var note: Note?
    @State private var selectedDay: Date?
    @State private var tour: TourStep?
    @State private var tourTask: Task<Void, Never>?
    /// The welcome gift after the tour (PRD v0.3 §5.4: the party hat, free).
    @State private var gift: GiftReveal?
    @State private var giftTask: Task<Void, Never>?

    private enum Note: Hashable { case asleep, second, week }

    /// The status area, this week's cells and the calendar row, as shown.
    private struct Shown {
        var status: HomeStatus
        var cells: WeekCells
        var days: [WeekDay]
    }

    var body: some View {
        let pet = model.mainPet3D
        let shown = held ?? Shown(status: model.homeStatus, cells: model.weekCells, days: model.weekStrip)
        VStack(spacing: 0) {
            topBar(pet)
                .padding(.horizontal, 24)
                .padding(.top, 6)
            WeekStrip(days: shown.days, selected: $selectedDay) { day in
                tour == nil ? model.dayNote(day) : nil
            }
            .padding(.horizontal, Metrics.gutter - 4)
            .padding(.top, 10)
            GeometryReader { geo in
                scene(pet: pet, size: geo.size)
            }
            .background(HomeSpot.mark("scene"))
            statusArea(shown)
                .padding(.horizontal, 44)
                .background(HomeSpot.mark("status"))
            dock
                .background(HomeSpot.mark("dock"))   // the buttons only, without the padding
                .padding(.top, 26)
                .padding(.bottom, 2)
        }
        // the layout is tight: text grows with the system size, but at most two steps (PRD v0.3 §8.2)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .coordinateSpace(name: HomeSpot.space)
        .onPreferenceChange(HomeSpot.Key.self) { spots = $0 }
        .overlay { FeedLayer(feeds: feeds) }
        .overlay(alignment: .topLeading) { popOverlay }
        .overlay { tourOverlay }
        .overlay {
            if let gift {
                GiftSheet(gift: gift, collected: model.dressUp.collected, pointsLeft: model.dressUp.points,
                          wear: { putOn(gift) }, later: { withAnimation(.easeOut(duration: 0.25)) { self.gift = nil } })
            }
        }
        .animation(.easeOut(duration: 0.25), value: gift)
        .background(Jade.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.impact(weight: .light), trigger: bites) { _, _ in FeelSettings.haptics }
        .sheet(isPresented: $weekCard) { WeekAchievedSheet(week: cardWeek) }
        .onAppear {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "hp3dRegrow") { model.regrowFood() }
            if UserDefaults.standard.bool(forKey: "hp3dWeekCard") { cardWeek = nil; weekCard = true }
            #endif
            onScreen = true
            greet()
        }
        .onDisappear {
            onScreen = false
            pop = nil
            if tour == .tryIt { tour = nil }
            waitForData(false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { greet() }
        }
        .onChange(of: stage.isReady) { greet() }
        .onChange(of: model.today) { greet() }
        .onChange(of: home.onboarded) { greet() }
        // the tour is over (or skipped): the welcome gift comes next
        .onChange(of: tour) { _, step in if step == nil { greet() } }
        .onChange(of: stage.tapCount) {
            guard onScreen else { return }
            let awake = stage.lastTapMode == "awake"
            say(awake ? model.petLine(energy: energy) : "Mm… so sleepy.", asleep: !awake)
        }
        // 拜托: the pet's one question about notifications
        .onChange(of: askingBedtime) { _, asking in if asking { stage.react("please") } }
        .onChange(of: model.isLoading) { _, loading in waitForData(loading) }
        .task(id: onScreen) { await keepTime() }
        .task(id: onScreen) { await begNowAndThen() }
        #if DEBUG
        .task(id: stage.isReady) { await debugLaunch() }
        #endif
    }

    /// The pet's slow condition: from the data, or the test build's override.
    private var energy: PetEnergy { home.energyOverride ?? model.energy }

    // MARK: - Top: name (switch the main pet) and more

    private func topBar(_ pet: Pet3D) -> some View {
        HStack {
            // the pet switcher: a small card of the pets met so far (bubble-settings-v1)
            Button { togglePop(.pets) } label: {
                HStack(spacing: 6) {
                    Text(pet.name)
                        .scaledFont(28, .bold)
                        .foregroundStyle(Jade.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Jade.ink2)
                        .rotationEffect(.degrees(pop == .pets ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(HomeSpot.mark("name"))
            .accessibilityLabel("Main pet: \(pet.name)")
            .accessibilityHint("Shows your pets to pick from")
            Spacer()
            // No feature, no entry (PRD v0.2): Settings, and the tour again (v3.4).
            Button { togglePop(.more) } label: { RoundIcon(systemName: "ellipsis") }
                .buttonStyle(.plain)
                .opacity(tour == nil || tour == .tryIt ? 1 : 0)
                .background(HomeSpot.mark("more"))
                .accessibilityLabel("More")
        }
    }

    private enum HomePop { case pets, more }

    private func togglePop(_ which: HomePop) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { pop = pop == which ? nil : which }
    }

    private func closePop() {
        withAnimation(.easeOut(duration: 0.18)) { pop = nil }
    }

    /// The two pop-up cards: under the pet's name (the pets met so far) and under 「…」.
    private var popOverlay: some View {
        let top = (spots["name"]?.maxY ?? 52) + 6
        return ZStack(alignment: .topLeading) {
            if pop != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { closePop() }
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                Color.clear.frame(height: top)
                if pop == .pets {
                    PetSwitcher(pets: model.unlockedPets, current: model.mainPet3D.id,
                                level: { model.record($0).level }, outfit: { model.dressUp.outfit(for: $0.id) }) { pet in
                        closePop()
                        guard pet.id != model.mainPet3D.id else { return }
                        model.mainPetID = pet.rosterID
                        // 点点头: the new main pet nods once it is on the stage
                        stage.react("nod", pet: pet.id)
                    }
                    .popIn(from: .top)
                }
            }
            .padding(.horizontal, 12)
            VStack(alignment: .trailing, spacing: 0) {
                Color.clear.frame(width: 1, height: top)
                if pop == .more {
                    VStack(spacing: 0) {
                        PopMenuRow(icon: "gearshape", title: "Settings", chevron: true) {
                            closePop()
                            router.path.append(.settings)
                        }
                        PopDivider()
                        PopMenuRow(icon: "hand.tap", title: "Show me around") {
                            closePop()
                            startTour()
                        }
                    }
                    .frame(width: 236)
                    .popCard()
                    .popIn(from: .topTrailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 18)
        }
    }

    // MARK: - The stage: pet, flat oval, food bubbles, a short line

    @ViewBuilder
    private func scene(pet: Pet3D, size: CGSize) -> some View {
        if size.width > 1, size.height > 1 {
            let layout = HomeLayout(size: size, anchors: stage.anchors(for: pet.id) ?? .standard, outfitTop: stage.outfitTop(for: pet.id))
            // the bedtime question is wide and sits above the pet (and its hat): the food waits until it is answered
            let waiting = foodHidden || askingBedtime ? [] : model.foodBubbles.filter { eating[$0.id] == nil }
            let bubbles = waiting + eating.values.sorted { $0.slot < $1.slot }
            ZStack(alignment: .topLeading) {
                LivePet(config: stageConfig(pet: pet, box: layout.box))
                    .frame(width: size.width, height: size.height)
                    .accessibilityLabel("\(pet.name). Tap, tap again, or hold.")

                // B 轻泡串: the beads end just above the pet (or its hat)
                if askingBedtime {
                    PetBubble(text: "Want me to yawn at you 30 minutes before bed?",
                              question: .init(no: "Not now", yes: "Sure",
                                              onNo: { answerBedtime(false) }, onYes: { answerBedtime(true) }))
                        .frame(maxWidth: min(300, size.width * 0.8))
                        .frame(width: size.width, height: max(130, layout.headTop - 2), alignment: .bottom)
                        .transition(.asymmetric(insertion: .identity, removal: .scale(scale: 0.35, anchor: .bottom).combined(with: .opacity)))
                        .zIndex(1)
                } else if let line {
                    PetBubble(text: line, icon: lineIcon, asleep: lineAsleep)
                        .id(line)
                        .frame(maxWidth: size.width * 0.7)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: LineFrameKey.self, value: g.frame(in: .named(Self.stageSpace)))
                        })
                        .frame(width: size.width, height: max(90, layout.headTop - 2), alignment: .bottom)
                        .allowsHitTesting(false)
                        .transition(.asymmetric(insertion: .identity, removal: .scale(scale: 0.35, anchor: .bottom).combined(with: .opacity)))
                        // over the food bubbles it covers (they step back meanwhile)
                        .zIndex(1)
                }

                ForEach(Array(bubbles.enumerated()), id: \.element.id) { index, bubble in
                    // the bubbles next to the pet's line step back while it is said
                    let hushed = line != nil && eating[bubble.id] == nil
                        && lineFrame.insetBy(dx: -35, dy: -35).contains(layout.slot(bubble.slot))
                    Button { harvest(bubble, layout: layout) } label: {
                        FoodBubbleView(bubble: bubble, phase: index, eaten: eating[bubble.id] != nil)
                    }
                    .buttonStyle(BubblePress())
                    .opacity(hushed ? 0.15 : 1)
                    .scaleEffect(hushed ? 0.9 : 1)
                    .animation(.easeOut(duration: 0.2), value: hushed)
                    .disabled(eating[bubble.id] != nil || (tour != nil && tour != .tryIt))
                    .position(layout.slot(bubble.slot))
                    .transition(.asymmetric(insertion: .scale(scale: 0.3).combined(with: .opacity),
                                            removal: reduceMotion ? .opacity : .identity))
                    .accessibilityLabel("Feed \(bubble.spoken)")
                    .accessibilityHint("Books it into this week")
                }

                if tour == .tryIt, let target = tryItBubble(waiting) {
                    let center = layout.slot(target.slot)
                    TryItHint(center: center, petName: pet.name, labelOnLeft: center.x > size.width / 2)
                }
            }
            .animation(.spring(duration: 0.45, bounce: 0.35), value: bubbles.map(\.id))
            .coordinateSpace(name: Self.stageSpace)
            .onPreferenceChange(LineFrameKey.self) { lineFrame = $0 }
        }
    }

    private static let stageSpace = "homeStage"

    private func stageConfig(pet: Pet3D, box: PetStageConfig.Box) -> PetStageConfig {
        // No mood from the health data (PRD v0.3): how the pet idles follows its energy, and today's
        // base state only the clock and the user's own choices (PRD §5.3): 看月亮 in the hour before
        // bed, 放假 on a leave day or a rested Whoop red day; 呼呼 among the idle moves once a
        // workout is booked.
        // each pet keeps its own outfit; switching the main pet switches what home shows (PRD v0.3 §5.4)
        #if DEBUG
        // simulator: -hp3dMood rest|bedtime shows 放假 / 看月亮 at any time
        let mood = UserDefaults.standard.string(forKey: "hp3dMood") ?? model.petMood(at: clock)
        #else
        let mood = model.petMood(at: clock)
        #endif
        return PetStageConfig(pet: pet.id, rug: true, dark: scheme == .dark, bedtime: model.isPetAsleep,
                       mood: mood, workedOut: model.workoutBookedToday,
                       energy: energy.rawValue, decor: model.dressUp.outfit(for: pet.id), box: box)
    }

    private func bubbleColor(_ kind: FoodBubble.Kind) -> Color {
        switch kind {
        case .workout, .steps: Jade.accent
        case .moon: Jade.sleep
        case .load: Jade.load
        }
    }

    // MARK: - Feeding: 点击 = 入账

    /// The bubble is booked at once (experience, this week, the ledger); the screen then plays it:
    /// jelly → pop → crumbs into the mouth → swallow → the tag and the dot into this week's cell.
    private func harvest(_ bubble: FoodBubble, layout: HomeLayout) {
        guard eating[bubble.id] == nil, let scene = spots["scene"] else { return }
        if reduceMotion { harvestCalmly(bubble, layout: layout); return }
        let at = layout.slot(bubble.slot)
        if held == nil { held = Shown(status: model.homeStatus, cells: model.weekCells, days: model.weekStrip) }
        let before = model.weekCells
        let feedback = model.book(bubble.credit)
        let after = model.weekCells
        eating[bubble.id] = bubble
        if tour == .tryIt { tour = nil }
        note = nil
        selectedDay = nil
        // the tag pops up where the pet's line sits
        lineTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { line = nil }

        stage.feed(at: CGPoint(x: at.x / layout.size.width, y: at.y / layout.size.height), then: feedback.expression)
        // 啵 as the jelly bursts, then the crumbs going in (PRD v0.3 §8.4); the cell's note when the dot lands
        Cues.pop.play()
        Cues.nibble.play(after: 0.76)

        let landing = landingSpot(feedback, before: before, after: after)
        let origin = scene.origin
        func onHome(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + origin.x, y: p.y + origin.y) }
        let target = spots[landing.spot].map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: scene.midX, y: scene.maxY + 60)
        let feed = Feed(id: "\(bubble.id)@\(Date().timeIntervalSince1970)", start: .now, from: onHome(at),
                        mouth: onHome(layout.mouth), feet: onHome(layout.feet), target: target,
                        color: bubbleColor(bubble.kind), tag: feedback.tag,
                        tagAt: onHome(CGPoint(x: layout.size.width / 2, y: layout.headTop - 26)))
        feeds.append(feed)
        inFlight += 1

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.34))
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { eating[bubble.id] = nil }
            try? await Task.sleep(for: .seconds(Feed.swallowAt - 0.34))
            bites += 1
            lastBite = Date()
            try? await Task.sleep(for: .seconds(Feed.landsAt - Feed.swallowAt))
            land(landing)
            try? await Task.sleep(for: .seconds(Feed.endsAt - Feed.landsAt))
            feeds.removeAll { $0.id == feed.id }
            // a new pet, a level, a 自律周: the moments after the meal
            if inFlight == 0 { afterMeal(feedback) }
        }
    }

    /// Reduce Motion (PRD v0.3 §8.2): the bubble fades, the cell fills at once and the tag is said;
    /// no jelly, crumbs or flying dot, and the pet only changes its face.
    private func harvestCalmly(_ bubble: FoodBubble, layout: HomeLayout) {
        let at = layout.slot(bubble.slot)
        if tour == .tryIt { tour = nil }
        note = nil
        selectedDay = nil
        let before = model.weekCells
        let feedback = withAnimation(.easeOut(duration: 0.3)) { model.book(bubble.credit) }
        stage.feed(at: CGPoint(x: at.x / layout.size.width, y: at.y / layout.size.height), then: feedback.expression)
        // only 啵 and the cell's note 0.3 s later, no chewing; two taps (the swallow's and the cell's)
        Cues.pop.play(haptics: false)
        let (cell, gain) = landingCue(landingSpot(feedback, before: before, after: model.weekCells))
        cell.play(after: 0.3, gain: gain)
        bites += 1
        lastBite = Date()
        if let tag = feedback.tag { say(tag, icon: BubbleIcon.of(feedback.kind)) }
        inFlight += 1
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            inFlight -= 1
            if inFlight == 0, model.foodBubbles.isEmpty { stage.celebrate("hop") }
            if inFlight == 0 { afterMeal(feedback) }
        }
    }

    /// After the last bite: the first on-time moon ever brings the pet's one question about the
    /// bedtime reminder; otherwise the usual moments (a new pet, a level, a 自律周).
    private func afterMeal(_ feedback: BookingFeedback) {
        if feedback.lightsCheck, !home.askedAboutBedtime {
            guard !home.notifyBedtime else { home.askedAboutBedtime = true; return greet() }
            lineTask?.cancel()
            line = nil
            withAnimation(.spring(duration: 0.3)) { askingBedtime = true }
            return
        }
        greet()
    }

    private func answerBedtime(_ sure: Bool) {
        home.askedAboutBedtime = true
        withAnimation(.easeOut(duration: 0.2)) { askingBedtime = false }
        Task { @MainActor in
            if sure {
                // the system asks for permission; a "no" there leaves the switch off
                home.notifyBedtime = await PetNotifications.requestPermission()
                say(home.notifyBedtime ? "Deal! I’ll yawn at you before bed." : "Okay. It’s in Settings if you change your mind.")
            } else {
                say("Okay. It’s in Settings if you change your mind.")
            }
            try? await Task.sleep(for: .seconds(3.2))
            greet()
        }
    }

    private struct Landing {
        var spot: String
        /// The cell fills now (bump after its 0.4 s fill); false = it was lit already, it only bumps.
        var fills: Bool
    }

    private func landingSpot(_ feedback: BookingFeedback, before: WeekCells, after: WeekCells) -> Landing {
        switch feedback.target {
        case .workouts:
            if after.workouts > before.workouts { return Landing(spot: "w\(before.workouts)", fills: true) }
            return Landing(spot: "w\(max(0, after.workouts - 1))", fills: false)
        case .nights:
            if let index = after.nights.indices.first(where: { after.nights[$0] != before.nights[$0] }) {
                return Landing(spot: "n\(index)", fills: true)
            }
            return Landing(spot: "n\(max(0, after.filledNights - 1))", fills: false)
        case .memories:
            return Landing(spot: "memories", fills: false)
        }
    }

    /// The note of what the dot lands on (PRD v0.3 §8.4): the workout cells climb C6 D6 E6 on the
    /// toy xylophone, the nights G6 to E7 on the music box (the leave night too), so a full week
    /// is a tune; a cell lit already only flashes, 6 dB lower. Memories: a neutral note.
    private func landingCue(_ landing: Landing) -> (Cue, Float) {
        if landing.spot == "memories" { return (Cues.toMemories, 1) }
        let number = (Int(landing.spot.dropFirst()) ?? 0) + 1
        let cue = landing.spot.hasPrefix("w") ? Cues.workoutCell(number) : Cues.nightCell(number)
        return (cue, landing.fills ? 1 : 0.5)
    }

    /// The dot is in: the held rows let go (the cell fills, the moon's check lights, today's
    /// calendar icon appears), and whatever it landed on bumps.
    private func land(_ landing: Landing) {
        let (cell, gain) = landingCue(landing)
        cell.play(gain: gain)
        inFlight -= 1
        if inFlight == 0 {
            withAnimation(.easeOut(duration: 0.4)) { held = nil }
        }
        let index = Int(landing.spot.dropFirst()) ?? 0
        let bump = {
            if landing.spot == "memories" { memoriesPulse += 1 }
            else if landing.spot.hasPrefix("w") { workoutPulses[index, default: 0] += 1 }
            else { nightPulses[index, default: 0] += 1 }
        }
        if landing.fills && inFlight == 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.4))
                bump()
            }
        } else {
            bump()
        }
        // the day's last bubble eaten: a happy hop
        if inFlight == 0, model.foodBubbles.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4 - (Feed.landsAt - Feed.swallowAt)))
                stage.celebrate("hop")
            }
        }
    }

    // MARK: - Status area and this week

    private func statusArea(_ shown: Shown) -> some View {
        VStack(spacing: 16) {
            AsleepRow(status: shown.status)
                .noteHighlight(note == .asleep)
                .onTapGesture { open(.asleep) }
                .infoNote(isPresented: noteShown(.asleep)) { asleepNote }
            Group {
                if shown.status.whoop { RecoveryRow(status: shown.status) } else { SleptRow(status: shown.status) }
            }
            .noteHighlight(note == .second)
            .onTapGesture { open(.second) }
            .infoNote(isPresented: noteShown(.second)) { secondNote }
            WeekRow(cells: shown.cells, workoutPulses: workoutPulses, nightPulses: nightPulses)
                .noteHighlight(note == .week)
                .onTapGesture { open(.week) }
                .infoNote(isPresented: noteShown(.week)) {
                    WeekNote(cells: model.weekCells, bedtime: SleepSchedule.clock(model.sleepSchedule.bedtimeMinutes))
                }
        }
    }

    private func open(_ which: Note) {
        guard tour == nil || tour == .tryIt else { return }
        note = which
    }

    private func noteShown(_ which: Note) -> Binding<Bool> {
        Binding(get: { note == which }, set: { if !$0, note == which { note = nil } })
    }

    private var asleepNote: some View {
        let target = SleepSchedule.clock(model.sleepSchedule.targets(nightEnding: Date()).bed)
        let onset = model.homeStatus.onsetText
        // No sleep at all in 30 days (no watch at night): say how the moon comes (PRD v0.3 §6).
        guard model.hasSleepData || onset != nil else {
            return InfoNote("Asleep", AppModel.noSleepLine)
        }
        return InfoNote(onset.map { "Asleep \($0)" } ?? "Asleep",
                        "When your watch saw you fall asleep. Your target is \(target); within 30 minutes counts as on time and lights the ✓.")
    }

    private var secondNote: some View {
        let status = model.homeStatus
        return status.whoop
            ? InfoNote("Recovery · WHOOP", "Your WHOOP recovery today. Just a bar here; the number is in Today.")
            : InfoNote(status.slept.map { "Slept \($0)" } ?? "Slept", "Time asleep last night, as your watch recorded it.")
    }

    // MARK: - The tour (v3.4)

    private func startTour() {
        tourTask?.cancel()
        note = nil
        selectedDay = nil
        home.tourDone = false
        withAnimation(.easeOut(duration: 0.25)) { tour = .bubbles }
    }

    private func nextTourStep() {
        guard let step = tour else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            switch step {
            case .bubbles: tour = .records
            case .records: tour = .dock
            case .dock, .tryIt:
                home.tourDone = true
                // the last step needs a bubble; with none today it ends here
                tour = tryItBubble(model.foodBubbles) == nil ? nil : .tryIt
            }
        }
    }

    private func endTour() {
        home.tourDone = true
        withAnimation(.easeOut(duration: 0.25)) { tour = nil }
    }

    private func tryItBubble(_ bubbles: [FoodBubble]) -> FoodBubble? {
        bubbles.first { $0.kind == .workout } ?? bubbles.first
    }

    @ViewBuilder
    private var tourOverlay: some View {
        if let tour, tour != .tryIt, let hole = tourHole(tour) {
            TourOverlay(step: tour, hole: hole, captionBelow: tour == .bubbles, skipAt: spots["more"],
                        petName: model.mainPet3D.name, whoop: model.isWhoopUser, next: nextTourStep, skip: endTour)
        }
    }

    /// The lit place of each step, in home coordinates.
    private func tourHole(_ step: TourStep) -> CGRect? {
        switch step {
        case .bubbles:
            guard let scene = spots["scene"] else { return nil }
            // from just above the highest bubble down to the pet's floor
            let highest = model.foodBubbles.map { HomeLayout.slots[min($0.slot, HomeLayout.slots.count - 1)].y }.min() ?? 0.226
            let top = scene.minY + max(0, highest * scene.height - 40)
            return CGRect(x: scene.minX + 26, y: top, width: scene.width - 52, height: scene.maxY - top + 4)
        case .records:
            return spots["status"]?.insetBy(dx: 18, dy: -14)
        case .dock:
            // the same margin all round the three buttons, so it stays off the This week row above
            return spots["dock"]?.insetBy(dx: -16, dy: -12)
        case .tryIt:
            return nil
        }
    }

    // MARK: - Moments: the morning, new pets, a 自律周, the tour

    /// One expression (nil = only words) with the line the pet says as it starts.
    private struct Moment {
        let expression: String?
        let line: String?
    }

    /// How long each moment holds the stage (the expressions' lengths in engine.js).
    private static let lengths: [String: Double] = [
        "proud": 3.2, "hop": 2.76, "cheer": 3.4, "starry": 2.8, "love": 3.0, "cheerup": 3.8, "confused": 3.2,
        "levelup": 3.2, "bigcheer": 4.8, "hello": 3.0, "missyou": 4.8,
    ]

    private func greet() {
        guard home.onboarded, stage.isReady, onScreen, scenePhase == .active, inFlight == 0, !askingBedtime else { return }

        // The first time after the first open: the wake-up, then the pet shows the user around.
        if !home.tourDone {
            guard tour == nil, tourTask == nil else { return }
            let morning = home.takeMorning()
            if morning { wakeUp() }
            tourTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(morning ? 5.8 : 0.8))
                tourTask = nil
                guard !Task.isCancelled, onScreen, !home.tourDone else { return }
                startTour()
            }
            return
        }
        // the party hat after the tour, once; also for those who did the tour before Dress up existed
        let giftDue = !model.dressUp.welcomeGiven && tour == nil
        guard !model.isPetAsleep else {
            if giftDue { offerWelcomeGift(after: 0.8) }
            return
        }

        var moments: [Moment] = []
        var start = 0.0

        // 醒来, then a word about last night (早上揭晓): an on-time night is said (its proud look
        // comes with the moon bubble), a level-up collected overnight hops, a cheer-up after a
        // lapse. Never sad.
        let morning = home.takeMorning()
        if morning {
            wakeUp()
            start = 5.2
            if let reveal = model.morningReveal(levelUps: home.takeLevelUps(model.petLevels)) {
                moments.append(Moment(expression: reveal.expression, line: reveal.line))
            } else if home.daysAway >= 3 {
                // 想你了: away 3 days or more. Only missing you, never the lapse or the progress.
                moments.append(Moment(expression: "missyou", line: "I missed you!"))
            } else if home.daysAway >= 2 || model.cameBackAfterLapse {
                moments.append(Moment(expression: "cheerup", line: "New day. Let's go again!"))
            }
            if let days = model.anniversaryToday {
                moments.append(Moment(expression: "love", line: "\(days) days together!"))
            }
        }

        // 打招呼: back after a few hours on the same day
        if !morning, home.takeHelloAfterAway() {
            moments.append(Moment(expression: "hello", line: nil))
        }

        if model.dataMissing, home.takeOnceToday("confused") {
            moments.append(Moment(expression: "confused", line: "No news from your watch yet."))
        }

        let newPets = home.takeNewPets(model.unlockedPets)
        if let first = newPets.first {
            moments.append(Moment(expression: "starry", line: newPets.count == 1 ? "\(first.name) joined you!" : "\(newPets.count) new pets!"))
        }

        // Last week first: it may only have counted at 04:00 on Monday, while the phone was
        // asleep, and still deserves its cheer and its card (dated last week). Only weeks the user
        // already had the pet in are celebrated.
        let doneWeek = [model.previousWeek, model.week].compactMap { $0 }.first { week in
            let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: week.weekStart) ?? week.weekStart
            return week.isDisciplined && model.store.adoptedOn < weekEnd && home.takeWeekCelebration(weekStart: week.weekStart)
        }
        let weekDone = doneWeek != nil
        // a monthly achievement only comes with a week that counts; the first look only remembers
        let newMonth = home.takeNewMonth(count: model.monthlyAchievements)
        if weekDone {
            cardWeek = doneWeek?.weekStart == model.week?.weekStart ? nil : doneWeek
            // 大庆祝 for a monthly achievement or every 10 disciplined weeks, the cheer otherwise
            let total = model.disciplinedWeekTotal
            if newMonth {
                moments.append(Moment(expression: "bigcheer", line: "Disciplined month ✓"))
            } else if total > 0, total % 10 == 0 {
                moments.append(Moment(expression: "bigcheer", line: "\(total) disciplined weeks!"))
            } else {
                moments.append(Moment(expression: "cheer", line: "Disciplined week ✓"))
            }
            if model.disciplinedWeekTotal == 1 {
                moments.append(Moment(expression: "love", line: "Our first disciplined week!"))
            }
        }

        // 大庆祝 for the big round numbers (PRD §8.4): 30 and 100 on-time nights, 100 workouts
        for milestone in home.takeMilestones(model.milestonesReached) {
            moments.append(Moment(expression: "bigcheer", line: AppModel.milestoneLine(milestone)))
        }

        if !morning, moments.isEmpty, model.almostWorkout, home.takeOnceToday("almost") {
            moments.append(Moment(expression: "cheerup", line: "Almost 10k steps!"))
        }
        // no bubbles: never a blank stage, one line a day
        if moments.isEmpty, model.today != nil, model.foodBubbles.isEmpty, home.takeOnceToday("nothingToEat") {
            moments.append(Moment(expression: nil, line: "Nothing to eat yet. A walk or a workout grows a snack here."))
        }

        guard !moments.isEmpty else {
            if giftDue { offerWelcomeGift(after: start + 0.8) }
            return
        }
        // queued in the page: each plays to the end, in order, after 醒来
        moments.compactMap(\.expression).forEach { stage.celebrate($0) }
        momentsTask?.cancel()
        momentsTask = Task {
            try? await Task.sleep(for: .seconds(start + 0.4))
            for moment in moments {
                guard !Task.isCancelled else { return }
                if let text = moment.line { say(text) }
                try? await Task.sleep(for: .seconds(moment.expression.flatMap { Self.lengths[$0] } ?? 3))
            }
            // the card slides up once the celebration is over
            if weekDone, !Task.isCancelled, onScreen { weekCard = true }
            else if giftDue, !Task.isCancelled { offerWelcomeGift(after: 0.2) }
        }
    }

    /// The welcome gift (D11, D12): a box to tap open, then the party hat and 「Put it on 〈pet〉」.
    /// Only on a quiet home: no tour, meal, question or card in the way (otherwise next time).
    private func offerWelcomeGift(after delay: Double) {
        guard !model.dressUp.welcomeGiven, giftTask == nil else { return }
        giftTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            giftTask = nil
            guard !Task.isCancelled, onScreen, scenePhase == .active, home.tourDone, tour == nil, inFlight == 0,
                  !weekCard, !askingBedtime, gift == nil, let id = model.dressUp.giveWelcome() else { return }
            gift = GiftReveal(item: id, welcome: true, petName: model.mainPet3D.name)
        }
    }

    /// 「Put it on Toast」: the main pet wears it, and its page shows it on (D13).
    private func putOn(_ gift: GiftReveal) {
        let pet = model.mainPet3D
        model.dressUp.wear(gift.item, on: pet.id)
        if let decor = Decor.with(id: gift.item) { Cues.wearOn(decor.slot.rawValue).play() }
        model.dressUp.justWorn = (pet.id, gift.item)
        self.gift = nil
        router.path = [.pets, .pet(pet.id)]
    }

    /// 醒来: the bubbles wait for the pet to wake up, then grow one by one.
    private func wakeUp() {
        stage.morning()
        foodHidden = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5.3))
            withAnimation(.spring(duration: 0.45, bounce: 0.35)) { foodHidden = false }
        }
    }

    /// Keeps `clock` within half a minute of now while home is on screen (the hour before bed).
    private func keepTime() async {
        while onScreen, !Task.isCancelled {
            clock = Date()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// 眼巴巴 (PRD §5.3): while food waits, the pet eyes the nearest bubble every 14–18 s; never
    /// during the wake-up, the tour, a meal (and 10 s after it), the bedtime question or a gift.
    private func begNowAndThen() async {
        guard onScreen else { return }
        try? await Task.sleep(for: .seconds(6))
        while onScreen, !Task.isCancelled {
            if let target = begTarget() { stage.beg(toward: target) }
            try? await Task.sleep(for: .seconds(Double.random(in: 14...18)))
        }
    }

    /// The bubble the pet would look at, as a fraction of its page; nil when it shouldn't now.
    private func begTarget() -> CGPoint? {
        guard scenePhase == .active, stage.isReady, !model.isPetAsleep, !foodHidden, !askingBedtime, inFlight == 0,
              tour == nil || tour == .tryIt, gift == nil, !weekCard, Date().timeIntervalSince(lastBite) > 10,
              let scene = spots["scene"] else { return nil }
        let pet = model.mainPet3D
        let layout = HomeLayout(size: scene.size, anchors: stage.anchors(for: pet.id) ?? .standard, outfitTop: stage.outfitTop(for: pet.id))
        let eyes = CGPoint(x: layout.size.width / 2, y: layout.stageRect.minY + layout.anchors.ey / 100 * layout.stageSide)
        let nearest = model.foodBubbles.map { layout.slot($0.slot) }
            .min { hypot($0.x - eyes.x, $0.y - eyes.y) < hypot($1.x - eyes.x, $1.y - eyes.y) }
        return nearest.map { CGPoint(x: $0.x / layout.size.width, y: $0.y / layout.size.height) }
    }

    /// 等一下 (PRD §5.3): a refresh that takes over a second (the watch's data on its way) — the pet
    /// keeps looking until it is in, then finds it and nods.
    private func waitForData(_ loading: Bool) {
        dataTask?.cancel()
        if loading {
            dataTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                // not during the morning's wake-up (the food waits for it too)
                guard !Task.isCancelled, model.isLoading, onScreen, !foodHidden, !model.isPetAsleep, !waitingForData else { return }
                waitingForData = true
                stage.react("wait", hold: true)
            }
        } else if waitingForData {
            waitingForData = false
            stage.endHold("wait")
        }
    }

    /// The pet says a line (B 轻泡串): 3 s, 4.5 s when it is long. A data line gets its icon.
    private func say(_ text: String, icon: BubbleIcon? = nil, asleep: Bool = false) {
        guard feeds.isEmpty else { return }   // a harvest's tag has that place
        lineTask?.cancel()
        lineIcon = icon ?? BubbleIcon.guess(text)
        lineAsleep = asleep || model.isPetAsleep
        withAnimation(.spring(duration: 0.3)) { line = text }
        lineTask = Task {
            try? await Task.sleep(for: .seconds(text.count > 40 ? 4.5 : 3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { line = nil }
        }
    }

    // MARK: - Dock: three circles of one size, the icon above its name inside (2026-11-26)

    /// Pets · Today · Memories as three circles of one size, each name inside its circle under the
    /// icon, so a name reads as part of what it opens. Today stands out by colour only (forest by
    /// day, lime at night), never by size.
    private var dock: some View {
        HStack(alignment: .bottom, spacing: 30) {
            NavigationLink(value: Route.pets) {
                // the dot: a new pet, or enough points for a draw (PRD v0.3 §5.4)
                DockItem(name: "Pets", dot: home.hasUnseen(model.unlockedPets) || model.dressUp.canDraw) {
                    PetFaceIcon(size: 22)
                }
            }
            NavigationLink(value: Route.today) {
                DockItem(name: "Today", primary: true) {
                    // C 三根小柱 (decided 2026-11-10): Today is where the numbers are, not a
                    // check-in button, so no check mark. VoiceOver still reads "Today".
                    TodayBars()
                        .stroke(Jade.onPrimary, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                        .frame(width: 22, height: 22)
                }
            }
            NavigationLink(value: Route.memories) {
                // named Diary since 2026-11-26 (was Memories); the route and spot keep the old name
                DockItem(name: "Diary") {
                    DiaryIcon(size: 22)
                }
                .pulse(memoriesPulse, amount: 1.1)
                .background(HomeSpot.mark("memories"))
            }
        }
        .buttonStyle(.plain)
    }

    #if DEBUG
    /// For screenshots on the simulator, once the pet is ready:
    /// -hp3dFeed all (or a bubble kind: workout, steps, night, load) eats the bubbles one by one;
    /// -hp3dTour 1|2|3|tryit shows that tour step; -hp3dNote asleep|slept|week|day opens that note;
    /// -hp3dAskBedtime YES shows the pet's one question about the bedtime reminder;
    /// -hp3dReact <expression> plays it after 3 s (wait and gift are let go 4 s later);
    /// -hp3dSay <line> has the pet say it after 3 s and keeps it up; -hp3dPop pets|more opens that card.
    private func debugLaunch() async {
        guard stage.isReady else { return }
        let defaults = UserDefaults.standard
        if let text = defaults.string(forKey: "hp3dSay") {
            try? await Task.sleep(for: .seconds(3))
            say(text)
            lineTask?.cancel()
        }
        if let which = defaults.string(forKey: "hp3dPop") {
            try? await Task.sleep(for: .seconds(2))
            togglePop(which == "more" ? .more : .pets)
        }
        if let id = defaults.string(forKey: "hp3dReact") {
            try? await Task.sleep(for: .seconds(3))
            let hold = id == "wait" || id == "gift"
            stage.react(id, hold: hold)
            if hold {
                try? await Task.sleep(for: .seconds(4))
                stage.endHold(id)
            }
        }
        if defaults.bool(forKey: "hp3dAskBedtime") {
            try? await Task.sleep(for: .seconds(3))
            lineTask?.cancel()
            line = nil
            withAnimation(.spring(duration: 0.3)) { askingBedtime = true }
        }
        if let step = defaults.string(forKey: "hp3dTour") {
            try? await Task.sleep(for: .seconds(1.5))
            tourTask?.cancel()
            tour = step == "tryit" ? TourStep.tryIt : TourStep(rawValue: Int(step) ?? 1)
        }
        if let which = defaults.string(forKey: "hp3dNote") {
            try? await Task.sleep(for: .seconds(3))
            switch which {
            case "asleep": note = .asleep
            case "rest", "slept": note = .second
            case "week": note = .week
            default:
                // A day only has a note once something is booked; on a Monday morning nothing is.
                if !model.weekStrip.contains(where: { model.dayNote($0) != nil }) {
                    for bubble in model.foodBubbles { _ = model.book(bubble.credit) }
                }
                selectedDay = model.weekStrip.first { model.dayNote($0) != nil }?.id
            }
        }
        if let which = defaults.string(forKey: "hp3dFeed") {
            try? await Task.sleep(for: .seconds(9))
            guard let scene = spots["scene"] else { return }
            let layout = HomeLayout(size: scene.size, anchors: stage.anchors(for: model.mainPet3D.id) ?? .standard,
                                    outfitTop: stage.outfitTop(for: model.mainPet3D.id))
            for bubble in model.foodBubbles where which == "all" || bubble.credit.kind.rawValue == which {
                // The clock time lets sim-shots.sh find this moment in its recording.
                FileHandle.standardError.write(Data("[feed] \(bubble.id) \(Date().timeIntervalSince1970)\n".utf8))
                harvest(bubble, layout: layout)
                try? await Task.sleep(for: .seconds(2.2))
            }
        }
    }
    #endif
}

/// The dock's Today icon: three small bars, short · tall · middle (drawn on a 24 pt grid).
private struct TodayBars: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var path = Path()
        for (x, top) in [(6.0, 14.0), (12.0, 4.5), (18.0, 10.0)] {
            path.move(to: CGPoint(x: rect.minX + x * s, y: rect.minY + 19.5 * s))
            path.addLine(to: CGPoint(x: rect.minX + x * s, y: rect.minY + top * s))
        }
        return path
    }
}

/// A dock button: one circle with the icon above its name inside. The circle grows with the
/// system text size (72 pt at the default size), so every name fits.
private struct DockItem<Icon: View>: View {
    let name: String
    var primary = false
    /// A small green dot just outside the circle's top-right edge.
    var dot = false
    @ViewBuilder var icon: () -> Icon
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 72

    var body: some View {
        VStack(spacing: 2) {
            icon()
            Text(name)
                .scaledFont(11, .heavy)
                .foregroundStyle(primary ? Jade.onPrimary : Jade.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.top, 2)
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(primary ? Jade.primary : Jade.card))
        .softShadow(primary ? 1.6 : 0.6)
        .overlay(alignment: .topTrailing) {
            if dot {
                // follows the rim at 45°, so the gap stays the same when the circle grows
                let inset = diameter * (1 - CGFloat(0.5).squareRoot()) / 2 - 7.5
                Circle().fill(Jade.accent).frame(width: 8, height: 8).offset(x: -inset, y: inset)
            }
        }
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
    }
}

/// Where things sit on the home stage, in the stage area's own points (the mocks are 402 wide).
struct HomeLayout {
    let size: CGSize
    let anchors: PetAnchors
    /// How high the outfit reaches, when it wears one (PetStage.outfitTop).
    var outfitTop: Double?

    /// The pet's 100 × 100 box: about 63% of the width, feet at 87% of the height.
    var stageSide: CGFloat { min(size.width * 0.63, size.height * 0.62) }

    var stageRect: CGRect {
        let side = stageSide
        let feet = size.height * 0.87
        return CGRect(x: (size.width - side) / 2, y: feet - side * anchors.bottom / 100, width: side, height: side)
    }

    var box: PetStageConfig.Box {
        let rect = stageRect
        return .init(x: Double(rect.minX / size.width), y: Double(rect.minY / size.height), size: Double(stageSide / size.width))
    }

    var mouth: CGPoint {
        let rect = stageRect
        return CGPoint(x: rect.minX + anchors.mouth.x * rect.width, y: rect.minY + anchors.mouth.y * rect.height)
    }

    /// Just above the floor under the pet: where the booking dot sets off.
    var feet: CGPoint {
        CGPoint(x: size.width / 2, y: stageRect.minY + anchors.bottom / 100 * stageSide - 4)
    }

    /// The top of the pet, or of its outfit when that reaches higher (a tall hat): the pet's line,
    /// the bedtime question and the booking tag sit above it, never on the hat.
    var headTop: CGFloat { stageRect.minY + min(anchors.top, outfitTop ?? anchors.top) / 100 * stageSide }

    /// Food bubble places (v3.3 mock): the moon top left, a workout top right, the 10k day middle
    /// left, a second workout middle right, Whoop strain top centre.
    static let slots: [CGPoint] = [
        CGPoint(x: 0.229, y: 0.226), CGPoint(x: 0.776, y: 0.226),
        CGPoint(x: 0.154, y: 0.607), CGPoint(x: 0.846, y: 0.607),
        CGPoint(x: 0.5, y: 0.1),
    ]

    func slot(_ index: Int) -> CGPoint {
        let p = Self.slots[min(index, Self.slots.count - 1)]
        return CGPoint(x: p.x * size.width, y: p.y * size.height)
    }
}

/// B 轻泡 (decided 2026-11-08): a 50 pt card-coloured circle with the soft v3.2 shadow, the same
/// colour inside and out; colour only on the icon (16 pt) and the number (11 pt): jade for a
/// workout or a 10k day, lime for the moon, grey for Whoop strain. A grey dot top right = not yet
/// booked. It floats 3.5 pt up and down every 3.4 s. Eaten: a jelly wobble, then it pops.
struct FoodBubbleView: View {
    let bubble: FoodBubble
    let phase: Int
    var eaten = false
    @State private var up = false
    /// Reduce Motion: the bubbles stand still (PRD v0.3 §8.2).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Pop {
        var sx: CGFloat = 1
        var sy: CGFloat = 1
        var scale: CGFloat = 1
        var opacity: Double = 1
    }

    private var ink: Color {
        switch bubble.kind {
        case .workout, .steps: Jade.accent
        case .moon: Jade.sleepText
        case .load: Jade.load
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: bubble.icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(height: 17)
            Text(bubble.label)
                .scaledFont(11, .heavy)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(ink)
        .frame(width: 50, height: 50)
        .background(Circle().fill(Jade.card))
        .softShadow(1.3)
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Jade.ink3)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Jade.card, lineWidth: 2))
                .offset(x: -2, y: 2)
        }
        .keyframeAnimator(initialValue: Pop(), trigger: eaten) { view, pop in
            view.scaleEffect(x: pop.sx * pop.scale, y: pop.sy * pop.scale).opacity(pop.opacity)
        } keyframes: { _ in
            // jelly: 10% wider and 9% shorter, back in 0.18 s; then from 0.17 s up to 1.22 and gone
            KeyframeTrack(\.sx) {
                CubicKeyframe(1.10, duration: 0.045)
                CubicKeyframe(1.0, duration: 0.045)
                CubicKeyframe(0.965, duration: 0.045)
                CubicKeyframe(1.0, duration: 0.045)
            }
            KeyframeTrack(\.sy) {
                CubicKeyframe(0.91, duration: 0.045)
                CubicKeyframe(1.0, duration: 0.045)
                CubicKeyframe(1.03, duration: 0.045)
                CubicKeyframe(1.0, duration: 0.045)
            }
            KeyframeTrack(\.scale) {
                LinearKeyframe(1, duration: 0.17)
                CubicKeyframe(1.22, duration: 0.12)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(1, duration: 0.17)
                LinearKeyframe(0, duration: 0.12)
                LinearKeyframe(0, duration: 0.3)
            }
        }
        .offset(y: reduceMotion ? 0 : up ? -3.5 : 3.5)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true).delay(Double(phase) * 0.45)) {
                up = true
            }
        }
        .contentShape(Circle())
    }
}

/// A bubble sinks a little under the finger.
private struct BubblePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Where the pet's line is on the stage, for the food bubbles it covers.
private struct LineFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

/// The pets met so far, four to a row: each on a small round plate with its name and level; the
/// main pet has a jade ring and a check. Up to twelve show whole; more scroll inside the card,
/// the next row peeking under a fade.
private struct PetSwitcher: View {
    let pets: [Pet3D]
    let current: String
    let level: (Pet3D) -> Int
    let outfit: (Pet3D) -> [String]
    let pick: (Pet3D) -> Void

    var body: some View {
        Group {
            if pets.count > 12 {
                ScrollView { grid }
                    .scrollIndicators(.hidden)
                    .frame(height: 400)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .black.opacity(0.25), location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            } else {
                grid
            }
        }
        .popCard()
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 2) {
            ForEach(pets) { pet in
                Button { pick(pet) } label: { cell(pet) }
                    .buttonStyle(PopRowPress())
                    .accessibilityLabel("\(pet.name), level \(level(pet))")
                    .accessibilityAddTraits(pet.id == current ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private func cell(_ pet: Pet3D) -> some View {
        let picked = pet.id == current
        return VStack(spacing: 4) {
            ZStack {
                Circle().fill(Jade.fill).padding(3)
                PetPicture(pet: pet, decor: outfit(pet))
                    .frame(width: 46, height: 46)
            }
            .frame(width: 62, height: 62)
            .overlay(Circle().strokeBorder(Jade.accent, lineWidth: 2.5).opacity(picked ? 1 : 0))
            .overlay(alignment: .topTrailing) {
                if picked { CheckBadge(size: 20).offset(x: 2, y: -2) }
            }
            Text(pet.name)
                .scaledFont(12.5, .bold)
                .foregroundStyle(Jade.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("Lv \(level(pet))")
                .scaledFont(10.5, .bold)
                .foregroundStyle(Jade.ink2)
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
