import Foundation
import PetCore
import ReplayCore

// health-replay: what Ovenpals would have made of the weeks in an Apple Health export.
//   swift run --package-path Packages/HealthReplay health-replay ~/Desktop/apple_health_export --bed 23:30

let usage = """
用法：health-replay <apple_health_export 文件夹，或其中的 export.xml / 导出.xml> [选项]

  --tz Asia/Shanghai     按哪个时区算（默认：这台电脑的时区）
  --bed 23:00            入睡目标（App 设置里的时间；晚 30 分钟内睡着算准时）
  --weekend-bed 00:00    周五、周六晚上的入睡目标（默认同平日）
  --wake 07:00           起床目标
  --weekend-wake 08:30   周六、周日的起床目标（默认同平日）
  --to 2026-11-23        回放到哪天（默认：导出数据的最后一天）
  --from 2026-10-01      从哪天开始（会往前挪到那周的周一）
  --days 56              不给 --from 时，往前回放多少天（默认 56 天 = 8 周）
  --csv days.csv         另外把每天的结果写成表格（可以用 Numbers / Excel 打开）
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func clock(_ text: String) -> (hour: Int, minute: Int)? {
    let parts = text.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
    return (parts[0], parts[1])
}

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(arguments.isEmpty ? 1 : 0)
}
var path: String?
var options: [String: String] = [:]
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument.hasPrefix("--") {
        guard !arguments.isEmpty else { fail("\(argument) 后面少了值\n\n\(usage)") }
        options[String(argument.dropFirst(2))] = arguments.removeFirst()
    } else if path == nil {
        path = argument
    } else {
        fail("多了一个参数：\(argument)\n\n\(usage)")
    }
}
let known: Set<String> = ["tz", "bed", "weekend-bed", "wake", "weekend-wake", "to", "from", "days", "csv"]
if let unknown = options.keys.first(where: { !known.contains($0) }) { fail("不认识的选项：--\(unknown)\n\n\(usage)") }
guard let path else { fail(usage) }

var settings = ReplaySettings()
if let tz = options["tz"] {
    guard let zone = TimeZone(identifier: tz) else { fail("不认识的时区：\(tz)（例如 Asia/Shanghai、America/Los_Angeles）") }
    settings.timeZone = zone
}
func bedtime(_ key: String) -> Bedtime? {
    guard let text = options[key] else { return nil }
    guard let time = clock(text) else { fail("--\(key) 要写成 23:00 这样") }
    return Bedtime(hour: time.hour, minute: time.minute)
}
func wakeTime(_ key: String) -> WakeTime? {
    guard let text = options[key] else { return nil }
    guard let time = clock(text) else { fail("--\(key) 要写成 07:00 这样") }
    return WakeTime(hour: time.hour, minute: time.minute)
}
if let bed = bedtime("bed") { settings.bedtime = bed }
settings.weekendBedtime = bedtime("weekend-bed")
if let wake = wakeTime("wake") { settings.wake = wake }
settings.weekendWake = wakeTime("weekend-wake")
let dayParser = DateFormatter()
dayParser.locale = Locale(identifier: "en_US_POSIX")
dayParser.timeZone = settings.timeZone
dayParser.dateFormat = "yyyy-MM-dd"
func day(_ key: String) -> Date? {
    guard let text = options[key] else { return nil }
    guard let date = dayParser.date(from: text) else { fail("--\(key) 要写成 2026-11-23 这样") }
    return date
}
settings.firstDay = day("from")
settings.lastDay = day("to")
if let text = options["days"] {
    guard let days = Int(text), days > 0 else { fail("--days 要是正整数") }
    settings.days = days
}

// MARK: - Read and replay

let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
FileHandle.standardError.write(Data("正在读 \(url.path)（导出文件大的话要一两分钟）…\n".utf8))
let export: HealthExport
do {
    export = try HealthExport.read(url)
} catch {
    fail("\(error)")
}
guard let result = Replay.run(export, settings: settings) else {
    fail("导出里没有步数、睡眠、运动或正念数据。")
}

// MARK: - Print

let calendar = settings.calendar
let format = ReplayFormat(calendar: calendar)
let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
func short(_ date: Date) -> String {
    let parts = calendar.dateComponents([.month, .day], from: date)
    return "\(parts.month!)/\(parts.day!)"
}
func named(_ date: Date) -> String { "\(weekdays[calendar.component(.weekday, from: date) - 1]) \(short(date))" }
func clockText(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
func plus30(_ bed: Bedtime) -> String {
    let total = (bed.hour * 60 + bed.minute + 30) % (24 * 60)
    return clockText(total / 60, total % 60)
}

/// Terminal width: Chinese characters take two columns.
func width(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { sum, scalar in
        let v = scalar.value
        let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v)
        return sum + (wide ? 2 : 1)
    }
}
func pad(_ text: String, _ columns: Int) -> String {
    text + String(repeating: " ", count: max(1, columns - width(text)))
}

let pets: [Activity: String] = [
    .walking: "Onigiri", .onTimeSleep: "Mantou", .earlyRise: "Coffee Bean", .mindfulness: "Matcha",
    .running: "Chili", .strength: "Baguette", .hiit: "Espresso", .cycling: "Avocado", .swimming: "Marshmallow",
    .hiking: "Lemon", .yoga: "Pudding", .pilates: "Mochi", .dance: "Strawberry Cake", .ballSports: "Pineapple",
    .climbing: "Dark Choco", .other: "Waffle", .recoveryMatch: "Honey", .sleepNeedMet: "Warm Milk", .redDayRest: "Protein Bar",
]
let chinese: [Activity: String] = [
    .walking: "万步", .onTimeSleep: "准时睡", .earlyRise: "早起", .mindfulness: "正念", .running: "跑步",
    .strength: "力量", .hiit: "HIIT", .cycling: "骑车", .swimming: "游泳", .hiking: "徒步", .yoga: "瑜伽",
    .pilates: "普拉提 / 拉伸", .dance: "跳舞", .ballSports: "球类", .climbing: "攀岩 / 滑雪", .other: "其他运动",
    .recoveryMatch: "负荷配恢复", .sleepNeedMet: "睡够", .redDayRest: "红灯日休息",
]

func workoutsText(_ day: ReplayDay) -> String {
    let list = day.workouts.map { "\($0.session.name) \(ReplayFormat.minutes($0.session.minutes))\($0.counts ? " ✓" : "")" }
    return list.isEmpty ? "—" : list.joined(separator: " / ")
}
func stepsText(_ day: ReplayDay) -> String {
    guard let steps = day.snapshot.steps else { return "—" }
    return ReplayFormat.number(steps) + (steps >= DisciplineRules.standard.activeDaySteps ? " ✓" : "")
}
func onsetText(_ day: ReplayDay) -> String {
    guard let onset = day.snapshot.sleepOnset, let onTime = day.onTime else { return "—" }
    return "\(format.time(onset)) \(onTime ? "✓" : "✗")"
}
func wakeText(_ day: ReplayDay) -> String {
    guard let wake = day.snapshot.wakeTime else { return "—" }
    return "\(format.time(wake))\(day.activities.contains(.earlyRise) ? " ✓" : "")"
}
func petsText(_ day: ReplayDay) -> String {
    Activity.allCases.filter(day.activities.contains).map { pets[$0] ?? $0.title }.joined(separator: " ")
}

let firstWeekday = weekdays[calendar.component(.weekday, from: result.firstDay) - 1]
let lastWeekday = weekdays[calendar.component(.weekday, from: result.lastDay) - 1]
var out = """
Ovenpals 真实数据回放
时区 \(settings.timeZone.identifier) · 入睡目标 \(clockText(settings.bedtime.hour, settings.bedtime.minute))（\(plus30(settings.bedtime)) 前睡着算准时）\
\(settings.weekendBedtime.map { "，周五 / 周六晚 \(clockText($0.hour, $0.minute))" } ?? "") · 起床目标 \(clockText(settings.wake.hour, settings.wake.minute))\
\(settings.weekendWake.map { "，周末 \(clockText($0.hour, $0.minute))" } ?? "")
回放 \(format.dateKey(result.firstDay))（\(firstWeekday)）到 \(format.dateKey(result.lastDay))（\(lastWeekday)），共 \(result.weeks.count) 周
数据来源：步数 \(result.stepSources.joined(separator: "、").nilIfEmpty ?? "无")；睡眠 \(result.sleepSourceNames.joined(separator: "、").nilIfEmpty ?? "无")；\
运动 \(result.workoutSources.joined(separator: "、").nilIfEmpty ?? "无")
假定：每个泡泡第二天 04:00 前都收下了；没有请假、没有「手表记错了」；只算 Apple 健康，Whoop 的宠物不在这里。
步数和 App 一样，每天取记得最多的那一个来源；「健康」App 把几个来源合起来，显示的数可能更大。


"""

let columns = [12, 12, 22, 10, 7, 10, 7]
for week in result.weeks {
    let progress = week.progress
    let rules = progress.rules
    let verdict = progress.isDisciplined ? "自律周 ✓"
        : week.isFinished ? "不是自律周（差 \([max(0, rules.workoutsPerWeek - progress.workouts) > 0 ? "\(rules.workoutsPerWeek - progress.workouts) 次运动" : nil, max(0, rules.onTimeNightsPerWeek - progress.onTimeNights) > 0 ? "\(rules.onTimeNightsPerWeek - progress.onTimeNights) 晚准时睡" : nil].compactMap { $0 }.joined(separator: "、"))）"
        : "这周还没过完"
    let end = calendar.date(byAdding: .day, value: 6, to: week.start)!
    out += "━━ \(named(week.start)) – \(named(end))   运动 \(progress.workouts)/\(rules.workoutsPerWeek)"
        + "  准时睡 \(progress.onTimeNights)/\(rules.onTimeNightsPerWeek)   \(verdict)\n"
    out += "  " + zip(["日期", "步数", "运动（分钟）", "入睡", "睡眠", "起床", "正念"], columns).map { pad($0, $1) }.joined() + "喂了谁\n"
    for day in week.days {
        let cells = [named(day.day), stepsText(day), workoutsText(day), onsetText(day),
                     day.snapshot.sleepHours.map { String(format: "%.1fh", $0) } ?? "—", wakeText(day),
                     day.snapshot.mindfulMinutes.map { "\(Int($0.rounded())) 分" } ?? "—"]
        out += "  " + zip(cells, columns).map { pad($0, $1) }.joined() + petsText(day) + "\n"
    }
    out += "\n"
}

out += "结果\n"
out += "  自律周 \(result.disciplinedWeeks.count) 个（共 \(result.weeks.filter(\.isFinished).count) 个完整的周），月度成就 \(result.monthlyAchievements) 个\n"
out += "  宠物（经验 = 做到的天数，自律周里的翻倍）：\n"
let unlocked = result.progress.values.filter(\.isUnlocked).sorted {
    $0.experience != $1.experience ? $0.experience > $1.experience : $0.activity.rawValue < $1.activity.rawValue
}
for pet in unlocked {
    let name = "\(pets[pet.activity] ?? pet.activity.title)（\(chinese[pet.activity] ?? pet.activity.title)）"
    out += "    " + pad(name, 30) + pad("Lv \(pet.level)", 7) + pad("\(pet.sessions) 天", 7) + "经验 \(pet.experience)\n"
}
if unlocked.isEmpty { out += "    还没有\n" }
if !result.nightsWithoutSleep.isEmpty {
    let list = result.nightsWithoutSleep.map(short)
    out += "  没有睡眠数据的晚上：\(list.count) 晚（\(list.prefix(12).joined(separator: "、"))\(list.count > 12 ? "…" : "")）\n"
}

let titles: [ReplayNote.Kind: String] = [
    .eveningNap: "晚上的小睡被当成入睡时间",
    .otherSleepSource: "入睡时间来自别的 App",
    .duplicateWorkout: "同一次运动可能记了两次",
    .almostTwentyMinutes: "差一点算 20 分钟的运动",
    .joinedWorkout: "分成几段记的运动（已合成一次）",
    .mindWorkout: "正念 / 太极类运动（算 Matcha，不算运动）",
    .stepsNearGoal: "步数离 1 万很近",
    .travel: "在别的时区记的数据",
]
let mattering = result.notes.filter(\.matters).count
out += "\n要留意的地方（\(result.notes.count) 条，其中 \(mattering) 条标 ★ = 会改变 App 里看到或算出的结果）\n"
if result.notes.isEmpty { out += "  没有\n" }
for kind in ReplayNote.Kind.allCases {
    let notes = result.notes.filter { $0.kind == kind }
    guard !notes.isEmpty else { continue }
    out += "  \(titles[kind] ?? kind.rawValue)：\(notes.count) 条\n"
    // days in a row with the same note (a trip) make one line
    var runs: [(first: ReplayNote, last: Date, count: Int)] = []
    for note in notes {
        if let run = runs.last, run.first.text == note.text,
           calendar.date(byAdding: .day, value: 1, to: run.last) == note.day {
            runs[runs.count - 1] = (run.first, note.day, run.count + 1)
        } else {
            runs.append((note, note.day, 1))
        }
    }
    for run in runs {
        let days = run.count == 1 ? named(run.first.day) : "\(named(run.first.day)) – \(named(run.last))（\(run.count) 天）"
        out += "    \(run.first.matters ? "★" : " ") \(days)  \(run.first.text)\n"
    }
}
print(out, terminator: "")
fflush(stdout)

// MARK: - CSV

if let csvPath = options["csv"] {
    func field(_ text: String) -> String {
        text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" : text
    }
    var rows = ["日期,星期,步数,各来源步数,运动,算运动,入睡,准时线,准时,睡眠小时,起床,早起,正念分钟,喂了谁,泡泡,留意"]
    for day in result.days {
        let notes = result.notes.filter { $0.day == day.day }.map { ($0.matters ? "★" : "") + $0.text }
        let bySource: String = day.stepsBySource.sorted { $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }.joined(separator: "; ")
        let workouts: String = day.workouts
            .map { "\($0.source): \($0.session.name) \(String(format: "%.1f", $0.session.minutes))" }.joined(separator: "; ")
        let onTime: String = day.onTime.map { $0 ? "是" : "否" } ?? ""
        let hours: String = day.snapshot.sleepHours.map { String(format: "%.2f", $0) } ?? ""
        let mindful: String = day.snapshot.mindfulMinutes.map { String(format: "%.0f", $0) } ?? ""
        var cells: [String] = [format.dateKey(day.day), weekdays[calendar.component(.weekday, from: day.day) - 1]]
        cells.append(day.snapshot.steps.map { String($0) } ?? "")
        cells += [bySource, workouts, day.countsAsWorkout ? "是" : ""]
        cells.append(day.snapshot.sleepOnset.map { format.time($0) } ?? "")
        cells += [format.time(day.latestOnTime), onTime, hours]
        cells.append(day.snapshot.wakeTime.map { format.time($0) } ?? "")
        cells += [day.activities.contains(.earlyRise) ? "是" : "", mindful, petsText(day), String(day.credits.count)]
        cells.append(notes.joined(separator: "; "))
        rows.append(cells.map(field).joined(separator: ","))
    }
    let csvURL = URL(fileURLWithPath: (csvPath as NSString).expandingTildeInPath)
    do {
        // with a byte order mark, so Excel opens the Chinese headers right
        try Data(("\u{FEFF}" + rows.joined(separator: "\n") + "\n").utf8).write(to: csvURL)
        FileHandle.standardError.write(Data("每天的结果写到了 \(csvURL.path)\n".utf8))
    } catch {
        fail("写不了 \(csvURL.path)：\(error)")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
