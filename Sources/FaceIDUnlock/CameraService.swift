@preconcurrency import AVFoundation
import Combine
import FaceIDCore
import Foundation

struct CameraDevice: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// The Mac's own camera, as opposed to a display, USB or iPhone camera. Studio Display cameras report
    /// the same device type as the Mac's own camera, so this comes from the transport ('bltn').
    var isBuiltIn = false
}

/// The connected cameras: the camera service in the app, a fake in tests.
@MainActor
protocol CameraList: AnyObject {
    var devices: [CameraDevice] { get }
    /// Sends the current list on subscribing, then each new list just before `devices` holds it, as
    /// @Published does.
    var devicesPublisher: AnyPublisher<[CameraDevice], Never> { get }
}

/// Which camera to use: the one the person picked when it is connected, else the built-in camera,
/// else a Studio Display camera, else the first one.
enum CameraPreference {
    static func choose(from devices: [CameraDevice], saved: String?) -> CameraDevice? {
        devices.first { $0.id == saved }
            ?? devices.first { $0.isBuiltIn }
            ?? devices.first { $0.displayName.localizedCaseInsensitiveContains("Studio Display") }
            ?? devices.first
    }

    /// The camera to switch to after the camera list changes, or nil to keep the current one. While idle it
    /// follows the preference, so a saved camera that reconnects is used again; while capturing it switches
    /// only if the current camera went away.
    static func next(current: String, devices: [CameraDevice], saved: String?, capturing: Bool) -> String? {
        let preferred = choose(from: devices, saved: saved)?.id ?? ""
        guard preferred != current, !capturing || !devices.contains(where: { $0.id == current }) else { return nil }
        return preferred
    }
}

struct CameraFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: TimeInterval
    let generation: UUID
}

enum CameraError: LocalizedError {
    case accessDenied, unavailable, changed
    case sharedID(name: String)
    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Allow Camera in System Settings → Privacy & Security → Camera."
        case .unavailable: return "The camera isn't available. Check that it's connected."
        case .changed: return "The camera changed. Try again."
        case .sharedID(let name):
            return "Two cameras show the same ID (\(name)). Unplug the one you don't use, then type your Mac password."
        }
    }
}

/// Camera access begins only through an explicit call to start().
@MainActor
final class CameraService: ObservableObject, CameraList {
    let session = AVCaptureSession()
    @Published private(set) var devices: [CameraDevice] = []
    var devicesPublisher: AnyPublisher<[CameraDevice], Never> { $devices.eraseToAnyPublisher() }
    /// Picking a connected camera from outside remembers it for later launches; automatic picks are not saved.
    @Published var selectedDeviceID = "" {
        didSet {
            guard oldValue != selectedDeviceID else { return }
            stop()
            if !autoSelecting, devices.contains(where: { $0.id == selectedDeviceID }) {
                defaults.set(selectedDeviceID, forKey: Self.savedCameraKey)
            }
        }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    var hasMultipleCameras: Bool { devices.count > 1 }
    /// False while the running camera is still adjusting exposure, and whenever it is off.
    var isExposureSettled: Bool { isRunning && frames.exposureSettled }
    static let savedCameraKey = "cameraID"
    /// kIOAudioDeviceTransportTypeBuiltIn, 'bltn'.
    private static let builtInTransport: Int32 = 0x626C_746E
    private let defaults: UserDefaults
    private var autoSelecting = false
    private let queue = DispatchQueue(label: "FaceIDUnlock.capture")
    private let frames = CameraFrameReceiver()
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDevices() }
            })
        }
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
        let cameras = discovery.devices.sorted { $0.uniqueID < $1.uniqueID }
        devices = cameras.map { device in
            CameraDevice(id: device.uniqueID, displayName: device.localizedName,
                         isBuiltIn: device.transportType == Self.builtInTransport)
        }
        if let next = CameraPreference.next(current: selectedDeviceID, devices: devices,
                                            saved: defaults.string(forKey: Self.savedCameraKey),
                                            capturing: isRunning || isStarting) {
            autoSelecting = true
            selectedDeviceID = next
            autoSelecting = false
        }
    }

    /// Keeps the current camera for later launches, even when it was picked automatically.
    func rememberSelection() {
        if devices.contains(where: { $0.id == selectedDeviceID }) {
            defaults.set(selectedDeviceID, forKey: Self.savedCameraKey)
        }
    }

    func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start() async throws {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        let currentGeneration = UUID()
        generation = currentGeneration
        guard await requestCameraAccess() else { throw CameraError.accessDenied }
        guard generation == currentGeneration else { throw CameraError.changed }
        let deviceID = selectedDeviceID
        frames.reset(generation: currentGeneration)
        let session = session, frames = frames, queue = queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw CameraError.unavailable }
                    session.beginConfiguration()
                    do {
                        session.inputs.forEach { session.removeInput($0) }
                        session.outputs.forEach { session.removeOutput($0) }
                        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else { throw CameraError.unavailable }
                        session.addInput(input)
                        let output = AVCaptureVideoDataOutput()
                        output.alwaysDiscardsLateVideoFrames = true
                        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        output.setSampleBufferDelegate(frames, queue: queue)
                        guard session.canAddOutput(output) else { throw CameraError.unavailable }
                        session.addOutput(output)
                        frames.activate(output: output, device: device, generation: currentGeneration)
                        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false
                            connection.isVideoMirrored = false
                        }
                        session.commitConfiguration()
                    } catch { session.commitConfiguration(); throw error }
                    session.startRunning()
                    guard session.isRunning else { throw CameraError.unavailable }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        guard generation == currentGeneration, selectedDeviceID == deviceID else { throw CameraError.changed }
        isRunning = true
    }

    func stop() {
        generation = UUID()
        frames.reset(generation: generation)
        isRunning = false
        let session = session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Which macOS video effects the running camera has on, for the score log; nil while it is off.
    var videoEffects: VideoEffects? {
        guard isRunning, let device = AVCaptureDevice(uniqueID: selectedDeviceID) else { return nil }
        return VideoEffects(portrait: device.isPortraitEffectActive, studioLight: device.isStudioLightActive,
                            centerStage: device.isCenterStageActive)
    }

    /// The newest frame from the running camera, if one has arrived.
    func latestFrame() -> CameraFrame? {
        guard isRunning, let frame = frames.latest(), frame.generation == generation else { return nil }
        return frame
    }

    nonisolated static var now: TimeInterval { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }
}

// Capture-session mutations are confined to the serial queue; this receiver protects every field with its lock.
private final class CameraFrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CameraFrame?
    private var generation = UUID()
    private weak var activeOutput: AVCaptureOutput?
    private weak var device: AVCaptureDevice?
    private var settled = false

    /// Whether the device had finished adjusting exposure when the latest frame arrived.
    var exposureSettled: Bool {
        lock.lock(); defer { lock.unlock() }
        return settled
    }

    func reset(generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation
        activeOutput = nil
        device = nil
        settled = false
        frame = nil
    }

    func activate(output: AVCaptureOutput, device: AVCaptureDevice, generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        activeOutput = output
        self.device = device
        settled = false
        self.generation = generation
        frame = nil
    }

    func latest() -> CameraFrame? {
        lock.lock(); defer { lock.unlock() }
        return frame
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard timestamp.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        guard output === activeOutput else { return }
        frame = CameraFrame(pixelBuffer: buffer, timestamp: timestamp, generation: generation)
        settled = device.map { !$0.isAdjustingExposure } ?? false
    }
}
