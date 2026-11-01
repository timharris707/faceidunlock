import XCTest
@testable import FaceIDCore

final class DialogPolicyTests: XCTestCase {
    private let securityAgent = "com.apple.SecurityAgent"
    private let coreautha = "com.apple.LocalAuthentication.UIAgent"
    private let settings = "com.apple.systempreferences"
    private let passwords = "com.apple.Passwords"

    private func facts(_ host: String, texts: [String] = [], secure: Int = 0, plain: [String] = [],
                       usePassword: Bool = false, hosting: Bool = false) -> DialogFacts {
        DialogFacts(hostBundleID: host, staticTexts: texts, secureFieldCount: secure, plainFieldValues: plain,
                    hasUsePasswordButton: usePassword, secureFieldInHostingView: hosting,
                    userName: "timharris", fullUserName: "Tim Harris")
    }

    // Step 0 shape 1: SecurityAgent keychain unlock, AppKit.
    func testLoginKeychainDialogGetsADirectWrite() {
        let decision = DialogPolicy.decide(facts(securityAgent, texts: [
            "security wants to use the “login” keychain.", "Please enter the keychain password.", "Password:"
        ], secure: 1))
        XCTAssertEqual(decision, .fill(method: .directValue))
    }

    // Step 0 shape 2: coreautha, SwiftUI, opens in Touch ID mode.
    func testTouchIDModeNeedsUsePasswordThenTypedKeys() {
        let texts = ["Keychain Access", "Touch ID or enter your password to allow this."]
        XCTAssertEqual(DialogPolicy.decide(facts(coreautha, texts: texts, usePassword: true)), .needsUsePasswordClick)
        XCTAssertEqual(DialogPolicy.decide(facts(coreautha, texts: texts, secure: 1, hosting: true)),
                       .fill(method: .typedKeys))
        XCTAssertEqual(DialogPolicy.decide(facts(coreautha, texts: texts, secure: 1, usePassword: true, hosting: true)),
                       .fill(method: .typedKeys), "Once the box exists, fill it even if the button is still there")
    }

    // Step 0 shape 3: SecurityAgent admin dialog, SwiftUI, user name plus password.
    func testAdminDialogForThisUserGetsTypedKeys() {
        let texts = ["Allow administrator access for a script started by “Terminal”."]
        for name in ["timharris", "Tim Harris", "TIMHARRIS", " timharris ", ""] {
            XCTAssertEqual(DialogPolicy.decide(facts(securityAgent, texts: texts, secure: 1, plain: [name], hosting: true)),
                           .fill(method: .typedKeys), "user name \(name)")
        }
    }

    func testAnotherUsersNameIsSkipped() {
        let decision = DialogPolicy.decide(facts(securityAgent, texts: ["Allow administrator access"], secure: 1,
                                                 plain: ["admin"], hosting: true))
        XCTAssertEqual(decision, .skip(reason: "This box asks for another user's password."))
    }

    func testEmptyAccountNamesNeverMatchAName() {
        let anonymous = DialogFacts(hostBundleID: securityAgent, secureFieldCount: 1, plainFieldValues: ["admin"],
                                    userName: "", fullUserName: "")
        XCTAssertEqual(DialogPolicy.decide(anonymous), .skip(reason: "This box asks for another user's password."))
    }

    func testOtherKeychainsAreSkipped() {
        for (text, name) in [("security wants to use the “System” keychain.", "System"),
                             ("To allow this, enter the “throwaway” keychain password.", "throwaway"),
                             ("security wants to use the \"Work\" Keychain.", "Work")] {
            XCTAssertEqual(DialogPolicy.decide(facts(securityAgent, texts: [text], secure: 1)),
                           .skip(reason: "This box asks for the “\(name)” keychain password."))
        }
    }

    func testItemNamesAndLoginKeychainAreNotMistakenForOtherKeychains() {
        let texts = ["codesign wants to use your confidential information stored in “Secret Thing” in your keychain.",
                     "To allow this, enter the “login” keychain password."]
        XCTAssertEqual(DialogPolicy.decide(facts(securityAgent, texts: texts, secure: 1)), .fill(method: .directValue))
        XCTAssertEqual(DialogPolicy.decide(facts(securityAgent, texts: ["Keychain Access wants to use the “LOGIN” keychain."],
                                                 secure: 1)), .fill(method: .directValue))
    }

    func testMoreThanOnePasswordBoxIsSkipped() {
        let decision = DialogPolicy.decide(facts(securityAgent, texts: ["Enter a new password."], secure: 2))
        XCTAssertEqual(decision, .skip(reason: "This box asks for more than one password."))
    }

    func testSkipRulesStillApplyBeforeUsePasswordClick() {
        XCTAssertEqual(DialogPolicy.decide(facts(securityAgent, texts: ["Touch ID to use the “System” keychain."],
                                                 usePassword: true)),
                       .skip(reason: "This box asks for the “System” keychain password."))
    }

    func testDialogsWithoutAPasswordBoxOrButtonAreIgnored() {
        XCTAssertEqual(DialogPolicy.decide(facts(securityAgent, texts: ["security wants to use the “System” keychain."])),
                       .none, "An Allow/Deny window is not a password box")
        XCTAssertEqual(DialogPolicy.decide(facts(coreautha, plain: ["admin"])), .none)
    }

    func testUnknownHostsAreNeverFilled() {
        XCTAssertEqual(DialogPolicy.decide(facts("com.example.Fake", secure: 1)), .none)
        XCTAssertEqual(DialogPolicy.decide(facts("com.apple.tcc.AuthorizationPromptService", secure: 1)), .none)
        XCTAssertEqual(DialogPolicy.host(for: securityAgent)?.executablePath,
                       "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent")
        XCTAssertNil(DialogPolicy.host(for: nil))
    }

    func testRequesterLineIsTheFirstTextOnOneShortLine() {
        XCTAssertEqual(DialogPolicy.requesterLine(["", "  ", "Keychain Access wants\n to  view a password.", "Other"]),
                       "Keychain Access wants to view a password.")
        let long = String(repeating: "word ", count: 30)
        let line = DialogPolicy.requesterLine([long])
        XCTAssertEqual(line?.count, 80)
        XCTAssertEqual(line?.hasSuffix("…"), true)
        XCTAssertEqual(DialogPolicy.requesterLine([String(repeating: "a", count: 80)])?.count, 80)
        XCTAssertNil(DialogPolicy.requesterLine([]))
        XCTAssertNil(DialogPolicy.requesterLine([" \n"]))
    }

    func testUsePasswordTitles() {
        for title in ["Use Password…", "Use Password...", "use password", " Use Password… "] {
            XCTAssertTrue(DialogPolicy.isUsePasswordTitle(title), title)
        }
        for title in [nil, "", "Password", "Cancel", "OK", "Use Passwords", "Allow Access"] as [String?] {
            XCTAssertFalse(DialogPolicy.isUsePasswordTitle(title), title ?? "nil")
        }
    }

    // System Settings' box, recorded 2026-10-30: a sheet whose field lives in another process.
    func testSystemSettingsPasswordBoxIsTypedAtKeyboardLevel() {
        let title = "Privacy & Security is trying to modify your system settings."
        XCTAssertEqual(DialogPolicy.decide(facts(settings, texts: [title, "Enter your password to continue with Privacy & Security."],
                                                 secure: 1, plain: ["Tim Harris"], hosting: true)),
                       .fill(method: .keyboardKeys))
        XCTAssertEqual(DialogPolicy.decide(facts(settings, texts: [title, "Touch ID or enter your password to continue."],
                                                 usePassword: true)), .needsUsePasswordClick)
        XCTAssertEqual(DialogPolicy.decide(facts(settings, texts: [title], secure: 1, plain: ["admin"], hosting: true)),
                       .skip(reason: "This box asks for another user's password."))
    }

    func testSystemSettingsSheetsForOtherPasswordsAreIgnored() {
        for texts in [["The Wi-Fi network “Home” requires a WPA2 password."], ["Sign in with your Apple Account."], []] {
            XCTAssertEqual(DialogPolicy.decide(facts(settings, texts: texts, secure: 1, plain: ["Tim Harris"], hosting: true)),
                           .none, "\(texts)")
        }
        // Tripwire: a nearby network can be named so its sheet says "is trying to", and an Enterprise Wi-Fi sheet
        // has a user name field the owner may fill with his own name. Only the whole request line counts.
        let spoofs = ["The Wi-Fi network “x is trying to unlock settings.” requires a WPA2 password.",
                      "The Wi-Fi network “Mac is trying to unlock settings” requires WPA2 enterprise credentials.",
                      "Mac is trying to unlock settings", " is trying to unlock system settings."]
        for text in spoofs {
            for plain in [[], [""], ["  "], ["timharris"], ["Tim Harris", ""]] {
                XCTAssertEqual(DialogPolicy.decide(facts(settings, texts: [text], secure: 1, plain: plain, hosting: true)),
                               .none, "\(text) \(plain)")
            }
        }
    }

    func testEverySystemSettingsRequestLineIsRecognized() {
        for title in ["Users & Groups is trying to unlock system settings.",
                      "Privacy & Security is trying to modify your system settings.",
                      "Users & Groups is trying to modify your account settings.",
                      "  Privacy & Security is trying to unlock system settings.\n"] {
            XCTAssertEqual(DialogPolicy.decide(facts(settings, texts: [title], secure: 1, plain: ["Tim Harris"], hosting: true)),
                           .fill(method: .keyboardKeys), title)
        }
    }

    // Passwords' lock screen, recorded 2026-10-30.
    func testPasswordsLockScreenForThisUserIsTypedAtKeyboardLevel() {
        let locked = "Passwords Is Locked"
        XCTAssertEqual(DialogPolicy.decide(facts(passwords, texts: [locked, "Touch ID or enter your password to continue."],
                                                 usePassword: true)), .needsUsePasswordClick)
        for name in ["Tim Harris", "timharris"] {
            XCTAssertEqual(DialogPolicy.decide(facts(passwords, texts: [locked, "Enter the password for the user “\(name)” to unlock."],
                                                     secure: 1, hosting: true)), .fill(method: .keyboardKeys), name)
        }
    }

    func testPasswordsOtherScreensAreIgnored() {
        // Tripwire: unlocked, Passwords shows saved passwords in secure fields; never fill those.
        XCTAssertEqual(DialogPolicy.decide(facts(passwords, texts: ["example.com", "Password"], secure: 1, hosting: true)), .none)
        XCTAssertEqual(DialogPolicy.decide(facts(passwords, texts: ["Passwords Is Locked", "Enter the password for the user “Someone Else” to unlock."],
                                                 secure: 1, hosting: true)), .none)
        XCTAssertEqual(DialogPolicy.decide(facts(passwords, texts: ["Passwords Is Locked"], secure: 1, hosting: true)), .none)
    }

    func testPasswordsLockScreenMustBeExactlyTheLockScreen() {
        // Tripwire: login names others choose can put the lock screen's lines into an unlocked window.
        let lines = ["Passwords Is Locked", "Enter the password for the user “Tim Harris” to unlock."]
        XCTAssertEqual(DialogPolicy.decide(facts(passwords, texts: lines + ["New Password", "Title", "Website", "User Name", "Password", "Notes"],
                                                 secure: 1, plain: ["", "", ""], hosting: true)), .none)
        XCTAssertEqual(DialogPolicy.decide(facts(passwords, texts: lines, secure: 1, plain: [""], hosting: true)), .none,
                       "The lock screen has no other field")
        XCTAssertEqual(DialogPolicy.decide(facts(passwords, texts: lines + ["Incorrect password"], secure: 1, hosting: true)), .none)
        XCTAssertEqual(DialogPolicy.decide(facts(passwords, texts: lines + ["", "  "], secure: 1, hosting: true)),
                       .fill(method: .keyboardKeys), "Blank lines don't count")
    }

    func testOnlySecurityAgentBoxesAndPasswordsLockScreenAskForTheGlance() {
        // Owner's decision 2026-10-30 (L4): admin and keychain prompts and Passwords' lock screen, not System Settings'
        // sheets or the general Touch ID box.
        XCTAssertEqual(DialogPolicy.hosts.filter(\.needsGlance).map(\.identifier), [securityAgent, passwords])
        XCTAssertEqual(DialogPolicy.host(for: settings)?.needsGlance, false)
        XCTAssertEqual(DialogPolicy.host(for: coreautha)?.needsGlance, false)
    }
}
