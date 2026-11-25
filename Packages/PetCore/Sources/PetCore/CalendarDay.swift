import Foundation

/// Days are kept as the start of a local day (`Calendar.startOfDay`): the activity log, the 自律周,
/// leave nights, fixed nights and the credits' ids. That start is a moment, and the same moment is
/// a different hour, often a different date, in another time zone. After a flight (or on an iPhone
/// set to another zone) every saved day would look new: collected food offered again, pets getting
/// a day's experience twice, and past 自律周 no longer matching their days, so levels could go
/// down (PRD §3). Rekeying turns a saved day back into the calendar date it was and gives the start
/// of that date in the calendar the phone has now.
public enum CalendarDay {
    /// The start, in `calendar`, of the calendar date `day` was the start of.
    ///
    /// A day already starting in `calendar` stays as it is. Any other was saved in another time zone:
    /// its date is read with a 13-hour shift, which is right for days saved anywhere from UTC−10:59
    /// to UTC+13 (Hawaii to New Zealand's summer time; not UTC−11 Samoa/Niue or UTC+14 Kiribati).
    public static func rekey(_ day: Date, in calendar: Calendar) -> Date {
        if calendar.startOfDay(for: day) == day { return day }
        let date = utc.dateComponents([.year, .month, .day], from: day.addingTimeInterval(13 * 3600))
        var noon = date
        noon.hour = 12
        guard let local = calendar.date(from: noon) else { return calendar.startOfDay(for: day) }
        return calendar.startOfDay(for: local)
    }

    public static func rekey(_ days: Set<Date>, in calendar: Calendar) -> Set<Date> {
        Set(days.map { rekey($0, in: calendar) })
    }

    /// Two saved days that turn out to be the same date are put together with `combine`.
    public static func rekey<Value>(_ byDay: [Date: Value], in calendar: Calendar,
                                    combine: (Value, Value) -> Value) -> [Date: Value] {
        var result: [Date: Value] = [:]
        for (day, value) in byDay {
            let key = rekey(day, in: calendar)
            result[key] = result[key].map { combine($0, value) } ?? value
        }
        return result
    }

    /// A credit id starts with its day in seconds: "1731456000/workout:Run:32".
    public static func rekeyID(_ id: String, in calendar: Calendar) -> String {
        guard let slash = id.firstIndex(of: "/"), let seconds = Int(id[..<slash]) else { return id }
        let day = rekey(Date(timeIntervalSince1970: TimeInterval(seconds)), in: calendar)
        return "\(Int(day.timeIntervalSince1970))\(id[slash...])"
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
