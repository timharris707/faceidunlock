import AppKit
import ApplicationServices
import AVFoundation
import Combine
import FaceIDCore
import LocalAuthentication
import ServiceManagement

/// What the bar at the top of the screen shows.
struct StatusBarContent: Equatable {
    enum Action: Equatable {
        case tryAgain, openSettings, turnBackOn
        var title: String {
            switch self {
            case .tryAgain: return "Try Again"
            case .openSettings: return "Open Settings"
            case .turnBackOn: return "Turn Back On"
            }
        }
    }
    /// The icon's colour: green once filled, blue while looking or asking, orange when you type it yourself.
    enum Tint: Equatable { case green, blue, orange }
    var symbol: String
    var tint: Tint
    /// One line.
    var text: String
    /// The bar's own reason or next step, shown instead of `requester`.
    var detail: String?
    /// Who is asking: the password box's first line.
    var requester: String?
    var action: Action?
    /// The glance: the symbol moves, unless Reduce Motion is on, and the bar shows on every screen.
    var animated = false
}

extension GlanceCheck.Direction {
    /// What the bar and the Home Test window ask for, and the bar's arrow.
    var instruction: String { self == .left ? "Look left" : "Look right" }
    var arrow: String { self == .left ? "arrow.left.circle.fill" : "arrow.right.circle.fill" }
}

/// Where face setup is, for the Settings window.
enum FaceSetupState: Equatable {
    case idle
    case capturing(FaceSetupCollector.Instruction, hint: FaceHint?, progress: [FaceGallery.Pose: Double])
    case failed(String)
}

/// Owns the app: the saved face, the Mac password, the camera, password-box watching and the score log.
/// Watches for password boxes every 0.5 s off the main thread. Each new box gets one automatic face check;
/// Try Again runs another. Boxes that need it get the random glance after a match, before anything is filled.
/// The camera is on only during a check, face setup or the Settings preview.
/// Three misses in a row, or a new camera, pause filling until the Mac password is typed in Settings.
@MainActor
final class AppController: ObservableObject {
    /// Misses in a row that pause face unlock (decision L1).
    static let missLimit = 3
    /// Seconds without any camera frame before the camera is restarted, once per check or setup.
    static let firstFrameLimit: TimeInterval = 2
    /// Runs one face check. Given a direction, a face it recognizes then gets the glance that way with the camera
    /// still on: `asking` runs as the glance starts, and the record carries it.
    typealias FaceCheckRunner = @MainActor (FaceGallery, _ glance: GlanceCheck.Direction?,
                                            _ asking: (GlanceCheck.Direction) -> Void) async throws -> CheckRecord
    /// Runs the camera, calling `step` with each newly analyzed frame (or nil while none is new) until it
    /// returns true or the task is cancelled, and `onFrame` with each analyzed frame's pixels just before. With
    /// `analyze` false, frames are only shown, never analyzed.
    typealias CaptureRunner = @MainActor (_ analyze: Bool,
                                          _ onFrame: ((CVPixelBuffer, FaceIDCore.FaceObservation) -> Void)?,
                                          _ step: (FaceIDCore.FaceObservation?, Bool, TimeInterval) -> Bool) async throws -> Void
    /// Opens a real password box and reports whether it was approved.
    typealias PasswordPrompt = @MainActor () async -> Bool

    let password: MacPasswordSession
    let scoreLog: ScoreLog
    @Published private(set) var gallery: FaceGallery?
    @Published private(set) var paused = false
    @Published private(set) var accessibilityAllowed: Bool
    @Published private(set) var cameraAllowed: Bool
    @Published private(set) var faceSetup = FaceSetupState.idle
    /// The camera is on in Settings so the person can see which camera they picked.
    @Published private(set) var previewing = false
    @Published private(set) var bar: StatusBarContent?
    @Published private(set) var modelError: String?
    @Published private(set) var tryResult: String?
    /// Set after three misses or a new camera; only typing the Mac password in Settings clears it.
    @Published private(set) var lockout: Lockout?
    /// What the hidden Home Test window shows (decision L5).
    @Published private(set) var homeTest = HomeTestState()
    /// A password box is open, so the Home Test can't check.
    @Published private(set) var passwordBoxOpen = false
    /// Which video effects the camera had on during the last capture, for the score log.
    var lastEffects: VideoEffects?
    /// Picks the way each glance asks for, at random; tests fix it.
    var glanceDirection: () -> GlanceCheck.Direction = { .random() }
    /// The open password box, as last scanned.
    private(set) var dialog: AuthDialog? {
        didSet { if (dialog != nil) != passwordBoxOpen { passwordBoxOpen = dialog != nil } }
    }
    /// The running check, face setup or preview. One at a time, so two never share the camera.
    private(set) var work: Task<Void, Never>?
    /// The running Try It.
    private(set) var tryTask: Task<Void, Never>?
    var openSettings: () -> Void = {}

    private let engine = FaceEngine()
    private let scanner: AuthDialogScanner
    private let store: FaceStore
    private let cameraAccess: () -> Bool
    private let accessibilityAccess: () -> Bool
    private let checkRunner: FaceCheckRunner?
    private let captureRunner: CaptureRunner?
    private let tryPrompt: PasswordPrompt?
    private let cameraChoice: (@MainActor () -> Void)?
    private let lockouts: LockoutStore
    private let cameraSource: (any CameraList)?
    private var cameraWatch: AnyCancellable?
    private var cameraInstance: CameraService?
    private var scanning: Task<Void, Never>?
    private var timer: Timer?
    private var filling = false
    private var fillCount = 0
    /// The open box has had its automatic check (or its skip notice).
    private var attempted = false
    private var askedForPassword = false
    /// When the open box was first seen, for the fill time in the score log.
    private var firstSeen: Date?
    /// Failed scans in a row, and when each kind of failure was last logged.
    private var scanFailures = 0
    /// Scans in a row that found no box while one was open. A box swapping its Touch ID stage for its password
    /// stage can read as empty for a moment, so it counts as closed only on the second.
    private var emptyScans = 0
    private var scanProblemsLogged: [DialogProblem: Date] = [:]
    /// The app filled a box while Try It was running.
    private var tryFilled = false
    private var hideCount = 0
    private var passwordChanges: AnyCancellable?
    /// Bumped each time the Home Test window locks, so a password check or face check still running from
    /// before can't change it.
    private var homeTestSession = 0
    private var homeTestWork: Task<Void, Never>?
    /// Why the running Home Test check was stopped, for its result line.
    private var homeTestStop: String?
    private let testPictures: TestPictures
    /// The open Home Test window's folder in Test Pictures, once it has saved a try.
    private var testPictureSession: String?
    /// The latest save, delete or count of the Test Pictures, run in turn off the main thread.
    private(set) var testPictureWork: Task<Void, Never>?

    /// Every argument is a seam for tests; the defaults are the real Mac. `rememberCamera` runs after a
    /// successful face setup; by default it keeps the camera setup used for later launches. `defaults` keeps
    /// the misses and the pause across launches. `cameras` lists the connected cameras and their changes;
    /// by default the camera service. `testPictures` is where Home Test pictures go.
    init(scanner: AuthDialogScanner = AuthDialogScanner(), password: MacPasswordSession? = nil,
         store: FaceStore = FaceStore(), scoreLog: ScoreLog = ScoreLog(),
         cameraAccess: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .video) == .authorized },
         accessibilityAccess: @escaping () -> Bool = { AXIsProcessTrusted() },
         faceCheck: FaceCheckRunner? = nil, capture: CaptureRunner? = nil, tryPrompt: PasswordPrompt? = nil,
         rememberCamera: (@MainActor () -> Void)? = nil, defaults: any PreferenceStore = UserDefaults.standard,
         cameras: (any CameraList)? = nil, testPictures: TestPictures = TestPictures()) {
        self.scanner = scanner
        self.testPictures = testPictures
        let password = password ?? MacPasswordSession()
        self.password = password
        self.store = store
        self.scoreLog = scoreLog
        self.cameraAccess = cameraAccess
        self.accessibilityAccess = accessibilityAccess
        checkRunner = faceCheck
        captureRunner = capture
        self.tryPrompt = tryPrompt
        cameraChoice = rememberCamera
        lockouts = LockoutStore(defaults: defaults)
        lockout = lockouts.lockout
        cameraSource = cameras
        cameraAllowed = cameraAccess()
        accessibilityAllowed = accessibilityAccess()
        passwordChanges = password.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Created on first use (at launch, to follow the camera list). The camera turns on only through start().
    var camera: CameraService {
        if let cameraInstance { return cameraInstance }
        let created = CameraService()
        cameraInstance = created
        return created
    }

    var isSettingUpFace: Bool {
        if case .capturing = faceSetup { return true }
        return false
    }

    /// The menu's status line.
    var statusText: String {
        switch lockout {
        case .misses: return "Paused after 3 misses"
        case .newCamera: return "Paused: a new camera was connected"
        case nil: break
        }
        if paused { return "Paused" }
        if gallery == nil || !accessibilityAllowed || !cameraAllowed || modelError != nil { return "Needs setup" }
        return password.hasPassword ? "Ready" : "Needs your password"
    }

    // MARK: Launch

    /// Loads the saved face and starts following the camera list, then checks for password boxes every 0.5 s.
    /// The face model loads in the background so Settings can open at once; a model that won't load opens
    /// Settings to say so.
    func launch() async {
        await loadFace()
        watchCameras()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissions()
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task {
            do { try await engine.prepare() } catch {
                modelError = error.localizedDescription
                openSettings()
            }
        }
    }

    /// Reads the saved face off the main thread; a keychain prompt must not freeze the app.
    func loadFace() async {
        let store = store
        gallery = try? await Task.detached { try store.load() }.value
    }

    func refreshPermissions() {
        let trusted = accessibilityAccess(), camera = cameraAccess()
        if trusted != accessibilityAllowed { accessibilityAllowed = trusted }
        if camera != cameraAllowed { cameraAllowed = camera }
    }

    // MARK: Watching password boxes

    /// Starts one scan unless one is running, a fill is under way, or there is nothing to do.
    func poll() {
        guard scanning == nil, !filling, gallery != nil, !paused else { return }
        scanning = Task {
            await scanOnce()
            scanning = nil
        }
    }

    /// Scans off the main thread, then acts on what it found.
    func scanOnce() async {
        let scanner = scanner, fills = fillCount
        let result = await Task.detached { scanner.scan() }.value
        // A fill that started or ended meanwhile may have changed the box; the next scan will see it.
        guard fills == fillCount, !filling, gallery != nil, !paused else { return }
        switch result {
        case .failed(let problem, let boxSeen):
            noteScanFailure(problem, boxSeen: boxSeen) // A failed read doesn't prove the box closed.
        case .none:
            scanFailures = 0
            emptyScans += 1
            if dialog != nil, emptyScans >= 2 { closeDialog() }
        case .dialog(let found):
            scanFailures = 0
            emptyScans = 0
            if let current = dialog, !isSameBox(current, found) { closeDialog() }
            if dialog == nil {
                firstSeen = found.scannedAt
                stopHomeTest("Stopped: a password box opened.") // The real box gets the camera.
            }
            dialog = found
            guard !attempted else { return }
            switch found.decision {
            case .skip:
                attempted = true
                showDifferentPassword()
            case .fill, .needsUsePasswordClick:
                guard gallery != nil, !isSettingUpFace, cameraAccess() else { return }
                // While paused, the check only says so; typing the password in Settings resumes.
                if password.hasPassword || lockout != nil {
                    attempted = true
                    startCheck()
                } else if !askedForPassword {
                    askedForPassword = true
                    show(StatusBarContent(symbol: "key", tint: .blue, text: "Add your Mac password",
                                          detail: "Face ID Unlock needs it once after each restart.",
                                          requester: found.requester, action: .openSettings))
                }
            case .none:
                return
            }
        }
    }

    func tryAgain() {
        guard dialog != nil, bar?.action == .tryAgain else { return }
        startCheck()
    }

    /// The bar's button: Try Again checks again; Open Settings and Turn Back On open Settings.
    func perform(_ action: StatusBarContent.Action) {
        if action == .tryAgain { tryAgain() } else { openSettings() }
    }

    /// The same box as before. Once it has been checked its first line may change, after "Use Password…"
    /// or as the box settles, so then the same window of the same process instance is enough.
    private func isSameBox(_ old: AuthDialog, _ new: AuthDialog) -> Bool {
        if old.dialogKey == new.dialogKey { return true }
        if case .skip = old.decision { return false }
        return attempted && old.identity == new.identity && CFEqual(old.window, new.window)
    }

    /// Logs a failed scan as a code: each kind once while nothing is open, and at most once a minute while
    /// a box may be on screen. When failures go on while a password box may be open, the bar says so;
    /// other windows a host keeps open are only logged.
    private func noteScanFailure(_ problem: DialogProblem, boxSeen: Bool) {
        scanFailures += 1
        let now = Date()
        if scanProblemsLogged[problem].map({ boxSeen && now.timeIntervalSince($0) >= 60 }) ?? true {
            scanProblemsLogged[problem] = now
            try? scoreLog.append(ScoreRecord(scanProblem: problem.rawValue, date: now))
        }
        if dialog == nil, boxSeen, scanFailures >= 4 {
            show(StatusBarContent(symbol: "exclamationmark.triangle", tint: .orange, text: problem.localizedDescription,
                                  detail: "Type the password yourself this time."), hideAfter: 3)
        }
    }

    /// The box closed or another replaced it: stop its check and hide the bar.
    private func closeDialog() {
        dialog = nil
        firstSeen = nil
        attempted = false
        askedForPassword = false
        if !isSettingUpFace && !previewing { work?.cancel() }
        hideBar()
    }

    /// One face check for the open box, then the glance where the box needs it; once both pass, the fill.
    /// Logged once it ends. The camera stays off while face unlock is paused or the Mac is being controlled
    /// remotely (decisions L1 and L2).
    private func startCheck() {
        guard let gallery, let host = dialog?.host else { return }
        checkCameras()
        guard lockout == nil else { return showPaused() }
        guard !scanner.system.isRemoteControlled() else { return showScreenSharing() }
        show(StatusBarContent(symbol: "person.crop.circle", tint: .blue, text: "Looking for you…",
                              requester: dialog?.requester))
        let glance = host.needsGlance ? glanceDirection() : nil
        begin { [self] in
            lastEffects = nil
            let record: CheckRecord
            do {
                record = try await faceCheck(gallery, glance: glance) { showGlance($0) }
            } catch {
                if !Task.isCancelled { showFailure("Couldn't check your face", reason: error.localizedDescription) }
                return
            }
            let letIn = Self.letsIn(record, glance: glance)
            var entry = ScoreRecord(check: record, date: Date(), host: host.identifier)
            entry.effects = lastEffects
            if !Task.isCancelled, letIn, let result = await fill() {
                entry.fill = result.code
                entry.fillMs = result.milliseconds
            }
            try? scoreLog.append(entry)
            countMisses(record, letIn: letIn)
            // A failed glance looks the same as a miss: it is what a replayed photo or video gives.
            guard !Task.isCancelled, record.outcome == .notRecognized || record.outcome == .recognized && !letIn
            else { return }
            if lockout != nil { showPaused() } else {
                showFailure("Didn't recognize you", symbol: "person.crop.circle.badge.exclamationmark")
            }
        }
    }

    /// A match lets the person in; where a glance was asked for, only once it has passed too.
    private static func letsIn(_ record: CheckRecord, glance: GlanceCheck.Direction?) -> Bool {
        record.outcome == .recognized && (glance == nil || record.glance?.outcome == .passed)
    }

    /// Clicks "Use Password…" when the box needs it (decision D2), then fills it, off the main thread.
    /// Returns the outcome's log code and the time since the box was first seen; nil with no box open.
    private func fill() async -> (code: String, milliseconds: Int?)? {
        guard let current = dialog else { return nil }
        let scanner = scanner, recognizedAt = scanner.system.now()
        var secret = password.withPassword { $0.withUnsafeBufferPointer { Array($0) } }
        filling = true
        fillCount += 1
        let (target, outcome, submitted) = await Task.detached { [secret] in
            Self.fill(current, password: secret, recognizedAt: recognizedAt, scanner: scanner)
        }.value
        secret.withUnsafeMutableBytes { if let base = $0.baseAddress { memset_s(base, $0.count, 0, $0.count) } }
        filling = false
        fillCount += 1
        let elapsed = firstSeen.map { Int((scanner.system.now().timeIntervalSince($0) * 1000).rounded()) }
        let code = outcome.logCode + (submitted ? "+approved" : "")
        // Same box: after "Use Password…" its key can change, which must not look like a new box.
        if let target, dialog != nil { dialog = target }
        if case .filled = outcome, tryTask != nil { tryFilled = true }
        guard !Task.isCancelled else { return (code, elapsed) }
        switch outcome {
        case .filled:
            let text = switch dialog?.host.kind {
            case .settingsSheet: submitted ? "Unlocking System Settings…" : "Password filled. Click Unlock or Modify Settings."
            case .lockedApp: submitted ? "Unlocking Passwords…" : "Password filled. Press Return to unlock."
            default: "Password filled. Click OK or Allow."
            }
            show(StatusBarContent(symbol: "checkmark.circle.fill", tint: .green, text: text,
                                  requester: dialog?.requester), hideAfter: 2)
        case .failed(.closed):
            closeDialog() // Approved or cancelled as the face matched: nothing to try again.
        case .failed(.screenSharing):
            showScreenSharing()
        case .failed(let problem):
            showFailure("Password not filled", reason: problem.localizedDescription)
        case .skipped:
            showDifferentPassword()
        }
        return (code, elapsed)
    }

    private nonisolated static func fill(_ dialog: AuthDialog, password: [UInt8], recognizedAt: Date,
                                         scanner: AuthDialogScanner) -> (AuthDialog?, FillOutcome, submitted: Bool) {
        let filler = AuthDialogFiller(scanner: scanner)
        var target: AuthDialog?
        let outcome: FillOutcome
        var submitted = false
        do {
            var current = try scanner.refresh(dialog)
            if case .needsUsePasswordClick = current.decision { current = try filler.pressUsePassword(current) }
            if case .skip(let reason) = current.decision { return (current, .skipped(reason: reason), false) }
            target = current
            outcome = filler.fill(current, password: password, recognizedAt: recognizedAt)
            if case .filled = outcome { submitted = filler.submit(current, password: password) }
        } catch {
            outcome = .failed(DialogProblem(error))
        }
        // A host that exited while the box was being filled, or "Use Password…" clicked, took the box with it.
        if case .failed = outcome, !scanner.system.isRunning(dialog.identity.processInstance) {
            return (nil, .failed(.closed), false)
        }
        return (target, outcome, submitted)
    }

    // MARK: Camera

    /// The face check, and glance, a password box and a Home Test check both run: the test seam when set, else
    /// the camera. Only Home Test checks pass a `recorder`.
    private func faceCheck(_ gallery: FaceGallery, glance: GlanceCheck.Direction?, recorder: TestPictureRecorder? = nil,
                           asking: (GlanceCheck.Direction) -> Void) async throws -> CheckRecord {
        if let checkRunner { return try await checkRunner(gallery, glance, asking) }
        return try await liveCheck(gallery, glance: glance, recorder: recorder, asking: asking)
    }

    /// The real face check: camera on, frames analyzed until the check ends or is cancelled, camera off. Given a
    /// direction, a match is followed by the glance on the same running camera, counted from the moment it asks.
    /// A `recorder` gets every analyzed frame.
    private func liveCheck(_ gallery: FaceGallery, glance direction: GlanceCheck.Direction?,
                           recorder: TestPictureRecorder?,
                           asking: (GlanceCheck.Direction) -> Void) async throws -> CheckRecord {
        var check = FaceCheck(gallery: gallery, startedAt: CameraService.now)
        var glance: GlanceCheck?
        try await capture(onFrame: recorder.map { recorder in { recorder.add($0, $1) } }) { observation, settled, now in
            if glance != nil {
                if let observation { glance?.observe(observation) } else { glance?.tick(now: now) }
                return glance?.outcome != nil
            }
            if let observation { check.observe(observation, exposureSettled: settled) } else { check.tick(now: now) }
            guard check.state == .recognized, let direction else {
                return check.state == .recognized || check.state == .notRecognized
            }
            glance = GlanceCheck(direction: direction, restingYaw: check.restingYaw, restingPoints: check.restingPoints,
                                 gallery: gallery, startedAt: now)
            recorder?.glanceStarted(at: now)
            asking(direction)
            return false
        }
        var record = check.record
        record.glance = glance?.record
        return record
    }

    /// Turns the camera on and calls `step` with each newly analyzed frame, or with nil about every 30 ms
    /// while none is new, until `step` returns true or the task is cancelled. The camera is off afterwards.
    /// `onFrame` gets each analyzed frame's pixels with what was found, just before `step`.
    private func capture(analyze: Bool = true, onFrame: ((CVPixelBuffer, FaceIDCore.FaceObservation) -> Void)? = nil,
                         _ step: (FaceIDCore.FaceObservation?, Bool, TimeInterval) -> Bool) async throws {
        if let captureRunner { return try await captureRunner(analyze, onFrame, step) }
        let camera = camera
        defer {
            lastEffects = camera.videoEffects
            camera.stop()
        }
        try await camera.start()
        var last = -TimeInterval.infinity
        // The Studio Display camera once streamed for 6 s without a single frame (its driver logged 0 frames
        // from 47,872 packets, 2026-10-30), and a fresh start then worked. So restart it once if nothing arrives.
        var restartAt: TimeInterval? = CameraService.now + Self.firstFrameLimit
        while !Task.isCancelled {
            var observation: FaceIDCore.FaceObservation?
            var settled = false
            let frame = camera.latestFrame()
            if frame != nil { restartAt = nil }
            if let at = restartAt, CameraService.now >= at {
                restartAt = nil
                camera.stop()
                try await camera.start()
            }
            if analyze, let frame, frame.timestamp > last {
                last = frame.timestamp
                settled = camera.isExposureSettled
                observation = await engine.analyze(frame: frame)
            }
            // Once cancelled, nothing more may change the check or the setup screen.
            if Task.isCancelled { return }
            if let observation, let frame { onFrame?(frame.pixelBuffer, observation) }
            if step(observation, settled, CameraService.now) { return }
            if observation == nil { try? await Task.sleep(for: .milliseconds(30)) }
        }
    }

    /// Runs `body` once any earlier check, setup or preview has fully stopped. `cancelled` runs instead when
    /// this work is cancelled before `body` starts.
    @discardableResult
    private func begin(_ body: @escaping @MainActor () async -> Void,
                       cancelled: (@MainActor () -> Void)? = nil) -> Task<Void, Never> {
        let previous = work
        previous?.cancel()
        previewing = false
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else {
                cancelled?()
                return
            }
            await body()
        }
        work = task
        return task
    }

    /// Shows what the picked camera sees in Settings, so two cameras with the same name can be told apart.
    /// Not while a password box is open or face setup runs. Stops when Settings closes or the camera is needed.
    func previewCamera() {
        guard !isSettingUpFace, dialog == nil, cameraAccess() else { return }
        begin { [self] in
            do { try await capture(analyze: false) { _, _, _ in false } } catch {
                if !Task.isCancelled { previewing = false }
            }
        }
        previewing = true
    }

    // MARK: Face setup

    /// Set Up My Face, Set Up Again and Try Again work once the camera is allowed.
    var canSetUpFace: Bool { cameraAllowed && !isSettingUpFace }

    /// Look at the screen, then turn a little each way. Saves the face to the keychain when it works,
    /// remembers the camera it used, and trusts every camera connected now. A face that replaces a saved one
    /// also forgets the Mac password, so nothing is filled for the new face until the password is typed.
    func setUpFace() {
        guard canSetUpFace else { return }
        let replacing = gallery != nil
        hideBar()
        // A box that is still open gets a fresh automatic check once setup ends.
        attempted = false
        askedForPassword = false
        faceSetup = .capturing(.lookAtScreen, hint: nil, progress: [:])
        begin { [self] in
            var collector = FaceSetupCollector(startedAt: CameraService.now)
            do {
                try await capture { observation, settled, now in
                    if let observation { collector.observe(observation, exposureSettled: settled) } else { collector.tick(now: now) }
                    let state = FaceSetupState.capturing(collector.instruction, hint: collector.hint,
                                                         progress: collector.poseProgress)
                    if state != faceSetup { faceSetup = state }
                    switch collector.instruction {
                    case .lookAtScreen, .turnSlowly: return false
                    case .done, .failed: return true
                    }
                }
            } catch {
                if !Task.isCancelled { faceSetup = .failed(error.localizedDescription) }
                return
            }
            try? scoreLog.append(ScoreRecord(setup: collector.record, date: Date()))
            // Cancelled by Cancel or by Settings closing, which already reset the screen; nothing is saved.
            guard !Task.isCancelled else { return }
            switch collector.instruction {
            case .done:
                guard let face = collector.finish() else {
                    faceSetup = .failed("Couldn't get a clear look at you. Try again.")
                    return
                }
                let store = store
                do { try await Task.detached { try store.save(face) }.value } catch {
                    faceSetup = .failed(error.localizedDescription)
                    return
                }
                gallery = face
                if replacing { password.forget() }
                lockouts.trust(connectedCameras.map(\.id))
                if let cameraChoice { cameraChoice() } else { cameraInstance?.rememberSelection() }
                faceSetup = .idle
            case .failed(let problem):
                faceSetup = .failed(Self.message(for: problem))
            case .lookAtScreen, .turnSlowly:
                faceSetup = .idle
            }
        }
    }

    static func message(for problem: FaceSetupCollector.Problem) -> String {
        switch problem {
        case .noFace: return "Couldn't see your face."
        case .multipleFaces: return "Only you should be in view."
        case .tooDark: return "It's too dark. Add some light."
        case .turnedAway: return "This camera sees you from the side. Face it, or pick the camera in front of you."
        case .unusable: return "Couldn't get a clear look. Face the screen."
        }
    }

    /// Cancel under the ring: the camera stops and nothing is saved.
    func cancelFaceSetup() {
        guard isSettingUpFace else { return }
        work?.cancel()
        faceSetup = .idle
    }

    /// The Settings window closed: stop face setup or the preview, and forget an old failure.
    func settingsClosed() {
        if isSettingUpFace || previewing { work?.cancel() }
        previewing = false
        faceSetup = .idle
    }

    /// Deletes the face and forgets the Mac password, so the next face set up needs the password again.
    func forgetFace() {
        try? store.delete()
        gallery = nil
        password.forget()
        stopWatching()
    }

    // MARK: Pausing after misses or a new camera (decisions L1 and L2)

    /// What the banner at the top of Settings says while face unlock is paused.
    var lockoutMessage: String? {
        switch lockout {
        case .misses:
            return "Face ID Unlock paused after 3 tries that didn't match. Type your Mac password to turn it back on."
        case .newCamera(let name):
            if LockoutStore.sharedID(in: connectedCameras) != nil { return CameraError.sharedID(name: name).localizedDescription }
            return "A new camera was plugged in (\(name)). To be safe, type your Mac password to keep using Face ID Unlock."
        case nil:
            return nil
        }
    }

    /// Settings shows the password field when none is saved, and while paused, since typing it resumes.
    var asksForPassword: Bool { !password.hasPassword || lockout != nil }

    /// Keeps the Mac password once it is checked against the account. A correct password, even the one
    /// already saved, also clears the misses, trusts the cameras connected when it was typed plus the camera
    /// the pause named (even if that one has gone since), and turns face unlock back on; a box that is still
    /// open then gets a fresh check. Two cameras sharing one ID keep it paused, and the error says to unplug one.
    func savePassword(_ text: String) async throws {
        // Taken before the check: a camera that appears while it runs was never shown, so it isn't approved.
        let approved = connectedCameras.map(\.id) + [lockouts.pausedCamera].compactMap { $0 }
        try await password.save(text)
        lockouts.misses = 0
        lockouts.trust(approved)
        if lockout != nil, let copy = LockoutStore.sharedID(in: connectedCameras) {
            throw CameraError.sharedID(name: copy.displayName)
        }
        if lockout != nil {
            lockout = nil
            lockouts.lockout = nil
            try? scoreLog.append(ScoreRecord(pausedFor: nil, date: Date()))
            attempted = false
        }
        checkCameras() // A camera that appeared while the password was checked pauses it again.
    }

    /// A miss is a check that didn't let the person in after it scored a face below the match line, had a
    /// matching face turned away by the photo/screen detector, or matched but then got a glance that didn't pass,
    /// however it ended: closing the box or choosing Pause part-way still counts. Checks that saw no face, or only
    /// faces that matched (refused because a second face was in view), don't count; letting the person in starts
    /// the count again. Three in a row pause face unlock.
    private func countMisses(_ record: CheckRecord, letIn: Bool) {
        if letIn { lockouts.misses = 0 }
        guard !letIn, record.outcome == .recognized || record.skipped.photoOrScreen > 0
                || record.scores.contains(where: { $0 < MatchSettings.threshold }) else { return }
        lockouts.misses += 1
        if lockouts.misses >= Self.missLimit, lockout == nil { lock(.misses) }
    }

    /// Stops filling until the Mac password is typed in Settings, across quits too. `camera` is the ID of
    /// the camera a new-camera pause names.
    private func lock(_ reason: Lockout, camera: String? = nil) {
        lockout = reason
        lockouts.lockout = reason
        lockouts.pausedCamera = camera
        try? scoreLog.append(ScoreRecord(pausedFor: reason.logCode, date: Date()))
    }

    /// Pauses face unlock when a camera that was never trusted is connected, or two share one ID, also turning
    /// a pause after misses into one that names the camera. A face saved before cameras were trusted adopts
    /// the cameras connected now.
    private func checkCameras() {
        guard gallery != nil, lockout == nil || lockout == .misses else { return }
        let cameras = connectedCameras
        if lockouts.trustedCameras == nil { lockouts.trust(cameras.map(\.id)) }
        if let camera = LockoutStore.newCamera(in: cameras, trusted: lockouts.trustedCameras ?? []) {
            lock(.newCamera(name: camera.displayName), camera: camera.id)
        }
    }

    /// Every camera discovery sees now.
    private var connectedCameras: [CameraDevice] { (cameraSource ?? camera).devices }

    /// Checks the cameras now, and again whenever one connects or disconnects.
    func watchCameras() {
        // Delivered on the next turn of the main queue, once the new list is in place.
        cameraWatch = (cameraSource ?? camera).devicesPublisher.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.camerasChanged() } }
        camerasChanged()
    }

    /// The camera list changed. A pause it causes stops a running check, Home Test checks too, and tells an open box.
    func camerasChanged() {
        let before = lockout
        checkCameras()
        guard lockout != before else { return }
        stopHomeTest("Stopped: a new camera was plugged in.")
        guard dialog != nil else { return }
        if !isSettingUpFace && !previewing { work?.cancel() }
        showPaused()
    }

    // MARK: Menu and Settings actions

    func togglePause() {
        paused.toggle()
        if paused { stopWatching() }
    }

    /// The menu item under the status line. Pause and Resume can't end a pause after misses or a new
    /// camera, so then it opens Settings, where typing the password turns face unlock back on.
    var pauseItemTitle: String { lockout != nil ? "Turn Back On…" : (paused ? "Resume" : "Pause") }

    func pauseItemChosen() {
        if lockout != nil { openSettings() } else { togglePause() }
    }

    func requestCamera() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            return openSystemSettings("Privacy_Camera")
        }
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            refreshPermissions()
        }
    }

    /// Asks macOS to list the app under Accessibility, then opens that page of System Settings.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSystemSettings("Privacy_Accessibility") }
    }

    func openSystemSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Turning it on can need approval in System Settings; then that page opens instead of failing silently.
    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                try newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                if newValue, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch {
                if newValue { SMAppService.openSystemSettingsLoginItems() }
            }
        }
    }

    /// Opens a real macOS password box so the whole flow can be tried end to end. Says it worked only
    /// when this app filled the box, not when the box was approved some other way.
    func tryIt() {
        guard tryTask == nil else { return }
        tryResult = nil
        tryFilled = false
        let prompt = tryPrompt ?? Self.askForPassword
        tryTask = Task {
            let approved = await prompt()
            tryResult = approved ? (tryFilled ? "It worked." : "Approved, but Face ID Unlock didn't fill it.") : nil
            tryTask = nil
        }
    }

    private static func askForPassword() async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Try Face ID Unlock")) ?? false
    }

    // MARK: Home test (decision L5)

    /// Seconds to wait before checking a photo, a screen or another person, so the owner can get it in place
    /// with their own face out of view. Tests set 0.
    var homeTestLeadIn = 3

    /// Why Check can't run now, or nil when it can.
    var homeTestUnavailable: String? {
        if gallery == nil { return "Set up your face in Settings first." }
        if !cameraAllowed { return "Allow the camera in Settings first." }
        if lockout != nil { return homeTestPausedLine }
        if passwordBoxOpen { return "A password box is open. Close it first." }
        if isSettingUpFace { return "Face setup is running." }
        return nil
    }

    /// For a new window and when it closes: asks for the Mac password again, stops a running check and turns
    /// saving pictures off. The tally stays until the app quits.
    func lockHomeTest() {
        homeTestSession += 1
        homeTestWork?.cancel()
        homeTestWork = nil
        testPictureSession = nil
        homeTest.savePictures = false
        homeTest.unlocked = false
        homeTest.checking = false
        homeTest.startingIn = nil
        homeTest.glance = nil
        homeTest.result = nil
    }

    /// Opens the window's checks once the password is checked against the account, as Settings checks it.
    /// Nothing is kept and the saved password is untouched. A wrong password throws and changes nothing.
    /// Without this gate, someone at an unlocked Mac could tune a photo or video with unlimited tries.
    func unlockHomeTest(_ text: String) async throws {
        let session = homeTestSession
        try await password.verify(text)
        guard session == homeTestSession else { throw CancellationError() }
        homeTest.unlocked = true
        changeTestPictures { _ in }
    }

    /// The Home Test window's switch: save the camera pictures of each try from now on (vision AI research,
    /// section 3). Off whenever the window opens; never for a real password box.
    func setSaveTestPictures(_ on: Bool) {
        guard homeTest.unlocked else { return }
        homeTest.savePictures = on
    }

    /// Removes every saved try, after any save still being written.
    func deleteTestPictures() {
        testPictureSession = nil
        changeTestPictures { try? $0.deleteAll() }
    }

    func showTestPictures() {
        NSWorkspace.shared.activateFileViewerSelecting([testPictures.folder])
    }

    /// Writes one finished try's pictures off the main thread, after the camera is off, into this window's folder.
    private func saveTestPictures(_ recorder: TestPictureRecorder, record: ScoreRecord, subject: HomeTestSubject) {
        let session = testPictureSession ?? TestPictures.sessionName(for: Date()), code = subject.rawValue
        testPictureSession = session
        changeTestPictures { pictures in
            let capture = await recorder.finish()
            _ = try? pictures.save(capture, record: record, subject: code, session: session)
        }
    }

    /// Runs `change` on the Test Pictures folder off the main thread, after the one before it, then shows the count.
    private func changeTestPictures(_ change: @escaping @Sendable (TestPictures) async -> Void) {
        let pictures = testPictures, previous = testPictureWork
        testPictureWork = Task {
            await previous?.value
            homeTest.savedTries = await Task.detached {
                await change(pictures)
                return pictures.count()
            }.value
        }
    }

    /// One face check of `subject` with no password box: the same check, glance and rules as the boxes that need
    /// the glance, but nothing is filled and it neither counts toward the pause after misses nor resets it. A pause
    /// or screen sharing stops it before the camera starts, as for a real box.
    func checkHomeTest(_ subject: HomeTestSubject) {
        guard homeTest.unlocked, !homeTest.checking, homeTestUnavailable == nil, cameraAccess(), let gallery else { return }
        homeTestStop = nil
        homeTest.result = nil
        checkCameras()
        guard lockout == nil else { return } // homeTestUnavailable now says why.
        if scanner.system.isRemoteControlled() {
            homeTest.result = Self.homeTestSharingLine
            return
        }
        homeTest.checking = true
        let session = homeTestSession
        homeTestWork = begin({ [self] in await runHomeTest(gallery, subject, session: session) },
                             cancelled: { [self] in endHomeTest(nil, session: session) })
    }

    /// The check itself, logged as a `homeTest` event whether it ends or is stopped. A photo, screen or other
    /// person gets `homeTestLeadIn` seconds first, counted down on screen with the camera off; stopped then,
    /// nothing is logged. With the switch on, a try that runs to the end saves its pictures; a stopped one doesn't.
    private func runHomeTest(_ gallery: FaceGallery, _ subject: HomeTestSubject, session: Int) async {
        if !subject.isOwner {
            do {
                for left in stride(from: homeTestLeadIn, to: 0, by: -1) {
                    homeTest.startingIn = left
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                return endHomeTest(nil, session: session)
            }
            homeTest.startingIn = nil
        }
        lastEffects = nil
        let glance = glanceDirection()
        let recorder = homeTest.savePictures ? TestPictureRecorder(gallery: gallery, startedAt: CameraService.now) : nil
        let record: CheckRecord
        do {
            record = try await faceCheck(gallery, glance: glance, recorder: recorder) {
                if session == homeTestSession { homeTest.glance = $0 }
            }
        } catch {
            return endHomeTest(Task.isCancelled ? nil : "Couldn't check your face. " + error.localizedDescription,
                               session: session)
        }
        let stopped = Task.isCancelled, passed = Self.letsIn(record, glance: glance)
        // A real fill looks for screen sharing again right before it types.
        let sharing = !stopped && passed && scanner.system.isRemoteControlled()
        let letIn = !stopped && !sharing && passed
        var entry = ScoreRecord(homeTest: record, subject: subject.rawValue, letIn: letIn, date: Date())
        entry.effects = lastEffects
        if sharing { entry.fill = FillOutcome.failed(.screenSharing).logCode }
        try? scoreLog.append(entry)
        guard !stopped else { return endHomeTest(nil, session: session) }
        guard !sharing else { return endHomeTest(Self.homeTestSharingLine, session: session) }
        homeTest.tally[subject, default: HomeTestState.Tally()].tries += 1
        if letIn { homeTest.tally[subject, default: HomeTestState.Tally()].letIn += 1 }
        if let recorder { saveTestPictures(recorder, record: entry, subject: subject) }
        endHomeTest(HomeTestState.line(for: record, subject: subject), session: session)
    }

    /// Shows `line`, or why the check was stopped, unless the window has locked since the check began.
    private func endHomeTest(_ line: String?, session: Int) {
        guard session == homeTestSession else { return }
        homeTestWork = nil
        homeTest.checking = false
        homeTest.startingIn = nil
        homeTest.glance = nil
        homeTest.result = line ?? homeTestStop ?? "Stopped."
    }

    /// Stops a running Home Test check; `reason` becomes its result line.
    private func stopHomeTest(_ reason: String) {
        guard homeTest.checking else { return }
        homeTestStop = reason
        homeTestWork?.cancel()
    }

    private var homeTestPausedLine: String {
        (lockout == .misses ? "Paused: 3 tries at real password boxes didn't match."
                            : "Paused: a new camera was plugged in.")
            + " Type your Mac password in Settings to turn it back on."
    }

    private static let homeTestSharingLine = "Screen sharing is on, so a real box wouldn't be filled."

    func showScoreLog() {
        let url = scoreLog.url
        NSWorkspace.shared.activateFileViewerSelecting(
            [FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()])
    }

    func quit() {
        timer?.invalidate()
        work?.cancel()
        cameraInstance?.stop()
    }

    // MARK: Bar

    private func stopWatching() {
        dialog = nil
        firstSeen = nil
        attempted = false
        askedForPassword = false
        if !isSettingUpFace && !previewing { work?.cancel() }
        hideBar()
    }

    private func show(_ content: StatusBarContent, hideAfter seconds: Double? = nil) {
        hideCount += 1
        bar = content
        guard let seconds else { return }
        let count = hideCount
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if count == hideCount { bar = nil }
        }
    }

    /// Says why, and stays until the box closes; Turn Back On opens Settings.
    private func showPaused() {
        let reason = lockout == .misses ? "3 tries didn't match." : "A new camera was plugged in."
        show(StatusBarContent(symbol: "pause.circle.fill", tint: .orange, text: "Face ID Unlock is paused",
                              detail: reason + " Type your password this time.", requester: dialog?.requester,
                              action: .turnBackOn))
    }

    /// The glance (decision L4): which way to turn, with a pulsing arrow pointing that way. The camera stays on.
    private func showGlance(_ direction: GlanceCheck.Direction) {
        show(StatusBarContent(symbol: direction.arrow, tint: .blue, text: direction.instruction,
                              detail: "Turn your head a little to the \(direction.rawValue).", requester: dialog?.requester,
                              animated: true))
    }

    private func showScreenSharing() {
        show(StatusBarContent(symbol: "rectangle.on.rectangle", tint: .orange, text: "Screen sharing is on",
                              detail: "Your password wasn't filled. Type it yourself this time.",
                              requester: dialog?.requester), hideAfter: 4)
    }

    /// The box wants another keychain's or another user's password, or more than one: trying again won't help.
    private func showDifferentPassword() {
        show(StatusBarContent(symbol: "key", tint: .orange, text: "This box needs a different password",
                              detail: "Type it yourself.", requester: dialog?.requester), hideAfter: 3)
    }

    /// With Try Again. `reason`, when given, shows instead of the box's first line.
    private func showFailure(_ text: String, reason: String? = nil, symbol: String = "exclamationmark.circle.fill") {
        show(StatusBarContent(symbol: symbol, tint: .orange, text: text, detail: reason, requester: dialog?.requester,
                              action: .tryAgain))
    }

    private func hideBar() {
        hideCount += 1
        bar = nil
    }
}
