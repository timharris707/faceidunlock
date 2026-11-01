import ApplicationServices
import FaceIDCore
import Foundation

/// Signed identity of the process that drew a dialog. Equal only for the same live process instance.
struct DialogHostIdentity: Equatable {
    let pid: pid_t
    let processInstance: ProcessInstance
    let executablePath: String
    let signingIdentifier: String
    let codeHash: Data
}

/// An opaque snapshot of one password dialog. Holds element references, never a field's contents.
struct AuthDialog {
    let identity: DialogHostIdentity
    let host: DialogPolicy.Host
    let window: AXUIElement
    /// The single password box, when there is exactly one.
    let field: AXUIElement?
    let usePasswordButton: AXUIElement?
    /// System Settings only: the box's Unlock or Modify Settings button.
    let confirmButton: AXUIElement?
    let decision: DialogDecision
    /// Short "who is asking" line for the status bar.
    let requester: String?
    /// Same for the same dialog across scans: process instance, window and first line of text.
    let dialogKey: String
    let scannedAt: Date
}

enum AuthDialogScan {
    /// Confirmed: no password dialog is open.
    case none
    case dialog(AuthDialog)
    /// `boxSeen`: a password field or a "Use Password…" button was seen anywhere in the parts of the hosts'
    /// windows that could be read, so a password box may be on screen. Other windows a host keeps open don't count.
    case failed(DialogProblem, boxSeen: Bool)
}

/// Why a password box couldn't be read or filled. The raw value is a fixed code for the score log;
/// the description is for the bar. Neither holds any text from the box.
enum DialogProblem: String, Error, LocalizedError {
    case noPermission, unverified, unreadable, changed, closed, timeout, tooLarge, several
    case noUsePasswordButton, usePasswordNotClicked, fieldDidNotAppear
    case cannotFill, unusablePassword, alreadyTyped, tooSlow, notAccepted, cleared, notCleared
    case clickTheBox, focusLost, keyMissed, firstKeyMissed, screenSharing

    var errorDescription: String? {
        switch self {
        case .noPermission: return "Face ID Unlock needs permission to fill password boxes."
        case .unverified: return "Can't confirm this password box comes from macOS."
        case .unreadable: return "Can't read the password box."
        case .changed: return "The password box changed."
        case .closed: return "The password box closed."
        case .timeout: return "Checking the password box took too long."
        case .tooLarge: return "This password box is too large to check safely."
        case .several: return "Several password boxes are open"
        case .noUsePasswordButton: return "There's no Use Password button to click."
        case .usePasswordNotClicked: return "Couldn't click Use Password."
        case .fieldDidNotAppear: return "The password box didn't appear."
        case .cannotFill: return "This password box can't be filled."
        case .unusablePassword: return "The saved password can't be used."
        case .alreadyTyped: return "You've started typing, so the box was left alone."
        case .tooSlow: return "That took too long. Try again."
        case .notAccepted: return "macOS didn't accept the password."
        case .cleared: return "The password didn't go in fully, so the box was cleared."
        case .notCleared: return "The password didn't go in fully. Clear the box before you type."
        case .clickTheBox: return "Click the password box, then try again."
        case .focusLost: return "Typing stopped when the password box lost focus. Clear it before you type."
        case .keyMissed: return "A key didn't reach the password box, so typing stopped. Clear it before you type."
        case .firstKeyMissed: return "The password wasn't filled. Click the password box, then try again."
        case .screenSharing: return "Screen sharing is on, so the password wasn't filled."
        }
    }

    init(_ error: Error) { self = error as? DialogProblem ?? .unreadable }
}

/// Finds the one password dialog drawn by a verified Apple host. Blocks on Accessibility for up to
/// about 1.25 s per host, so call it off the main thread.
struct AuthDialogScanner {
    let system: any DialogSystem
    let userName: String
    let fullUserName: String

    init(system: any DialogSystem = LiveDialogSystem(),
         userName: String = NSUserName(), fullUserName: String = NSFullUserName()) {
        self.system = system
        self.userName = userName
        self.fullUserName = fullUserName
    }

    func scan() -> AuthDialogScan {
        guard system.isTrusted() else { return .failed(.noPermission, boxSeen: false) }
        var found: [AuthDialog] = []
        var failure: DialogProblem?, appFailure: DialogProblem?
        var boxSeen = false
        for app in system.runningApps() {
            guard let host = DialogPolicy.host(for: app.bundleID) else { continue }
            // Passwords locks itself in the background too; its lock screen is a box only while it is in front.
            if host.kind == .lockedApp, system.frontmostPID() != app.pid { continue }
            do {
                found += try dialogs(pid: app.pid, host: host, boxSeen: &boxSeen).filter {
                    if case .none = $0.decision { return false }
                    return true
                }
            } catch where host.kind.isInsideAnApp {
                appFailure = DialogProblem(error)
            } catch {
                failure = failure ?? DialogProblem(error)
            }
        }
        if found.count > 1 { return .failed(.several, boxSeen: true) }
        // A host that couldn't be read might hide a second dialog, so don't trust a lone match. The exception is a
        // regular app (System Settings, Passwords), open far more often: a window there that can't be read can't take
        // a password written or typed into another host's verified box, so it only blocks its own boxes.
        if let failure { return .failed(failure, boxSeen: boxSeen) }
        if let appFailure, found.isEmpty { return .failed(appFailure, boxSeen: boxSeen) }
        guard let dialog = found.first else { return .none }
        return .dialog(dialog)
    }

    /// Re-reads the same window or sheet after re-verifying its host. Throws if the host changed or the window closed;
    /// a host that has exited took its window with it, so that is `closed` too.
    func refresh(_ dialog: AuthDialog) throws -> AuthDialog {
        do { return try reread(dialog) } catch {
            throw system.isRunning(dialog.identity.processInstance) ? error : DialogProblem.closed
        }
    }

    private func reread(_ dialog: AuthDialog) throws -> AuthDialog {
        guard system.isTrusted() else { throw DialogProblem.noPermission }
        try confirm(dialog.identity, host: dialog.host)
        guard try containers(pid: dialog.identity.pid, host: dialog.host).contains(where: { CFEqual($0, dialog.window) }) else {
            throw DialogProblem.closed
        }
        var budget = Budget(nodes: 1, deadline: system.uptime() + Self.timeLimit)
        var boxSeen = false
        guard let current = try inspect(window: dialog.window, identity: dialog.identity, host: dialog.host,
                                        budget: &budget, boxSeen: &boxSeen) else {
            throw DialogProblem.changed
        }
        try confirm(dialog.identity, host: dialog.host)
        return current
    }

    private static let maximumWindows = 16
    private static let maximumNodes = 256
    /// Passwords' lock screen has 12 elements; its unlocked window has far more and is read every half second.
    private static let maximumLockScreenNodes = 48
    private static let timeLimit: TimeInterval = 1.25

    private struct Budget {
        var nodes: Int
        let deadline: TimeInterval
    }

    /// Every window of one host (for System Settings, every sheet), read between two identity checks of the
    /// same process instance.
    /// `boxSeen` is set once a password field or "Use Password…" button turns up in any window. A window that
    /// can't be read doesn't stop the others being read, but the first failure is thrown at the end.
    private func dialogs(pid: pid_t, host: DialogPolicy.Host, boxSeen: inout Bool) throws -> [AuthDialog] {
        let identity = try system.identity(pid: pid, host: host)
        let windows = try containers(pid: pid, host: host)
        var found: [AuthDialog] = []
        var failure: Error?
        var budget = Budget(nodes: windows.count, deadline: system.uptime() + Self.timeLimit)
        for window in windows {
            // Each sheet or window inside an app gets its own count. Its password box has about ten elements, so
            // one too large to read is something else, not a failure. Passwords' unlocked window is also slow to
            // walk and holds nothing to fill, so anything short of a verified lock screen there is passed over.
            if host.kind.isInsideAnApp { budget.nodes = 1 }
            var seenHere = false
            defer { boxSeen = boxSeen || seenHere }
            do {
                if let dialog = try inspect(window: window, identity: identity, host: host, budget: &budget,
                                            boxSeen: &seenHere) {
                    found.append(dialog)
                }
            } catch DialogProblem.tooLarge where host.kind.isInsideAnApp {
                seenHere = false
                continue
            } catch let problem as DialogProblem where host.kind == .lockedApp && problem != .unverified && !seenHere {
                continue // Some other Passwords window, not a lock screen that went unreadable for a moment.
            } catch let problem as DialogProblem where problem == .timeout || problem == .tooLarge {
                throw problem
            } catch {
                failure = failure ?? error
            }
        }
        try confirm(identity, host: host)
        if let failure { throw failure }
        return found
    }

    /// What can be a password box: each window of a dialog host, or each sheet on System Settings' windows.
    private func containers(pid: pid_t, host: DialogPolicy.Host) throws -> [AXUIElement] {
        guard let windows = try system.elements(system.application(pid: pid), kAXWindowsAttribute,
                                                maximum: Self.maximumWindows) else {
            throw DialogProblem.unreadable
        }
        guard host.kind == .settingsSheet else { return windows }
        return try windows.flatMap { window in
            try (system.elements(window, kAXChildrenAttribute, maximum: Self.maximumNodes) ?? []).filter {
                try system.string($0, kAXRoleAttribute, required: false) == kAXSheetRole
            }
        }
    }

    private func confirm(_ identity: DialogHostIdentity, host: DialogPolicy.Host) throws {
        guard try system.identity(pid: identity.pid, host: host) == identity else {
            throw DialogProblem.changed
        }
    }

    /// Walks one window in reading order, collecting texts, fields and the "Use Password…" button.
    /// Never reads a secure field's value. An element that can't be read is skipped with its children, so a
    /// password box later in the window is still seen; the first such failure is then thrown, so a window
    /// read only in part is never returned as a dialog. Running out of time or elements stops at once.
    private func inspect(window: AXUIElement, identity: DialogHostIdentity, host: DialogPolicy.Host,
                         budget: inout Budget, boxSeen: inout Bool) throws -> AuthDialog? {
        let containerRole = host.kind == .settingsSheet ? kAXSheetRole : kAXWindowRole
        guard try system.string(window, kAXRoleAttribute, required: true) == containerRole else { return nil }
        var texts: [String] = []
        var plainValues: [String] = []
        var secureFields: [(element: AXUIElement, inHostingView: Bool)] = []
        var usePassword: AXUIElement?, confirm: AXUIElement?
        var visited: [AXUIElement] = []
        var failure: Error?
        var stack: [(element: AXUIElement, inHostingView: Bool)] = [(window, false)]
        while let (node, inHostingView) = stack.popLast() {
            guard system.uptime() < budget.deadline else {
                throw DialogProblem.timeout
            }
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            visited.append(node)
            let subrole: String?, children: [AXUIElement]?
            do {
                let role = try system.string(node, kAXRoleAttribute, required: true)
                subrole = try system.string(node, kAXSubroleAttribute, required: false)
                if subrole == kAXSecureTextFieldSubrole {
                    secureFields.append((node, inHostingView))
                    boxSeen = true
                } else if role == kAXTextFieldRole {
                    plainValues.append(try system.string(node, kAXValueAttribute, required: false) ?? "")
                } else if role == kAXStaticTextRole {
                    if let text = try system.string(node, kAXValueAttribute, required: false) { texts.append(text) }
                } else if role == kAXButtonRole {
                    let title = try system.string(node, kAXTitleAttribute, required: false)
                        ?? system.string(node, kAXDescriptionAttribute, required: false)
                    if usePassword == nil, DialogPolicy.isUsePasswordTitle(title) {
                        usePassword = node
                        boxSeen = true
                    } else if host.kind == .settingsSheet, confirm == nil, let title,
                              DialogPolicy.settingsConfirmTitles.contains(title) {
                        confirm = node
                    }
                }
                children = try system.elements(node, kAXChildrenAttribute, maximum: Self.maximumNodes)
            } catch {
                failure = failure ?? error
                continue
            }
            guard let children else { continue }
            budget.nodes += children.count
            guard budget.nodes <= (host.kind == .lockedApp ? Self.maximumLockScreenNodes : Self.maximumNodes) else {
                throw DialogProblem.tooLarge
            }
            let hosting = inHostingView || subrole == "AXHostingView"
            stack.append(contentsOf: children.reversed().map { ($0, hosting) })
        }
        if let failure { throw failure }
        let facts = DialogFacts(hostBundleID: host.identifier, staticTexts: texts,
                                secureFieldCount: secureFields.count, plainFieldValues: plainValues,
                                hasUsePasswordButton: usePassword != nil,
                                secureFieldInHostingView: secureFields.first?.inHostingView ?? false,
                                userName: userName, fullUserName: fullUserName)
        let decision = DialogPolicy.decide(facts)
        let field = secureFields.count == 1 ? secureFields[0].element : nil
        // Inside an app the field must be the app's own; in System Settings it comes from another process, and only
        // Apple's own settings extensions count.
        if host.kind.isInsideAnApp, case .fill = decision, let field {
            guard let owner = system.pid(of: field), owner == identity.pid
                    || (host.kind == .settingsSheet && system.isSettingsExtension(pid: owner)) else {
                throw DialogProblem.unverified
            }
        }
        let firstText = texts.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let instance = identity.processInstance
        return AuthDialog(identity: identity, host: host, window: window, field: field,
                          usePasswordButton: usePassword, confirmButton: confirm, decision: decision,
                          requester: DialogPolicy.requesterLine(texts),
                          dialogKey: "\(identity.pid)-\(instance.startSeconds).\(instance.startMicroseconds)"
                              + "-\(CFHash(window))-\(firstText)",
                          scannedAt: system.now())
    }
}
