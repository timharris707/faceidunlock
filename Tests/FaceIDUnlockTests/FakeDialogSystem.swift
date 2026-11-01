import ApplicationServices
import FaceIDCore
import Foundation
@testable import FaceIDUnlock

/// A scripted dialog tree, keyboard and clock. Element references are application elements for
/// made-up pids, and only this fake ever receives them, so no call reaches a real process.
final class FakeDialogSystem: DialogSystem {
    final class Node {
        let element: AXUIElement
        let role: String
        var subrole: String?
        var title: String?
        var value: String?
        var children: [Node]
        var enabled = true
        var settable = true
        var onPress: (() -> Void)?
        /// The process that draws this element when it isn't the window's, as with System Settings' password field.
        var owner: pid_t?
        /// Contents of a secure field. Only the fake sees this; the app reads the count.
        var content = ""
        /// What the box held when Return reached it.
        var submittedContent: String?

        init(_ element: AXUIElement, role: String, subrole: String?, title: String?, value: String?, children: [Node]) {
            self.element = element
            self.role = role
            self.subrole = subrole
            self.title = title
            self.value = value
            self.children = children
        }
    }

    static let securityAgent = DialogPolicy.hosts[0]
    static let coreautha = DialogPolicy.hosts[1]
    static let systemSettings = DialogPolicy.hosts[2]
    static let passwords = DialogPolicy.hosts[3]

    private var nextID: pid_t = 80_000
    private var nodes: [Node] = []
    var trusted = true
    var apps: [(pid: pid_t, bundleID: String?)] = []
    var windows: [pid_t: [Node]] = [:]
    var identities: [pid_t: DialogHostIdentity] = [:]
    /// Processes that pass as Apple's own System Settings extensions.
    var settingsExtensions: Set<pid_t> = []
    var onIdentity: ((Int) -> Void)?
    private(set) var identityCalls = 0
    private(set) var inspectedPIDs: [pid_t] = []

    var frontmost: pid_t?
    /// The app under test. Activating another app works only while this one is in front, as on the Mac.
    let ownPID: pid_t = 70_000
    var activationAccepted = true
    var focused: [pid_t: Node] = [:]
    var focusAccepted = true
    /// Off: AXPress fails, as when the button's process has gone.
    var pressAccepted = true
    var reportsFocus = true
    var writeAccepted = true
    var writeLimit = Int.max
    var appKeysDelivered = false
    var keyboardKeysDelivered = false
    var keyLimit = Int.max
    var loseFocusAfterKeyboardKeys: Int?
    var unreadableCount = false
    /// A Screen Sharing client is connected.
    var remoteControlled = false
    private(set) var remoteChecks = 0
    private(set) var events: [String] = []
    private(set) var secureValueReads = 0
    private(set) var keyboardTextKeys = 0
    /// Text from keyboard-level keys that did not go into a password box: what another window would get.
    private(set) var strayKeyboardText = ""
    private(set) var clock: TimeInterval = 1_000
    private var scheduled: [(at: TimeInterval, action: () -> Void)] = []

    // MARK: Building trees

    func node(_ role: String, _ subrole: String? = nil, title: String? = nil, value: String? = nil,
              _ children: [Node] = []) -> Node {
        nextID += 1
        let node = Node(AXUIElementCreateApplication(nextID), role: role, subrole: subrole, title: title,
                        value: value, children: children)
        nodes.append(node)
        return node
    }

    func text(_ value: String) -> Node { node(kAXStaticTextRole, value: value) }
    func button(_ title: String) -> Node { node(kAXButtonRole, title: title) }
    func secureField() -> Node { node(kAXTextFieldRole, kAXSecureTextFieldSubrole) }
    func plainField(_ value: String) -> Node { node(kAXTextFieldRole, value: value) }
    func hosting(_ children: [Node]) -> Node { node(kAXGroupRole, "AXHostingView", children) }
    func window(_ children: [Node]) -> Node { node(kAXWindowRole, kAXStandardWindowSubrole, children) }
    func sheet(_ children: [Node]) -> Node { node(kAXSheetRole, nil, children) }

    /// Registers a running host whose identity verifies.
    func addHost(_ host: DialogPolicy.Host, pid: pid_t, windows: [Node]) {
        apps.append((pid, host.identifier))
        self.windows[pid] = windows
        identities[pid] = Self.identity(pid: pid, host: host)
    }

    static func identity(pid: pid_t, host: DialogPolicy.Host, start: UInt64 = 100) -> DialogHostIdentity {
        DialogHostIdentity(pid: pid, processInstance: ProcessInstance(pid: pid, startSeconds: start, startMicroseconds: 0),
                           executablePath: host.executablePath, signingIdentifier: host.identifier, codeHash: Data([1, 2]))
    }

    func after(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        scheduled.append((clock + delay, action))
    }

    func lookup(_ element: AXUIElement) -> Node? { nodes.first { CFEqual($0.element, element) } }

    // MARK: DialogSystem

    func isTrusted() -> Bool { trusted }
    func runningApps() -> [(pid: pid_t, bundleID: String?)] { apps }

    func identity(pid: pid_t, host: DialogPolicy.Host) throws -> DialogHostIdentity {
        identityCalls += 1
        onIdentity?(identityCalls)
        guard let identity = identities[pid], identity.signingIdentifier == host.identifier else {
            throw DialogProblem.unverified
        }
        return identity
    }

    func pid(of element: AXUIElement) -> pid_t? {
        guard let node = lookup(element) else { return nil }
        return node.owner ?? windows.first { $0.value.contains { contains($0, node) } }?.key
    }

    func isSettingsExtension(pid: pid_t) -> Bool { settingsExtensions.contains(pid) }

    /// A host exits when its identity is removed; a restarted host has a new process instance.
    func isRunning(_ instance: ProcessInstance) -> Bool { identities[instance.pid]?.processInstance == instance }

    func isRemoteControlled() -> Bool {
        remoteChecks += 1
        return remoteControlled
    }

    func application(pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    func elements(_ element: AXUIElement, _ attribute: String, maximum: Int) throws -> [AXUIElement]? {
        let list: [Node]
        if attribute == kAXWindowsAttribute {
            guard let pid = windows.keys.first(where: { CFEqual(AXUIElementCreateApplication($0), element) }) else {
                throw DialogProblem.unreadable
            }
            inspectedPIDs.append(pid)
            list = windows[pid] ?? []
        } else {
            guard let node = lookup(element) else { throw DialogProblem.unreadable }
            if node.children.isEmpty { return nil }
            list = node.children
        }
        guard list.count <= maximum else { throw DialogProblem.tooLarge }
        return list.map(\.element)
    }

    func string(_ element: AXUIElement, _ attribute: String, required: Bool) throws -> String? {
        guard let node = lookup(element) else { throw DialogProblem.unreadable }
        let value: String?
        switch attribute {
        case kAXRoleAttribute: value = node.role
        case kAXSubroleAttribute: value = node.subrole
        case kAXTitleAttribute: value = node.title
        case kAXValueAttribute:
            if node.subrole == kAXSecureTextFieldSubrole { secureValueReads += 1 }
            value = node.value
        default: value = nil
        }
        if value == nil && required { throw DialogProblem.unreadable }
        return value
    }

    func isSettable(_ field: AXUIElement) -> Bool { lookup(field)?.settable ?? false }
    func isEnabled(_ element: AXUIElement) -> Bool { lookup(element)?.enabled ?? false }

    func characterCount(_ field: AXUIElement) -> Int? {
        unreadableCount ? nil : lookup(field)?.content.count
    }

    func setValue(_ field: AXUIElement, _ text: String) -> Bool {
        events.append(text.isEmpty ? "setValue:empty" : "setValue")
        guard writeAccepted, let node = lookup(field) else { return false }
        node.content = String(text.prefix(writeLimit))
        return true
    }

    func focus(_ field: AXUIElement) -> Bool {
        events.append("focus")
        guard focusAccepted, let node = lookup(field) else { return false }
        if let pid = windows.first(where: { $0.value.contains { contains($0, node) } })?.key { focused[pid] = node }
        return true
    }

    func press(_ button: AXUIElement) -> Bool {
        guard let node = lookup(button) else { return false }
        events.append("press:\(node.title ?? "?")")
        node.onPress?()
        return pressAccepted
    }

    func focusedElement(pid: pid_t) -> AXUIElement? { reportsFocus ? focused[pid]?.element : nil }
    func frontmostPID() -> pid_t? { frontmost }

    func activate(pid: pid_t) -> Bool {
        events.append("activate")
        guard activationAccepted, frontmost == ownPID else { return false }
        frontmost = pid
        return true
    }

    func post(_ key: DialogKeystroke, to route: DialogKeyRoute) {
        let target: Node?
        switch route {
        case .app(let pid):
            events.append("app:\(name(key))")
            target = appKeysDelivered ? focused[pid] : nil
        case .keyboard:
            events.append("keyboard:\(name(key))")
            if case .text = key { keyboardTextKeys += 1 }
            let pid = frontmost ?? 0
            target = keyboardKeysDelivered ? focused[pid] : nil
            if let limit = loseFocusAfterKeyboardKeys, keyboardTextKeys >= limit { frontmost = 1 }
        }
        guard let target, target.subrole == kAXSecureTextFieldSubrole else {
            if route == .keyboard, case .text(let text) = key { strayKeyboardText += text }
            return
        }
        switch key {
        case .text(let text):
            if target.content.count < keyLimit { target.content += text }
            else if route == .keyboard { strayKeyboardText += text }
        case .deleteBackward:
            if !target.content.isEmpty { target.content.removeLast() }
        case .returnKey:
            target.submittedContent = target.content
        }
    }

    func pause(_ seconds: TimeInterval) {
        clock += seconds
        let due = scheduled.filter { $0.at <= clock }
        scheduled.removeAll { $0.at <= clock }
        due.forEach { $0.action() }
    }

    func now() -> Date { Date(timeIntervalSinceReferenceDate: clock) }
    func uptime() -> TimeInterval { clock }

    // MARK: Helpers

    private func name(_ key: DialogKeystroke) -> String {
        switch key {
        case .text: return "text"
        case .deleteBackward: return "delete"
        case .returnKey: return "return"
        }
    }

    private func contains(_ root: Node, _ node: Node) -> Bool {
        root === node || root.children.contains { contains($0, node) }
    }
}
