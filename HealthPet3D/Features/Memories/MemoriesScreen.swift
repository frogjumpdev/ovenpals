import SwiftUI
import PetCore

/// Memories = the achievement ledger (PRD v0.2): every 自律周 and month, every pet that joined,
/// Lv 10 / 20, 30 / 100 on-time nights, 100 workouts, the first 20k-step day and the days
/// together, newest first. On top: how many days you have been together. Below the achievements,
/// every food bubble that was eaten (点击 = 入账, §4.4): what it was, which pet got it, and
/// 「Collected for you」 when 04:00 booked it.
struct MemoriesScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = model.ledger
        PageScroll {
            PageHeader(title: "Diary", count: entries.isEmpty ? nil : "\(entries.count)")
                .padding(.bottom, 4)
            HStack(spacing: 14) {
                PetPicture(pet: model.mainPet3D, happy: true).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.daysTogether)").scaledFont(28, .bold).foregroundStyle(Jade.ink)
                    Label(model.daysTogether == 1 ? "day together" : "days together", systemImage: "heart")
                        .scaledFont(13, .semibold)
                        .foregroundStyle(Jade.ink2)
                }
                Spacer()
            }
            .card()
            .accessibilityElement(children: .combine)
            ForEach(entries) { entry in
                LedgerRow(entry: entry)
            }
            let collected = Array(model.creditRecords.prefix(60))
            if !collected.isEmpty {
                Text("Collected")
                    .scaledFont(15, .semibold)
                    .foregroundStyle(Jade.ink)
                    .padding(.top, 14)
                    .padding(.leading, 4)
                ForEach(collected) { record in
                    CreditRow(record: record)
                }
            }
        }
    }
}

/// One ledger line: a picture or an icon in the legend's colour, what happened, when.
struct LedgerRow: View {
    let entry: LedgerEntry

    var body: some View {
        HStack(spacing: 14) {
            badge
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(17, .semibold)
                    .foregroundStyle(Jade.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(entry.day.formatted(.dateTime.year().month(.abbreviated).day()))
                    .scaledFont(12, .semibold)
                    .foregroundStyle(Jade.ink2)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private var pet: Pet3D? {
        switch entry.kind {
        case .unlocked(let activity), .level(let activity, _):
            Pet3D.all.first { $0.activity == activity }
        default:
            nil
        }
    }

    private var title: String {
        switch entry.kind {
        case .disciplinedWeek(let n): "Disciplined week \(n)"
        case .monthlyAchievement(let n): "Disciplined month \(n)"
        case .unlocked: "\(pet?.name ?? "A new pet") joined"
        case .level(_, let level): "\(pet?.name ?? "A pet") Lv \(level)"
        case .onTimeNights(let n): "\(n) on-time nights"
        case .workouts(let n): "\(n) workouts"
        case .firstTwentyKSteps: "First 20k-step day"
        case .daysTogether(let n): "\(n) days together"
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let pet {
            PetPicture(pet: pet, happy: true)
        } else {
            let look = icon
            Image(systemName: look.name)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(look.on)
                .frame(width: 40, height: 40)
                .background(Circle().fill(look.fill))
        }
    }

    /// Colour is the legend: jade = workouts, lime = sleep, the primary for whole weeks and months.
    private var icon: (name: String, fill: Color, on: Color) {
        switch entry.kind {
        case .disciplinedWeek: ("checkmark", Jade.primary, Jade.onPrimary)
        case .monthlyAchievement: ("star.fill", Jade.primary, Jade.onPrimary)
        case .onTimeNights: ("moon.fill", Jade.sleep, Jade.onSleep)
        case .workouts, .firstTwentyKSteps: ("figure.run", Jade.accent, Jade.onAccent)
        case .daysTogether: ("heart.fill", Jade.fill, Jade.ink)
        case .unlocked, .level: ("pawprint.fill", Jade.fill, Jade.ink)
        }
    }
}

/// One booked food bubble: its icon in the legend's colour, what it was, the pet it fed (and its
/// level when it went up), the day; 「Collected for you」 when it was booked at 04:00.
struct CreditRow: View {
    let record: CreditRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Jade.canvas))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.detail)
                    .scaledFont(16, .semibold)
                    .foregroundStyle(Jade.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .scaledFont(12, .semibold)
                    .foregroundStyle(Jade.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }

    private var pet: Pet3D? {
        record.activity.flatMap { activity in Pet3D.all.first { $0.activity == activity } }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let pet {
            if let from = record.levelFrom, let to = record.levelTo, from > 0 {
                parts.append("\(pet.name) Lv \(from) → \(to)")
            } else {
                parts.append("\(pet.name) +1")
            }
        }
        parts.append(record.day.formatted(.dateTime.month(.abbreviated).day()))
        if record.auto { parts.append("Collected for you") }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch record.kind {
        case .workout: workoutIcon(String(record.detail.split(separator: " ").first ?? ""))
        case .steps: "shoeprints.fill"
        case .night: "moon"
        case .load: "gauge.with.dots.needle.50percent"
        }
    }

    private var tint: Color {
        switch record.kind {
        case .workout, .steps: Jade.accent
        case .night: Jade.sleepText
        case .load: Jade.load
        }
    }
}
