import ApplicationServices
import FaceIDCore
import XCTest
@testable import FaceIDUnlock

final class AuthDialogFillerTests: XCTestCase {
    private let pid: pid_t = 90_001
    /// A made-up password for the fake only.
    private let password = "pa55-Word!"
    private var fake: FakeDialogSystem!
    private var shapes: DialogShapes!
    private var scanner: AuthDialogScanner!
    private var filler: AuthDialogFiller!

    override func setUp() {
        fake = FakeDialogSystem()
        shapes = DialogShapes(fake: fake)
        scanner = AuthDialogScanner(system: fake, userName: "timharris", fullUserName: "Tim Harris")
        filler = AuthDialogFiller(scanner: scanner)
    }

    override func tearDown() {
        // No path may ever press OK or Allow; only System Settings' own approve buttons may be pressed (via submit).
        let allowed: Set = ["press:Use Password…", "press:Unlock", "press:Modify Settings"]
        XCTAssertFalse(fake.events.contains { $0.hasPrefix("press:") && !allowed.contains($0) }, "\(fake.events)")
        fake.onIdentity = nil
    }

    private func open(_ window: FakeDialogSystem.Node, host: DialogPolicy.Host = FakeDialogSystem.securityAgent) throws -> AuthDialog {
        fake.addHost(host, pid: pid, windows: [window])
        return try XCTUnwrap(scannedDialog(scanner.scan()))
    }

    private func fill(_ dialog: AuthDialog, _ text: String? = nil, recognizedAt: Date? = nil) -> FillOutcome {
        filler.fill(dialog, password: Array((text ?? password).utf8), recognizedAt: recognizedAt ?? fake.now())
    }

    private func repeated(_ event: String, _ count: Int) -> [String] { Array(repeating: event, count: count) }
    /// The space typed and cleared before any keyboard-level password key.
    private let probe = ["keyboard:text", "keyboard:delete"]

    // MARK: Direct value (AppKit)

    func testAppKitDialogGetsOneDirectWrite() throws {
        let (window, field) = shapes.keychain()
        XCTAssertEqual(fill(try open(window)), .filled(.directValue))
        XCTAssertEqual(field.content, password)
        XCTAssertEqual(fake.events, ["setValue"], "No focus change and no keys for AppKit dialogs")
    }

    func testDirectWriteShortfallIsClearedAndReported() throws {
        let (window, field) = shapes.keychain()
        fake.writeLimit = 4
        XCTAssertEqual(fill(try open(window)), .failed(.cleared))
        XCTAssertEqual(field.content, "")
        XCTAssertEqual(fake.events, ["setValue", "setValue:empty"])
    }

    func testRefusedOrUnsettableWriteFails() throws {
        let (window, field) = shapes.keychain()
        let dialog = try open(window)
        fake.writeAccepted = false
        XCTAssertEqual(fill(dialog), .failed(.notAccepted))
        field.settable = false
        XCTAssertEqual(fill(dialog), .failed(.cannotFill))
        XCTAssertEqual(field.content, "")
    }

    // MARK: Typed keys (SwiftUI)

    func testSwiftUIDialogTypesToTheAppFirst() throws {
        let (window, _, field) = shapes.touchID()
        let dialog = try filler.pressUsePassword(try open(window, host: FakeDialogSystem.coreautha))
        XCTAssertTrue(CFEqual(try XCTUnwrap(dialog.field), field.element))
        fake.appKeysDelivered = true
        fake.keyboardKeysDelivered = true
        XCTAssertEqual(fill(dialog), .filled(.appKeys))
        XCTAssertEqual(field.content, password)
        XCTAssertEqual(fake.events, ["press:Use Password…", "focus"] + repeated("app:text", password.count),
                       "Keyboard-level typing is never used when app keys arrive")
    }

    func testAppKeysStillWorkWhenTheHostDoesNotReportFocus() throws {
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.reportsFocus = false
        fake.appKeysDelivered = true
        XCTAssertEqual(fill(dialog), .filled(.appKeys))
        XCTAssertEqual(field.content, password)
    }

    func testKeyboardTypingOnlyAfterAppKeysDoNotArrive() throws {
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        XCTAssertEqual(fill(dialog), .filled(.keyboard))
        XCTAssertEqual(field.content, password)
        XCTAssertEqual(fake.events, ["focus", "app:text"] + probe + repeated("keyboard:text", password.count),
                       "One probe key to the app, a probe space at keyboard level, then keyboard-level typing")
    }

    func testKeyboardTypingNeedsTheDialogFrontmost() throws {
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.keyboardKeysDelivered = true
        fake.frontmost = 1
        XCTAssertEqual(fill(dialog), .failed(.clickTheBox))
        XCTAssertEqual(fake.events, ["focus", "app:text"])
        XCTAssertEqual(field.content, "")
    }

    func testKeyboardTypingNeedsTheHostToReportThisFieldFocused() throws {
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        fake.reportsFocus = false
        XCTAssertEqual(fill(dialog), .failed(.clickTheBox))
        XCTAssertEqual(fake.events, ["focus", "app:text"])
        XCTAssertEqual(field.content, "")
    }

    func testNoKeysWhileAnotherControlHasFocus() throws {
        let (window, _, userField) = shapes.admin()
        let dialog = try open(window)
        fake.focusAccepted = false
        fake.focused[pid] = userField
        fake.appKeysDelivered = true
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        XCTAssertEqual(fill(dialog), .failed(.clickTheBox))
        XCTAssertEqual(fake.events, ["focus"], "Not even the probe key goes to the user name field")
    }

    func testKeyboardTypingStopsTheMomentFocusMoves() throws {
        let (window, _, _) = shapes.admin()
        let dialog = try open(window)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        fake.loseFocusAfterKeyboardKeys = 3
        XCTAssertEqual(fill(dialog), .failed(.focusLost))
        XCTAssertEqual(fake.keyboardTextKeys, 3)
        XCTAssertEqual(fake.events, ["focus", "app:text"] + probe + repeated("keyboard:text", 2),
                       "No more keyboard events of any kind once focus has gone elsewhere")
    }

    func testPartialAppKeysAreClearedByTheSameRoute() throws {
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.appKeysDelivered = true
        fake.keyLimit = 4
        XCTAssertEqual(fill(dialog), .failed(.cleared))
        XCTAssertEqual(field.content, "")
        XCTAssertTrue(fake.events.contains("app:delete"))
        XCTAssertFalse(fake.events.contains { $0.hasPrefix("keyboard:") })
    }

    func testKeyboardKeysThatGoElsewhereStopAfterOneKey() throws {
        // Tripwire: keyboard-level keys land wherever keyboard focus really is. The old loop typed the whole
        // password into another window, then sent Select All and Delete there too.
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.keyboardKeysDelivered = false
        fake.frontmost = pid
        let outcome = fill(dialog)
        XCTAssertEqual(outcome, .failed(.firstKeyMissed))
        XCTAssertEqual(fake.events, ["focus", "app:text", "keyboard:text"], "No clearing keys go to another window")
        // Tripwire: a panel such as Spotlight can hold the keyboard unseen, so what goes astray is the probe space.
        XCTAssertEqual(fake.strayKeyboardText, " ", "Only the probe space can go astray, never part of the password")
        XCTAssertEqual(field.content, "")
        // Tripwire: the box is still empty, so asking to clear it before typing was wrong.
        XCTAssertEqual(DialogProblem.firstKeyMissed.localizedDescription,
                       "The password wasn't filled. Click the password box, then try again.")
        XCTAssertFalse(DialogProblem.keyMissed.localizedDescription.contains("cleared"))
    }

    func testKeyboardTypingStopsAtTheFirstKeyThatDoesNotLand() throws {
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        fake.keyLimit = 4
        XCTAssertEqual(fill(dialog), .failed(.keyMissed))
        XCTAssertEqual(fake.keyboardTextKeys, 6, "The probe space and five password keys")
        XCTAssertEqual(Array(fake.events.dropFirst(2).prefix(2)), probe)
        XCTAssertFalse(fake.events.dropFirst(4).contains { $0 == "keyboard:delete" })
        XCTAssertEqual(fake.strayKeyboardText.count, 1)
        XCTAssertEqual(field.content, String(password.prefix(4)), "Left for the user to clear")
    }

    func testExtraCharactersDuringKeyboardTypingAreClearedInTheBox() throws {
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        // Someone types into the box while the app is typing; keys are landing there, so clearing is safe.
        // Lands mid-password: the probe space and its clearing are done by about 0.48 s on the fake clock.
        fake.after(0.52) { field.content += "x" }
        XCTAssertEqual(fill(dialog), .failed(.cleared))
        XCTAssertEqual(field.content, "")
        XCTAssertTrue(fake.events.contains("keyboard:delete"))
        XCTAssertEqual(fake.strayKeyboardText, "")
    }

    func testSettingsInFrontHandsTheFrontBackToTheDialog() throws {
        // After the Mac password is typed in Settings, this app is in front. Admin boxes take keyboard-level
        // keys only while their host is in front, so the app hands the front back before typing.
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.keyboardKeysDelivered = true
        fake.frontmost = fake.ownPID
        XCTAssertEqual(fill(dialog), .filled(.keyboard))
        XCTAssertEqual(field.content, password)
        XCTAssertEqual(fake.events.prefix(2), ["activate", "focus"])
    }

    func testNeverTakesTheFrontFromAnotherApp() throws {
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.keyboardKeysDelivered = true
        fake.frontmost = 1
        XCTAssertEqual(fill(dialog), .failed(.clickTheBox))
        XCTAssertFalse(fake.events.contains("activate"))
        XCTAssertEqual(field.content, "")
    }

    func testOverfullBoxIsClearedToo() throws {
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.appKeysDelivered = true
        fake.after(0.05) { field.content += "x" }
        XCTAssertEqual(fill(dialog), .failed(.cleared))
        XCTAssertEqual(field.content, "")
    }

    // MARK: Refusals before any input

    func testRefusesWhenTheBoxAlreadyHasCharacters() throws {
        let keychain = shapes.keychain()
        try assertLeftAlone(keychain.window, keychain.field)
        setUp()
        let admin = shapes.admin()
        try assertLeftAlone(admin.window, admin.field)
    }

    private func assertLeftAlone(_ window: FakeDialogSystem.Node, _ field: FakeDialogSystem.Node,
                                 line: UInt = #line) throws {
        let dialog = try open(window)
        field.content = "ti"
        fake.appKeysDelivered = true
        XCTAssertEqual(fill(dialog), .failed(.alreadyTyped), line: line)
        XCTAssertEqual(field.content, "ti", line: line)
        XCTAssertEqual(fake.events, [], line: line)
    }

    func testRefusesStaleOrFutureRecognition() throws {
        let (window, field) = shapes.keychain()
        let dialog = try open(window)
        for offset in [-10.0, -60, 1] {
            XCTAssertEqual(fill(dialog, recognizedAt: fake.now().addingTimeInterval(offset)),
                           .failed(.tooSlow), "recognized \(offset) s from now")
        }
        XCTAssertEqual(fake.events, [])
        XCTAssertEqual(fill(dialog, recognizedAt: fake.now().addingTimeInterval(-9.9)), .filled(.directValue))
        XCTAssertEqual(field.content, password)
    }

    func testRefusesWhenTheFieldWasReplaced() throws {
        let (window, _) = shapes.keychain()
        let dialog = try open(window)
        window.children[3] = fake.secureField()
        XCTAssertEqual(fill(dialog), .failed(.changed))
        XCTAssertEqual(fake.events, [])
    }

    func testRefusesWhenTheHostChangedRestartedOrExitedOrTheWindowClosed() throws {
        let (window, _) = shapes.keychain()
        let dialog = try open(window)
        let original = dialog.identity
        fake.identities[pid] = DialogHostIdentity(pid: pid, processInstance: original.processInstance,
                                                  executablePath: original.executablePath,
                                                  signingIdentifier: original.signingIdentifier, codeHash: Data([9]))
        XCTAssertEqual(fill(dialog), .failed(.changed), "Same process, different code")
        // A restarted or exited host took its box with it.
        fake.identities[pid] = FakeDialogSystem.identity(pid: pid, host: FakeDialogSystem.securityAgent, start: 500)
        XCTAssertEqual(fill(dialog), .failed(.closed))
        fake.identities[pid] = nil
        XCTAssertEqual(fill(dialog), .failed(.closed))
        fake.identities[pid] = dialog.identity
        fake.windows[pid] = []
        XCTAssertEqual(fill(dialog), .failed(.closed))
        fake.windows[pid] = [window]
        fake.trusted = false
        XCTAssertEqual(fill(dialog), .failed(.noPermission))
        XCTAssertEqual(fake.events, [])
    }

    func testRefusesPasswordsThatCouldSubmitOrAreUnusable() throws {
        let (window, field, _) = shapes.admin()
        let dialog = try open(window)
        fake.appKeysDelivered = true
        for bad in ["pass\rword", "pass\nword", "tab\tbed", ""] {
            XCTAssertEqual(fill(dialog, bad), .failed(.unusablePassword))
        }
        XCTAssertEqual(filler.fill(dialog, password: [0xFF, 0xFE], recognizedAt: fake.now()),
                       .failed(.unusablePassword))
        XCTAssertEqual(fake.events, [])
        XCTAssertEqual(field.content, "")
    }

    func testNothingIsTypedWhileTheMacIsRemotelyControlled() throws {
        let keychain = shapes.keychain()
        fake.remoteControlled = true
        XCTAssertEqual(fill(try open(keychain.window)), .failed(.screenSharing))
        XCTAssertEqual(keychain.field.content, "")
        setUp()
        let admin = shapes.admin()
        let dialog = try open(admin.window)
        fake.remoteControlled = true
        fake.appKeysDelivered = true
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        XCTAssertEqual(fill(dialog), .failed(.screenSharing))
        XCTAssertEqual(fake.events, [], "Not one key, write or focus change")
        XCTAssertEqual(admin.field.content, "")
    }

    func testRefusesWhenTheLengthCannotBeRead() throws {
        let (window, _) = shapes.keychain()
        let dialog = try open(window)
        fake.unreadableCount = true
        XCTAssertEqual(fill(dialog), .failed(.unreadable))
        XCTAssertEqual(fake.events, [])
    }

    func testOnlyFillDecisionsAreFilled() throws {
        let touchID = try open(shapes.touchID().window, host: FakeDialogSystem.coreautha)
        XCTAssertEqual(fill(touchID), .failed(.cannotFill))
        setUp()
        let other = try open(shapes.keychain("System").window)
        XCTAssertEqual(fill(other), .failed(.cannotFill))
        XCTAssertEqual(fake.events, [])
    }

    // MARK: Use Password…

    func testPressUsePasswordWaitsForTheBox() throws {
        let (window, _, field) = shapes.touchID(fieldAfter: 0.3)
        let dialog = try open(window, host: FakeDialogSystem.coreautha)
        let start = fake.uptime()
        let refreshed = try filler.pressUsePassword(dialog)
        XCTAssertEqual(refreshed.decision, .fill(method: .typedKeys))
        XCTAssertTrue(CFEqual(try XCTUnwrap(refreshed.field), field.element))
        XCTAssertEqual(refreshed.dialogKey, dialog.dialogKey)
        XCTAssertLessThan(fake.uptime() - start, 0.5)
        XCTAssertEqual(fake.events, ["press:Use Password…"])
    }

    func testPressUsePasswordGivesUpAfterOneAndAHalfSeconds() throws {
        let dialog = try open(shapes.touchID(fieldAfter: nil).window, host: FakeDialogSystem.coreautha)
        let start = fake.uptime()
        XCTAssertThrowsError(try filler.pressUsePassword(dialog)) {
            XCTAssertEqual($0.localizedDescription, "The password box didn't appear.")
        }
        XCTAssertGreaterThanOrEqual(fake.uptime() - start, 1.5)
        XCTAssertLessThan(fake.uptime() - start, 1.7)
    }

    func testPressUsePasswordStopsAtOnceWhenTheBoxCloses() throws {
        let (window, button, _) = shapes.touchID(fieldAfter: nil)
        let dialog = try open(window, host: FakeDialogSystem.coreautha)
        button.onPress = { [fake, pid] in fake!.after(0.2) { fake!.windows[pid] = [] } }
        let start = fake.uptime()
        XCTAssertThrowsError(try filler.pressUsePassword(dialog)) { XCTAssertEqual($0 as? DialogProblem, .closed) }
        XCTAssertLessThan(fake.uptime() - start, 0.5)
    }

    func testPressUsePasswordStopsAtOnceWhenTheHostExits() throws {
        // Tripwire: coreautha can exit as its box closes, and the wait went on retrying a dead host for 1.5 s.
        let (window, button, _) = shapes.touchID(fieldAfter: nil)
        let dialog = try open(window, host: FakeDialogSystem.coreautha)
        button.onPress = { [fake, pid] in fake!.after(0.2) { fake!.identities[pid] = nil } }
        let start = fake.uptime()
        XCTAssertThrowsError(try filler.pressUsePassword(dialog)) { XCTAssertEqual($0 as? DialogProblem, .closed) }
        XCTAssertLessThan(fake.uptime() - start, 0.5)
    }

    func testPressUsePasswordRefusesAChangedHostOrAFillableDialog() throws {
        let dialog = try open(shapes.touchID().window, host: FakeDialogSystem.coreautha)
        fake.identities[pid] = FakeDialogSystem.identity(pid: pid, host: FakeDialogSystem.coreautha, start: 700)
        XCTAssertThrowsError(try filler.pressUsePassword(dialog))
        setUp()
        XCTAssertThrowsError(try filler.pressUsePassword(try open(shapes.keychain().window)))
        XCTAssertEqual(fake.events, [])
    }

    // MARK: System Settings

    func testSystemSettingsIsTypedAtKeyboardLevelOnly() throws {
        let (window, _, field, _) = shapes.settings(fieldOwner: 90_050, touchID: true)
        fake.settingsExtensions = [90_050]
        let dialog = try filler.pressUsePassword(try open(window, host: FakeDialogSystem.systemSettings))
        XCTAssertEqual(dialog.decision, .fill(method: .keyboardKeys))
        fake.appKeysDelivered = true
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        XCTAssertEqual(fill(dialog), .filled(.keyboard))
        XCTAssertEqual(field.content, password)
        XCTAssertEqual(fake.events, ["press:Use Password…", "focus"] + probe + repeated("keyboard:text", password.count),
                       "Keys posted to System Settings could land in its search field, so none are sent")
    }

    func testSystemSettingsIsNotTypedIntoFromBehindAnotherApp() throws {
        let (window, _, field, _) = shapes.settings(fieldOwner: 90_050)
        fake.settingsExtensions = [90_050]
        let dialog = try open(window, host: FakeDialogSystem.systemSettings)
        fake.keyboardKeysDelivered = true
        fake.frontmost = 1
        XCTAssertEqual(fill(dialog), .failed(.clickTheBox))
        XCTAssertEqual(fake.events, ["focus"])
        XCTAssertEqual(field.content, "")
        XCTAssertEqual(fake.strayKeyboardText, "")
    }

    func testUnreadableLengthAfterTheProbeSendsNothingMore() throws {
        // Tripwire: clearing keys used to follow a probe whose landing couldn't be read; the probe may have gone astray.
        let (window, _, _, _) = shapes.settings(fieldOwner: 90_050)
        fake.settingsExtensions = [90_050]
        let dialog = try open(window, host: FakeDialogSystem.systemSettings)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        fake.after(0.1) { [fake] in fake?.unreadableCount = true }
        XCTAssertEqual(fill(dialog), .failed(.keyMissed))
        XCTAssertEqual(fake.events, ["focus", "keyboard:text"], "No Delete after a probe that can't be confirmed")
    }

    func testUnverifiedFieldAfterUsePasswordSaysSo() throws {
        // Tripwire: this used to wait out the 1.5 s and report "The password box didn't appear."
        let (window, _, _, _) = shapes.settings(fieldOwner: 4242, touchID: true)
        let dialog = try open(window, host: FakeDialogSystem.systemSettings)
        XCTAssertThrowsError(try filler.pressUsePassword(dialog)) { XCTAssertEqual($0 as? DialogProblem, .unverified) }
    }

    // MARK: Passwords

    func testPasswordsLockScreenIsTypedAtKeyboardLevelOnly() throws {
        let (window, field, _) = shapes.passwordsLocked(touchID: true)
        fake.frontmost = pid
        let dialog = try filler.pressUsePassword(try open(window, host: FakeDialogSystem.passwords))
        XCTAssertEqual(dialog.decision, .fill(method: .keyboardKeys))
        fake.appKeysDelivered = true
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        XCTAssertEqual(fill(dialog), .filled(.keyboard))
        XCTAssertEqual(field.content, password)
        XCTAssertEqual(fake.events, ["press:Use Password…", "focus"] + probe + repeated("keyboard:text", password.count))
    }

    func testPasswordsLockScreenGetsReturnOnlyWhenTheWholePasswordIsIn() throws {
        let (window, field, _) = shapes.passwordsLocked()
        fake.frontmost = pid
        let dialog = try open(window, host: FakeDialogSystem.passwords)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        XCTAssertEqual(fill(dialog), .filled(.keyboard))
        XCTAssertTrue(filler.submit(dialog, password: Array(password.utf8)))
        XCTAssertEqual(fake.events.last, "keyboard:return")
        XCTAssertEqual(field.submittedContent, password)

        field.content = String(password.dropLast())
        XCTAssertFalse(filler.submit(dialog, password: Array(password.utf8)), "Not the whole password")
        field.content = password
        fake.frontmost = 1
        XCTAssertFalse(filler.submit(dialog, password: Array(password.utf8)), "Passwords no longer in front")
        fake.frontmost = pid
        fake.remoteControlled = true
        XCTAssertFalse(filler.submit(dialog, password: Array(password.utf8)), "Someone may be watching")
        XCTAssertEqual(fake.events.filter { $0 == "keyboard:return" }.count, 1)
    }

    func testBoxesAnyProgramCanRaiseAreNeverApproved() throws {
        // Tripwire: admin, keychain and general Touch ID boxes wait for the user's own click, even when their button
        // reads like System Settings' (SecurityAgent's admin box can say "… is trying to modify your system settings.").
        func neverApproved(host: DialogPolicy.Host, usePassword: Bool = false,
                           _ build: () -> FakeDialogSystem.Node) throws {
            setUp()
            let dialog = try open(build(), host: host)
            let target = usePassword ? try filler.pressUsePassword(dialog) : dialog
            fake.appKeysDelivered = true
            fake.keyboardKeysDelivered = true
            fake.frontmost = pid
            guard case .filled = fill(target) else { return XCTFail("\(host.identifier) wasn't filled") }
            XCTAssertNil(target.confirmButton)
            XCTAssertFalse(filler.submit(target, password: Array(password.utf8)))
            XCTAssertFalse(fake.events.contains { $0.hasSuffix(":return") || ($0.hasPrefix("press:") && $0 != "press:Use Password…") },
                           "\(host.identifier): \(fake.events)")
        }
        try neverApproved(host: FakeDialogSystem.securityAgent) { shapes.admin().window }
        try neverApproved(host: FakeDialogSystem.securityAgent) { shapes.keychain().window }
        try neverApproved(host: FakeDialogSystem.coreautha, usePassword: true) { shapes.touchID().window }
        for title in ["Modify Settings", "Unlock"] {
            try neverApproved(host: FakeDialogSystem.securityAgent) {
                let window = shapes.admin().window
                window.children[0].children.append(fake.button(title))
                return window
            }
            try neverApproved(host: FakeDialogSystem.coreautha, usePassword: true) {
                let window = shapes.touchID().window
                window.children[0].children.append(fake.button(title))
                return window
            }
        }
    }

    func testSystemSettingsBoxIsApprovedOnlyWhenTheWholePasswordIsIn() throws {
        let (window, _, field, _) = shapes.settings(fieldOwner: 90_050)
        fake.settingsExtensions = [90_050]
        let dialog = try open(window, host: FakeDialogSystem.systemSettings)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        XCTAssertEqual(fill(dialog), .filled(.keyboard))
        field.content = String(password.dropLast())
        XCTAssertFalse(filler.submit(dialog, password: Array(password.utf8)), "Not the whole password")
        field.content = password
        fake.frontmost = 1
        XCTAssertFalse(filler.submit(dialog, password: Array(password.utf8)), "System Settings no longer in front")
        fake.frontmost = pid
        XCTAssertTrue(filler.submit(dialog, password: Array(password.utf8)))
        XCTAssertEqual(fake.events.filter { $0.hasPrefix("press:") }, ["press:Unlock"])
    }

    func testSystemSettingsBoxWithAnUnknownButtonWaitsForTheUser() throws {
        let (window, sheet, _, _) = shapes.settings(fieldOwner: 90_050)
        fake.settingsExtensions = [90_050]
        let group = sheet.children[0]
        group.children = group.children.map { $0.title == "Unlock" ? fake.button("Delete Everything") : $0 }
        let dialog = try open(window, host: FakeDialogSystem.systemSettings)
        XCTAssertNil(dialog.confirmButton)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        XCTAssertEqual(fill(dialog), .filled(.keyboard))
        XCTAssertFalse(filler.submit(dialog, password: Array(password.utf8)))
        XCTAssertFalse(fake.events.contains { $0.hasPrefix("press:") })
    }

    func testPasswordsIsNeverBroughtForwardToBeUnlocked() throws {
        // Tripwire: with this app in front (Settings), Passwords used to be brought forward, filled and unlocked.
        let (window, field, _) = shapes.passwordsLocked()
        fake.frontmost = pid
        let dialog = try open(window, host: FakeDialogSystem.passwords)
        fake.keyboardKeysDelivered = true
        fake.frontmost = fake.ownPID
        XCTAssertEqual(fill(dialog), .failed(.clickTheBox))
        XCTAssertFalse(fake.events.contains("activate"))
        XCTAssertFalse(filler.submit(dialog, password: Array(password.utf8)))
        XCTAssertEqual(field.content, "")
        XCTAssertNil(field.submittedContent)
    }
}
