import AppKit
import AVFoundation
import FaceIDCore
import SwiftUI

/// The Settings window: the app's icon and name, four rows that tick themselves green, then Open at login and
/// Test It Now. While Face ID Unlock is paused, a banner under the name says why.
struct SetupView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var camera: CameraService
    @State private var passwordText = ""
    @State private var passwordError: String?
    @State private var checkingPassword = false
    /// The saved face when setup began, so a newly added one can be told from a cancelled or failed setup.
    @State private var galleryAtStart: FaceGallery?
    /// Set while setup runs, and for a second after it adds a face, so the ring can show its tick.
    @State private var finishing = false
    @Environment(\.colorSchemeContrast) private var contrast

    /// Lines up what sits below the boxes with what is inside them: the box's own inset plus the rows'.
    private static let belowBoxes: CGFloat = 11

    private var allDone: Bool {
        controller.cameraAllowed && controller.accessibilityAllowed && !controller.asksForPassword
            && controller.gallery != nil && controller.modelError == nil
    }

    /// The setup this window watched has just saved a new face.
    private var faceAdded: Bool {
        finishing && !controller.isSettingUpFace && controller.gallery != nil && controller.gallery != galleryAtStart
    }

    /// What the ring under "Your face" shows: setup as it runs, then everything done while a new face holds.
    private var ring: (instruction: FaceSetupCollector.Instruction, hint: FaceHint?, progress: [FaceGallery.Pose: Double])? {
        if case .capturing(let instruction, let hint, let progress) = controller.faceSetup { return (instruction, hint, progress) }
        return faceAdded ? (.done, nil, [.center: 1, .left: 1, .right: 1]) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let message = controller.lockoutMessage { pauseBanner(message) }
            GroupBox {
                VStack(spacing: 0) {
                    SetupRow(done: controller.cameraAllowed, title: "Camera") { cameraRow }
                    Divider().padding(.leading, 38).padding(.trailing, 6)
                    SetupRow(done: controller.accessibilityAllowed, title: "Let it fill password boxes") {
                        if !controller.accessibilityAllowed {
                            Text("In the window that opens, turn on Face ID Unlock.").font(.callout).foregroundStyle(.secondary)
                            Button("Open System Settings") { controller.requestAccessibility() }
                        }
                    }
                    Divider().padding(.leading, 38).padding(.trailing, 6)
                    // While paused the field below turns it back on, so the step isn't done.
                    SetupRow(done: !controller.asksForPassword, title: "Your Mac password") { passwordRow }
                    Divider().padding(.leading, 38).padding(.trailing, 6)
                    SetupRow(done: controller.gallery != nil, title: "Your face") { faceRow }
                    if let ring { faceScan(ring.instruction, hint: ring.hint, progress: ring.progress) }
                }
            }
            GroupBox {
                HStack {
                    Text("Open at login").accessibilityHidden(true) // VoiceOver reads the switch's name instead.
                    Spacer()
                    Toggle("Open at login", isOn: $controller.opensAtLogin)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            if controller.paused {
                Text("Paused. Resume from the menu bar.").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, Self.belowBoxes)
            } else if allDone && ring == nil {
                // The result, once there is one, replaces the caption.
                HStack(alignment: .firstTextBaseline) {
                    Text(controller.tryResult ?? "Opens a test password box.").font(.callout)
                        .foregroundStyle(controller.tryResult == nil ? .secondary : .primary)
                    Spacer()
                    Button("Test It Now") { controller.tryIt() }.buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, Self.belowBoxes)
            }
            Text("A photo or video of you could fool a regular camera. Use this for convenience, not security.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, Self.belowBoxes)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4) // The transparent title bar above gives the rest.
        .padding(.bottom, 20)
        .frame(width: 440)
        .onChange(of: controller.isSettingUpFace, initial: true) { _, settingUp in
            if settingUp {
                galleryAtStart = controller.gallery
                finishing = true
            } else if faceAdded {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    finishing = false
                }
            } else {
                finishing = false
            }
        }
    }

    /// The app's icon and name, centred, in place of the hidden window title.
    private var header: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 56, height: 56).accessibilityHidden(true)
            Text("Face ID Unlock").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var cameraRow: some View {
        if !controller.cameraAllowed {
            Text("So it can see your face.").font(.callout).foregroundStyle(.secondary)
            Button("Allow Camera") { controller.requestCamera() }
        } else if camera.hasMultipleCameras {
            // Picking a camera shows what it sees, so cameras with the same name can be told apart.
            Picker("Camera", selection: Binding(get: { camera.selectedDeviceID },
                                                set: { camera.selectedDeviceID = $0; controller.previewCamera() })) {
                ForEach(camera.devices) { Text($0.displayName).tag($0.id) }
            }
            .labelsHidden()
            .disabled(controller.isSettingUpFace)
            if controller.previewing {
                CameraCircle(session: camera.session).frame(width: 120, height: 120)
            }
        }
    }

    /// While Face ID Unlock is paused the field shows even with a password saved: typing it turns it back on.
    @ViewBuilder private var passwordRow: some View {
        if !controller.asksForPassword {
            Text("Kept until you quit or restart. You'll type it here once after each restart.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            HStack {
                SecureField("Mac password", text: $passwordText).onSubmit(savePassword)
                Button("Save", action: savePassword).disabled(passwordText.isEmpty || checkingPassword)
                if checkingPassword { ProgressView().controlSize(.small) }
            }
            if let passwordError { Text(passwordError).font(.callout).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var faceRow: some View {
        if let modelError = controller.modelError {
            Text(modelError).font(.callout).foregroundStyle(.red)
        } else if ring != nil {
            EmptyView() // The ring shows below the row, across the whole box.
        } else {
            switch controller.faceSetup {
            case .capturing:
                EmptyView()
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(Color.readableOrange)
                Button("Try Again") { controller.setUpFace() }.disabled(!controller.canSetUpFace)
            case .idle:
                if controller.gallery != nil {
                    Text(allDone ? "All set. Next time a Mac password box opens, just look at the screen." : "Face added")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Set Up Again") { controller.setUpFace() }.disabled(!controller.canSetUpFace)
                        Button("Forget My Face") { controller.forgetFace() }
                    }
                } else {
                    Text("Look at the screen, then turn a little left and right.").font(.callout).foregroundStyle(.secondary)
                    Button("Set Up My Face") { controller.setUpFace() }.disabled(!controller.canSetUpFace)
                }
            }
        }
    }

    /// The camera in a ring that fills as the face is taken, centred in the box, with Cancel. A hint (too
    /// dark, no face, two faces) replaces the instruction, in orange. Once a face is added the ring holds a
    /// tick for a second. Cancel goes as soon as it reads "Face added", since the face is saved either way.
    private func faceScan(_ instruction: FaceSetupCollector.Instruction, hint: FaceHint?,
                          progress: [FaceGallery.Pose: Double]) -> some View {
        let text = hint.map { Self.text(for: $0) } ?? Self.text(for: instruction)
        let done = instruction == .done
        return VStack(spacing: 12) {
            FaceRing(session: camera.session, progress: progress, added: faceAdded)
            Text(text)
                .font(.body.weight(.semibold)).multilineTextAlignment(.center)
                .foregroundStyle(hint == nil ? Color.primary : Color.readableOrange)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: text)
            Button("Cancel") { controller.cancelFaceSetup() }
                .opacity(done ? 0 : 1).disabled(done).accessibilityHidden(done)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// Why Face ID Unlock is paused. The password field below turns it back on.
    private func pauseBanner(_ message: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous) // As the boxes below.
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pause.circle.fill").font(.title2).foregroundStyle(.orange).frame(width: 22)
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
        // Icon and text line up with the rows' marks and titles below.
        .padding(.vertical, 12)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(Color.orange.opacity(0.12))
            shape.strokeBorder(Color.orange.opacity(contrast == .increased ? 0.6 : 0.28), lineWidth: 1)
        }
    }

    private func savePassword() {
        guard !passwordText.isEmpty, !checkingPassword else { return }
        let text = passwordText
        checkingPassword = true
        passwordError = nil
        Task {
            do {
                try await controller.savePassword(text)
                passwordText = ""
            } catch is CancellationError {
            } catch {
                passwordError = error.localizedDescription
            }
            checkingPassword = false
        }
    }

    /// Tick `index` of the setup ring's 72, clockwise from 12 o'clock: how green it is, and whether it is lit.
    /// Straight-ahead samples tint every tick together, never a route around the ring. Each turn lights the half
    /// of the mirrored picture it turns toward, spreading from that half's middle: `.left` (positive yaw) is the
    /// screen-left half.
    static func tick(_ index: Int, progress: [FaceGallery.Pose: Double]) -> (green: Double, lit: Bool) {
        let angle = FaceRing.angle(index)
        let (pose, middle) = angle < 180 ? (FaceGallery.Pose.right, 90.0) : (.left, 270.0)
        if abs(angle - middle) < 90 * (progress[pose] ?? 0) { return (1, true) }
        return (0.4 * (progress[.center] ?? 0), false)
    }

    static func text(for instruction: FaceSetupCollector.Instruction) -> String {
        switch instruction {
        case .lookAtScreen: return "Look at the screen"
        case .turnSlowly: return "Now turn your head slowly a little left and right"
        case .done: return "Face added"
        case .failed(let problem): return AppController.message(for: problem)
        }
    }

    static func text(for hint: FaceHint) -> String {
        switch hint {
        case .noFace: return "Move so your face is in view."
        case .multipleFaces: return AppController.message(for: .multipleFaces)
        case .tooDark: return AppController.message(for: .tooDark)
        }
    }
}

/// One setup step: a mark that turns into a green tick by itself, a title and whatever the step needs.
private struct SetupRow<Content: View>: View {
    let done: Bool
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(done ? Color.white : Color.secondary, Color.green)
                .font(.title2)
                .frame(width: 22)
                .accessibilityLabel(done ? "Done" : "Not done")
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .animation(reduceMotion ? nil : .snappy, value: done)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
    }
}

/// The live camera picture in a circle, in the app icon's navy well with a thin steel rim, so it is never an
/// empty hole before the first frame. The same in light and dark mode, as a camera picture is dark either way.
struct CameraCircle: View {
    private static let well = Color(.sRGB, red: 0.071, green: 0.106, blue: 0.180)
    private static let rim = Color(.sRGB, red: 0.765, green: 0.788, blue: 0.820).opacity(0.55)
    let session: AVCaptureSession

    var body: some View {
        ZStack {
            Circle().fill(Self.well)
            MirroredCameraPreview(session: session).clipShape(Circle())
            Circle().strokeBorder(Self.rim, lineWidth: 1)
        }
    }
}

/// The setup ring, as on iPhone: the camera picture inside 72 ticks that turn green as the face is taken (see
/// `SetupView.tick`). Lit ticks are longer. Once a face is added, the picture dims under a white tick.
private struct FaceRing: View {
    let session: AVCaptureSession
    let progress: [FaceGallery.Pose: Double]
    let added: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// Degrees clockwise from 12 o'clock; none sits exactly at the top or bottom.
    static func angle(_ index: Int) -> Double { 2.5 + 5 * Double(index) }

    var body: some View {
        let increased = contrast == .increased
        let mean = progress.values.reduce(0, +) / 3
        ZStack {
            CameraCircle(session: session).frame(width: 200, height: 200)
            ZStack {
                if added {
                    Circle().fill(Color.black.opacity(0.35))
                    Image(systemName: "checkmark").font(.system(size: 52, weight: .semibold)).foregroundStyle(.white)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: 200, height: 200)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.25), value: added)
            ForEach(0..<72, id: \.self) { index in
                let tick = SetupView.tick(index, progress: progress)
                let length: CGFloat = tick.lit ? 12 : 8
                ZStack {
                    Capsule().fill(Color.primary.opacity(increased ? 0.32 : 0.16))
                    Capsule().fill(Color.green.opacity(tick.green))
                }
                .frame(width: 3, height: length)
                .offset(y: -(106 + length / 2))
                .rotationEffect(.degrees(Self.angle(index)))
                .animation(animation(index, lit: tick.lit), value: tick.green)
            }
        }
        .frame(width: 240, height: 240)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your face")
        .accessibilityValue("\(Int(mean * 100)) percent")
    }

    /// Ticks lit together fill in outward from their half's middle, six steps at a time; a tint reaches every
    /// tick at once. With Reduce Motion a tint is a quick crossfade and a tick lights at once, without growing.
    /// A tick's green changes whenever it lights.
    private func animation(_ index: Int, lit: Bool) -> Animation? {
        if reduceMotion { return lit ? nil : .easeInOut(duration: 0.15) }
        guard lit else { return .easeOut(duration: 0.35) }
        let fromMiddle = Int(abs(Self.angle(index).truncatingRemainder(dividingBy: 180) - 90) / 5)
        return .easeOut(duration: 0.35).delay(Double(fromMiddle % 6) * 0.012)
    }
}

extension Color {
    /// Orange text that stays readable on a light window: darker in light mode (darker still with Increase
    /// Contrast), the system orange in dark.
    static let readableOrange = Color(nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                           .accessibilityHighContrastDarkAqua]) {
        case .darkAqua?, .accessibilityHighContrastDarkAqua?: return .systemOrange
        case .accessibilityHighContrastAqua?: return NSColor(srgbRed: 0.62, green: 0.27, blue: 0, alpha: 1)
        default: return NSColor(srgbRed: 0.72, green: 0.33, blue: 0, alpha: 1)
        }
    })
}
