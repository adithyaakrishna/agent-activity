import Foundation

enum ActivityFormatters {
  static let dateLabel: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEEE, MMM d"
    return formatter
  }()

  static let dateKey: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  static let month: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "MMM"
    return formatter
  }()

  static func tokens(_ value: Int) -> String {
    if value >= 1_000_000 {
      let millions = Double(value) / 1_000_000
      return millions.rounded() == millions
        ? "\(Int(millions))m" : String(format: "%.1fm", millions)
    }
    return "\(Int((Double(value) / 1_000).rounded()))k"
  }
}
