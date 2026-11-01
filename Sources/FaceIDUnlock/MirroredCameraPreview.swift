@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// Live camera preview in a circle that looks like a mirror. Only the preview is mirrored; analysis frames stay unmirrored.
struct MirroredCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> MirroredPreviewView { MirroredPreviewView(session: session) }
    func updateNSView(_ view: MirroredPreviewView, context: Context) { view.mirror() }
}

final class MirroredPreviewView: NSView {
    let preview: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
        mirror()
        // CameraService rebuilds the session's inputs on every start, which gives the preview a new connection.
        NotificationCenter.default.addObserver(self, selector: #selector(sessionStarted),
                                               name: AVCaptureSession.didStartRunningNotification, object: session)
    }

    required init?(coder: NSCoder) { nil }

    @objc private nonisolated func sessionStarted(_ notification: Notification) {
        Task { @MainActor in self.mirror() }
    }

    /// Mirrors the current connection, or flips the layer when the connection can't mirror.
    func mirror() {
        guard let connection = preview.connection else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
            preview.setAffineTransform(.identity)
        } else {
            preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        }
    }

    override func layout() {
        super.layout()
        // Bounds and position, not frame: frame is undefined once the layer has a transform.
        preview.bounds = bounds
        preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Clipped here as well as in SwiftUI, which may not clip an AppKit layer.
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        layer?.masksToBounds = true
    }
}
