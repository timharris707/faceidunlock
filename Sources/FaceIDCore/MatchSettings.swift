import Foundation

/// Every recognition and face-setup tunable, in one place. Times are seconds; angles are Vision radians.
public enum MatchSettings {
    /// Cosine a frame needs against its closest saved sample. 0.70, the owner's call on 2026-10-30 after his home
    /// test: someone logging in looks right at the camera, as with Face ID on the iPhone.
    public static let threshold: Float = 0.70
    /// No tuning may go below this.
    public static let minimumThreshold: Float = 0.40
    /// Matching frames needed, all within `matchWindow`.
    public static let requiredMatches = 3
    public static let matchWindow: TimeInterval = 1.0
    /// Camera warm-up: settled exposure counts after the minimum; the maximum ends warm-up regardless.
    public static let warmUpMinimum: TimeInterval = 0.3
    public static let warmUpMaximum: TimeInterval = 1.0
    /// Measured from the end of warm-up.
    public static let checkTimeout: TimeInterval = 5.0
    public static let setupTimeout: TimeInterval = 12.0
    /// Face setup keeps this many samples per pose, at least `minimumSampleSpacing` apart.
    public static let samplesPerPose = 3
    public static let minimumSampleSpacing: TimeInterval = 0.1
    /// Setup angles are measured from the resting angle: the median of the last `restFrames` face frames
    /// while they lie within `restSpread` of each other, taken until the straight-ahead samples are complete.
    public static let restFrames = 3
    public static let restSpread = 0.10
    /// A resting angle beyond this means the camera sees the person from the side.
    public static let maximumRestYaw = 0.45
    /// Frames turned further than this from the camera are never used.
    public static let maximumYaw = 0.75
    /// Pose bins, relative to the resting angle.
    public static let centerYaw = 0.10
    public static let sideYawMin = 0.15
    public static let sideYawMax = 0.45
    public static let maximumRoll = 0.35
    /// Face setup drops samples less similar than this to the typical straight-ahead sample.
    public static let outlierCosine: Float = 0.35
    /// How many recent frames the on-screen hint looks at.
    public static let hintFrames = 5
    /// A matching frame counts only if the photo/screen detector, when it gave a score, rated it at least this real.
    public static let minimumReal: Float = 0.60

    /// The glance (decision L4): within `glanceTimeout` of asking, a frame turned at least `glanceYaw` from the
    /// resting angle the asked way, still matching at `glanceThreshold` (turned faces score lower).
    public static let glanceTimeout: TimeInterval = 3.0
    public static let glanceYaw = 0.20
    public static let glanceThreshold: Float = 0.45
    /// The sign of the yaw change when the person turns to their own left. Confirmed live 2026-10-30 on the Studio
    /// Display camera (unmirrored frames): six Home Test glances all passed, left turns +0.23 to +0.34, right turns
    /// -0.24 to -0.52. A camera that delivers mirrored frames would need the opposite sign.
    public static let leftYawSign = 1.0
    /// The glance's flatness score (`GlanceRecord.flatness`) a passing turn will need. Nil: watch-only, logged and
    /// never blocking. Set it only after the owner's own glances and tilted-photo tries in Home Test show where it
    /// belongs; nothing reads it until then.
    public static let flatnessLine: Double? = nil

    /// A tuned threshold held at or above the minimum; a non-finite value gives the default.
    public static func clampedThreshold(_ value: Float) -> Float {
        value.isFinite ? max(value, minimumThreshold) : threshold
    }
}
