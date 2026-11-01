import ApplicationServices
import Combine
import CoreVideo
import FaceIDCore
import XCTest
@testable import FaceIDUnlock

/// The daily flow with every system boundary faked: the dialog tree, the keychain item, the password check,
/// the camera list, the preferences and the face check. No camera, Accessibility, keychain or OpenDirectory
/// call is made.
@MainActor
final class AppControllerTests: XCTestCase {
    /// Any password but "wrong-password" is the account's.
    private final class AnyPassword: MacPasswordVerifier {
        func isLoginPassword(_ password: String) throws -> Bool { password != "wrong-password" }
    }

    /// Like AnyPassword, but each check waits for `release()`, so a test can act while it runs.
    private final class GatedPassword: MacPasswordVerifier, @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var started = false
        var isChecking: Bool { lock.withLock { started } }
        func release() { gate.signal() }
        func isLoginPassword(_ password: String) throws -> Bool {
            lock.withLock { started = true }
            gate.wait()
            return password != "wrong-password"
        }
    }

    /// The cameras discovery sees. Like the camera service, it sends a new list just before holding it.
    @MainActor
    private final class FakeCameras: CameraList {
        /// Off: changes go unreported, as when a camera connects just before its notification arrives.
        var reportsChanges = true
        var devices: [CameraDevice] { willSet { if reportsChanges { changes.send(newValue) } } }
        private let changes: CurrentValueSubject<[CameraDevice], Never>
        var devicesPublisher: AnyPublisher<[CameraDevice], Never> { changes.eraseToAnyPublisher() }
        init(_ devices: [CameraDevice]) {
            self.devices = devices
            changes = CurrentValueSubject(devices)
        }
    }

    /// What a faked face check does: match, and turn the way a glance asks; match, then turn the other way; match,
    /// then hold still through the glance until cancelled; see the owner only on what the photo/screen detector
    /// calls a screen, until it gives up; see only a face that doesn't match until it gives up; see no face until
    /// it gives up; see only the owner, with a second face in view between, until it gives up; or see a face that
    /// doesn't match and run until cancelled.
    private enum Check { case recognized, wrongWay, glancing, onScreen, notRecognized, noFace, secondFace, looking }

    private final class MemoryItem: SecretItem, @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func read() throws -> Data? { lock.withLock { data } }
        func write(_ data: Data) throws { lock.withLock { self.data = data } }
        func delete() throws { lock.withLock { data = nil } }
    }

    private let pid: pid_t = 91_001
    /// A made-up password for the fake only.
    private let password = "pa55-Word!"
    private let face = FaceGallery(samples: [.init(pose: .center, embedding: [1] + Array(repeating: 0, count: 127))])
    /// Scores 0 against `face`.
    private let stranger: [Float] = [0, 1] + Array(repeating: 0, count: 126)
    private let usbCamera = CameraDevice(id: "0x1100000046d0825", displayName: "USB Camera")
    private let phoneCamera = CameraDevice(id: "phone-camera", displayName: "Tim's iPhone Camera")
    private var fake: FakeDialogSystem!
    private var shapes: DialogShapes!
    private var logURL: URL!
    /// Home Test pictures, beside the log in the test's own temporary folder.
    private var picturesURL: URL { logURL.deletingLastPathComponent().appendingPathComponent("Test Pictures") }
    /// Stands in for the app's preferences; a second controller on them is a relaunch.
    private var defaults: MemoryPreferences!
    private var cameras: FakeCameras!
    /// The cameras discovery sees; changing it is reported as a change unless `cameras.reportsChanges` is off.
    private var connected: [CameraDevice] {
        get { cameras.devices }
        set { cameras.devices = newValue }
    }
    /// What each face check does, in order; `.looking` once the list is empty.
    private var outcomes: [Check] = []
    private var checks = 0
    private var cancelledChecks = 0
    /// The glance each face check was given, nil where the box needs none.
    private var glances: [GlanceCheck.Direction?] = []
    /// Runs at the start of each face check.
    private var onCheck: (() -> Void)?
    /// Runs as a faked glance asks which way to turn.
    private var onGlance: (() -> Void)?
    /// The `analyze` flag of each camera capture: true for face setup, false for the Settings preview.
    private var captures: [Bool] = []
    private var remembered = 0
    private var prompt: () async -> Bool = { false }
    /// Whether the camera is allowed.
    private var cameraGranted = true
    /// Face setup's camera stays on, sending nothing, until it is cancelled.
    private var setupHolds = false
    /// The faked camera is on.
    private var cameraOn = false
    /// The faked camera's person rests at this head angle; off centre only where a test sets it.
    private var restYaw = 0.0

    override func setUp() async throws {
        fake = FakeDialogSystem()
        shapes = DialogShapes(fake: fake)
        logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppControllerTests-\(UUID().uuidString)/scores.jsonl")
        defaults = MemoryPreferences()
        cameras = FakeCameras([CameraDevice(id: "built-in", displayName: "MacBook Pro Camera", isBuiltIn: true)])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent())
        // No path may ever press OK or Allow; only System Settings' own approve buttons may be pressed.
        let allowed: Set = ["press:Use Password…", "press:Unlock", "press:Modify Settings"]
        XCTAssertFalse(fake.events.contains { $0.hasPrefix("press:") && !allowed.contains($0) }, "\(fake.events)")
    }

    /// `liveCheck`: face checks run the app's own camera loop on the faked camera instead of the faked check.
    private func controller(passwordSaved: Bool = true, faceSaved: Bool = true,
                            verifier: any MacPasswordVerifier = AnyPassword(),
                            liveCheck: Bool = false) async throws -> AppController {
        let session = MacPasswordSession(verifier: verifier, workspace: NotificationCenter(), app: NotificationCenter())
        if passwordSaved { try await session.save(password) }
        let item = MemoryItem()
        if faceSaved { try FaceStore(item: item).save(face) }
        let controller = AppController(
            scanner: AuthDialogScanner(system: fake, userName: "timharris", fullUserName: "Tim Harris"),
            password: session, store: FaceStore(item: item), scoreLog: ScoreLog(url: logURL),
            cameraAccess: { [unowned self] in cameraGranted }, accessibilityAccess: { true },
            faceCheck: liveCheck ? nil : { [unowned self] in await self.runCheck($0, $1, $2) },
            capture: { [unowned self] in try await self.capture($0, $1, $2) },
            tryPrompt: { [unowned self] in await self.prompt() }, rememberCamera: { [unowned self] in remembered += 1 },
            defaults: defaults, cameras: cameras, testPictures: TestPictures(folder: picturesURL))
        controller.homeTestLeadIn = 0 // The countdown has its own test.
        // As at launch.
        await controller.loadFace()
        controller.watchCameras()
        return controller
    }

    /// A real FaceCheck fed made-up frames, then for a match a real GlanceCheck, so the record is what the camera
    /// loop would produce.
    private func runCheck(_ gallery: FaceGallery, _ glance: GlanceCheck.Direction?,
                          _ asking: (GlanceCheck.Direction) -> Void) async -> CheckRecord {
        checks += 1
        glances.append(glance)
        onCheck?()
        var check = FaceCheck(gallery: gallery, startedAt: 0)
        func see(_ embedding: [Float], real: Float? = nil) {
            for step in 0...20 {
                let photoScreen = real.map { PhotoScreenScore(real: $0, probs27: [1 - $0, $0, 0], probs40: [0, $0, 1 - $0]) }
                check.observe(FaceObservation(kind: .face, timestamp: Double(step) / 10, embedding: embedding, yaw: 0,
                                              photoScreen: photoScreen), exposureSettled: true)
            }
        }
        let outcome = outcomes.isEmpty ? .looking : outcomes.removeFirst()
        switch outcome {
        case .recognized, .wrongWay, .glancing:
            see(gallery.samples[0].embedding)
        case .onScreen:
            see(gallery.samples[0].embedding, real: 0.4)
            check.tick(now: 100)
        case .notRecognized:
            see(stranger)
            check.tick(now: 100)
        case .noFace:
            check.tick(now: 0)
            check.tick(now: 100)
        case .secondFace:
            for step in 0...40 {
                let time = Double(step) / 20
                check.observe(step.isMultiple(of: 2)
                                  ? FaceObservation(kind: .face, timestamp: time, embedding: gallery.samples[0].embedding)
                                  : FaceObservation(kind: .multipleFaces, timestamp: time), exposureSettled: true)
            }
            check.tick(now: 100)
        case .looking:
            see(stranger)
            let deadline = Date().addingTimeInterval(2)
            while !Task.isCancelled, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            if Task.isCancelled { cancelledChecks += 1 }
        }
        var record = check.record
        guard record.outcome == .recognized, let glance else { return record }
        asking(glance)
        onGlance?()
        var looking = GlanceCheck(direction: glance, restingYaw: check.restingYaw, restingPoints: check.restingPoints,
                                  gallery: gallery, startedAt: 2.1)
        if outcome == .glancing {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            cancelledChecks += 1
        } else {
            // A head turn of 0.3 rad from the resting angle, the asked way or not.
            let turn = (glance == .left ? 1 : -1) * MatchSettings.leftYawSign * (outcome == .wrongWay ? -0.3 : 0.3)
            looking.observe(FaceObservation(kind: .face, timestamp: 2.5, embedding: gallery.samples[0].embedding,
                                            yaw: (check.restingYaw ?? 0) + turn))
        }
        record.glance = looking.record
        return record
    }

    /// The camera, faked. Face setup gets a person who looks straight ahead for a second, then turns each
    /// way; the Settings preview runs until it is cancelled. Each frame's pixels are one small BGRA picture; its
    /// points have eyes 80 px apart and a nose that moves 40 px per radian of turn, so a 0.3 rad turn scores 0.15.
    private func capture(_ analyze: Bool, _ onFrame: ((CVPixelBuffer, FaceObservation) -> Void)?,
                         _ step: (FaceObservation?, Bool, TimeInterval) -> Bool) async throws {
        captures.append(analyze)
        cameraOn = true
        defer { cameraOn = false }
        guard analyze, !setupHolds else {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return
        }
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_32BGRA, nil, &pixels)
        let buffer = try XCTUnwrap(pixels)
        let start = CameraService.now
        for index in 0..<600 {
            let time = Double(index) / 30
            let turn = time < 1 ? 0 : (time < 2 ? 0.3 : -0.3)
            let points = FacePoints(leftEye: [600, 300], rightEye: [680, 300], nose: [640 + 40 * turn, 350],
                                    leftMouth: [608, 380], rightMouth: [672, 380])
            let frame = FaceObservation(kind: .face, timestamp: start + time, embedding: face.samples[0].embedding,
                                        yaw: restYaw + turn, roll: 0, quality: 0.5, points: points)
            onFrame?(buffer, frame)
            if step(frame, true, start + time) { return }
        }
    }

    private func open(_ window: FakeDialogSystem.Node, host: DialogPolicy.Host = FakeDialogSystem.securityAgent) {
        fake.addHost(host, pid: pid, windows: [window])
    }

    private func scanAndFinish(_ controller: AppController) async {
        await controller.scanOnce()
        await controller.work?.value
    }

    private func loggedLines() throws -> [String] {
        try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    // MARK: Daily flow

    func testRecognizedFaceFillsTheBoxAndSaysClickOK() async throws {
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.recognized]
        let controller = try await controller()
        await controller.scanOnce()
        XCTAssertEqual(controller.bar?.text, "Looking for you…")
        XCTAssertEqual(controller.bar?.requester, "security wants to use the “login” keychain.")
        await controller.work?.value
        XCTAssertEqual(dialog.field.content, password)
        XCTAssertEqual(controller.bar?.text, "Password filled. Click OK or Allow.")
        XCTAssertNil(controller.bar?.action)
    }

    func testTouchIDBoxGetsUsePasswordClickedThenTypedInto() async throws {
        // Decision D2: after recognizing the owner, the app clicks "Use Password…" itself.
        let dialog = shapes.touchID()
        // Make the click change the box's first line, and so its key.
        let firstLine = dialog.window.children[0].children[0]
        let press = dialog.button.onPress
        dialog.button.onPress = { press?(); firstLine.value = "Enter your password to allow this." }
        open(dialog.window, host: FakeDialogSystem.coreautha)
        fake.appKeysDelivered = true
        outcomes = [.recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertTrue(fake.events.contains("press:Use Password…"))
        XCTAssertEqual(dialog.field.content, password)
        XCTAssertEqual(controller.bar?.text, "Password filled. Click OK or Allow.")
        XCTAssertEqual(glances, [nil], "The general Touch ID box gets no glance")
        // The click changed the box's contents, but it is the same box: no second check.
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 1)
    }

    func testUsePasswordBoxWhoseTextSettlesLateIsStillTheSameBox() async throws {
        // Tripwire: the box's first line changes a beat after its password field appears. That made the
        // filled box look new: a second check ran and ended on "You've started typing".
        let dialog = shapes.touchID(fieldAfter: 0.3)
        let firstLine = dialog.window.children[0].children[0]
        let press = dialog.button.onPress
        dialog.button.onPress = { [fake] in
            press?()
            fake!.after(0.5) { firstLine.value = "Enter your password to allow this." }
        }
        open(dialog.window, host: FakeDialogSystem.coreautha)
        fake.appKeysDelivered = true
        outcomes = [.recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertEqual(dialog.field.content, password)
        XCTAssertEqual(firstLine.value, "Enter your password to allow this.")
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(controller.bar?.text, "Password filled. Click OK or Allow.")
    }

    func testClickingUsePasswordYourselfDuringACheckDoesNotRestartIt() async throws {
        let dialog = shapes.touchID(fieldAfter: 0.1)
        open(dialog.window, host: FakeDialogSystem.coreautha)
        outcomes = [.looking]
        let controller = try await controller()
        await controller.scanOnce()
        XCTAssertTrue(fake.press(dialog.button.element))
        fake.pause(0.1)
        dialog.window.children[0].children[0].value = "Enter your password to allow this."
        await controller.scanOnce()
        XCTAssertEqual(controller.bar?.text, "Looking for you…")
        controller.togglePause()
        await controller.work?.value
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(cancelledChecks, 1, "Only Pause stopped the check")
    }

    func testBoxClosingAsTheFaceMatchesJustHidesTheBar() async throws {
        // Tripwire: approving with Touch ID or cancelling as the face matched showed "The password box closed."
        // with Try Again, which turned the camera on for a box that was gone.
        open(shapes.keychain().window)
        outcomes = [.recognized]
        onCheck = { [unowned self] in fake.windows[pid] = [] }
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertNil(controller.bar)
        controller.tryAgain()
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(try loggedLines()[0].contains(#""fill":"failed:closed""#))
    }

    func testBoxWantingAnotherPasswordAfterUsePasswordSaysWhyWithoutTryAgain() async throws {
        let dialog = shapes.touchID(fieldAfter: 0.1)
        let press = dialog.button.onPress
        dialog.button.onPress = { press?(); dialog.window.children[0].children[1].value = "Enter the “System” keychain password." }
        open(dialog.window, host: FakeDialogSystem.coreautha)
        outcomes = [.recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertEqual(controller.bar?.text, "This box needs a different password")
        XCTAssertEqual(controller.bar?.detail, "Type it yourself.")
        XCTAssertNil(controller.bar?.action, "Trying again would only refuse again")
        XCTAssertEqual(dialog.field.content, "")
    }

    func testMissShowsTryAgainAndTryAgainChecksTheSameBoxAgain() async throws {
        // Tripwire: the old app gave each box one try and then did nothing until it was closed and reopened.
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.notRecognized, .recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertEqual(controller.bar?.text, "Didn't recognize you")
        XCTAssertEqual(controller.bar?.action, .tryAgain)
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 1, "The same box gets one automatic check")
        XCTAssertEqual(controller.bar?.action, .tryAgain, "Try Again stays while the box is open")
        controller.tryAgain()
        await controller.work?.value
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(dialog.field.content, password)
    }

    func testEachNewBoxGetsItsOwnAutomaticCheck() async throws {
        open(shapes.keychain().window)
        outcomes = [.notRecognized, .recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        fake.windows[pid] = [shapes.keychain().window]
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(controller.bar?.text, "Password filled. Click OK or Allow.")
    }

    func testClosingTheBoxStopsTheCheckAndHidesTheBar() async throws {
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.looking]
        let controller = try await controller()
        await controller.scanOnce()
        XCTAssertNotNil(controller.bar)
        fake.windows[pid] = []
        await controller.scanOnce()
        XCTAssertNotNil(controller.bar, "One empty scan may be a Touch ID box swapping in its password stage")
        XCTAssertEqual(cancelledChecks, 0)
        await controller.scanOnce()
        XCTAssertNil(controller.bar)
        await controller.work?.value
        XCTAssertEqual(cancelledChecks, 1)
        XCTAssertEqual(dialog.field.content, "")
    }

    func testFailedScanIsNotTakenAsTheBoxClosing() async throws {
        open(shapes.keychain().window)
        outcomes = [.looking]
        let controller = try await controller()
        await controller.scanOnce()
        fake.trusted = false
        await controller.scanOnce()
        XCTAssertEqual(controller.bar?.text, "Looking for you…")
        XCTAssertEqual(cancelledChecks, 0)
        controller.togglePause()
        await controller.work?.value
        XCTAssertEqual(cancelledChecks, 1)
        XCTAssertNil(controller.bar)
    }

    func testUnreadableBoxIsLoggedOnceAndExplainedWhenItPersists() async throws {
        // Tripwire: failed scans were dropped silently, so a box the app couldn't read left no bar and no record.
        open(fake.window([fake.text("security wants to use the “login” keychain."), fake.secureField(), unreadable()]))
        let controller = try await controller()
        for _ in 0..<3 { await controller.scanOnce() }
        XCTAssertNil(controller.bar, "A brief failure says nothing")
        await controller.scanOnce()
        XCTAssertEqual(controller.bar?.text, "Can't read the password box.")
        XCTAssertNil(controller.bar?.action)
        await controller.scanOnce()
        let lines = try loggedLines()
        XCTAssertEqual(lines.count, 1, "Logged once, not every half second")
        XCTAssertTrue(lines[0].contains(#""event":"scan""#) && lines[0].contains(#""outcome":"failed: unreadable""#))
        XCTAssertFalse(lines[0].contains("keychain"), "No text from the box")
        XCTAssertEqual(checks, 0)
    }

    /// One element that answers no Accessibility reads at all.
    private func unreadable() -> FakeDialogSystem.Node {
        FakeDialogSystem.Node(AXUIElementCreateApplication(99_999), role: kAXGroupRole, subrole: nil,
                              title: nil, value: nil, children: [])
    }

    func testUnreadableElementBeforeThePasswordFieldIsStillExplained() async throws {
        // Tripwire: only a field read before the failure counted, so this box got no bar at all.
        open(fake.window([unreadable(), fake.text("security wants to use the “login” keychain."), fake.secureField(),
                          fake.button("Cancel"), fake.button("OK")]))
        let controller = try await controller()
        for _ in 0..<4 { await controller.scanOnce() }
        XCTAssertEqual(controller.bar?.text, "Can't read the password box.")
        XCTAssertEqual(checks, 0)
    }

    func testReadableBoxNextToAnUnreadableWindowIsExplainedNotFilled() async throws {
        // Tripwire: the scan stopped at the broken window, so the box after it was never seen or explained.
        let box = shapes.keychain()
        open(fake.window([fake.text("Allow access?"), unreadable()]))
        fake.windows[pid]?.append(box.window)
        let controller = try await controller()
        for _ in 0..<4 { await controller.scanOnce() }
        XCTAssertEqual(controller.bar?.text, "Can't read the password box.")
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(box.field.content, "")
    }

    func testUnreadableWindowWithoutAPasswordBoxIsOnlyLogged() async throws {
        // Tripwire: "Can't read the password box" appeared for any other window a host kept open.
        open(fake.window([fake.text("Allow access?"), unreadable(), fake.button("Allow")]))
        let controller = try await controller()
        for _ in 0..<6 { await controller.scanOnce() }
        XCTAssertNil(controller.bar)
        let lines = try loggedLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains(#""outcome":"failed: unreadable""#))
    }

    func testBoxWantingAnotherPasswordShowsWhyAndIsNeverChecked() async throws {
        open(shapes.keychain("System").window)
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertEqual(controller.bar?.text, "This box needs a different password")
        XCTAssertEqual(controller.bar?.detail, "Type it yourself.")
        XCTAssertNil(controller.bar?.action)
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 0)
    }

    func testSkippedBoxReusedForANewRequestIsCheckedAsANewBox() async throws {
        let (window, field) = shapes.keychain("System")
        open(window)
        outcomes = [.recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 0)
        window.children[0].value = "security wants to use the “login” keychain."
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(field.content, password)
    }

    func testMissingPasswordAsksForItThenChecksOnceItIsSaved() async throws {
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.recognized]
        let controller = try await controller(passwordSaved: false)
        await scanAndFinish(controller)
        XCTAssertEqual(controller.bar?.text, "Add your Mac password")
        XCTAssertEqual(controller.bar?.detail, "Face ID Unlock needs it once after each restart.")
        XCTAssertEqual(controller.bar?.action?.title, "Open Settings")
        XCTAssertEqual(checks, 0)
        try await controller.password.save(password)
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(dialog.field.content, password)
    }

    func testSavingThePasswordWithSettingsInFrontStillFillsAnAdminBox() async throws {
        // Tripwire: after the password is typed in Settings this app is in front, and admin boxes take keys
        // only while their host is in front. The fill used to stop at "Click the password box".
        let dialog = shapes.admin()
        open(dialog.window)
        fake.keyboardKeysDelivered = true
        outcomes = [.recognized]
        let controller = try await controller(passwordSaved: false)
        await scanAndFinish(controller)
        XCTAssertEqual(controller.bar?.action, .openSettings)
        fake.frontmost = fake.ownPID
        try await controller.password.save(password)
        await scanAndFinish(controller)
        XCTAssertEqual(dialog.field.content, password)
        XCTAssertEqual(controller.bar?.text, "Password filled. Click OK or Allow.")
        XCTAssertEqual(glances.count, 1)
        XCTAssertNotNil(glances[0], "Admin boxes get the glance")
    }

    func testNothingHappensWithoutASavedFaceOrWhilePaused() async throws {
        open(shapes.keychain().window)
        let noFace = try await controller(faceSaved: false)
        await scanAndFinish(noFace)
        XCTAssertNil(noFace.bar)
        XCTAssertEqual(noFace.statusText, "Needs setup")

        let paused = try await controller()
        paused.togglePause()
        await scanAndFinish(paused)
        XCTAssertNil(paused.bar)
        XCTAssertEqual(paused.statusText, "Paused")
        XCTAssertEqual(checks, 0)
    }

    func testEveryCheckIsLoggedAsNumbersOnly() async throws {
        open(shapes.keychain().window)
        outcomes = [.notRecognized, .recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        controller.tryAgain()
        await controller.work?.value
        let lines = try loggedLines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(#""outcome":"notRecognized""#))
        XCTAssertFalse(lines[0].contains(#""fill""#))
        XCTAssertTrue(lines[1].contains(#""outcome":"recognized""#))
        XCTAssertTrue(lines[1].contains(#""fill":"filled:directValue""#) && lines[1].contains(#""fillMs":"#),
                      "How the fill went and how long it took from first seeing the box")
        XCTAssertTrue(lines.allSatisfy { $0.contains(#""host":"com.apple.SecurityAgent""#) && !$0.contains(password) })
    }

    // MARK: Settings

    func testSettingUpTheFaceAgainNeedsThePasswordThenGivesAnOpenBoxAFreshCheck() async throws {
        // Tripwire: anyone at the unlocked Mac could click Set Up Again with their own face and then have the
        // saved password typed into every box, admin boxes included. Also: after a miss, setting up the face
        // again left the open box with no check and no Try Again.
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.notRecognized, .recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertEqual(controller.bar?.text, "Didn't recognize you")
        controller.setUpFace()
        await controller.work?.value
        XCTAssertEqual(controller.faceSetup, .idle)
        XCTAssertEqual(controller.gallery?.samples.count, 9)
        XCTAssertFalse(controller.password.hasPassword, "A new face needs the password typed again")
        XCTAssertEqual(controller.statusText, "Needs your password")
        await scanAndFinish(controller)
        XCTAssertEqual(controller.bar?.text, "Add your Mac password")
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(dialog.field.content, "")

        try await controller.savePassword(password)
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(dialog.field.content, password)
    }

    func testForgettingTheFaceForgetsThePasswordSoANewCameraAndFaceNeedIt() async throws {
        // Tripwire: Forget My Face, plug in a camera, set up a face: the camera was trusted and boxes were
        // filled, all without the password.
        let controller = try await controller()
        controller.forgetFace()
        XCTAssertFalse(controller.password.hasPassword)
        connected.append(usbCamera)
        controller.camerasChanged()
        controller.setUpFace()
        await controller.work?.value
        XCTAssertNotNil(controller.gallery)
        XCTAssertEqual(controller.statusText, "Needs your password")
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.recognized]
        await scanAndFinish(controller)
        XCTAssertEqual(controller.bar?.text, "Add your Mac password")
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(dialog.field.content, "")

        try await controller.savePassword(password)
        await scanAndFinish(controller)
        XCTAssertEqual(dialog.field.content, password)
    }

    func testSuccessfulSetupRemembersTheCameraItUsed() async throws {
        let controller = try await controller(faceSaved: false)
        controller.setUpFace()
        await controller.work?.value
        XCTAssertNotNil(controller.gallery)
        XCTAssertEqual(remembered, 1, "Daily checks use the camera the face was set up with")
        XCTAssertTrue(controller.password.hasPassword, "A first face keeps the password typed just before it")
    }

    func testCancelDuringFaceSetupStopsTheCameraAndSavesNothing() async throws {
        let controller = try await controller(faceSaved: false)
        setupHolds = true
        controller.setUpFace()
        for _ in 0..<200 where !cameraOn { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(cameraOn)
        controller.cancelFaceSetup()
        XCTAssertEqual(controller.faceSetup, .idle)
        await controller.work?.value
        XCTAssertFalse(cameraOn, "The camera is off")
        XCTAssertNil(controller.gallery)
        await controller.loadFace()
        XCTAssertNil(controller.gallery, "No face was saved")
        XCTAssertEqual(remembered, 0)
        XCTAssertTrue(controller.password.hasPassword)
    }

    func testSetUpMyFaceWaitsUntilTheCameraIsAllowed() async throws {
        cameraGranted = false
        let controller = try await controller(faceSaved: false)
        XCTAssertFalse(controller.canSetUpFace, "The button is disabled")
        controller.setUpFace()
        XCTAssertEqual(controller.faceSetup, .idle)
        XCTAssertEqual(captures, [])
        cameraGranted = true
        controller.refreshPermissions()
        XCTAssertTrue(controller.canSetUpFace)
        controller.setUpFace()
        await controller.work?.value
        XCTAssertNotNil(controller.gallery)
    }

    func testPickingACameraShowsItUntilSettingsCloses() async throws {
        let controller = try await controller()
        controller.previewCamera()
        XCTAssertTrue(controller.previewing)
        for _ in 0..<200 where captures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(captures, [false], "The preview shows frames without analyzing them")
        controller.settingsClosed()
        await controller.work?.value
        XCTAssertFalse(controller.previewing)
    }

    func testNoPreviewWhileAPasswordBoxIsBeingChecked() async throws {
        open(shapes.keychain().window)
        outcomes = [.looking]
        let controller = try await controller()
        await controller.scanOnce()
        for _ in 0..<200 where checks == 0 { try await Task.sleep(for: .milliseconds(5)) }
        controller.previewCamera()
        XCTAssertFalse(controller.previewing)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(cancelledChecks, 0, "Picking a camera doesn't stop the check")
        controller.togglePause()
        await controller.work?.value
        XCTAssertEqual(cancelledChecks, 1)
        XCTAssertEqual(captures, [])
    }

    func testModelThatWontLoadOpensSettings() async throws {
        // Settings no longer waits for the model, so a model failure must still bring it up.
        let controller = try await controller()
        var opened = 0
        controller.openSettings = { opened += 1 }
        await controller.launch()
        for _ in 0..<200 where controller.modelError == nil { try await Task.sleep(for: .milliseconds(10)) }
        controller.quit()
        XCTAssertNotNil(controller.modelError)
        XCTAssertEqual(opened, 1)
    }

    func testTryItSaysItWorkedOnlyWhenTheAppFilledTheBox() async throws {
        let dialog = shapes.keychain()
        outcomes = [.recognized]
        let controller = try await controller()
        prompt = { [unowned self] in
            open(dialog.window)
            await scanAndFinish(controller)
            return true
        }
        controller.tryIt()
        await controller.tryTask?.value
        XCTAssertEqual(dialog.field.content, password)
        XCTAssertEqual(controller.tryResult, "It worked.")

        // Approved some other way, such as Touch ID: not a pass.
        prompt = { true }
        controller.tryIt()
        await controller.tryTask?.value
        XCTAssertEqual(controller.tryResult, "Approved, but Face ID Unlock didn't fill it.")

        prompt = { false }
        controller.tryIt()
        await controller.tryTask?.value
        XCTAssertNil(controller.tryResult)
    }

    func testForgetMyFaceStopsWatching() async throws {
        open(shapes.keychain().window)
        outcomes = [.looking]
        let controller = try await controller()
        await controller.scanOnce()
        controller.forgetFace()
        await controller.work?.value
        XCTAssertNil(controller.gallery)
        XCTAssertNil(controller.bar)
        XCTAssertEqual(cancelledChecks, checks, "A check that had started was stopped")
        await controller.scanOnce()
        XCTAssertNil(controller.bar)
    }

    // MARK: Three misses, then the password once (decision L1)

    private let pausedText = "Face ID Unlock is paused"
    private let missesReason = "3 tries didn't match. Type your password this time."

    private func tryAgainAndFinish(_ controller: AppController) async {
        controller.tryAgain()
        await controller.work?.value
    }

    func testThreeMissesInARowPauseFillingAndKeepTheCameraOff() async throws {
        // Tripwire: with unlimited Try Again, a trick that works 1 time in 20 gets in about 2 times in 3 within
        // 20 tries.
        open(shapes.keychain().window)
        outcomes = [.notRecognized, .notRecognized, .notRecognized, .recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        await tryAgainAndFinish(controller)
        XCTAssertEqual(controller.bar?.action, .tryAgain, "Two misses still offer Try Again")
        XCTAssertNil(controller.lockout)
        await tryAgainAndFinish(controller)
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(controller.lockout, .misses)
        XCTAssertEqual(controller.bar?.text, pausedText)
        XCTAssertEqual(controller.bar?.detail, missesReason)
        XCTAssertEqual(controller.bar?.action, .turnBackOn)
        XCTAssertEqual(controller.statusText, "Paused after 3 misses")

        let next = shapes.keychain()
        fake.windows[pid] = [next.window]
        await scanAndFinish(controller)
        XCTAssertEqual(controller.bar?.text, pausedText)
        XCTAssertEqual(controller.bar?.action, .turnBackOn)
        XCTAssertEqual(checks, 3, "No check for a new box, so the camera stays off")
        XCTAssertEqual(next.field.content, "")
    }

    func testPausedBarStaysWhileTheBoxIsOpenAndTurnBackOnOpensSettings() async throws {
        // Tripwire: the paused bar left after 4 s with no button, so a box that stayed open said nothing and
        // gave no way back.
        open(shapes.keychain().window)
        outcomes = [.notRecognized, .notRecognized, .notRecognized]
        let controller = try await controller()
        var opened = 0
        controller.openSettings = { opened += 1 }
        await scanAndFinish(controller)
        await tryAgainAndFinish(controller)
        await tryAgainAndFinish(controller)
        let action = try XCTUnwrap(controller.bar?.action)
        XCTAssertEqual(action.title, "Turn Back On")
        controller.perform(action)
        XCTAssertEqual(opened, 1, "Turn Back On opens Settings")
        XCTAssertEqual(checks, 3, "and starts no check")

        try await Task.sleep(for: .seconds(4.5))
        XCTAssertEqual(controller.bar?.text, pausedText, "Still there after the old 4 s")
        fake.windows[pid] = []
        await controller.scanOnce()
        await controller.scanOnce()
        XCTAssertNil(controller.bar, "Gone once the box closes")
    }

    func testChecksThatSawNoFaceOrOnlyYouAreNotMisses() async throws {
        // Nobody in view can't let anyone in. A check refused only because a second face kept appearing scored
        // nobody but the owner.
        open(shapes.keychain().window)
        outcomes = [.notRecognized, .noFace, .secondFace, .secondFace, .secondFace, .notRecognized, .noFace]
        let controller = try await controller()
        await scanAndFinish(controller)
        for _ in 0..<6 { await tryAgainAndFinish(controller) }
        XCTAssertEqual(checks, 7)
        XCTAssertNil(controller.lockout, "Two misses so far")
        outcomes = [.notRecognized]
        await tryAgainAndFinish(controller)
        XCTAssertEqual(controller.lockout, .misses, "Those checks didn't break the run of misses")
    }

    /// Opens a box and waits until its check has seen a face that doesn't match.
    private func openAndStartLooking(_ controller: AppController) async throws {
        let before = checks
        fake.windows[pid] = [shapes.keychain().window]
        await controller.scanOnce()
        for _ in 0..<200 where checks == before { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(checks, before + 1)
    }

    func testClosingTheBoxPartWayThroughACheckStillCountsAMiss() async throws {
        // Tripwire: a stopped check never counted, so closing the box just before the timeout gave unlimited
        // full-length tries; in 20 such tries a trick that works 1 time in 20 gets in about 2 times in 3.
        fake.addHost(FakeDialogSystem.securityAgent, pid: pid, windows: [])
        let controller = try await controller()
        for _ in 0..<3 {
            try await openAndStartLooking(controller)
            fake.windows[pid] = []
            await controller.scanOnce()
            await controller.scanOnce()
            await controller.work?.value
        }
        XCTAssertEqual(cancelledChecks, 3)
        XCTAssertEqual(controller.lockout, .misses)
        let next = shapes.keychain()
        fake.windows[pid] = [next.window]
        outcomes = [.recognized]
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 3)
        XCTAssertEqual(next.field.content, "")
        XCTAssertEqual(controller.bar?.text, pausedText)
    }

    func testPauseAndResumeFromTheMenuDoNotGiveFreeTries() async throws {
        fake.addHost(FakeDialogSystem.securityAgent, pid: pid, windows: [])
        let controller = try await controller()
        try await openAndStartLooking(controller)
        for _ in 0..<2 {
            controller.togglePause()
            await controller.work?.value
            controller.togglePause()
            await controller.scanOnce()
            for _ in 0..<200 where checks == cancelledChecks { try await Task.sleep(for: .milliseconds(5)) }
        }
        controller.togglePause()
        await controller.work?.value
        XCTAssertEqual(cancelledChecks, 3)
        XCTAssertEqual(controller.lockout, .misses)
        controller.togglePause()
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 3, "Resuming gives the open box no fresh check")
    }

    func testAMatchStartsTheCountAgain() async throws {
        open(shapes.keychain().window)
        outcomes = [.notRecognized, .notRecognized, .recognized, .notRecognized, .notRecognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        await tryAgainAndFinish(controller)
        await tryAgainAndFinish(controller)
        XCTAssertEqual(controller.bar?.text, "Password filled. Click OK or Allow.")
        fake.windows[pid] = [shapes.keychain().window]
        await scanAndFinish(controller)
        await tryAgainAndFinish(controller)
        XCTAssertEqual(checks, 5)
        XCTAssertNil(controller.lockout)
        XCTAssertEqual(controller.bar?.action, .tryAgain)
    }

    func testMissesAndThePauseSurviveQuittingAndRelaunching() async throws {
        open(shapes.keychain().window)
        outcomes = [.notRecognized, .notRecognized, .notRecognized]
        let first = try await controller()
        await scanAndFinish(first)
        await tryAgainAndFinish(first)
        first.quit()

        let second = try await controller()
        XCTAssertNil(second.lockout)
        fake.windows[pid] = [shapes.keychain().window]
        await scanAndFinish(second)
        XCTAssertEqual(second.lockout, .misses, "The miss before quitting still counted")
        second.quit()

        // After a restart the password isn't saved yet: the box still just says it's paused.
        let third = try await controller(passwordSaved: false)
        XCTAssertEqual(third.statusText, "Paused after 3 misses")
        fake.windows[pid] = [shapes.keychain().window]
        await scanAndFinish(third)
        XCTAssertEqual(third.bar?.text, pausedText)
        XCTAssertEqual(third.bar?.action, .turnBackOn)
        XCTAssertEqual(checks, 3)
    }

    func testTypingTheMacPasswordInSettingsTurnsItBackOn() async throws {
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.notRecognized, .notRecognized, .notRecognized, .recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        await tryAgainAndFinish(controller)
        await tryAgainAndFinish(controller)
        XCTAssertTrue(controller.password.hasPassword)
        XCTAssertTrue(controller.asksForPassword, "Settings shows the password field even with one saved")
        XCTAssertEqual(controller.lockoutMessage,
                       "Face ID Unlock paused after 3 tries that didn't match. Type your Mac password to turn it back on.")

        try? await controller.savePassword("wrong-password")
        XCTAssertEqual(controller.lockout, .misses, "Only the right password turns it back on")

        try await controller.savePassword(password) // The same password that was already saved.
        XCTAssertNil(controller.lockout)
        XCTAssertNil(controller.lockoutMessage)
        XCTAssertFalse(controller.asksForPassword)
        XCTAssertEqual(controller.statusText, "Ready")
        await scanAndFinish(controller)
        XCTAssertEqual(dialog.field.content, password, "The box that is still open gets a fresh check")
        let relaunched = try await self.controller()
        XCTAssertNil(relaunched.lockout, "Still on after a relaunch")

        let lines = try loggedLines()
        let pauses = lines.filter { $0.contains(#""event":"pause""#) }
        XCTAssertEqual(pauses.count, 2)
        XCTAssertTrue(pauses[0].contains(#""outcome":"paused: misses""#))
        XCTAssertTrue(pauses[1].contains(#""outcome":"resumed""#))
        XCTAssertFalse(lines.contains { $0.contains(password) })
    }

    func testTypingThePasswordStartsTheCountAgain() async throws {
        open(shapes.keychain().window)
        outcomes = [.notRecognized, .notRecognized, .notRecognized, .notRecognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        await tryAgainAndFinish(controller)
        try await controller.savePassword(password)
        await tryAgainAndFinish(controller)
        await tryAgainAndFinish(controller)
        XCTAssertEqual(checks, 4)
        XCTAssertNil(controller.lockout, "Two misses since the password was typed")
    }

    // MARK: Trusted cameras and remote control (decision L2)

    private let newCameraText = "A new camera was plugged in (USB Camera). To be safe, type your Mac password to keep using Face ID Unlock."

    func testANewCameraPausesFaceUnlockBeforeTheCheckStarts() async throws {
        open(shapes.keychain().window)
        outcomes = [.recognized]
        let controller = try await controller()
        cameras.reportsChanges = false
        connected.append(usbCamera) // Not yet reported as a change.
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 0, "The camera never started")
        XCTAssertEqual(controller.lockout, .newCamera(name: "USB Camera"))
        XCTAssertEqual(controller.bar?.text, pausedText)
        XCTAssertEqual(controller.bar?.detail, "A new camera was plugged in. Type your password this time.",
                       "Says a different reason from the misses")
        XCTAssertEqual(controller.bar?.action, .turnBackOn)
        XCTAssertEqual(controller.statusText, "Paused: a new camera was connected")
        XCTAssertEqual(controller.lockoutMessage, newCameraText)
        XCTAssertTrue(controller.asksForPassword)
        XCTAssertTrue(try loggedLines().contains { $0.contains(#""outcome":"paused: newCamera""#) })
    }

    func testANewCameraDuringACheckStopsIt() async throws {
        open(shapes.keychain().window)
        outcomes = [.looking]
        let controller = try await controller()
        await controller.scanOnce()
        for _ in 0..<200 where checks == 0 { try await Task.sleep(for: .milliseconds(5)) }
        connected.append(usbCamera)
        controller.camerasChanged()
        await controller.work?.value
        XCTAssertEqual(cancelledChecks, 1)
        XCTAssertEqual(controller.lockout, .newCamera(name: "USB Camera"))
        XCTAssertEqual(controller.bar?.text, pausedText)
    }

    func testCamerasThatComeAndGoStayTrusted() async throws {
        // Tim's iPhone shows up as a camera only some of the time.
        connected.append(phoneCamera)
        open(shapes.keychain().window)
        outcomes = [.recognized]
        let controller = try await controller()
        connected.removeLast()
        controller.camerasChanged()
        connected.append(phoneCamera)
        controller.camerasChanged()
        XCTAssertNil(controller.lockout)
        await scanAndFinish(controller)
        XCTAssertEqual(controller.bar?.text, "Password filled. Click OK or Allow.")
    }

    func testTwoCamerasWithOneIDPauseFaceUnlockUntilOneIsUnplugged() async throws {
        // Tripwire: Settings asked for the password, which silently did nothing, and never said to unplug one.
        let controller = try await controller()
        connected.append(CameraDevice(id: "built-in", displayName: "Copy Camera"))
        controller.camerasChanged()
        XCTAssertEqual(controller.lockout, .newCamera(name: "Copy Camera"))
        let unplug = "Two cameras show the same ID (Copy Camera). Unplug the one you don't use, then type your Mac password."
        XCTAssertEqual(controller.lockoutMessage, unplug)
        do {
            try await controller.savePassword(password)
            XCTFail("Typing the password can't make a copy safe")
        } catch {
            XCTAssertEqual(error.localizedDescription, unplug)
        }
        XCTAssertEqual(controller.lockout, .newCamera(name: "Copy Camera"))
        XCTAssertFalse(try loggedLines().contains { $0.contains(#""outcome":"resumed""#) })

        connected.removeLast()
        controller.camerasChanged()
        try await controller.savePassword(password)
        XCTAssertNil(controller.lockout)
    }

    func testTypingThePasswordTrustsTheCameraThatPausedItEvenAfterItLeft() async throws {
        // Tripwire: the iPhone camera went away before the password was typed, so it was never trusted and
        // paused face unlock again each time it came back.
        let controller = try await controller()
        connected.append(phoneCamera)
        controller.camerasChanged()
        XCTAssertEqual(controller.lockout, .newCamera(name: "Tim's iPhone Camera"))
        connected.removeLast()
        controller.camerasChanged()
        try await controller.savePassword(password)
        XCTAssertNil(controller.lockout)
        connected.append(phoneCamera)
        controller.camerasChanged()
        XCTAssertNil(controller.lockout)
        let relaunched = try await self.controller()
        XCTAssertNil(relaunched.lockout, "Still trusted after a relaunch")
    }

    func testACameraConnectedWhilePausedForMissesIsNamed() async throws {
        // Tripwire: the pause kept saying "3 tries", and typing the password trusted a camera never shown.
        open(shapes.keychain().window)
        outcomes = [.notRecognized, .notRecognized, .notRecognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        await tryAgainAndFinish(controller)
        await tryAgainAndFinish(controller)
        XCTAssertEqual(controller.lockout, .misses)
        connected.append(usbCamera)
        controller.camerasChanged()
        XCTAssertEqual(controller.lockout, .newCamera(name: "USB Camera"))
        XCTAssertEqual(controller.lockoutMessage, newCameraText)
        try await controller.savePassword(password)
        XCTAssertNil(controller.lockout)
    }

    func testACameraThatAppearsWhileThePasswordIsCheckedStaysPaused() async throws {
        // Tripwire: the password approved every camera connected when its check finished, including one that
        // appeared during the check and was never shown.
        let gate = GatedPassword()
        let controller = try await controller(passwordSaved: false, verifier: gate)
        let saving = Task { try await controller.savePassword(password) }
        for _ in 0..<400 where !gate.isChecking { try await Task.sleep(for: .milliseconds(5)) }
        connected.append(usbCamera)
        controller.camerasChanged()
        gate.release()
        try await saving.value
        XCTAssertTrue(controller.password.hasPassword)
        XCTAssertEqual(controller.lockout, .newCamera(name: "USB Camera"))
        XCTAssertEqual(controller.lockoutMessage, newCameraText)
    }

    func testACameraListChangeFromTheCameraServicePausesFaceUnlock() async throws {
        // The list is sent just before it is stored; reading it at once would see the old list and miss the camera.
        let controller = try await controller()
        connected.append(usbCamera)
        for _ in 0..<200 where controller.lockout == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.lockout, .newCamera(name: "USB Camera"))
    }

    func testWhilePausedTheMenuOffersTurnBackOnWhichOpensSettings() async throws {
        // Tripwire: the menu offered Pause and Resume under "Paused…", and neither did anything.
        let controller = try await controller()
        var opened = 0
        controller.openSettings = { opened += 1 }
        XCTAssertEqual(controller.pauseItemTitle, "Pause")
        connected.append(usbCamera)
        controller.camerasChanged()
        XCTAssertEqual(controller.pauseItemTitle, "Turn Back On…")
        controller.pauseItemChosen()
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(controller.paused)
        try await controller.savePassword(password)
        XCTAssertEqual(controller.pauseItemTitle, "Pause")
        controller.pauseItemChosen()
        XCTAssertTrue(controller.paused)
        XCTAssertEqual(controller.pauseItemTitle, "Resume")
    }

    func testTypingThePasswordTrustsTheCamerasConnectedNow() async throws {
        let controller = try await controller()
        connected.append(usbCamera)
        controller.camerasChanged()
        XCTAssertEqual(controller.lockoutMessage, newCameraText)
        try await controller.savePassword(password)
        XCTAssertNil(controller.lockout)
        connected.removeLast()
        controller.camerasChanged()
        connected.append(usbCamera)
        controller.camerasChanged()
        XCTAssertNil(controller.lockout)
        let relaunched = try await self.controller()
        XCTAssertNil(relaunched.lockout, "Still trusted after a relaunch")
    }

    func testFaceSetupTrustsTheCamerasConnectedThen() async throws {
        let controller = try await controller(faceSaved: false)
        controller.setUpFace()
        await controller.work?.value
        XCTAssertNotNil(controller.gallery)
        connected.append(usbCamera)
        controller.camerasChanged()
        XCTAssertEqual(controller.lockout, .newCamera(name: "USB Camera"))
    }

    func testAFaceSavedBeforeCamerasWereTrustedAdoptsTheCamerasConnectedAtLaunch() async throws {
        connected.append(usbCamera)
        let controller = try await controller()
        XCTAssertNil(controller.lockout, "Adopted silently")
        XCTAssertEqual(controller.statusText, "Ready")
        cameras.reportsChanges = false
        connected.append(phoneCamera) // After launch, not yet reported as a change.
        open(shapes.keychain().window)
        outcomes = [.recognized]
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(controller.lockout, .newCamera(name: "Tim's iPhone Camera"),
                       "Only the cameras connected at launch were adopted")
    }

    func testEachCheckLogsWhichVideoEffectsWereOn() async throws {
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.recognized]
        let controller = try await controller()
        onCheck = { controller.lastEffects = VideoEffects(portrait: false, studioLight: true, centerStage: true) }
        await scanAndFinish(controller)
        XCTAssertEqual(dialog.field.content, password, "Effects are recorded, never blocking")
        XCTAssertTrue(try loggedLines()[0].contains(#""effects":{"centerStage":true,"portrait":false,"studioLight":true}"#))
    }

    func testNoCheckWhileTheMacIsRemotelyControlled() async throws {
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.recognized]
        fake.remoteControlled = true
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 0, "The camera never started")
        XCTAssertEqual(controller.bar?.text, "Screen sharing is on")
        XCTAssertEqual(controller.bar?.detail, "Your password wasn't filled. Type it yourself this time.")
        XCTAssertNil(controller.bar?.action)
        XCTAssertEqual(dialog.field.content, "")
    }

    func testScreenSharingThatStartsDuringTheCheckStopsTheFill() async throws {
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.recognized]
        onCheck = { [unowned self] in fake.remoteControlled = true }
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(dialog.field.content, "")
        XCTAssertEqual(controller.bar?.text, "Screen sharing is on")
        XCTAssertEqual(controller.bar?.detail, "Your password wasn't filled. Type it yourself this time.")
        XCTAssertNil(controller.bar?.action)
        XCTAssertTrue(try loggedLines()[0].contains(#""fill":"failed:screenSharing""#))
    }

    // MARK: The glance (decision L4)

    func testKeychainAndAdminBoxesAskForAGlanceAndFillOnlyOnceItPasses() async throws {
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.recognized, .recognized]
        let controller = try await controller()
        var asked: [StatusBarContent] = []
        var fieldDuringGlance: [String] = []
        onGlance = {
            if let bar = controller.bar { asked.append(bar) }
            fieldDuringGlance.append(dialog.field.content)
        }
        controller.glanceDirection = { .left }
        await scanAndFinish(controller)
        XCTAssertEqual(glances, [.left])
        XCTAssertEqual(asked, [StatusBarContent(symbol: "arrow.left.circle.fill", tint: .blue, text: "Look left",
                                                detail: "Turn your head a little to the left.",
                                                requester: "security wants to use the “login” keychain.", animated: true)])
        XCTAssertEqual(fieldDuringGlance, [""], "Nothing is filled until the glance passes")
        XCTAssertEqual(dialog.field.content, password)
        XCTAssertEqual(controller.bar?.text, "Password filled. Click OK or Allow.")
        let logged = try json(XCTUnwrap(loggedLines().first))
        let glance = try XCTUnwrap(logged["glance"] as? [String: Any])
        XCTAssertEqual(glance["asked"] as? String, "left")
        XCTAssertEqual(glance["outcome"] as? String, "passed")
        XCTAssertEqual(glance["yawChange"] as? Double, MatchSettings.leftYawSign * 0.3)
        XCTAssertEqual(glance["passMs"] as? Int, 400)

        let next = shapes.keychain()
        fake.windows[pid] = [next.window]
        controller.glanceDirection = { .right }
        await scanAndFinish(controller)
        XCTAssertEqual(asked.last?.text, "Look right")
        XCTAssertEqual(asked.last?.symbol, "arrow.right.circle.fill")
        XCTAssertEqual(next.field.content, password)
    }

    func testAGlanceTheWrongWayIsAMissThatFillsNothingAndOffersTryAgain() async throws {
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.wrongWay, .wrongWay, .recognized]
        let controller = try await controller()
        let store = LockoutStore(defaults: defaults)
        await scanAndFinish(controller)
        XCTAssertEqual(dialog.field.content, "")
        XCTAssertEqual(controller.bar?.text, "Didn't recognize you", "The same as any miss: it is what a replayed video does")
        XCTAssertEqual(controller.bar?.action, .tryAgain)
        XCTAssertEqual(store.misses, 1)
        let logged = try json(XCTUnwrap(loggedLines().first))
        XCTAssertEqual(logged["outcome"] as? String, "recognized")
        XCTAssertEqual((logged["glance"] as? [String: Any])?["outcome"] as? String, "wrongWay")
        XCTAssertNil(logged["fill"])

        await tryAgainAndFinish(controller)
        XCTAssertEqual(store.misses, 2)
        await tryAgainAndFinish(controller)
        XCTAssertEqual(dialog.field.content, password)
        XCTAssertEqual(store.misses, 0, "A passed glance starts the count again")
    }

    func testThreeFailedGlancesInARowPauseFilling() async throws {
        open(shapes.keychain().window)
        outcomes = [.wrongWay, .wrongWay, .wrongWay, .recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        await tryAgainAndFinish(controller)
        await tryAgainAndFinish(controller)
        XCTAssertEqual(controller.lockout, .misses)
        XCTAssertEqual(controller.bar?.text, pausedText)
    }

    func testClosingTheBoxDuringTheGlanceStillCountsAMiss() async throws {
        // Otherwise a replayed clip could close the box whenever the bar asks for the way it doesn't turn, and try
        // again for free until it asks for the right one.
        let dialog = shapes.keychain()
        open(dialog.window)
        outcomes = [.glancing]
        let controller = try await controller()
        controller.glanceDirection = { .right }
        await controller.scanOnce()
        for _ in 0..<400 where controller.bar?.text != "Look right" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.bar?.text, "Look right")
        fake.windows[pid] = []
        await controller.scanOnce()
        await controller.scanOnce()
        await controller.work?.value
        XCTAssertEqual(cancelledChecks, 1)
        XCTAssertNil(controller.bar)
        XCTAssertEqual(LockoutStore(defaults: defaults).misses, 1)
        XCTAssertEqual(dialog.field.content, "")
        let logged = try json(XCTUnwrap(loggedLines().first))
        XCTAssertEqual((logged["glance"] as? [String: Any])?["outcome"] as? String, "stopped")
    }

    func testMatchingFacesTheDetectorCallsAPhotoOrScreenAreMisses() async throws {
        // Owner's decision 2026-10-30: the detector now blocks, and what it blocks counts toward the pause.
        open(shapes.keychain().window)
        outcomes = [.onScreen, .onScreen, .onScreen]
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertEqual(controller.bar?.text, "Didn't recognize you")
        let logged = try json(XCTUnwrap(loggedLines().first))
        XCTAssertGreaterThan((logged["skipped"] as? [String: Int])?["photoOrScreen"] ?? 0, 0)
        XCTAssertTrue((logged["scores"] as? [Double])?.allSatisfy { $0 >= Double(MatchSettings.threshold) } ?? false,
                      "Every face matched; only the detector turned them away")
        await tryAgainAndFinish(controller)
        await tryAgainAndFinish(controller)
        XCTAssertEqual(controller.lockout, .misses)
    }

    func testTheCameraStaysOnFromTheFaceCheckThroughTheGlance() async throws {
        // The app's own camera loop on the faked camera: the owner, seen a little from the side, rests for a
        // second, then turns 0.3 rad one way, then the other way.
        restYaw = 0.15
        let firstTurn: GlanceCheck.Direction = MatchSettings.leftYawSign > 0 ? .left : .right
        let otherTurn: GlanceCheck.Direction = firstTurn == .left ? .right : .left
        let dialog = shapes.keychain()
        open(dialog.window)
        let controller = try await controller(liveCheck: true)
        // The glance bar is up only briefly, so collect every text the bar shows.
        var texts: [String] = []
        let watching = controller.$bar.compactMap { $0?.text }.sink { texts.append($0) }
        defer { watching.cancel() }
        controller.glanceDirection = { firstTurn }
        await scanAndFinish(controller)
        XCTAssertEqual(captures, [true], "One camera run for the face check and the glance")
        XCTAssertTrue(texts.contains(firstTurn.instruction), "\(texts)")
        XCTAssertFalse(texts.contains(otherTurn.instruction), "The bar asks the way the check expects: \(texts)")
        XCTAssertEqual(dialog.field.content, password)
        let passed = try XCTUnwrap(json(XCTUnwrap(loggedLines().first))["glance"] as? [String: Any])
        XCTAssertEqual(passed["outcome"] as? String, "passed")
        XCTAssertEqual(passed["yawChange"] as? Double, 0.3, "Measured from the resting angle of the matching frames")
        let passMs = try XCTUnwrap(passed["passMs"] as? Int)
        XCTAssertTrue((500...700).contains(passMs), "Counted from the match, about 0.4 s in, to the turn at 1 s: \(passMs)")
        XCTAssertEqual(passed["flatness"] as? Double, 0.15, "The matching frames' points reach the glance")

        let next = shapes.keychain()
        fake.windows[pid] = [next.window]
        texts = []
        controller.glanceDirection = { otherTurn }
        await scanAndFinish(controller)
        XCTAssertTrue(texts.contains(otherTurn.instruction), "\(texts)")
        XCTAssertFalse(texts.contains(firstTurn.instruction), "\(texts)")
        XCTAssertEqual(next.field.content, "")
        XCTAssertEqual(controller.bar?.text, "Didn't recognize you")
        let failed = try XCTUnwrap(json(XCTUnwrap(loggedLines().last))["glance"] as? [String: Any])
        XCTAssertEqual(failed["outcome"] as? String, "wrongWay")
        XCTAssertEqual(failed["yawChange"] as? Double, 0.3, "Also measured from the resting angle")
    }

    // MARK: Home test (decision L5)

    private func homeTestAndFinish(_ controller: AppController, _ subject: HomeTestSubject) async {
        controller.checkHomeTest(subject)
        await controller.work?.value
    }

    private func json(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    func testHomeTestAsksForTheMacPasswordEachTimeAndAWrongOneChangesNothing() async throws {
        // Tripwire: without the gate, someone at an unlocked Mac gets unlimited tries to tune a photo or video.
        outcomes = [.recognized]
        let controller = try await controller(passwordSaved: false)
        controller.checkHomeTest(.me)
        XCTAssertEqual(checks, 0, "No check before the password")
        do {
            try await controller.unlockHomeTest("wrong-password")
            XCTFail("A wrong password opened the Home Test")
        } catch {
            XCTAssertEqual(error as? MacPasswordError, .wrongPassword)
        }
        XCTAssertEqual(controller.homeTest, HomeTestState(), "The window didn't change")
        controller.checkHomeTest(.me)
        await controller.work?.value
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(LockoutStore(defaults: defaults).misses, 0, "A wrong password isn't a face miss")
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))

        try await controller.unlockHomeTest(password)
        XCTAssertTrue(controller.homeTest.unlocked)
        XCTAssertFalse(controller.password.hasPassword, "The gate keeps nothing")
        controller.lockHomeTest() // The window closed.
        XCTAssertFalse(controller.homeTest.unlocked)
        controller.checkHomeTest(.me)
        XCTAssertEqual(checks, 0, "Reopening asks again")
    }

    func testClosingTheHomeTestWhileThePasswordIsCheckedKeepsItLocked() async throws {
        let gate = GatedPassword()
        let controller = try await controller(passwordSaved: false, verifier: gate)
        let unlocking = Task { try await controller.unlockHomeTest(password) }
        for _ in 0..<400 where !gate.isChecking { try await Task.sleep(for: .milliseconds(5)) }
        controller.lockHomeTest()
        gate.release()
        do { try await unlocking.value; XCTFail("A closed window was opened") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(controller.homeTest.unlocked)
    }

    func testHomeTestChecksNeverFillAndNeitherCountNorResetMisses() async throws {
        // Two real misses, then Home Test checks: three that don't match and one that does. None pauses face
        // unlock or starts the count again, so the next real miss is the third in a row.
        open(shapes.keychain().window)
        outcomes = [.notRecognized, .notRecognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        await tryAgainAndFinish(controller)
        fake.windows[pid] = []
        await controller.scanOnce()
        await controller.scanOnce() // A box counts as closed on the second empty scan.
        XCTAssertFalse(controller.passwordBoxOpen)
        let store = LockoutStore(defaults: defaults)
        XCTAssertEqual(store.misses, 2)
        let events = fake.events

        try await controller.unlockHomeTest(password)
        outcomes = [.notRecognized, .notRecognized, .notRecognized, .recognized]
        for subject in [HomeTestSubject.printedPhoto, .phonePhoto, .otherPerson, .me] {
            await homeTestAndFinish(controller, subject)
        }
        XCTAssertEqual(checks, 6)
        XCTAssertNil(controller.lockout)
        XCTAssertEqual(store.misses, 2, "Not counted, not reset")
        XCTAssertEqual(fake.events, events, "Nothing written, focused, pressed or typed")
        XCTAssertEqual(fake.keyboardTextKeys, 0)
        controller.password.withPassword { XCTAssertEqual($0, Array(password.utf8), "The saved password is untouched") }
        XCTAssertEqual(controller.homeTest.result, "Would have filled. Best match 1.00.")
        XCTAssertEqual(controller.homeTest.tally[.me], HomeTestState.Tally(tries: 1, letIn: 1))
        XCTAssertEqual(controller.homeTest.tally[.printedPhoto], HomeTestState.Tally(tries: 1, letIn: 0))
        let tests = try loggedLines().filter { $0.contains(#""event":"homeTest""#) }
        XCTAssertEqual(tests.count, 4)
        XCTAssertFalse(tests.contains { $0.contains(#""fill""#) || $0.contains(#""host""#) })

        outcomes = [.notRecognized]
        fake.windows[pid] = [shapes.keychain().window]
        await scanAndFinish(controller)
        XCTAssertEqual(controller.lockout, .misses)
    }

    func testEveryHomeTestCheckRunsTheGlanceAndSaysWhenItStoppedTheTry() async throws {
        outcomes = [.wrongWay, .recognized]
        let controller = try await controller()
        controller.glanceDirection = { .right }
        var shown: [GlanceCheck.Direction?] = []
        onGlance = { shown.append(controller.homeTest.glance) }
        try await controller.unlockHomeTest(password)
        await homeTestAndFinish(controller, .phoneVideoFar)
        XCTAssertEqual(glances, [.right], "As an admin box would")
        XCTAssertEqual(shown, [.right], "The window says which way to turn")
        XCTAssertNil(controller.homeTest.glance)
        XCTAssertEqual(controller.homeTest.result, "Kept out at the glance (turned the other way). Best match 1.00.")
        XCTAssertEqual(controller.homeTest.tally[.phoneVideoFar], HomeTestState.Tally(tries: 1, letIn: 0))
        await homeTestAndFinish(controller, .me)
        XCTAssertEqual(controller.homeTest.result, "Would have filled. Best match 1.00.")
        let lines = try loggedLines().map { try json($0) }
        XCTAssertEqual(lines.map { $0["letIn"] as? Bool }, [false, true])
        XCTAssertEqual(lines.map { ($0["glance"] as? [String: Any])?["outcome"] as? String }, ["wrongWay", "passed"])
        XCTAssertEqual(lines.map { ($0["glance"] as? [String: Any])?["asked"] as? String }, ["right", "right"])
        XCTAssertEqual(LockoutStore(defaults: defaults).misses, 0, "Home Test misses never count")
    }

    func testARealPasswordBoxStopsARunningHomeTestCheckAndGetsTheCamera() async throws {
        fake.addHost(FakeDialogSystem.securityAgent, pid: pid, windows: [])
        outcomes = [.looking, .recognized]
        let controller = try await controller()
        try await controller.unlockHomeTest(password)
        controller.checkHomeTest(.phoneVideoClose)
        for _ in 0..<200 where checks == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(controller.homeTest.checking)
        let dialog = shapes.keychain()
        fake.windows[pid] = [dialog.window]
        await scanAndFinish(controller)
        XCTAssertEqual(cancelledChecks, 1)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(dialog.field.content, password, "The real box was checked and filled")
        XCTAssertFalse(controller.homeTest.checking)
        XCTAssertEqual(controller.homeTest.result, "Stopped: a password box opened.")
        XCTAssertTrue(controller.homeTest.tally.isEmpty, "A stopped check isn't a try")

        XCTAssertEqual(controller.homeTestUnavailable, "A password box is open. Close it first.")
        controller.checkHomeTest(.me)
        await controller.work?.value
        XCTAssertEqual(checks, 2, "No test check while a box is open")

        let lines = try loggedLines()
        XCTAssertEqual(lines.count, 2)
        let stopped = try json(lines[0])
        XCTAssertEqual(stopped["event"] as? String, "homeTest")
        XCTAssertEqual(stopped["outcome"] as? String, "stopped")
        XCTAssertEqual(stopped["letIn"] as? Bool, false)
        XCTAssertTrue(lines[1].contains(#""event":"check""#) && lines[1].contains(#""fill":"filled:directValue""#))
    }

    func testHomeTestChecksAreLoggedWithWhatWasInFrontOfTheCameraAsNumbersOnly() async throws {
        outcomes = [.recognized, .notRecognized]
        let controller = try await controller()
        onCheck = { controller.lastEffects = VideoEffects(portrait: false, studioLight: false, centerStage: true) }
        try await controller.unlockHomeTest(password)
        await homeTestAndFinish(controller, .meDimOrBacklit)
        await homeTestAndFinish(controller, .iPadVideo)
        XCTAssertEqual(controller.homeTest.result, "Kept out. Best match 0.00.")
        let lines = try loggedLines()
        XCTAssertEqual(lines.count, 2)
        let me = try json(lines[0]), video = try json(lines[1])
        XCTAssertEqual(Set(me.keys), ["date", "event", "subject", "outcome", "letIn", "scores", "skipped",
                                      "firstFrameMs", "firstMatchMs", "totalMs", "effects", "glance", "matchOnly"])
        XCTAssertEqual((me["glance"] as? [String: Any])?["outcome"] as? String, "passed")
        XCTAssertEqual(me["matchOnly"] as? Int, 3, "The faked frames carry no detector score")
        XCTAssertNil(video["glance"], "No match, so no glance")
        XCTAssertEqual(me["event"] as? String, "homeTest")
        XCTAssertEqual(me["subject"] as? String, "meDimOrBacklit")
        XCTAssertEqual(me["outcome"] as? String, "recognized")
        XCTAssertEqual(me["letIn"] as? Bool, true)
        XCTAssertEqual(me["effects"] as? [String: Bool], ["portrait": false, "studioLight": false, "centerStage": true])
        XCTAssertEqual(video["subject"] as? String, "iPadVideo")
        XCTAssertEqual(video["outcome"] as? String, "notRecognized")
        XCTAssertEqual(video["letIn"] as? Bool, false)
        XCTAssertFalse(lines.contains { $0.contains(password) })
    }

    func testHomeTestStopsForScreenSharingANewCameraOrAPauseLikeARealBox() async throws {
        let sharing = "Screen sharing is on, so a real box wouldn't be filled."
        outcomes = [.recognized, .recognized]
        let controller = try await controller()
        try await controller.unlockHomeTest(password)
        fake.remoteControlled = true
        await homeTestAndFinish(controller, .me)
        XCTAssertEqual(checks, 0, "The camera never started")
        XCTAssertEqual(controller.homeTest.result, sharing)

        // Screen sharing that starts during the check stops it where a fill would type.
        fake.remoteControlled = false
        onCheck = { [unowned self] in fake.remoteControlled = true }
        await homeTestAndFinish(controller, .me)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(controller.homeTest.result, sharing)
        XCTAssertNil(controller.homeTest.tally[.me])
        let logged = try json(XCTUnwrap(loggedLines().last))
        XCTAssertEqual(logged["letIn"] as? Bool, false)
        XCTAssertEqual(logged["fill"] as? String, "failed:screenSharing")

        fake.remoteControlled = false
        onCheck = nil
        cameras.reportsChanges = false
        connected.append(usbCamera)
        await homeTestAndFinish(controller, .me)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(controller.lockout, .newCamera(name: "USB Camera"), "Paused the same way as a real box")
        XCTAssertEqual(controller.homeTestUnavailable,
                       "Paused: a new camera was plugged in. Type your Mac password in Settings to turn it back on.")
        XCTAssertNil(controller.homeTest.result)

        // Tripwire: a pause showed only after Check was clicked, and its line stayed once it was turned back on.
        connected.removeLast()
        LockoutStore(defaults: defaults).lockout = .misses
        let paused = try await self.controller()
        try await paused.unlockHomeTest(password)
        XCTAssertEqual(paused.homeTestUnavailable, "Paused: 3 tries at real password boxes didn't match. "
                       + "Type your Mac password in Settings to turn it back on.", "Shown as the window unlocks")
        await homeTestAndFinish(paused, .me)
        XCTAssertEqual(checks, 1)
        try await paused.savePassword(password) // In Settings.
        XCTAssertNil(paused.homeTestUnavailable)
        XCTAssertNil(paused.homeTest.result, "Nothing stale left once it is back on")
    }

    func testANewCameraOrClosingTheWindowStopsAHomeTestCheck() async throws {
        outcomes = [.looking, .looking]
        let controller = try await controller()
        try await controller.unlockHomeTest(password)
        controller.checkHomeTest(.me)
        for _ in 0..<200 where checks == 0 { try await Task.sleep(for: .milliseconds(5)) }
        connected.append(usbCamera)
        controller.camerasChanged()
        await controller.work?.value
        XCTAssertEqual(cancelledChecks, 1)
        XCTAssertEqual(controller.homeTest.result, "Stopped: a new camera was plugged in.")
        XCTAssertEqual(controller.homeTestUnavailable,
                       "Paused: a new camera was plugged in. Type your Mac password in Settings to turn it back on.")

        try await controller.savePassword(password)
        controller.checkHomeTest(.me)
        for _ in 0..<200 where checks == 1 { try await Task.sleep(for: .milliseconds(5)) }
        controller.lockHomeTest()
        await controller.work?.value
        XCTAssertEqual(cancelledChecks, 2)
        XCTAssertEqual(controller.homeTest, HomeTestState(), "Closed: locked, with nothing left on screen")
        XCTAssertEqual(try loggedLines().filter { $0.contains(#""outcome":"stopped""#) }.count, 2)
    }

    func testAPhotoScreenOrOtherPersonCheckCountsDownWithTheCameraOffFirst() async throws {
        // Tripwire: the camera started as Check was clicked, so the owner's own face, still in front of the
        // screen, was scored and tallied as the attack.
        outcomes = [.recognized, .recognized]
        let controller = try await controller()
        controller.homeTestLeadIn = 1
        try await controller.unlockHomeTest(password)
        controller.checkHomeTest(.printedPhoto)
        for _ in 0..<200 where controller.homeTest.startingIn == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.homeTest.startingIn, 1)
        XCTAssertTrue(controller.homeTest.checking)
        XCTAssertEqual(checks, 0, "The camera is off during the countdown")
        controller.lockHomeTest() // Closed during the countdown.
        await controller.work?.value
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(controller.homeTest, HomeTestState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path), "Nothing was looked at, so nothing logged")

        try await controller.unlockHomeTest(password)
        controller.checkHomeTest(.otherPerson)
        await controller.work?.value
        XCTAssertEqual(checks, 1, "Looks once the countdown ends")
        XCTAssertNil(controller.homeTest.startingIn)
        XCTAssertEqual(controller.homeTest.tally[.otherPerson], HomeTestState.Tally(tries: 1, letIn: 1))

        controller.checkHomeTest(.me)
        XCTAssertNil(controller.homeTest.startingIn, "The owner's own checks start at once")
        await controller.work?.value
        XCTAssertEqual(checks, 2)
    }

    func testAHomeTestCheckStoppedBeforeTheCameraWasFreeDoesNotKeepLooking() async throws {
        // Work cancelled while it waits for the camera never runs; the window must still end the check.
        let controller = try await controller()
        try await controller.unlockHomeTest(password)
        controller.previewCamera()
        controller.checkHomeTest(.me)
        XCTAssertTrue(controller.homeTest.checking)
        controller.togglePause()
        await controller.work?.value
        XCTAssertEqual(checks, 0)
        XCTAssertFalse(controller.homeTest.checking)
        XCTAssertEqual(controller.homeTest.result, "Stopped.")
    }

    /// The try folders saved so far, as "<window folder>/<NN-subject>".
    private func savedTries() throws -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: picturesURL.path) else { return [] }
        return try manager.contentsOfDirectory(atPath: picturesURL.path).flatMap { session in
            try manager.contentsOfDirectory(atPath: picturesURL.appendingPathComponent(session).path).map { "\(session)/\($0)" }
        }.sorted()
    }

    func testHomeTestSavesPicturesOnlyWithTheSwitchOnAndNeverForARealBox() async throws {
        outcomes = [.recognized, .recognized, .recognized, .looking, .recognized, .notRecognized]
        let controller = try await controller()
        try await controller.unlockHomeTest(password)
        await homeTestAndFinish(controller, .me)
        await controller.testPictureWork?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: picturesURL.path), "Off until switched on")
        XCTAssertEqual(controller.homeTest.savedTries, 0)

        controller.setSaveTestPictures(true)
        await homeTestAndFinish(controller, .phonePhoto)
        await controller.testPictureWork?.value
        let saved = try savedTries()
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].hasSuffix("/01-phonePhoto"), "\(saved)")
        XCTAssertEqual(controller.homeTest.savedTries, 1)
        let text = try String(contentsOf: picturesURL.appendingPathComponent(saved[0]).appendingPathComponent("try.json"),
                              encoding: .utf8)
        XCTAssertFalse(text.contains(password))
        let file = try json(text)
        XCTAssertEqual(file["subject"] as? String, "phonePhoto")
        XCTAssertEqual((file["record"] as? [String: Any])?["event"] as? String, "homeTest")
        let excluded = try picturesURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "Kept out of Time Machine backups")

        // Switched off before another try, say with someone else in view: that try saves nothing.
        controller.setSaveTestPictures(false)
        XCTAssertFalse(controller.homeTest.savePictures)
        await homeTestAndFinish(controller, .me)
        await controller.testPictureWork?.value
        XCTAssertEqual(try savedTries().count, 1)
        XCTAssertEqual(controller.homeTest.savedTries, 1)
        controller.setSaveTestPictures(true)

        // A real box stops a Home Test try (nothing saved) and its own check saves nothing, switch or not.
        fake.addHost(FakeDialogSystem.securityAgent, pid: pid, windows: [])
        controller.checkHomeTest(.iPadVideo)
        for _ in 0..<200 where checks < 4 { try await Task.sleep(for: .milliseconds(5)) }
        let dialog = shapes.keychain()
        fake.windows[pid] = [dialog.window]
        await scanAndFinish(controller)
        await controller.testPictureWork?.value
        XCTAssertEqual(dialog.field.content, password, "The real box was filled")
        XCTAssertEqual(controller.homeTest.result, "Stopped: a password box opened.")
        XCTAssertTrue(controller.homeTest.savePictures, "The switch is still on")
        XCTAssertEqual(try savedTries().count, 1, "Neither the stopped try nor the real box saved pictures")

        fake.windows[pid] = []
        await controller.scanOnce()
        await controller.scanOnce()
        await homeTestAndFinish(controller, .otherPerson)
        await controller.testPictureWork?.value
        XCTAssertEqual(try savedTries().map { $0.components(separatedBy: "/")[1] }, ["01-phonePhoto", "02-otherPerson"],
                       "The same window's tries share a folder")
        XCTAssertEqual(Set(try savedTries().map { $0.components(separatedBy: "/")[0] }).count, 1)
    }

    func testTheSaveSwitchIsOffEachTimeTheWindowOpensAndDeleteRemovesEveryTry() async throws {
        outcomes = [.recognized, .recognized]
        let controller = try await controller()
        controller.setSaveTestPictures(true)
        XCTAssertFalse(controller.homeTest.savePictures, "Not before the password")
        try await controller.unlockHomeTest(password)
        controller.setSaveTestPictures(true)
        await homeTestAndFinish(controller, .me)
        controller.lockHomeTest() // The window closed.
        XCTAssertFalse(controller.homeTest.savePictures)
        try await controller.unlockHomeTest(password)
        XCTAssertFalse(controller.homeTest.savePictures, "Off again when the window opens")
        await controller.testPictureWork?.value
        XCTAssertEqual(controller.homeTest.savedTries, 1, "Counted from the folder when the window opens")
        controller.setSaveTestPictures(true)
        await homeTestAndFinish(controller, .me)
        await controller.testPictureWork?.value
        XCTAssertEqual(controller.homeTest.savedTries, 2)
        XCTAssertEqual(try savedTries().count, 2, "A new window's try never replaces an earlier one")

        controller.deleteTestPictures()
        await controller.testPictureWork?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: picturesURL.path), "The whole Test Pictures folder is gone")
        XCTAssertEqual(controller.homeTest.savedTries, 0)
    }

    func testASavedTryHoldsTheCamerasFramesFromTheCheckAndTheGlance() async throws {
        // Tripwire: the app's own camera loop on the faked camera, so a saved try without pictures fails here.
        let controller = try await controller(liveCheck: true)
        controller.glanceDirection = { MatchSettings.leftYawSign > 0 ? .left : .right }
        try await controller.unlockHomeTest(password)
        controller.setSaveTestPictures(true)
        await homeTestAndFinish(controller, .me)
        await controller.testPictureWork?.value
        XCTAssertEqual(controller.homeTest.result?.hasPrefix("Would have filled."), true, controller.homeTest.result ?? "")
        let saved = try savedTries()
        XCTAssertEqual(saved.count, 1)
        let tryFolder = picturesURL.appendingPathComponent(try XCTUnwrap(saved.first))
        let file = try json(String(contentsOf: tryFolder.appendingPathComponent("try.json"), encoding: .utf8))
        XCTAssertNotNil(file["glanceStart"] as? Double)
        let stages = try XCTUnwrap(file["frames"] as? [[String: Any]]).map { $0["stage"] as? String }
        XCTAssertTrue(stages.contains("check") && stages.contains("glance"), "\(stages)")
        for name in ["frame.jpg", "glance-001.jpg"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: tryFolder.appendingPathComponent(name).path), name)
        }
    }

    func testHomeTestLineSaysWhichStepStoppedItWithTheBestMatchAndTheMedianRealFaceScore() {
        /// A real FaceCheck's record after frames with these match and real-face scores, then the timeout; after a
        /// match, a real glance asked left that sees one face turned `turn` radians that way (negative: the other
        /// way), or no turn at all.
        func record(_ matches: [Float], _ real: [Float?] = [], turn: Double? = 0.3) -> CheckRecord {
            var check = FaceCheck(gallery: face, startedAt: 0)
            check.observe(FaceObservation(kind: .noFace, timestamp: 0), exposureSettled: true)
            for (index, match) in matches.enumerated() {
                let embedding = [match, (1 - match * match).squareRoot()] + Array(repeating: Float(0), count: 126)
                let photoScreen = index < real.count ? real[index].map {
                    PhotoScreenScore(real: $0, probs27: [1 - $0, $0, 0], probs40: [0, $0, 1 - $0])
                } : nil
                check.observe(FaceObservation(kind: .face, timestamp: 0.5 + Double(index) / 10, embedding: embedding,
                                              yaw: 0, photoScreen: photoScreen), exposureSettled: true)
            }
            check.tick(now: 100)
            var result = check.record
            guard result.outcome == .recognized else { return result }
            var glance = GlanceCheck(direction: .left, restingYaw: check.restingYaw, restingPoints: check.restingPoints,
                                     gallery: face, startedAt: 10)
            if let turn {
                glance.observe(FaceObservation(kind: .face, timestamp: 10.5, embedding: face.samples[0].embedding,
                                               yaw: MatchSettings.leftYawSign * turn))
            }
            glance.tick(now: 20)
            result.glance = glance.record
            return result
        }
        var filled = record([0.3, 0.92, 0.75, 0.8, 0.71], [0.9, 0.2, 0.96, 0.98, 0.61])
        XCTAssertEqual(filled.outcome, .recognized, "0.92 looked like a screen, so the three after it made the match")
        XCTAssertEqual(HomeTestState.line(for: filled, subject: .me), "Would have filled. Best match 0.92, real-face score 0.90.")
        filled.glance?.flatness = 0.1449
        XCTAssertEqual(HomeTestState.line(for: filled, subject: .me),
                       "Would have filled. Best match 0.92, real-face score 0.90, 3D score 0.14.")
        XCTAssertEqual(HomeTestState.line(for: record([0.31], [0.97]), subject: .meDimOrBacklit),
                       "Wouldn't have filled. Best match 0.31, real-face score 0.97.")
        XCTAssertEqual(HomeTestState.line(for: record([0.8, 0.8, 0.8], [0.99, 0.99, 0.99], turn: -0.3), subject: .me),
                       "Wouldn't have filled: stopped at the glance (turned the other way). Best match 0.80, real-face score 0.99.")
        XCTAssertEqual(HomeTestState.line(for: record([0.82, 0.8, 0.81], [0.95, 0.97, 0.99], turn: nil), subject: .phoneVideoFar),
                       "Kept out at the glance (no turn in time). Best match 0.82, real-face score 0.97.")
        XCTAssertEqual(HomeTestState.line(for: record([0.82, 0.8, 0.81], [0.95, 0.97, 0.99]), subject: .phoneVideoFar),
                       "Let in. Best match 0.82, real-face score 0.97.")
        XCTAssertEqual(HomeTestState.line(for: record([0.76, 0.75, 0.77], [0.55, 0.53, 0.57]), subject: .iPadVideo),
                       "Kept out. Best match 0.77, real-face score 0.55.")
        XCTAssertEqual(HomeTestState.line(for: record([0.12]), subject: .otherPerson), "Kept out. Best match 0.12.")
        XCTAssertEqual(HomeTestState.line(for: record([]), subject: .printedPhoto), "Kept out. No clear face seen.")
        XCTAssertEqual(HomeTestSubject.allCases.map(\.rawValue),
                       ["me", "meDimOrBacklit", "printedPhoto", "phonePhoto", "phoneVideoFar", "phoneVideoClose",
                        "iPadVideo", "otherPerson"], "Fixed codes in the score log")
    }

    // MARK: Hosts that exit as their box closes

    func testHostExitingAsTheBoxClosesJustHidesTheBar() async throws {
        // Tripwire: this showed "Can't confirm this password box comes from macOS." with Try Again.
        open(shapes.keychain().window)
        outcomes = [.recognized]
        onCheck = { [unowned self] in fake.identities[pid] = nil }
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertNil(controller.bar)
        controller.tryAgain()
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(try loggedLines()[0].contains(#""fill":"failed:closed""#))
    }

    func testHostExitingAsUsePasswordIsClickedJustHidesTheBar() async throws {
        // Tripwire: Touch ID or Cancel just as the face matched showed "Couldn't click Use Password." with Try Again.
        let dialog = shapes.touchID()
        open(dialog.window, host: FakeDialogSystem.coreautha)
        dialog.button.onPress = { [unowned self] in
            fake.identities[pid] = nil
            fake.windows[pid] = []
        }
        fake.pressAccepted = false
        outcomes = [.recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertNil(controller.bar)
        controller.tryAgain()
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(try loggedLines()[0].contains(#""fill":"failed:closed""#))
    }

    func testHostExitingWhileTypingJustHidesTheBar() async throws {
        let dialog = shapes.admin()
        open(dialog.window)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        outcomes = [.recognized]
        // Partway through keyboard-level typing the host exits and the front moves on.
        // 0.5 s is past the probe space (cleared by about 0.47 s on the fake clock), so password keys are being typed.
        onCheck = { [unowned self] in fake.after(0.5) { [unowned self] in fake.identities[pid] = nil; fake.frontmost = 1 } }
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertGreaterThan(fake.keyboardTextKeys, 1)
        XCTAssertNil(controller.bar)
        XCTAssertTrue(try loggedLines()[0].contains(#""fill":"failed:closed""#))
    }

    func testPasswordsLockScreenIsFilledAndUnlocked() async throws {
        let locked = shapes.passwordsLocked()
        open(locked.window, host: FakeDialogSystem.passwords)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        outcomes = [.recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertEqual(locked.field.submittedContent, password)
        XCTAssertEqual(controller.bar?.text, "Unlocking Passwords…")
        XCTAssertEqual(glances.count, 1)
        XCTAssertNotNil(glances[0], "Passwords' lock screen gets the glance")
        XCTAssertTrue(try loggedLines()[0].contains(#""fill":"filled:keyboard+approved""#))
    }

    func testSystemSettingsBoxIsFilledAndApproved() async throws {
        let settings = shapes.settings(fieldOwner: 91_050)
        fake.settingsExtensions = [91_050]
        open(settings.window, host: FakeDialogSystem.systemSettings)
        fake.keyboardKeysDelivered = true
        fake.frontmost = pid
        outcomes = [.recognized]
        let controller = try await controller()
        await scanAndFinish(controller)
        XCTAssertEqual(settings.field.content, password)
        XCTAssertEqual(fake.events.filter { $0.hasPrefix("press:") }, ["press:Unlock"])
        XCTAssertEqual(controller.bar?.text, "Unlocking System Settings…")
        XCTAssertEqual(glances, [nil], "System Settings' boxes get no glance")
        XCTAssertTrue(try loggedLines()[0].contains(#""fill":"filled:keyboard+approved""#))
    }
}
