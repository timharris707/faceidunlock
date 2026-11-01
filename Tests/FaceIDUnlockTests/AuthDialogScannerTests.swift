import ApplicationServices
import FaceIDCore
import XCTest
@testable import FaceIDUnlock

/// The three dialog shapes recorded in Step 0 of the overhaul plan, plus System Settings' box recorded on
/// 2026-10-30, as fake Accessibility trees.
struct DialogShapes {
    let fake: FakeDialogSystem

    /// SecurityAgent keychain unlock: AppKit, one secure field.
    func keychain(_ name: String = "login") -> (window: FakeDialogSystem.Node, field: FakeDialogSystem.Node) {
        let field = fake.secureField()
        let window = fake.window([fake.text("security wants to use the “\(name)” keychain."),
                                  fake.text("Please enter the keychain password."), fake.text("Password:"),
                                  field, fake.button("Cancel"), fake.button("OK")])
        return (window, field)
    }

    /// coreautha in Touch ID mode: SwiftUI, no secure field until "Use Password…" is pressed.
    /// Pressing it adds the field after `delay` seconds, or never when `delay` is nil.
    func touchID(fieldAfter delay: TimeInterval? = 0.3)
        -> (window: FakeDialogSystem.Node, button: FakeDialogSystem.Node, field: FakeDialogSystem.Node) {
        let field = fake.secureField()
        let usePassword = fake.button("Use Password…")
        let group = fake.hosting([fake.text("Keychain Access"), fake.text("Touch ID or enter your password to allow this."),
                                  usePassword, fake.button("Cancel")])
        if let delay {
            usePassword.onPress = { [fake] in
                fake.after(delay) {
                    group.children.removeAll { $0 === usePassword }
                    group.children.insert(field, at: 2)
                    group.children.append(fake.button("OK"))
                }
            }
        }
        return (fake.window([group]), usePassword, field)
    }

    /// SecurityAgent admin dialog: SwiftUI, a user name field plus a secure field nested under the hosting view.
    func admin(user: String = "timharris")
        -> (window: FakeDialogSystem.Node, field: FakeDialogSystem.Node, userField: FakeDialogSystem.Node) {
        let field = fake.secureField()
        let userField = fake.plainField(user)
        let group = fake.hosting([fake.text("Allow administrator access for a script started by “Terminal”."),
                                  fake.node(kAXGroupRole, nil, [userField, fake.node(kAXGroupRole, nil, [field])]),
                                  fake.button("Don’t Allow"), fake.button("Allow Access")])
        return (fake.window([group]), field, userField)
    }

    /// System Settings: a sheet on the settings window whose password field belongs to the settings extension
    /// that asked. With Touch ID it opens on "Use Password…", which swaps in the password stage after 0.3 s.
    func settings(fieldOwner: pid_t, touchID: Bool = false)
        -> (window: FakeDialogSystem.Node, sheet: FakeDialogSystem.Node, field: FakeDialogSystem.Node,
            button: FakeDialogSystem.Node) {
        let field = fake.secureField()
        field.owner = fieldOwner
        let usePassword = fake.button("Use Password…")
        let title = fake.text("Privacy & Security is trying to unlock system settings.")
        let passwordStage = [title, fake.text("Enter your password to continue with Privacy & Security."),
                             fake.plainField("Tim Harris"), field, fake.button("Unlock"), fake.button("Cancel")]
        let group = fake.hosting(touchID ? [title, fake.text("Touch ID or enter your password to continue with Privacy & Security."),
                                            usePassword, fake.button("Cancel")] : passwordStage)
        usePassword.onPress = { [fake] in fake.after(0.3) { group.children = passwordStage } }
        let sheet = fake.sheet([group])
        // The settings themselves: more elements than any box may have, so walking them would fail the scan.
        let content = fake.hosting((0..<3).map { part in fake.node(kAXGroupRole, nil, (0..<100).map { fake.text("setting \(part).\($0)") }) })
        return (fake.window([content, fake.text("Privacy & Security"), sheet]), sheet, field, usePassword)
    }

    /// Passwords' lock screen, recorded live 2026-10-30: inside its own window, no button after "Use Password…".
    func passwordsLocked(touchID: Bool = false)
        -> (window: FakeDialogSystem.Node, field: FakeDialogSystem.Node, button: FakeDialogSystem.Node) {
        let field = fake.secureField()
        let usePassword = fake.button("Use Password…")
        let title = fake.text("Passwords Is Locked")
        let passwordStage = [fake.node(kAXImageRole, title: "Lock"), title,
                             fake.text("Enter the password for the user “Tim Harris” to unlock."), field]
        let group = fake.hosting(touchID ? [fake.node(kAXImageRole, title: "Touch Id"), title,
                                            fake.text("Touch ID or enter your password to continue."), usePassword]
                                         : passwordStage)
        usePassword.onPress = { [fake] in fake.after(0.3) { group.children = passwordStage } }
        return (fake.window([fake.hosting([]), fake.hosting([group]), fake.button("")]), field, usePassword)
    }

    /// Passwords once unlocked: a long list and a saved password's own field.
    func passwordsUnlocked() -> FakeDialogSystem.Node {
        let rows = (0..<3).map { part in fake.node(kAXGroupRole, nil, (0..<30).map { fake.text("site \(part).\($0)") }) }
        return fake.window([fake.hosting(rows + [fake.text("Password"), fake.secureField()])])
    }
}

func scannedDialog(_ scan: AuthDialogScan, file: StaticString = #filePath, line: UInt = #line) -> AuthDialog? {
    guard case .dialog(let dialog) = scan else {
        XCTFail("Expected one dialog, got \(scan)", file: file, line: line)
        return nil
    }
    return dialog
}

final class AuthDialogScannerTests: XCTestCase {
    private let securityAgentPID: pid_t = 90_001
    private let coreauthaPID: pid_t = 90_002
    private var fake: FakeDialogSystem!
    private var shapes: DialogShapes!
    private var scanner: AuthDialogScanner!

    override func setUp() {
        fake = FakeDialogSystem()
        shapes = DialogShapes(fake: fake)
        scanner = AuthDialogScanner(system: fake, userName: "timharris", fullUserName: "Tim Harris")
    }

    func testKeychainDialogIsAnAppKitDirectWrite() throws {
        let (window, field) = shapes.keychain()
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [window])
        let dialog = try XCTUnwrap(scannedDialog(scanner.scan()))
        XCTAssertEqual(dialog.decision, .fill(method: .directValue))
        XCTAssertTrue(CFEqual(try XCTUnwrap(dialog.field), field.element))
        XCTAssertTrue(CFEqual(dialog.window, window.element))
        XCTAssertNil(dialog.usePasswordButton)
        XCTAssertEqual(dialog.requester, "security wants to use the “login” keychain.")
        XCTAssertEqual(dialog.identity, FakeDialogSystem.identity(pid: securityAgentPID, host: FakeDialogSystem.securityAgent))
        XCTAssertEqual(fake.secureValueReads, 0)
    }

    func testTouchIDDialogNeedsUsePassword() throws {
        let (window, button, _) = shapes.touchID()
        fake.addHost(FakeDialogSystem.coreautha, pid: coreauthaPID, windows: [window])
        let dialog = try XCTUnwrap(scannedDialog(scanner.scan()))
        XCTAssertEqual(dialog.decision, .needsUsePasswordClick)
        XCTAssertTrue(CFEqual(try XCTUnwrap(dialog.usePasswordButton), button.element))
        XCTAssertNil(dialog.field)
        XCTAssertEqual(dialog.requester, "Keychain Access")
    }

    func testAdminDialogUsesTypedKeysForThisUserAndSkipsOthers() throws {
        let (window, _, userField) = shapes.admin()
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [window])
        XCTAssertEqual(try XCTUnwrap(scannedDialog(scanner.scan())).decision, .fill(method: .typedKeys),
                       "A secure field nested anywhere under a hosting view is SwiftUI")
        userField.value = "admin"
        XCTAssertEqual(try XCTUnwrap(scannedDialog(scanner.scan())).decision,
                       .skip(reason: "This box asks for another user's password."))
        XCTAssertEqual(fake.secureValueReads, 0)
    }

    func testOtherKeychainIsReportedAsASkip() throws {
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [shapes.keychain("System").window])
        XCTAssertEqual(try XCTUnwrap(scannedDialog(scanner.scan())).decision,
                       .skip(reason: "This box asks for the “System” keychain password."))
    }

    func testNothingOpenIsConfirmedAbsence() {
        guard case .none = scanner.scan() else { return XCTFail("No hosts running") }
        fake.addHost(FakeDialogSystem.coreautha, pid: coreauthaPID, windows: [])
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID,
                     windows: [fake.window([fake.text("Allow access?"), fake.button("Deny"), fake.button("Allow")])])
        guard case .none = scanner.scan() else { return XCTFail("Windows without a password box are not dialogs") }
    }

    func testSeveralDialogsFail() {
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [shapes.keychain().window])
        fake.addHost(FakeDialogSystem.coreautha, pid: coreauthaPID, windows: [shapes.touchID().window])
        guard case .failed(let message, _) = scanner.scan() else { return XCTFail("Two hosts with dialogs") }
        XCTAssertEqual(message.localizedDescription, "Several password boxes are open")

        let single = FakeDialogSystem()
        let singleShapes = DialogShapes(fake: single)
        single.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID,
                       windows: [singleShapes.keychain().window, singleShapes.admin().window])
        guard case .failed(let sameHost, _) = AuthDialogScanner(system: single, userName: "timharris", fullUserName: "").scan() else {
            return XCTFail("Two windows in one host")
        }
        XCTAssertEqual(sameHost.localizedDescription, "Several password boxes are open")
    }

    func testUnknownAppsAreNeverInspected() {
        fake.apps = [(4242, "com.example.FakeSecurityAgent"), (4243, nil), (4244, "com.apple.tcc.AuthorizationPromptService")]
        guard case .none = scanner.scan() else { return XCTFail("Only the Apple hosts are watched") }
        XCTAssertEqual(fake.identityCalls, 0)
        XCTAssertTrue(fake.inspectedPIDs.isEmpty)
    }

    func testUnverifiedHostFailsClosedEvenNextToAValidDialog() {
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [shapes.keychain().window])
        fake.apps.append((coreauthaPID, FakeDialogSystem.coreautha.identifier))
        guard case .failed(let message, _) = scanner.scan() else { return XCTFail("Unverified host must fail the scan") }
        XCTAssertEqual(message.localizedDescription, "Can't confirm this password box comes from macOS.")
    }

    func testHostThatChangesDuringTheScanFails() {
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [shapes.keychain().window])
        fake.onIdentity = { [fake, securityAgentPID] call in
            if call == 2 {
                fake!.identities[securityAgentPID] = FakeDialogSystem.identity(pid: securityAgentPID,
                                                                               host: FakeDialogSystem.securityAgent, start: 200)
            }
        }
        guard case .failed(let message, _) = scanner.scan() else { return XCTFail("Process instance changed") }
        XCTAssertEqual(message.localizedDescription, "The password box changed.")
    }

    func testNoPermissionFails() {
        fake.trusted = false
        guard case .failed(let message, _) = scanner.scan() else { return XCTFail("Accessibility is off") }
        XCTAssertEqual(message.localizedDescription, "Face ID Unlock needs permission to fill password boxes.")
    }

    func testOversizedTreesFail() {
        let groups = (0..<3).map { group in fake.node(kAXGroupRole, nil, (0..<100).map { fake.text("line \(group).\($0)") }) }
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [fake.window(groups + [fake.secureField()])])
        guard case .failed(let message, _) = scanner.scan() else { return XCTFail("Too many elements in total") }
        XCTAssertEqual(message.localizedDescription, "This password box is too large to check safely.")

        fake.windows[securityAgentPID] = [fake.window((0..<300).map { fake.text("line \($0)") } + [fake.secureField()])]
        guard case .failed = scanner.scan() else { return XCTFail("Too many children on one element") }
    }

    func testFailedScanSaysWhetherAPasswordBoxWasSeen() {
        // A box whose tree can't be read: one element answers no Accessibility reads at all.
        let unreadable = FakeDialogSystem.Node(AXUIElementCreateApplication(99_999), role: kAXGroupRole, subrole: nil,
                                               title: nil, value: nil, children: [])
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID,
                     windows: [fake.window([fake.text("security wants to use the “login” keychain."), fake.secureField(),
                                            unreadable])])
        guard case .failed(.unreadable, let boxSeen) = scanner.scan() else { return XCTFail("Unreadable box") }
        XCTAssertTrue(boxSeen)

        fake.windows[securityAgentPID] = [fake.window([fake.text("Keychain Access"), fake.button("Use Password…"), unreadable])]
        guard case .failed(.unreadable, let buttonSeen) = scanner.scan() else { return XCTFail("Unreadable Touch ID box") }
        XCTAssertTrue(buttonSeen)

        fake.windows[securityAgentPID] = [fake.window([fake.text("Allow access?"), unreadable, fake.secureField()])]
        guard case .failed(.unreadable, let fieldAfter) = scanner.scan() else { return XCTFail("Field after the failure") }
        XCTAssertTrue(fieldAfter, "A password field anywhere in the readable part of the window counts")

        fake.windows[securityAgentPID] = [fake.window([fake.text("Allow access?"), unreadable]), shapes.keychain().window]
        guard case .failed(.unreadable, let nextWindow) = scanner.scan() else {
            return XCTFail("A window that can't be read fails the scan, even next to a readable box")
        }
        XCTAssertTrue(nextWindow, "The host's other windows are still read")

        fake.windows[securityAgentPID] = [fake.window([fake.text("Allow access?"), unreadable, fake.button("Allow")])]
        guard case .failed(.unreadable, let otherWindow) = scanner.scan() else { return XCTFail("Unreadable window") }
        XCTAssertFalse(otherWindow, "No password field or Use Password button anywhere")

        fake.windows[securityAgentPID] = []
        fake.apps.append((coreauthaPID, FakeDialogSystem.coreautha.identifier))
        guard case .failed(.unverified, let unverifiedWindow) = scanner.scan() else { return XCTFail("Unverified host") }
        XCTAssertFalse(unverifiedWindow, "An unverified host's windows are never read")

        fake.trusted = false
        guard case .failed(.noPermission, let noPermissionWindow) = scanner.scan() else { return XCTFail("No permission") }
        XCTAssertFalse(noPermissionWindow)
    }

    func testDialogKeyIsStableForTheSameRequestOnly() throws {
        let (window, _) = shapes.keychain()
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [window])
        let first = try XCTUnwrap(scannedDialog(scanner.scan()))
        XCTAssertEqual(try XCTUnwrap(scannedDialog(scanner.scan())).dialogKey, first.dialogKey)

        window.children[0].value = "security wants to use the “login” keychain again."
        XCTAssertNotEqual(try XCTUnwrap(scannedDialog(scanner.scan())).dialogKey, first.dialogKey,
                          "A reused window with a new request is a new dialog")

        window.children[0].value = "security wants to use the “login” keychain."
        fake.identities[securityAgentPID] = FakeDialogSystem.identity(pid: securityAgentPID,
                                                                      host: FakeDialogSystem.securityAgent, start: 300)
        XCTAssertNotEqual(try XCTUnwrap(scannedDialog(scanner.scan())).dialogKey, first.dialogKey,
                          "A restarted host is a new dialog")
    }

    func testRefreshFollowsTheSameWindowOnly() throws {
        let (window, _) = shapes.keychain()
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [window])
        let dialog = try XCTUnwrap(scannedDialog(scanner.scan()))
        XCTAssertEqual(try scanner.refresh(dialog).dialogKey, dialog.dialogKey)
        fake.windows[securityAgentPID] = [shapes.keychain().window]
        XCTAssertThrowsError(try scanner.refresh(dialog)) {
            XCTAssertEqual($0.localizedDescription, "The password box closed.")
        }
    }

    func testRefreshOfAHostThatExitedIsTheBoxClosing() throws {
        // Tripwire: SecurityAgent can exit as its box closes; that read as "Can't confirm this password box
        // comes from macOS." with Try Again.
        let (window, _) = shapes.keychain()
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [window])
        let dialog = try XCTUnwrap(scannedDialog(scanner.scan()))
        fake.identities[securityAgentPID] = nil
        XCTAssertThrowsError(try scanner.refresh(dialog)) { XCTAssertEqual($0 as? DialogProblem, .closed) }
    }

    // MARK: System Settings

    private let settingsPID: pid_t = 90_003
    private let extensionPID: pid_t = 90_004

    func testSystemSettingsSheetIsTypedAtKeyboardLevel() throws {
        let (window, sheet, field, _) = shapes.settings(fieldOwner: extensionPID)
        fake.settingsExtensions = [extensionPID]
        fake.addHost(FakeDialogSystem.systemSettings, pid: settingsPID, windows: [window])
        let dialog = try XCTUnwrap(scannedDialog(scanner.scan()))
        XCTAssertEqual(dialog.decision, .fill(method: .keyboardKeys))
        XCTAssertTrue(CFEqual(dialog.window, sheet.element), "The sheet is the box; the settings around it are never walked")
        XCTAssertTrue(CFEqual(try XCTUnwrap(dialog.field), field.element))
        XCTAssertEqual(dialog.requester, "Privacy & Security is trying to unlock system settings.")
        XCTAssertEqual(fake.secureValueReads, 0)
    }

    func testSystemSettingsTouchIDSheetNeedsUsePassword() throws {
        let (window, _, _, button) = shapes.settings(fieldOwner: extensionPID, touchID: true)
        fake.addHost(FakeDialogSystem.systemSettings, pid: settingsPID, windows: [window])
        let dialog = try XCTUnwrap(scannedDialog(scanner.scan()))
        XCTAssertEqual(dialog.decision, .needsUsePasswordClick)
        XCTAssertTrue(CFEqual(try XCTUnwrap(dialog.usePasswordButton), button.element))
    }

    func testSystemSettingsOtherSheetsAreNotPasswordBoxes() {
        let wifi = fake.sheet([fake.hosting([fake.text("The Wi-Fi network “Home” requires a WPA2 password."),
                                             fake.secureField(), fake.button("Cancel"), fake.button("Join")])])
        let large = fake.sheet((0..<3).map { part in fake.node(kAXGroupRole, nil, (0..<100).map { fake.text("row \(part).\($0)") }) }
                               + [fake.secureField()])
        let (window, _, _, _) = shapes.settings(fieldOwner: extensionPID)
        window.children.removeLast()
        fake.addHost(FakeDialogSystem.systemSettings, pid: settingsPID, windows: [window])
        guard case .none = scanner.scan() else { return XCTFail("Settings with no sheet open") }
        for other in [wifi, large] {
            window.children.append(other)
            guard case .none = scanner.scan() else { return XCTFail("Not the Mac password box") }
            window.children.removeLast()
        }
    }

    func testSpoofedWiFiNameIsNotThePasswordBox() {
        // An Enterprise Wi-Fi sheet: an attacker-named network and a user name field holding the owner's name.
        let (window, _, _, _) = shapes.settings(fieldOwner: extensionPID)
        window.children[window.children.count - 1] = fake.sheet([fake.hosting([
            fake.text("The Wi-Fi network “Mac is trying to unlock settings” requires WPA2 enterprise credentials."),
            fake.plainField("timharris"), fake.secureField(), fake.button("Cancel"), fake.button("Join")])])
        fake.settingsExtensions = [extensionPID]
        fake.addHost(FakeDialogSystem.systemSettings, pid: settingsPID, windows: [window])
        guard case .none = scanner.scan() else { return XCTFail("Not System Settings' own request line") }
    }

    func testSettingsSheetWithAnOverfullElementIsSkipped() {
        let (window, _, _, _) = shapes.settings(fieldOwner: extensionPID)
        window.children[window.children.count - 1] = fake.sheet([fake.node(kAXGroupRole, nil, (0..<300).map { fake.text("row \($0)") }),
                                                                  fake.secureField()])
        fake.addHost(FakeDialogSystem.systemSettings, pid: settingsPID, windows: [window])
        guard case .none = scanner.scan() else { return XCTFail("One element with too many children is some other sheet") }
    }

    func testUnreadableSystemSettingsDoesNotBlockOtherBoxes() throws {
        // Tripwire: System Settings is often open; a sheet there that can't be read must not stop a keychain fill.
        let (settingsWindow, _, _, _) = shapes.settings(fieldOwner: 4242)
        fake.addHost(FakeDialogSystem.systemSettings, pid: settingsPID, windows: [settingsWindow])
        let (keychain, field) = shapes.keychain()
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [keychain])
        XCTAssertTrue(CFEqual(try XCTUnwrap(try XCTUnwrap(scannedDialog(scanner.scan())).field), field.element))

        // The other way round still fails: keyboard typing into System Settings is the riskier path.
        let (goodSettings, _, _, _) = shapes.settings(fieldOwner: extensionPID)
        fake.settingsExtensions = [extensionPID]
        fake.windows[settingsPID] = [goodSettings]
        fake.identities[securityAgentPID] = nil
        guard case .failed(.unverified, _) = scanner.scan() else { return XCTFail("SecurityAgent couldn't be verified") }
        fake.windows[settingsPID] = [settingsWindow]
        fake.settingsExtensions = []
        guard case .failed(.unverified, _) = scanner.scan() else { return XCTFail("Nothing found, so the failure stands") }
    }

    func testSystemSettingsFieldMustComeFromAnAppleSettingsExtension() throws {
        let (window, _, _, _) = shapes.settings(fieldOwner: 4242)
        fake.settingsExtensions = [extensionPID]
        fake.addHost(FakeDialogSystem.systemSettings, pid: settingsPID, windows: [window])
        guard case .failed(let problem, let boxSeen) = scanner.scan() else { return XCTFail("Field from an unknown process") }
        XCTAssertEqual(problem, .unverified)
        XCTAssertTrue(boxSeen)

        let (ownWindow, _, ownField, _) = shapes.settings(fieldOwner: settingsPID)
        ownField.owner = nil
        fake.windows[settingsPID] = [ownWindow]
        XCTAssertNotNil(scannedDialog(scanner.scan()), "A field System Settings draws itself is trusted with it")
    }

    func testSystemSettingsSheetThatClosesIsClosed() throws {
        let (window, _, _, _) = shapes.settings(fieldOwner: extensionPID)
        fake.settingsExtensions = [extensionPID]
        fake.addHost(FakeDialogSystem.systemSettings, pid: settingsPID, windows: [window])
        let dialog = try XCTUnwrap(scannedDialog(scanner.scan()))
        XCTAssertNoThrow(try scanner.refresh(dialog))
        window.children.removeLast()
        XCTAssertThrowsError(try scanner.refresh(dialog)) { XCTAssertEqual($0 as? DialogProblem, .closed) }
    }

    // MARK: Passwords

    private let passwordsPID: pid_t = 90_005

    func testPasswordsLockScreenIsTypedAtKeyboardLevel() throws {
        let (window, field, _) = shapes.passwordsLocked()
        fake.addHost(FakeDialogSystem.passwords, pid: passwordsPID, windows: [window])
        fake.frontmost = passwordsPID
        let dialog = try XCTUnwrap(scannedDialog(scanner.scan()))
        XCTAssertEqual(dialog.decision, .fill(method: .keyboardKeys))
        XCTAssertTrue(CFEqual(try XCTUnwrap(dialog.field), field.element))
        XCTAssertEqual(dialog.requester, "Passwords Is Locked")
    }

    func testPasswordsTouchIDLockScreenNeedsUsePassword() throws {
        let (window, _, button) = shapes.passwordsLocked(touchID: true)
        fake.addHost(FakeDialogSystem.passwords, pid: passwordsPID, windows: [window])
        fake.frontmost = passwordsPID
        let dialog = try XCTUnwrap(scannedDialog(scanner.scan()))
        XCTAssertEqual(dialog.decision, .needsUsePasswordClick)
        XCTAssertTrue(CFEqual(try XCTUnwrap(dialog.usePasswordButton), button.element))
    }

    func testUnlockedPasswordsIsNeverAPasswordBox() {
        // Tripwire: an unlocked Passwords window holds saved passwords in fields of their own.
        fake.addHost(FakeDialogSystem.passwords, pid: passwordsPID, windows: [shapes.passwordsUnlocked()])
        fake.frontmost = passwordsPID
        guard case .none = scanner.scan() else { return XCTFail("Too large for a lock screen: passed over quietly") }
        let small = fake.window([fake.hosting([fake.text("Password"), fake.secureField()])])
        fake.windows[passwordsPID] = [small]
        guard case .none = scanner.scan() else { return XCTFail("No lock screen text, so nothing to fill") }
    }

    func testPasswordsFieldFromAnotherProcessIsNotTrusted() {
        let (window, field, _) = shapes.passwordsLocked()
        field.owner = 4242
        fake.addHost(FakeDialogSystem.passwords, pid: passwordsPID, windows: [window])
        fake.frontmost = passwordsPID
        guard case .failed(.unverified, _) = scanner.scan() else { return XCTFail("Field drawn by another process") }
    }

    func testUnreadablePasswordsDoesNotBlockOtherBoxes() throws {
        let broken = FakeDialogSystem.Node(AXUIElementCreateApplication(99_998), role: kAXGroupRole, subrole: nil,
                                           title: nil, value: nil, children: [])
        fake.addHost(FakeDialogSystem.passwords, pid: passwordsPID, windows: [fake.window([broken])])
        fake.frontmost = passwordsPID
        let (keychain, field) = shapes.keychain()
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [keychain])
        XCTAssertTrue(CFEqual(try XCTUnwrap(try XCTUnwrap(scannedDialog(scanner.scan())).field), field.element))
    }

    func testPasswordsLockedInTheBackgroundIsNotABox() throws {
        // Tripwire: Passwords locks itself in the background; that used to switch the camera on and, beside a real
        // box, read as "several password boxes".
        let (window, _, _) = shapes.passwordsLocked(touchID: true)
        fake.addHost(FakeDialogSystem.passwords, pid: passwordsPID, windows: [window])
        fake.frontmost = 1
        guard case .none = scanner.scan() else { return XCTFail("Not in front, so not a box") }
        XCTAssertFalse(fake.inspectedPIDs.contains(passwordsPID), "Not even read")
        let (keychain, field) = shapes.keychain()
        fake.addHost(FakeDialogSystem.securityAgent, pid: securityAgentPID, windows: [keychain])
        XCTAssertTrue(CFEqual(try XCTUnwrap(try XCTUnwrap(scannedDialog(scanner.scan())).field), field.element))
    }

    func testAPasswordsLockScreenThatGoesUnreadableIsNotTakenForClosed() {
        let (window, field, _) = shapes.passwordsLocked()
        let unreadable = FakeDialogSystem.Node(AXUIElementCreateApplication(99_997), role: kAXGroupRole, subrole: nil,
                                               title: nil, value: nil, children: [])
        window.children[1].children[0].children.append(unreadable)
        _ = field
        fake.addHost(FakeDialogSystem.passwords, pid: passwordsPID, windows: [window])
        fake.frontmost = passwordsPID
        guard case .failed(_, let boxSeen) = scanner.scan() else { return XCTFail("A lock screen read in part is a failure") }
        XCTAssertTrue(boxSeen)
    }
}
