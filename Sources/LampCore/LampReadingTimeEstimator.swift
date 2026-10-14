import Foundation

public enum LampReadingTimeEstimator {
    public static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    public static func minutes(wordCount: Int, wordsPerMinute: Double) -> Int {
        guard wordCount > 0 else { return 0 }
        // Settings can come from an older database or another device, bypassing
        // the settings slider. Never convert infinity or NaN to an integer.
        let rate = wordsPerMinute.isFinite ? max(wordsPerMinute, 1) : 1
        let minutes = ceil(Double(wordCount) / rate)
        return minutes >= Double(Int.max) ? Int.max : max(Int(minutes), 1)
    }

    public static func minutes(wordCount: Int, wordsPerMinute: Int) -> Int {
        minutes(wordCount: wordCount, wordsPerMinute: Double(wordsPerMinute))
    }

    public static func description(wordCount: Int, wordsPerMinute: Int) -> String {
        let minutes = minutes(wordCount: wordCount, wordsPerMinute: wordsPerMinute)
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }
}
