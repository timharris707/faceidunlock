import Foundation

/// What the scanner saw in one dialog window. Holds no password and no secure field contents.
public struct DialogFacts: Equatable, Sendable {
    public var hostBundleID: String
    public var staticTexts: [String]
    public var secureFieldCount: Int
    /// Values of plain text fields, such as the user name field in an admin dialog.
    public var plainFieldValues: [String]
    public var hasUsePasswordButton: Bool
    /// True when the secure field sits under a SwiftUI hosting view.
    public var secureFieldInHostingView: Bool
    public var userName: String
    public var fullUserName: String

    public init(hostBundleID: String, staticTexts: [String] = [], secureFieldCount: Int = 0,
                plainFieldValues: [String] = [], hasUsePasswordButton: Bool = false,
                secureFieldInHostingView: Bool = false, userName: String, fullUserName: String) {
        self.hostBundleID = hostBundleID
        self.staticTexts = staticTexts
        self.secureFieldCount = secureFieldCount
        self.plainFieldValues = plainFieldValues
        self.hasUsePasswordButton = hasUsePasswordButton
        self.secureFieldInHostingView = secureFieldInHostingView
        self.userName = userName
        self.fullUserName = fullUserName
    }
}

public enum DialogDecision: Equatable, Sendable {
    public enum FillMethod: Equatable, Sendable {
        /// Accessibility value write. AppKit dialogs accept it.
        case directValue
        /// Typed keystrokes. SwiftUI dialogs ignore value writes.
        case typedKeys
        /// Keyboard-level keystrokes only. System Settings' box keeps its field in another process,
        /// which keys posted to an app never reach (tested 2026-10-30).
        case keyboardKeys
    }
    case fill(method: FillMethod)
    case needsUsePasswordClick
    case skip(reason: String)
    case none
}

/// Decides whether a macOS password dialog should get the Mac login password, and how.
public enum DialogPolicy {
    public struct Host: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Every window of the process is a dialog.
            case dialogWindow
            /// System Settings: the box is a sheet on its window, and the password field inside it belongs to
            /// the settings extension that asked (Users & Groups, Privacy & Security).
            case settingsSheet
            /// An app whose own window turns into a lock screen asking for the Mac password (Passwords).
            case lockedApp

            /// The box lives inside a regular app, whose windows are mostly something else and can be large or slow
            /// to read; one that is too large is passed over instead of failing the scan.
            public var isInsideAnApp: Bool { self != .dialogWindow }
        }
        public let identifier: String
        public let executablePath: String
        public var kind = Kind.dialogWindow

        /// The random glance follows the face check here (decision L4): every SecurityAgent box (admin and keychain
        /// prompts, which any program can raise) and Passwords' lock screen. Not System Settings' sheets or
        /// coreautha's general box.
        public var needsGlance: Bool { identifier == "com.apple.SecurityAgent" || kind == .lockedApp }
    }

    /// The Apple processes that draw password dialogs on macOS 27.
    public static let hosts = [
        Host(identifier: "com.apple.SecurityAgent",
             executablePath: "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent"),
        Host(identifier: "com.apple.LocalAuthentication.UIAgent",
             executablePath: "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreautha.bundle/Contents/MacOS/coreautha"),
        Host(identifier: "com.apple.systempreferences",
             executablePath: "/System/Applications/System Settings.app/Contents/MacOS/System Settings",
             kind: .settingsSheet),
        Host(identifier: "com.apple.Passwords",
             executablePath: "/System/Applications/Passwords.app/Contents/MacOS/Passwords",
             kind: .lockedApp)
    ]

    /// How System Settings' Mac password box states its request: "<pane> is trying to unlock system settings." and
    /// the variants in the settings extensions' own strings. Each ending is longer than a Wi-Fi network name can be.
    static let settingsRequestEndings = [" is trying to unlock system settings.", " is trying to modify your system settings.",
                                         " is trying to modify your account settings."]

    /// The buttons that approve System Settings' Mac password box, recorded live 2026-10-30. The app presses one of
    /// these itself once the password is in (Tim's decision); a box with any other button waits for his click.
    public static let settingsConfirmTitles: Set<String> = ["Unlock", "Modify Settings"]

    /// Where Apple's own System Settings extensions live. Third-party settings panes run elsewhere
    /// (PreferencePanes' legacyLoader), so a password field from them is never trusted.
    public static let settingsExtensionsFolder = "/System/Library/ExtensionKit/Extensions/"

    public static func host(for bundleID: String?) -> Host? {
        hosts.first { $0.identifier == bundleID }
    }

    /// One password box gets filled; a Touch ID dialog first needs "Use Password…";
    /// boxes that want some other password are skipped with a reason.
    public static func decide(_ facts: DialogFacts) -> DialogDecision {
        guard let host = host(for: facts.hostBundleID),
              facts.secureFieldCount > 0 || facts.hasUsePasswordButton else { return .none }
        // System Settings' other sheets ask for Wi-Fi, account and sharing passwords, and some show names that
        // others choose (networks, servers) and a user name field. Its Mac password box has one whole line of the
        // form "<pane> is trying to unlock system settings." and shows the user's name above the field.
        if host.kind == .settingsSheet {
            guard facts.staticTexts.contains(where: isSettingsRequest) else { return .none }
            if facts.secureFieldCount > 0,
               !facts.plainFieldValues.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return .none
            }
        }
        // Passwords' lock screen, recorded live 2026-10-30. Unlocked, its window shows saved passwords in fields of
        // their own, and logins whose names others can choose, so only a window holding exactly the lock screen's
        // lines and no other fields counts, and its password field only when the screen names this user.
        if host.kind == .lockedApp {
            let named = [facts.fullUserName, facts.userName].filter { !$0.isEmpty }
                .map { "Enter the password for the user “\($0)” to unlock." }
            let allowed = Set(["Passwords Is Locked", "Touch ID or enter your password to continue."] + named)
            let lines = facts.staticTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard lines.contains("Passwords Is Locked"), lines.allSatisfy(allowed.contains),
                  facts.plainFieldValues.isEmpty else { return .none }
            if facts.secureFieldCount > 0, !lines.contains(where: named.contains) { return .none }
        }
        if facts.secureFieldCount > 1 {
            return .skip(reason: "This box asks for more than one password.")
        }
        if facts.plainFieldValues.contains(where: { isOtherUser($0, facts) }) {
            return .skip(reason: "This box asks for another user's password.")
        }
        if let keychain = otherKeychain(in: facts.staticTexts) {
            return .skip(reason: "This box asks for the “\(keychain)” keychain password.")
        }
        if facts.secureFieldCount == 1 {
            if host.kind.isInsideAnApp { return .fill(method: .keyboardKeys) }
            return .fill(method: facts.secureFieldInHostingView ? .typedKeys : .directValue)
        }
        return .needsUsePasswordClick
    }

    /// The dialog's first line of text, on one line and at most 80 characters, for the status bar.
    public static func requesterLine(_ staticTexts: [String]) -> String? {
        let lines = staticTexts.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        guard let first = lines.first(where: { !$0.isEmpty }) else { return nil }
        return first.count <= 80 ? first : String(first.prefix(79)) + "…"
    }

    /// Matches "Use Password…" and its plain-dots spelling, ignoring case.
    public static func isUsePasswordTitle(_ title: String?) -> Bool {
        guard var text = title?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        for suffix in ["…", "..."] where text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        return text == "use password"
    }

    private static func isSettingsRequest(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return settingsRequestEndings.contains { line.hasSuffix($0) && line.count > $0.count }
    }

    private static func isOtherUser(_ value: String, _ facts: DialogFacts) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return ![facts.userName, facts.fullUserName].contains {
            !$0.isEmpty && $0.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// The first keychain named in the texts ("the “System” keychain") other than "login".
    private static func otherKeychain(in texts: [String]) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"[“"]([^”"]+)[”"]\s+keychain"#, options: .caseInsensitive)
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[nameRange])
                if name.caseInsensitiveCompare("login") != .orderedSame { return name }
            }
        }
        return nil
    }
}
