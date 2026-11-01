// Diagnostic probe used for the 2026-10-29 fill proof (docs/design/2026-10-overhaul-plan.md, Step 0).
// Build: swiftc -O scripts/auth-dialog-probe.swift -o /tmp/auth-probe. Needs Accessibility for the launching process.
// Modes: dump | fill <file> | press <title> | keys <file> | hidkeys <file> | seltext <file>. PROBE_HOSTS=a,b overrides hosts.
// Never prints secure field contents.
// Probe for macOS auth dialogs: dump structure, fill the single secure field, press a button.
// Usage: probe dump | probe fill <passwordFile> | probe press <buttonTitle>
import AppKit
import ApplicationServices

let hosts = ProcessInfo.processInfo.environment["PROBE_HOSTS"].map { $0.components(separatedBy: ",") } ?? ["SecurityAgent", "coreautha", "LocalAuthentication", "SecurityAgentHelper"]

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

func walk(_ e: AXUIElement, depth: Int = 0, visit: (AXUIElement, Int) -> Void) {
    visit(e, depth)
    if depth < 12 { for c in children(e) { walk(c, depth: depth + 1, visit: visit) } }
}

func hostApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { app in
        let id = app.bundleIdentifier ?? ""
        let name = app.executableURL?.lastPathComponent ?? ""
        return hosts.contains { id.localizedCaseInsensitiveContains($0) || name.localizedCaseInsensitiveContains($0) }
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? "dump"
var secureFields: [AXUIElement] = []
var buttons: [(String, AXUIElement)] = []

for app in hostApps() {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 0.5)
    let windows = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    print("APP \(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier) exe=\(app.executableURL?.path ?? "?") windows=\(windows.count)")
    for w in windows {
        walk(w) { el, d in
            let role = attr(el, kAXRoleAttribute) as? String ?? ""
            let sub = attr(el, kAXSubroleAttribute) as? String ?? ""
            let title = (attr(el, kAXTitleAttribute) as? String) ?? (attr(el, kAXDescriptionAttribute) as? String) ?? ""
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
            let isSecure = sub == "AXSecureTextField"
            // Never print secure field values; print static text values (dialog wording) only.
            let text = role == "AXStaticText" ? (attr(el, kAXValueAttribute) as? String ?? "") : ""
            if mode == "dump" {
                print(String(repeating: "  ", count: d) + "\(role)/\(sub) title=\"\(title)\" \(text.isEmpty ? "" : "text=\"\(text)\"") \(isSecure ? "secure settable=\(settable.boolValue) len=\((attr(el, kAXNumberOfCharactersAttribute) as? Int) ?? -1)" : "")")
            }
            if isSecure { secureFields.append(el) }
            if role == "AXButton" { buttons.append((title, el)); if mode == "dump" { print(String(repeating: "  ", count: d) + "  enabled=\((attr(el, kAXEnabledAttribute) as? Bool).map(String.init) ?? "?")") } }
        }
    }
}

switch mode {
case "fill":
    let pw = try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).trimmingCharacters(in: .newlines)
    guard secureFields.count == 1 else { print("FILL REFUSED: \(secureFields.count) secure fields"); exit(2) }
    let r = AXUIElementSetAttributeValue(secureFields[0], kAXValueAttribute as CFString, pw as CFString)
    let n = attr(secureFields[0], kAXNumberOfCharactersAttribute) as? Int ?? -1
    let v = (attr(secureFields[0], kAXValueAttribute) as? String)?.count ?? -1
    print("FILL result=\(r.rawValue) chars-after=\(n) valuelen-after=\(v) expected=\(pw.count)")
case "press":
    let want = CommandLine.arguments[2]
    guard let b = buttons.first(where: { $0.0 == want }) else { print("NO BUTTON \(want); have \(buttons.map { $0.0 })"); exit(3) }
    print("PRESS \(want) result=\(AXUIElementPerformAction(b.1, kAXPressAction as CFString).rawValue)")
case "hidkeys":
    let pw = try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).trimmingCharacters(in: .newlines)
    guard secureFields.count == 1 else { print("REFUSED: \(secureFields.count) secure fields"); exit(2) }
    let f = AXUIElementSetAttributeValue(secureFields[0], kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    var hostPid: pid_t = 0
    AXUIElementGetPid(secureFields[0], &hostPid)
    let appAX = AXUIElementCreateApplication(hostPid)
    let focused = attr(appAX, kAXFocusedUIElementAttribute)
    let front = NSWorkspace.shared.frontmostApplication
    let same = (focused.map { CFEqual($0, secureFields[0]) } ?? false) && front?.processIdentifier == hostPid
    print("HID focus-set=\(f.rawValue) app-focus-is-field=\(focused.map { CFEqual($0, secureFields[0]) } ?? false) frontmost=\(front?.bundleIdentifier ?? "?")")
    guard same else { print("REFUSED: field does not have keyboard focus"); exit(4) }
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in pw.utf16 {
        var c = ch
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
            e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            e.post(tap: .cghidEventTap)
        }
        usleep(8_000)
    }
    usleep(200_000)
    print("valuelen-after=\((attr(secureFields[0], kAXValueAttribute) as? String)?.count ?? -1) expected=\(pw.count)")
case "seltext", "keys":
    let pw = try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).trimmingCharacters(in: .newlines)
    guard secureFields.count == 1, let app = hostApps().first else { print("REFUSED: \(secureFields.count) secure fields"); exit(2) }
    let f = AXUIElementSetAttributeValue(secureFields[0], kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    if mode == "seltext" {
        let r = AXUIElementSetAttributeValue(secureFields[0], kAXSelectedTextAttribute as CFString, pw as CFString)
        print("SELTEXT focus=\(f.rawValue) result=\(r.rawValue)")
    } else {
        let src = CGEventSource(stateID: .privateState)
        for ch in pw.utf16 {
            var c = ch
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
                e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                e.postToPid(app.processIdentifier)
            }
            usleep(8_000)
        }
        print("KEYS focus=\(f.rawValue) posted=\(pw.count)")
    }
    usleep(200_000)
    print("valuelen-after=\((attr(secureFields[0], kAXValueAttribute) as? String)?.count ?? -1)")
default: break
}
