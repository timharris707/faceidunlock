import Foundation

/// Why face unlock stopped filling until the Mac password is typed in Settings (decisions L1 and L2).
enum Lockout: Equatable {
    /// Three face checks in a row saw a face that didn't match.
    case misses
    /// A camera that wasn't trusted at face setup appeared, or two cameras share one ID.
    case newCamera(name: String)

    /// A fixed code for the score log.
    var logCode: String {
        switch self {
        case .misses: return "misses"
        case .newCamera: return "newCamera"
        }
    }
}

/// The two preferences calls the app makes: UserDefaults in the app, a dictionary in tests.
protocol PreferenceStore: AnyObject {
    func object(forKey key: String) -> Any?
    /// nil removes the value.
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStore {}

/// The misses in a row, the lockout and the trusted cameras, kept in the app's preferences so that
/// quitting and relaunching resets none of them.
struct LockoutStore {
    let defaults: any PreferenceStore

    var misses: Int {
        get { defaults.object(forKey: "missesInARow") as? Int ?? 0 }
        nonmutating set { defaults.set(newValue, forKey: "missesInARow") }
    }

    var lockout: Lockout? {
        get {
            switch defaults.object(forKey: "pausedFor") as? String {
            case "misses": return .misses
            case "newCamera": return .newCamera(name: defaults.object(forKey: "pausedForCamera") as? String ?? "")
            default: return nil
            }
        }
        nonmutating set {
            defaults.set(newValue?.logCode, forKey: "pausedFor")
            if case .newCamera(let name) = newValue { defaults.set(name, forKey: "pausedForCamera") } else {
                defaults.set(nil, forKey: "pausedForCamera")
                defaults.set(nil, forKey: "pausedForCameraID")
            }
        }
    }

    /// The ID of the camera a new-camera pause names. Typing the password trusts it even if it has gone since.
    var pausedCamera: String? {
        get { defaults.object(forKey: "pausedForCameraID") as? String }
        nonmutating set { defaults.set(newValue, forKey: "pausedForCameraID") }
    }

    /// Camera IDs trusted at face setup or when the password was typed; nil before any were.
    var trustedCameras: Set<String>? {
        (defaults.object(forKey: "trustedCameras") as? [String]).map(Set.init)
    }

    /// Adds these camera IDs. Earlier ones stay trusted, so a camera that comes and goes is fine.
    func trust(_ ids: [String]) {
        defaults.set((trustedCameras ?? []).union(ids).sorted(), forKey: "trustedCameras")
    }

    /// The first camera that was never trusted, else the second of two that share one ID.
    static func newCamera(in devices: [CameraDevice], trusted: Set<String>) -> CameraDevice? {
        devices.first { !trusted.contains($0.id) } ?? sharedID(in: devices)
    }

    /// The second of two cameras that share one ID. Typing the password can't make that safe.
    static func sharedID(in devices: [CameraDevice]) -> CameraDevice? {
        var seen = Set<String>()
        return devices.first { !seen.insert($0.id).inserted }
    }
}
