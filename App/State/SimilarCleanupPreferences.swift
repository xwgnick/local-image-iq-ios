import CoreFoundation
import Foundation

/// Store integer slider ticks only. Do not let UserDefaults' convenience getters
/// coerce strings, booleans, fractional numbers or non-finite values into settings.
/// A new policy default applies only when no valid saved tick exists. Keep v1
/// (including 80) unchanged; initialization and draft edits never rewrite it.
enum SimilarCleanupPreferences {
    static let thresholdKey = "similarCleanupThreshold.v1"

    static func threshold(in preferences: UserDefaults?) -> Float {
        guard let number = preferences?.object(forKey: thresholdKey) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              number.doubleValue >= 50, number.doubleValue <= 99 else {
            return SimilarPhotoGroupingPolicy.defaultThreshold
        }
        return Float(number.intValue) / 100
    }

    static func save(threshold: Float, in preferences: UserDefaults?) {
        guard threshold.isFinite, SimilarPhotoGroupingPolicy.thresholdRange.contains(threshold) else { return }
        let tick = Int((threshold * 100).rounded())
        guard (50...99).contains(tick), Float(tick) / 100 == threshold else { return }
        preferences?.set(tick, forKey: thresholdKey)
    }
}