import AppKit
import ApplicationServices
import FaceIDCore
import Security

enum DialogKeystroke: Equatable {
    case text(String), deleteBackward, returnKey
}

enum DialogKeyRoute: Equatable {
    /// Posted to one process only.
    case app(pid_t)
    /// Posted at keyboard level; lands wherever keyboard focus is.
    case keyboard
}

/// Every Accessibility, process and keyboard call made while finding and filling password dialogs.
/// `LiveDialogSystem` talks to macOS; tests use a fake.
protocol DialogSystem {
    func isTrusted() -> Bool
    func runningApps() -> [(pid: pid_t, bundleID: String?)]
    /// Signed identity of one live host process. Throws unless it is the expected Apple binary.
    func identity(pid: pid_t, host: DialogPolicy.Host) throws -> DialogHostIdentity
    /// The process an element belongs to, which inside a System Settings sheet can differ from the window's.
    func pid(of element: AXUIElement) -> pid_t?
    /// An Apple-signed System Settings extension running from the system volume.
    func isSettingsExtension(pid: pid_t) -> Bool
    /// The same process instance still exists.
    func isRunning(_ instance: ProcessInstance) -> Bool
    /// Someone may be watching or controlling this Mac remotely, so nothing may be typed.
    func isRemoteControlled() -> Bool
    func application(pid: pid_t) -> AXUIElement
    /// nil when the element has no such attribute; throws when the read fails or exceeds `maximum`.
    func elements(_ element: AXUIElement, _ attribute: String, maximum: Int) throws -> [AXUIElement]?
    /// nil only for a missing optional attribute; any failed read throws.
    func string(_ element: AXUIElement, _ attribute: String, required: Bool) throws -> String?
    func isSettable(_ field: AXUIElement) -> Bool
    func isEnabled(_ element: AXUIElement) -> Bool
    /// How many characters a field holds, from the length of its value. Never its contents.
    func characterCount(_ field: AXUIElement) -> Int?
    func setValue(_ field: AXUIElement, _ text: String) -> Bool
    func focus(_ field: AXUIElement) -> Bool
    func press(_ button: AXUIElement) -> Bool
    /// The host app's own focused element (the system-wide query is unreliable for these dialogs).
    func focusedElement(pid: pid_t) -> AXUIElement?
    func frontmostPID() -> pid_t?
    /// This app's own process.
    var ownPID: pid_t { get }
    /// Brings the app with this pid to the front, handing the front over from this app.
    func activate(pid: pid_t) -> Bool
    func post(_ key: DialogKeystroke, to route: DialogKeyRoute)
    func pause(_ seconds: TimeInterval)
    func now() -> Date
    func uptime() -> TimeInterval
}

struct LiveDialogSystem: DialogSystem {
    private let timeout: Float = 0.15

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func runningApps() -> [(pid: pid_t, bundleID: String?)] {
        NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.bundleIdentifier) }
    }

    /// Apple anchor, signing identifier, executable path and code hash, all read within one process instance.
    func identity(pid: pid_t, host: DialogPolicy.Host) throws -> DialogHostIdentity {
        do {
            return try ProcessInstance.verifying(pid: pid) { processInstance in
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                      app.bundleIdentifier == host.identifier, let executable = app.executableURL else {
                    throw DialogProblem.unverified
                }
                let path = executable.resolvingSymlinksInPath().path
                guard path == URL(fileURLWithPath: host.executablePath).resolvingSymlinksInPath().path else {
                    throw DialogProblem.unverified
                }
                var code: SecCode?
                let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
                guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
                    throw DialogProblem.unverified
                }
                var requirement: SecRequirement?
                let requirementText = "anchor apple and identifier \"\(host.identifier)\""
                guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
                      let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
                    throw DialogProblem.unverified
                }
                var staticCode: SecStaticCode?
                guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
                    throw DialogProblem.unverified
                }
                var information: CFDictionary?
                guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
                      let info = information as? [String: Any],
                      info[kSecCodeInfoIdentifier as String] as? String == host.identifier,
                      let codeHash = info[kSecCodeInfoUnique as String] as? Data else {
                    throw DialogProblem.unverified
                }
                return DialogHostIdentity(pid: pid, processInstance: processInstance, executablePath: path,
                                          signingIdentifier: host.identifier, codeHash: codeHash)
            }
        } catch {
            throw DialogProblem.unverified
        }
    }

    func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid > 0 ? pid : nil
    }

    func isSettingsExtension(pid: pid_t) -> Bool {
        (try? ProcessInstance.verifying(pid: pid) { _ -> Bool in
            // The kernel's path, not LaunchServices': it alone tells Apple's extensions from legacyLoader,
            // which is Apple-signed too but runs third-party settings panes.
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
                    .hasPrefix(DialogPolicy.settingsExtensionsFolder) else { return false }
            var code: SecCode?, requirement: SecRequirement?
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { return false }
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }) ?? false
    }

    func isRunning(_ instance: ProcessInstance) -> Bool {
        (try? ProcessInstance.read(pid: instance.pid)) == instance
    }

    func isRemoteControlled() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        // kCGSessionOnConsoleKey, a C macro Swift doesn't import.
        return Self.isRemoteControlled(onConsole: session?["kCGSSessionOnConsoleKey"] as? Bool,
                                       processes: Self.processNames())
    }

    /// A Screen Sharing or Remote Management client is connected (screensharingd runs only then), or this
    /// login session isn't the one on the Mac's own screen. Other apps that could share the screen don't
    /// count. A process list that can't be read counts as remote control.
    static func isRemoteControlled(onConsole: Bool?, processes: [String]?) -> Bool {
        guard onConsole != false, let processes else { return true }
        return processes.contains("screensharingd")
    }

    /// Every process's short name, root daemons included (proc_name can't see those); nil if unreadable.
    static func processNames() -> [String]? {
        var request = [CTL_KERN, KERN_PROC, KERN_PROC_ALL], size = 0
        guard sysctl(&request, 3, nil, &size, nil, 0) == 0 else { return nil }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 64)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&request, 3, &processes, &size, nil, 0) == 0 else { return nil }
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).map { process in
            withUnsafeBytes(of: process.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
    }

    func application(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    func elements(_ element: AXUIElement, _ attribute: String, maximum: Int) throws -> [AXUIElement]? {
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { throw DialogProblem.unreadable }
        var count: CFIndex = 0
        let countResult = AXUIElementGetAttributeValueCount(element, attribute as CFString, &count)
        if countResult == .attributeUnsupported || countResult == .noValue { return nil }
        guard countResult == .success else { throw DialogProblem.unreadable }
        guard count <= maximum else { throw DialogProblem.tooLarge }
        if count == 0 { return [] }
        var value: CFArray?
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0, count, &value) == .success,
              let values = value as? [AXUIElement] else { throw DialogProblem.unreadable }
        return values
    }

    func string(_ element: AXUIElement, _ attribute: String, required: Bool) throws -> String? {
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { throw DialogProblem.unreadable }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if !required && (result == .attributeUnsupported || result == .noValue) { return nil }
        guard result == .success, let text = value as? String else { throw DialogProblem.unreadable }
        return text
    }

    func isSettable(_ field: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    func isEnabled(_ element: AXUIElement) -> Bool {
        var enabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success else {
            return false
        }
        return (enabled as? Bool) == true
    }

    func characterCount(_ field: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
        if result == .noValue { return 0 }
        guard result == .success, let masked = value as? String else { return nil }
        return masked.count
    }

    func setValue(_ field: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success
    }

    func focus(_ field: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    func press(_ button: AXUIElement) -> Bool {
        AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    func focusedElement(pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application(pid: pid), kAXFocusedUIElementAttribute as CFString,
                                            &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    func activate(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate(from: .current, options: []) ?? false
    }

    /// Key down and up. Flags are set explicitly so a held modifier can't turn a character into a shortcut.
    func post(_ key: DialogKeystroke, to route: DialogKeyRoute) {
        let source: CGEventSource?
        switch route {
        case .app: source = CGEventSource(stateID: .privateState)
        case .keyboard: source = CGEventSource(stateID: .hidSystemState)
        }
        // Virtual key 0x00 is A, 0x33 is Delete (backspace), 0x24 is Return; Delete and Return are the same on every layout.
        let (virtualKey, flags, text): (CGKeyCode, CGEventFlags, String?) = switch key {
        case .text(let text): (0x00, [], text)
        case .deleteBackward: (0x33, [], nil)
        case .returnKey: (0x24, [], nil)
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down) else { return }
            event.flags = flags
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            switch route {
            case .app(let pid): event.postToPid(pid)
            case .keyboard: event.post(tap: .cghidEventTap)
            }
        }
    }

    func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
    func now() -> Date { Date() }
    func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
