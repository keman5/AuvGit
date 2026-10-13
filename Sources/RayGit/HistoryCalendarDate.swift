import Foundation
import RayGitLocalization
import GitCore

extension GitStash {
    var datedTitle: String {
        guard let createdDate else { return subject }
        return HistoryCalendarDate.text(createdDate) + " · " + subject
    }
}

/// Calendar boundaries remain stable within a day; all visible times stop at minutes.
enum HistoryCalendarDate {
    private static let formatters: NSCache<NSString, DateFormatter> = {
        let cache = NSCache<NSString, DateFormatter>(); cache.countLimit = 32; return cache
    }()
    private static func formatted(_ date: Date, pattern: String, calendar: Calendar, locale: Locale) -> String {
        let key = (locale.identifier + "|" + String(describing: calendar.identifier) + "|" + calendar.timeZone.identifier + "|" + pattern) as NSString
        if let formatter = formatters.object(forKey: key) { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = locale; formatter.dateFormat = pattern
        formatters.setObject(formatter, forKey: key)
        return formatter.string(from: date)
    }
    static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.locale) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? -1
        let language = locale.language.languageCode?.identifier ?? "en"
        let labels: [String]
        switch language {
        case "zh": labels = ["今天", "昨天", "前天"]
        case "ja": labels = ["今日", "昨日", "一昨日"]
        default: labels = ["Today", "Yesterday", "Two days ago"]
        }
        let time = formatted(date, pattern: "HH:mm", calendar: calendar, locale: locale)
        let label: String
        if (0...2).contains(days) { label = labels[days] }
        else if (3...6).contains(days) { label = formatted(date, pattern: "EEEE", calendar: calendar, locale: locale) }
        else { label = formatted(date, pattern: "yyyy-MM-dd", calendar: calendar, locale: locale) }
        return label + " " + time
    }
}
