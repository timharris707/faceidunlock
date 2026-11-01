import AppKit
import XCTest
@testable import FaceIDUnlock

final class MacPasswordSessionTests: XCTestCase {
    /// Stands in for OpenDirectory: only "right-test-value" is the account password.
    private final class Verifier: MacPasswordVerifier, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let failure: Error?
        init(failure: Error? = nil) { self.failure = failure }
        var calls: Int { lock.withLock { count } }
        func isLoginPassword(_ password: String) throws -> Bool {
            lock.withLock { count += 1 }
            if let failure { throw failure }
            return password == "right-test-value"
        }
    }

    private let workspace = NotificationCenter()
    private let app = NotificationCenter()

    @MainActor
    private func session(_ verifier: Verifier = Verifier()) -> MacPasswordSession {
        MacPasswordSession(verifier: verifier, workspace: workspace, app: app)
    }

    @MainActor
    private func savedSession() async throws -> MacPasswordSession {
        let session = session()
        try await session.save("right-test-value")
        return session
    }

    @MainActor
    private func assertKept(_ session: MacPasswordSession, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(session.hasPassword, file: file, line: line)
        session.withPassword { XCTAssertEqual($0, Array("right-test-value".utf8), file: file, line: line) }
    }

    @MainActor
    private func assertErased(_ session: MacPasswordSession, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(session.hasPassword, file: file, line: line)
        session.withPassword { XCTAssertTrue($0.isEmpty, file: file, line: line) }
    }

    @MainActor
    func testCheckedPasswordIsKept() async throws {
        assertKept(try await savedSession())
    }

    @MainActor
    func testWrongPasswordIsRefusedInPlainWords() async {
        let session = session()
        do {
            try await session.save("wrong-test-value")
            XCTFail("A wrong password was kept")
        } catch {
            XCTAssertEqual(error as? MacPasswordError, .wrongPassword)
            XCTAssertEqual(error.localizedDescription, "That isn't your Mac password.")
        }
        assertErased(session)
    }

    @MainActor
    func testWrongPasswordLeavesTheEarlierCheckedOne() async throws {
        let session = try await savedSession()
        try? await session.save("wrong-test-value")
        assertKept(session)
    }

    @MainActor
    func testEmptyPasswordIsRefusedWithoutAskingTheSystem() async {
        let verifier = Verifier()
        let session = session(verifier)
        do { try await session.save(""); XCTFail("An empty password was kept") }
        catch { XCTAssertEqual(error as? MacPasswordError, .wrongPassword) }
        XCTAssertEqual(verifier.calls, 0)
    }

    @MainActor
    func testFailedCheckIsNotCalledAWrongPassword() async {
        struct Unreachable: Error {}
        let session = session(Verifier(failure: Unreachable()))
        do { try await session.save("right-test-value"); XCTFail("An unchecked password was kept") }
        catch { XCTAssertEqual(error as? MacPasswordError, .couldNotCheck) }
        assertErased(session)
    }

    @MainActor
    func testVerifyChecksThePasswordWithoutKeepingOrReplacingOne() async throws {
        // The Home Test gate (decision L5) checks the password the same way, but must not change the saved one.
        let fresh = session()
        try await fresh.verify("right-test-value")
        assertErased(fresh)

        let saved = try await savedSession()
        do { try await saved.verify("wrong-test-value"); XCTFail("A wrong password passed") }
        catch { XCTAssertEqual(error as? MacPasswordError, .wrongPassword) }
        assertKept(saved)

        let verifier = Verifier()
        do { try await session(verifier).verify(""); XCTFail("An empty password passed") }
        catch { XCTAssertEqual(error as? MacPasswordError, .wrongPassword) }
        XCTAssertEqual(verifier.calls, 0)

        struct Unreachable: Error {}
        do { try await session(Verifier(failure: Unreachable())).verify("right-test-value"); XCTFail("Unchecked") }
        catch { XCTAssertEqual(error as? MacPasswordError, .couldNotCheck) }
    }

    /// Tripwire for the old behavior that erased the password on every lock and sleep (decision D1).
    @MainActor
    func testPasswordSurvivesLockSleepAndAppSwitching() async throws {
        let session = try await savedSession()
        let names: [Notification.Name] = [
            NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            .init("com.apple.screenIsLocked"), .init("com.apple.screenIsUnlocked"),
            .init("com.apple.screensaver.didstart"),
            NSApplication.willResignActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification
        ]
        for name in names {
            workspace.post(name: name, object: nil)
            app.post(name: name, object: nil)
        }
        assertKept(session)
    }

    @MainActor
    func testSwitchingToAnotherUserErasesThePassword() async throws {
        let session = try await savedSession()
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        assertErased(session)
    }

    @MainActor
    func testQuitErasesThePassword() async throws {
        let session = try await savedSession()
        app.post(name: NSApplication.willTerminateNotification, object: nil)
        assertErased(session)
    }

    @MainActor
    func testForgetErasesThePassword() async throws {
        let session = try await savedSession()
        session.forget()
        assertErased(session)
        session.forget()
        assertErased(session)
    }

    @MainActor
    func testPasswordCanBeSavedAgainAfterForget() async throws {
        let session = try await savedSession()
        session.forget()
        try await session.save("right-test-value")
        assertKept(session)
    }

    @MainActor
    func testSwitchingUserDuringTheCheckKeepsNothing() async throws {
        final class SlowVerifier: MacPasswordVerifier, @unchecked Sendable {
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            func isLoginPassword(_ password: String) throws -> Bool {
                started.signal()
                release.wait()
                return true
            }
        }
        let verifier = SlowVerifier()
        let session = MacPasswordSession(verifier: verifier, workspace: workspace, app: app)
        let saving = Task { @MainActor in try await session.save("right-test-value") }
        await withCheckedContinuation { done in
            DispatchQueue.global().async { verifier.started.wait(); done.resume() }
        }
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        verifier.release.signal()
        do { try await saving.value; XCTFail("A password checked before the switch was kept") }
        catch { XCTAssertTrue(error is CancellationError) }
        assertErased(session)
    }
}
