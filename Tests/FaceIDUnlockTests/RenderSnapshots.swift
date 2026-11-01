import AppKit
import ApplicationServices
import Combine
import FaceIDCore
import SwiftUI
import XCTest
@testable import FaceIDUnlock

/// Draws the Settings window and the status bar offscreen into PNGs, so the UI can be looked at without
/// launching the app, opening a window or turning on the camera. Does nothing unless FID_RENDER_DIR names a
/// folder; then writes every state there at 2x, light and dark. System boundaries are faked as in
/// AppControllerTests, except the Settings camera row, which uses a real CameraService that only lists cameras.
@MainActor
final class RenderSnapshots: XCTestCase {
    private final class AnyPassword: MacPasswordVerifier {
        func isLoginPassword(_ password: String) throws -> Bool { true }
    }

    @MainActor
    private final class FakeCameras: CameraList {
        var reportsChanges = true
        var devices: [CameraDevice] { willSet { if reportsChanges { changes.send(newValue) } } }
        private let changes: CurrentValueSubject<[CameraDevice], Never>
        var devicesPublisher: AnyPublisher<[CameraDevice], Never> { changes.eraseToAnyPublisher() }
        init(_ devices: [CameraDevice]) {
            self.devices = devices
            changes = CurrentValueSubject(devices)
        }
    }

    private final class MemoryItem: SecretItem, @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func read() throws -> Data? { lock.withLock { data } }
        func write(_ data: Data) throws { lock.withLock { self.data = data } }
        func delete() throws { lock.withLock { data = nil } }
    }

    /// What a faked face check does: match (and turn the way a glance asks), match then turn the other way, match
    /// then hold the glance until cancelled, see only a stranger until it gives up, or keep looking until cancelled.
    private enum Check { case recognized, wrongWay, glancing, notRecognized, looking }
    /// What the faked camera shows during face setup, and when it holds still so the screen can be drawn.
    /// `.turningDone` carries on from `.turningHeld`, turning each way in turn until setup ends.
    private enum Scene { case lookingHeld, turningHeld, turningDone, darkHeld, darkUntilTimeout }

    private let pid: pid_t = 91_001
    private let password = "pa55-Word!"
    private let face = FaceGallery(samples: [.init(pose: .center, embedding: [1] + Array(repeating: 0, count: 127))])
    private let stranger: [Float] = [0, 1] + Array(repeating: 0, count: 126)
    private let usbCamera = CameraDevice(id: "0x1100000046d0825", displayName: "USB Camera")

    private var output: URL!
    private var written: [String] = []
    private var logDir: URL!
    private var fake: FakeDialogSystem!
    private var shapes: DialogShapes!
    private var cameras: FakeCameras!
    private var check = Check.looking
    /// The faked check's match score (nil: the saved face itself, or the stranger) and real-face score.
    private var matchScore: Float?
    private var realScore: Float?
    /// When set, the faked frames carry face points and the glance's nose moves this many pixels against the face
    /// (eyes 80 px apart), for a 3D score.
    private var noseShift: Double?
    private var scene = Scene.turningHeld
    private weak var current: AppController?
    /// Lists this Mac's cameras for the Settings camera row. Never started; reads a throwaway preferences suite.
    private lazy var cameraList = CameraService(defaults: UserDefaults(suiteName: "FaceIDUnlockRenderSnapshots")!)

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["FID_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("Set FID_RENDER_DIR to a folder to render the UI into PNGs.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // The Settings header shows the app icon, which a test process doesn't have.
        let icon = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.icns")
        NSApplication.shared.applicationIconImage = try XCTUnwrap(NSImage(contentsOf: icon))
        logDir = FileManager.default.temporaryDirectory.appendingPathComponent("RenderSnapshots-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let logDir { try? FileManager.default.removeItem(at: logDir) }
        if !written.isEmpty { print("Rendered:\n" + written.joined(separator: "\n")) }
    }

    // MARK: Settings window

    func testRenderSettingsWindow() async throws {
        let first = try await controller(cameraAllowed: false, fillAllowed: false, passwordSaved: false, faceSaved: false)
        XCTAssertFalse(first.cameraAllowed || first.accessibilityAllowed || first.password.hasPassword)
        try await renderSetup("setup-1-first-launch", first)

        let permissions = try await controller(passwordSaved: false, faceSaved: false)
        XCTAssertTrue(permissions.asksForPassword)
        try await renderSetup("setup-2-permissions-done", permissions)

        let passwordSaved = try await controller(faceSaved: false)
        XCTAssertFalse(passwordSaved.asksForPassword)
        XCTAssertNil(passwordSaved.gallery)
        try await renderSetup("setup-3-password-saved", passwordSaved)

        let looking = try await controller(faceSaved: false)
        scene = .lookingHeld
        looking.setUpFace()
        try await waitFor { holds(looking.faceSetup) }
        try await renderSetup("setup-4a-look-at-screen", looking)
        looking.settingsClosed()
        await looking.work?.value

        let settingUp = try await controller(faceSaved: false)
        scene = .turningHeld
        settingUp.setUpFace()
        try await waitFor { holds(settingUp.faceSetup) }
        XCTAssertTrue(settingUp.isSettingUpFace, "Cancel shows under the ring")
        try await renderSetup("setup-4-face-in-progress", settingUp)
        settingUp.settingsClosed()
        await settingUp.work?.value

        // The tick shows only to a window that watched setup end, so each look gets its own setup.
        for look in ["light", "dark"] {
            let added = try await controller(faceSaved: false)
            scene = .turningHeld
            added.setUpFace()
            try await waitFor { holds(added.faceSetup) }
            try await renderSetup("setup-4c-face-done", added, only: look) {
                self.scene = .turningDone
                await added.work?.value
                XCTAssertNotNil(added.gallery)
                XCTAssertEqual(added.faceSetup, .idle) // Drawn well inside the ring's one-second hold.
            }
        }

        let done = try await controller()
        XCTAssertEqual(done.statusText, "Ready")
        try await renderSetup("setup-5-all-done", done)

        let misses = try await controller(lockout: .misses)
        XCTAssertNotNil(misses.lockoutMessage)
        XCTAssertTrue(misses.asksForPassword)
        try await renderSetup("setup-6-paused-after-misses", misses)

        let newCamera = try await controller()
        cameras.devices.append(usbCamera)
        newCamera.camerasChanged()
        XCTAssertEqual(newCamera.lockout, .newCamera(name: "USB Camera"))
        try await renderSetup("setup-7-paused-new-camera", newCamera)

        let tooDark = try await controller(faceSaved: false)
        scene = .darkUntilTimeout
        tooDark.setUpFace()
        await tooDark.work?.value
        XCTAssertEqual(tooDark.faceSetup, .failed(AppController.message(for: .tooDark)))
        try await renderSetup("setup-8-too-dark-failed", tooDark)

        let darkHint = try await controller(faceSaved: false)
        scene = .darkHeld
        darkHint.setUpFace()
        try await waitFor { holds(darkHint.faceSetup) }
        try await renderSetup("setup-8b-too-dark-hint", darkHint)
        darkHint.settingsClosed()
        await darkHint.work?.value
    }

    /// The Settings window's content, below the space its transparent title bar takes.
    private func renderSetup(_ name: String, _ controller: AppController, only look: String? = nil,
                             shown: () async throws -> Void = {}) async throws {
        try await render(SetupView(controller: controller, camera: cameraList)
                            .padding(.top, 28)
                            .background(Color(nsColor: .windowBackgroundColor)), name: name, only: look, shown: shown)
    }

    // MARK: Status bar

    func testRenderStatusBar() async throws {
        check = .looking
        let looking = try await controller()
        open(shapes.keychain().window)
        await looking.scanOnce()
        try await renderBar("looking", looking, expecting: "Looking for you…")
        looking.togglePause()
        await looking.work?.value

        check = .recognized
        let filled = try await controller()
        open(shapes.keychain().window)
        await scanAndFinish(filled)
        try await renderBar("filled", filled, expecting: "Password filled. Click OK or Allow.")

        check = .notRecognized
        let missed = try await controller()
        open(shapes.keychain().window)
        await scanAndFinish(missed)
        XCTAssertEqual(missed.bar?.action, .tryAgain)
        try await renderBar("not-recognized", missed, expecting: "Didn't recognize you")

        let needsPassword = try await controller(passwordSaved: false)
        open(shapes.keychain().window)
        await scanAndFinish(needsPassword)
        XCTAssertEqual(needsPassword.bar?.action, .openSettings)
        try await renderBar("needs-password", needsPassword, expecting: "Add your Mac password")

        let paused = try await controller(lockout: .misses)
        open(shapes.keychain().window)
        await scanAndFinish(paused)
        XCTAssertEqual(paused.bar?.detail, "3 tries didn't match. Type your password this time.")
        XCTAssertEqual(paused.bar?.action, .turnBackOn)
        try await renderBar("paused-misses", paused, expecting: "Face ID Unlock is paused")

        let sharing = try await controller()
        fake.remoteControlled = true
        open(shapes.keychain().window)
        await scanAndFinish(sharing)
        try await renderBar("screen-sharing", sharing, expecting: "Screen sharing is on")

        let otherPassword = try await controller()
        open(shapes.keychain("System").window)
        await scanAndFinish(otherPassword)
        try await renderBar("different-password", otherPassword, expecting: "This box needs a different password")

        let unreadableBox = try await controller()
        open(fake.window([fake.text("security wants to use the “login” keychain."), fake.secureField(), unreadable()]))
        for _ in 0..<4 { await unreadableBox.scanOnce() }
        try await renderBar("cant-read", unreadableBox, expecting: "Can't read the password box.")

        let newCamera = try await controller()
        cameras.reportsChanges = false
        cameras.devices.append(usbCamera)
        open(shapes.keychain().window)
        await scanAndFinish(newCamera)
        XCTAssertEqual(newCamera.lockout, .newCamera(name: "USB Camera"))
        XCTAssertEqual(newCamera.bar?.detail, "A new camera was plugged in. Type your password this time.")
        try await renderBar("paused-new-camera", newCamera, expecting: "Face ID Unlock is paused")
    }

    private func renderBar(_ name: String, _ controller: AppController, expecting text: String) async throws {
        XCTAssertEqual(controller.bar?.text, text, name)
        // Glass draws blank without a window, so the bar is drawn on its material, as before macOS 26.
        try await render(StatusBarView(controller: controller, glass: false), name: "bar-\(name)")
    }

    // MARK: The glance (decision L4)

    func testRenderGlance() async throws {
        check = .glancing
        for direction in GlanceCheck.Direction.allCases {
            let glancing = try await controller()
            glancing.glanceDirection = { direction }
            open(shapes.keychain().window)
            await glancing.scanOnce()
            try await waitFor { glancing.bar?.text == direction.instruction }
            try await renderBar("glance-\(direction.rawValue)", glancing, expecting: direction.instruction)
            glancing.togglePause()
            await glancing.work?.value
        }

        let asking = try await controller()
        try await asking.unlockHomeTest(password)
        asking.glanceDirection = { .left }
        asking.checkHomeTest(.me)
        try await waitFor { asking.homeTest.glance == .left }
        try await renderHomeTest("home-test-glance-asking", asking)
        asking.lockHomeTest()
        await asking.work?.value

        check = .wrongWay
        let keptOut = try await controller()
        try await keptOut.unlockHomeTest(password)
        (matchScore, realScore) = (0.82, 0.97)
        keptOut.checkHomeTest(.phoneVideoFar)
        await keptOut.work?.value
        XCTAssertEqual(keptOut.homeTest.result,
                       "Kept out at the glance (turned the other way). Best match 0.82, real-face score 0.97.")
        try await renderHomeTest("home-test-glance-kept-out", keptOut, subject: .phoneVideoFar)
        (matchScore, realScore) = (nil, nil)
    }

    // MARK: Home Test window (decision L5)

    func testRenderHomeTestWindow() async throws {
        let locked = try await controller()
        locked.lockHomeTest() // As a new window does.
        try await renderHomeTest("home-test-1-password", locked)

        let ready = try await controller()
        try await ready.unlockHomeTest(password)
        try await renderHomeTest("home-test-2-ready", ready)

        check = .looking
        let looking = try await controller()
        try await looking.unlockHomeTest(password)
        looking.checkHomeTest(.me)
        XCTAssertTrue(looking.homeTest.checking)
        try await renderHomeTest("home-test-3-looking", looking)
        looking.lockHomeTest()
        await looking.work?.value

        let starting = try await controller()
        try await starting.unlockHomeTest(password)
        starting.homeTestLeadIn = 3
        starting.checkHomeTest(.printedPhoto)
        for _ in 0..<200 where starting.homeTest.startingIn == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(starting.homeTest.startingIn, 3)
        try await renderHomeTest("home-test-3b-photo-starting", starting, subject: .printedPhoto)
        starting.lockHomeTest()
        await starting.work?.value

        let results = try await controller()
        try await results.unlockHomeTest(password)
        (check, matchScore, realScore) = (.recognized, 0.82, 0.97)
        results.checkHomeTest(.me)
        await results.work?.value
        XCTAssertEqual(results.homeTest.result, "Would have filled. Best match 0.82, real-face score 0.97.")
        try await renderHomeTest("home-test-4-me-would-fill", results)

        (check, matchScore, realScore) = (.notRecognized, 0.21, 0.04)
        results.checkHomeTest(.printedPhoto)
        await results.work?.value
        XCTAssertEqual(results.homeTest.result, "Kept out. Best match 0.21, real-face score 0.04.")
        try await renderHomeTest("home-test-5-photo-kept-out", results, subject: .printedPhoto)

        (check, matchScore, realScore) = (.looking, nil, nil)
        open(shapes.keychain().window)
        await results.scanOnce()
        XCTAssertEqual(results.homeTestUnavailable, "A password box is open. Close it first.")
        try await renderHomeTest("home-test-6-box-open", results, subject: .printedPhoto)
        results.togglePause()
        await results.work?.value

        let paused = try await controller(lockout: .misses)
        try await paused.unlockHomeTest(password)
        XCTAssertEqual(paused.homeTestUnavailable, "Paused: 3 tries at real password boxes didn't match. "
                       + "Type your Mac password in Settings to turn it back on.")
        try await renderHomeTest("home-test-7-paused", paused, subject: .phoneVideoClose)

        // The save switch on, after three saved tries; the last try's line ends with its 3D score.
        let saving = try await controller()
        try await saving.unlockHomeTest(password)
        saving.setSaveTestPictures(true)
        (check, matchScore, realScore, noseShift) = (.recognized, 0.84, 0.98, 11.2)
        for _ in 0..<3 {
            saving.checkHomeTest(.me)
            await saving.work?.value
        }
        await saving.testPictureWork?.value
        XCTAssertEqual(saving.homeTest.savedTries, 3)
        XCTAssertEqual(saving.homeTest.result, "Would have filled. Best match 0.84, real-face score 0.98, 3D score 0.14.")
        try await renderHomeTest("home-test-8-saving-pictures", saving)
        (check, matchScore, realScore, noseShift) = (.looking, nil, nil, nil)
    }

    private func renderHomeTest(_ name: String, _ controller: AppController,
                                subject: HomeTestSubject = .me) async throws {
        try await render(HomeTestView(controller: controller, subject: subject)
                            .background(Color(nsColor: .windowBackgroundColor)), name: name)
    }

    // MARK: Fakes, as in AppControllerTests

    /// A fresh controller on fresh fakes, as at launch. `lockout` is a pause saved by an earlier launch.
    private func controller(cameraAllowed: Bool = true, fillAllowed: Bool = true, passwordSaved: Bool = true,
                            faceSaved: Bool = true, lockout: Lockout? = nil) async throws -> AppController {
        fake = FakeDialogSystem()
        shapes = DialogShapes(fake: fake)
        cameras = FakeCameras([CameraDevice(id: "built-in", displayName: "MacBook Pro Camera", isBuiltIn: true)])
        let defaults = MemoryPreferences()
        if let lockout {
            let saved = LockoutStore(defaults: defaults)
            saved.lockout = lockout
        }
        let session = MacPasswordSession(verifier: AnyPassword(), workspace: NotificationCenter(), app: NotificationCenter())
        if passwordSaved { try await session.save(password) }
        let item = MemoryItem()
        if faceSaved { try FaceStore(item: item).save(face) }
        let controller = AppController(
            scanner: AuthDialogScanner(system: fake, userName: "timharris", fullUserName: "Tim Harris"),
            password: session, store: FaceStore(item: item),
            scoreLog: ScoreLog(url: logDir.appendingPathComponent("\(UUID().uuidString).jsonl")),
            cameraAccess: { cameraAllowed }, accessibilityAccess: { fillAllowed },
            faceCheck: { [unowned self] in await self.runCheck($0, $1, $2) },
            capture: { [unowned self] in try await self.capture($0, $2) },
            tryPrompt: { false }, rememberCamera: {}, defaults: defaults, cameras: cameras,
            testPictures: TestPictures(folder: logDir.appendingPathComponent("Test Pictures \(UUID().uuidString)")))
        controller.homeTestLeadIn = 0
        await controller.loadFace()
        controller.watchCameras()
        current = controller
        return controller
    }

    private func runCheck(_ gallery: FaceGallery, _ glance: GlanceCheck.Direction?,
                          _ asking: (GlanceCheck.Direction) -> Void) async -> CheckRecord {
        var record = FaceCheck(gallery: gallery, startedAt: 0)
        /// Eyes 80 px apart, the nose `nose` pixels to the side.
        func points(nose: Double) -> FacePoints? {
            noseShift.map { _ in
                FacePoints(leftEye: [600, 300], rightEye: [680, 300], nose: [640 + nose, 350], leftMouth: [608, 380],
                           rightMouth: [672, 380])
            }
        }
        func see(_ embedding: [Float]) {
            for step in 0...20 {
                let photoScreen = realScore.map { PhotoScreenScore(real: $0, probs27: [1 - $0, $0, 0], probs40: [0, $0, 1 - $0]) }
                record.observe(FaceIDCore.FaceObservation(kind: .face, timestamp: Double(step) / 10, embedding: embedding,
                                                          yaw: 0, photoScreen: photoScreen, points: points(nose: 0)),
                               exposureSettled: true)
            }
        }
        /// Scores `score` against the saved face.
        func look(_ score: Float) -> [Float] { [score, (1 - score * score).squareRoot()] + Array(repeating: 0, count: 126) }
        switch check {
        case .recognized, .wrongWay, .glancing:
            see(matchScore.map(look) ?? gallery.samples[0].embedding)
            guard record.state == .recognized, let glance else { break }
            asking(glance)
            var turning = GlanceCheck(direction: glance, restingYaw: record.restingYaw, restingPoints: record.restingPoints,
                                      gallery: gallery, startedAt: 3)
            if check == .glancing {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            } else {
                let way = (glance == .left ? 1 : -1) * MatchSettings.leftYawSign * (check == .wrongWay ? -0.3 : 0.3)
                turning.observe(FaceIDCore.FaceObservation(kind: .face, timestamp: 3.5,
                                                           embedding: gallery.samples[0].embedding, yaw: way,
                                                           points: points(nose: noseShift ?? 0)))
            }
            var result = record.record
            result.glance = turning.record
            return result
        case .notRecognized:
            see(matchScore.map(look) ?? stranger)
            record.tick(now: 100)
        case .looking:
            see(stranger)
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        return record.record
    }

    /// The camera, faked. Held scenes stop sending frames once the setup screen shows what is wanted, and
    /// wait to be cancelled; the Settings preview runs until it is cancelled.
    private func capture(_ analyze: Bool, _ step: (FaceIDCore.FaceObservation?, Bool, TimeInterval) -> Bool) async throws {
        let start = CameraService.now
        if analyze {
            for index in 0..<900 {
                let time = start + Double(index) / 30
                let frame: FaceIDCore.FaceObservation
                switch scene {
                case .lookingHeld, .turningHeld, .turningDone:
                    // Straight ahead, then turned left; once released, left and right in turn.
                    var yaw = scene == .lookingHeld || index < 30 ? 0 : 0.3
                    if scene == .turningDone, index.isMultiple(of: 2) { yaw = -0.3 }
                    frame = FaceIDCore.FaceObservation(kind: .face, timestamp: time, embedding: face.samples[0].embedding,
                                                       yaw: yaw, roll: 0, quality: 0.5)
                case .darkHeld, .darkUntilTimeout:
                    frame = FaceIDCore.FaceObservation(kind: .tooDark, timestamp: time)
                }
                if step(frame, true, time) { return }
                while holds(current?.faceSetup), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                if Task.isCancelled { break }
            }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func holds(_ state: FaceSetupState?) -> Bool {
        guard case .capturing(let instruction, let hint, let progress) = state else { return false }
        switch scene {
        case .lookingHeld: return instruction == .lookAtScreen && (progress[.center] ?? 0) >= 2.0 / 3
        case .turningHeld: return instruction == .turnSlowly && (progress[.left] ?? 0) >= 2.0 / 3
        case .darkHeld: return hint == .tooDark
        case .turningDone, .darkUntilTimeout: return false
        }
    }

    private func open(_ window: FakeDialogSystem.Node) {
        fake.addHost(FakeDialogSystem.securityAgent, pid: pid, windows: [window])
    }

    private func scanAndFinish(_ controller: AppController) async {
        await controller.scanOnce()
        await controller.work?.value
    }

    private func unreadable() -> FakeDialogSystem.Node {
        FakeDialogSystem.Node(AXUIElementCreateApplication(99_999), role: kAXGroupRole, subrole: nil,
                              title: nil, value: nil, children: [])
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "State not reached")
    }

    // MARK: Drawing

    /// Draws the view at its natural size into a 2x bitmap, once light and once dark (or only `look`), with
    /// no window. `shown` runs once the view is up, for a change the view must see happen. Animations are off:
    /// without a window they never run, and the drawing would show where they start.
    private func render<Content: View>(_ view: Content, name: String, only look: String? = nil,
                                       shown: () async throws -> Void = {}) async throws {
        for (suffix, appearanceName, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light),
                                                 ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark)]
        where look == nil || look == suffix {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme)
                                                 .transaction { $0.disablesAnimations = true })
            host.appearance = appearance
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            try await shown()
            // Lets onReceive and other state updates land before drawing.
            try await Task.sleep(for: .milliseconds(150))
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            let size = host.bounds.size
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let file = output.appendingPathComponent("\(name)-\(suffix).png")
            try png.write(to: file)
            written.append(file.path)
        }
    }
}
