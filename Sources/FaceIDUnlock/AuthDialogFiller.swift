import ApplicationServices
import FaceIDCore
import Foundation

enum FillOutcome: Equatable {
    enum Method: String, Equatable {
        /// Accessibility value write.
        case directValue
        /// Keystrokes posted to the dialog's process.
        case appKeys
        /// Keyboard-level typing while the dialog was frontmost with this box focused.
        case keyboard
    }
    case filled(Method)
    case failed(DialogProblem)
    /// The box turned out to want some other password (found after "Use Password…" was clicked).
    case skipped(reason: String)

    /// A fixed code for the score log, never text from the box.
    var logCode: String {
        switch self {
        case .filled(let method): return "filled:\(method.rawValue)"
        case .failed(let problem): return "failed:\(problem.rawValue)"
        case .skipped: return "skipped"
        }
    }
}

/// Puts the saved password into a scanned dialog's password box and leaves OK to the user.
/// Never presses OK, Return or Allow, except to approve Passwords' lock screen and System Settings' box (see `submit`);
/// never uses the clipboard, and reads only the box's length.
/// Blocks for up to a couple of seconds, so call it off the main thread.
struct AuthDialogFiller {
    let scanner: AuthDialogScanner
    private var system: any DialogSystem { scanner.system }

    private static let focusDelay: TimeInterval = 0.15
    private static let keyGap: TimeInterval = 0.01
    private static let settleDelay: TimeInterval = 0.15
    /// How long a keyboard-level key may take to show up in the box before typing stops.
    private static let keyLandingLimit: TimeInterval = 0.25
    private static let recognitionLimit: TimeInterval = 10

    /// Clicks "Use Password…" and waits up to 1.5 s for the password box to appear.
    /// Returns the refreshed dialog, whose decision is then `.fill` or `.skip`.
    func pressUsePassword(_ dialog: AuthDialog) throws -> AuthDialog {
        guard case .needsUsePasswordClick = dialog.decision, let button = dialog.usePasswordButton else {
            throw DialogProblem.noUsePasswordButton
        }
        let current = try scanner.refresh(dialog)
        guard current.dialogKey == dialog.dialogKey, let currentButton = current.usePasswordButton,
              CFEqual(currentButton, button) else { throw DialogProblem.changed }
        guard system.press(button) else { throw DialogProblem.usePasswordNotClicked }
        let deadline = system.uptime() + 1.5
        while system.uptime() < deadline {
            system.pause(0.1)
            let next: AuthDialog
            do { next = try scanner.refresh(dialog) } catch let problem as DialogProblem where problem == .closed || problem == .unverified {
                throw problem
            } catch { continue }
            switch next.decision {
            case .fill, .skip: return next
            case .needsUsePasswordClick, .none: continue
            }
        }
        throw DialogProblem.fieldDidNotAppear
    }

    /// Approves the two boxes only the user's own action can raise, once the box holds exactly the password and still
    /// has keyboard focus (Tim's decisions, 2026-10-30): Return on Passwords' lock screen, which has no button, and
    /// System Settings' Unlock or Modify Settings. Boxes any program can raise (admin rights, keychain items, the
    /// general Touch ID box) wait for the user's own click.
    func submit(_ dialog: AuthDialog, password: [UInt8]) -> Bool {
        // Focus is checked last, right before the key or press: keys sent to Passwords itself don't reach its box
        // (tested live 2026-10-30), so its Return goes out at keyboard level, like its password.
        guard dialog.host.kind.isInsideAnApp, let field = dialog.field,
              !system.isRemoteControlled(),
              let text = String(bytes: password, encoding: .utf8),
              system.characterCount(field) == text.count,
              hasKeyboardFocus(field, pid: dialog.identity.pid) else { return false }
        switch dialog.host.kind {
        case .lockedApp:
            system.post(.returnKey, to: .keyboard)
            return true
        case .settingsSheet:
            guard let button = dialog.confirmButton, system.isEnabled(button) else { return false }
            return system.press(button)
        case .dialogWindow:
            return false
        }
    }

    /// Fills the dialog's single password box. `recognizedAt` is when the face matched, not when the scan began.
    func fill(_ dialog: AuthDialog, password: [UInt8], recognizedAt: Date) -> FillOutcome {
        guard case .fill(let method) = dialog.decision, let field = dialog.field else {
            return .failed(.cannotFill)
        }
        // A control character such as Return would submit the dialog when typed.
        guard let text = String(bytes: password, encoding: .utf8), !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return .failed(.unusablePassword)
        }
        do {
            let current = try scanner.refresh(dialog)
            guard current.dialogKey == dialog.dialogKey, current.decision == dialog.decision,
                  let currentField = current.field, CFEqual(currentField, field) else {
                return .failed(.changed)
            }
        } catch {
            return .failed(DialogProblem(error))
        }
        guard system.isEnabled(field), method != .directValue || system.isSettable(field) else {
            return .failed(.cannotFill)
        }
        guard let existing = system.characterCount(field) else { return .failed(.unreadable) }
        guard existing == 0 else { return .failed(.alreadyTyped) }
        let age = system.now().timeIntervalSince(recognizedAt)
        guard age >= 0, age < Self.recognitionLimit else { return .failed(.tooSlow) }
        // Checked again here, right before typing, as well as before the face check (decision L2).
        guard !system.isRemoteControlled() else { return .failed(.screenSharing) }
        switch method {
        case .directValue: return write(text, into: field)
        case .typedKeys: return type(text, into: field, pid: dialog.identity.pid, appKeysFirst: true, mayActivate: true)
        case .keyboardKeys:
            // Passwords is filled and unlocked only while Tim has it in front himself, never brought forward.
            return type(text, into: field, pid: dialog.identity.pid, appKeysFirst: false,
                        mayActivate: dialog.host.kind != .lockedApp)
        }
    }

    private func write(_ text: String, into field: AXUIElement) -> FillOutcome {
        guard system.setValue(field, text) else { return .failed(.notAccepted) }
        if system.characterCount(field) == text.count { return .filled(.directValue) }
        let emptied = system.setValue(field, "") && system.characterCount(field) == 0
        return .failed(emptied ? .cleared : .notCleared)
    }

    /// Keys to the dialog's process first, unless they can't reach the box; the first key shows whether they
    /// arrive at all. If none arrive, keyboard-level typing after a probe space, re-checking before each key that
    /// the box still has focus and after each key that it landed in the box.
    private func type(_ text: String, into field: AXUIElement, pid: pid_t, appKeysFirst: Bool,
                      mayActivate: Bool) -> FillOutcome {
        let characters = text.map(String.init)
        // Settings may still be in front after the Mac password was typed there. Hand the front back to
        // the dialog, but never take it from another app.
        if mayActivate, system.frontmostPID() == system.ownPID { _ = system.activate(pid: pid) }
        _ = system.focus(field)
        system.pause(Self.focusDelay)
        // Never type while the dialog says another of its controls (such as a user name) has focus.
        if let focused = system.focusedElement(pid: pid), !isField(focused, field) {
            return .failed(.clickTheBox)
        }
        if appKeysFirst {
            system.post(.text(characters[0]), to: .app(pid))
            system.pause(Self.settleDelay)
            if system.characterCount(field) != 0 {
                for character in characters.dropFirst() {
                    system.pause(Self.keyGap)
                    system.post(.text(character), to: .app(pid))
                }
                return verify(text, in: field, route: .app(pid), method: .appKeys, pid: pid)
            }
        }
        // A panel such as Spotlight can hold the keyboard while the dialog is in front and says the box has focus,
        // and nothing this app can read shows it (the system-wide focus query fails on macOS 27). So the first
        // keyboard-level key is a space, cleared again once it lands: a key that goes astray is never part of the
        // password.
        guard hasKeyboardFocus(field, pid: pid) else { return .failed(.clickTheBox) }
        system.post(.text(" "), to: .keyboard)
        guard let probed = count(of: field, changingFrom: 0) else { return .failed(.keyMissed) }
        if probed == 0 { return .failed(.firstKeyMissed) }
        guard clear(field, route: .keyboard, pid: pid) else { return .failed(.notCleared) }
        // More than the space arrived, so someone else is typing in the box.
        guard probed == 1 else { return .failed(.cleared) }
        for (index, character) in characters.enumerated() {
            guard hasKeyboardFocus(field, pid: pid) else { return .failed(index == 0 ? .clickTheBox : .focusLost) }
            system.post(.text(character), to: .keyboard)
            // Keyboard-level keys go wherever keyboard focus really is. A key that doesn't show up in the box
            // may have gone to another window, so nothing more is typed there, not even a clearing key.
            let landed = count(of: field, changingFrom: index)
            if landed == index + 1 { continue }
            // Nothing went in: the box is still empty, so there is nothing to clear.
            if index == 0, landed == 0 { return .failed(.firstKeyMissed) }
            guard let landed, landed > index + 1 else { return .failed(.keyMissed) }
            // Extra characters arrived: keys are landing in the box, so clear it by the same route.
            return .failed(clear(field, route: .keyboard, pid: pid) ? .cleared : .notCleared)
        }
        return verify(text, in: field, route: .keyboard, method: .keyboard, pid: pid)
    }

    /// The box's length once it differs from `before`, waiting up to `keyLandingLimit`.
    private func count(of field: AXUIElement, changingFrom before: Int) -> Int? {
        let deadline = system.uptime() + Self.keyLandingLimit
        var count: Int?
        repeat {
            system.pause(Self.keyGap)
            count = system.characterCount(field)
        } while count == before && system.uptime() < deadline
        return count
    }

    private func verify(_ text: String, in field: AXUIElement, route: DialogKeyRoute,
                        method: FillOutcome.Method, pid: pid_t) -> FillOutcome {
        system.pause(Self.settleDelay)
        if system.characterCount(field) == text.count { return .filled(method) }
        return .failed(clear(field, route: route, pid: pid) ? .cleared : .notCleared)
    }

    /// One Delete per character, by the same route; the caret is at the end, since the app typed into an empty box.
    /// No Select All: Command plus the A key's position is Command-Q on an AZERTY keyboard. Keyboard-level keys only
    /// while the box keeps focus.
    private func clear(_ field: AXUIElement, route: DialogKeyRoute, pid: pid_t) -> Bool {
        let deletes = min(max(system.characterCount(field) ?? 1, 1), 256)
        for _ in 0..<deletes {
            if route == .keyboard, !hasKeyboardFocus(field, pid: pid) { return false }
            system.post(.deleteBackward, to: route)
            system.pause(Self.keyGap)
        }
        system.pause(Self.settleDelay)
        return system.characterCount(field) == 0
    }

    private func hasKeyboardFocus(_ field: AXUIElement, pid: pid_t) -> Bool {
        guard system.frontmostPID() == pid, let focused = system.focusedElement(pid: pid) else { return false }
        return isField(focused, field)
    }

    /// Whether the host's focused element is this box. System Settings' box belongs to a settings extension; in case
    /// the host's reference to it doesn't compare equal, a password field of that extension must have the host's
    /// focus and the extension must itself report this box as focused (seen live 2026-10-30).
    private func isField(_ focused: AXUIElement, _ field: AXUIElement) -> Bool {
        if CFEqual(focused, field) { return true }
        guard let owner = system.pid(of: field), system.pid(of: focused) == owner,
              (try? system.string(focused, kAXSubroleAttribute, required: false)) == kAXSecureTextFieldSubrole,
              let ownFocus = system.focusedElement(pid: owner) else { return false }
        return CFEqual(ownFocus, field)
    }
}
