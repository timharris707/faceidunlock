import FaceIDCore
import SwiftUI

/// What is in front of the camera for a Home Test check (decision L5, liveness research section 4). The raw
/// values are the fixed codes in the score log.
enum HomeTestSubject: String, CaseIterable {
    case me, meDimOrBacklit, printedPhoto, phonePhoto, phoneVideoFar, phoneVideoClose, iPadVideo, otherPerson

    var title: String {
        switch self {
        case .me: return "Me"
        case .meDimOrBacklit: return "Me, dim or backlit"
        case .printedPhoto: return "Printed photo"
        case .phonePhoto: return "Photo on a phone"
        case .phoneVideoFar: return "Phone video, arm's length"
        case .phoneVideoClose: return "Phone video, held close"
        case .iPadVideo: return "Video on the iPad"
        case .otherPerson: return "Another person"
        }
    }

    /// The owner's own face, where a match would fill the box. For the rest, a match lets someone in.
    var isOwner: Bool { self == .me || self == .meDimOrBacklit }
}

/// What the Home Test window shows.
struct HomeTestState: Equatable {
    struct Tally: Equatable { var tries = 0, letIn = 0 }
    /// The Mac password was typed since the window opened.
    var unlocked = false
    var checking = false
    /// Seconds left before a photo, screen or other-person check starts looking; nil otherwise.
    var startingIn: Int?
    /// The way the running check's glance asks the person to turn; nil before and after it.
    var glance: GlanceCheck.Direction?
    /// What the last check found, in one line.
    var result: String?
    /// Checks that ran to the end, per kind, and how many got through the face check and the glance.
    var tally: [HomeTestSubject: Tally] = [:]
    /// The switch to save each try's camera pictures; off whenever the window opens.
    var savePictures = false
    /// Tries saved in Test Pictures, from every window so far.
    var savedTries = 0

    /// Would it have filled (or let them in); if the face matched but the glance stopped it, that and why; then
    /// the best match score, the median real-face score and the glance's flatness score.
    static func line(for record: CheckRecord, subject: HomeTestSubject) -> String {
        let matched = record.outcome == .recognized, passed = matched && record.glance?.outcome == .passed
        let why = switch record.glance?.outcome {
        case .wrongWay: " (turned the other way)"
        case .timeout: " (no turn in time)"
        case .lostFace: " (the face didn't match, or a second face appeared)"
        case .notReal: " (looked like a photo or screen)"
        case .passed, nil: ""
        }
        let verdict = switch (subject.isOwner, passed, matched) {
        case (true, true, _): "Would have filled."
        case (true, false, true): "Wouldn't have filled: stopped at the glance\(why)."
        case (true, false, false): "Wouldn't have filled."
        case (false, true, _): "Let in."
        case (false, false, true): "Kept out at the glance\(why)."
        case (false, false, false): "Kept out."
        }
        guard let best = record.scores.max() else { return verdict + " No clear face seen." }
        var line = verdict + " Best match " + String(format: "%.2f", best)
        if let real = median(record.photoScreen.map(\.real)) { line += ", real-face score " + String(format: "%.2f", real) }
        if let flatness = record.glance?.flatness { line += ", 3D score " + String(format: "%.2f", flatness) }
        return line + "."
    }

    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// The hidden Home Test window, opened from the menu with Option held. It asks for the Mac password each time
/// it opens; then pick what is in front of the camera and click Check. Each check runs the face check and the
/// glance, as an admin or keychain box would. Nothing is ever filled. A switch, off each time the window opens,
/// saves each try's camera pictures for the bake-off.
struct HomeTestView: View {
    @ObservedObject var controller: AppController
    /// Closes the window.
    var done: () -> Void = {}
    /// What is in front of the camera; "Me" when the window opens.
    @State var subject = HomeTestSubject.me
    @State private var passwordText = ""
    @State private var passwordError: String?
    @State private var checkingPassword = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if controller.homeTest.unlocked { checks } else { gate }
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
    }

    @ViewBuilder private var gate: some View {
        Text("Checks your face without filling anything. Type your Mac password to start.")
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            SecureField("Mac password", text: $passwordText).onSubmit(unlock)
            Button("Continue", action: unlock).buttonStyle(.borderedProminent)
                .disabled(passwordText.isEmpty || checkingPassword)
            if checkingPassword { ProgressView().controlSize(.small) }
        }
        if let passwordError { Text(passwordError).foregroundStyle(.red) }
    }

    @ViewBuilder private var checks: some View {
        let state = controller.homeTest
        Picker("In front of the camera", selection: $subject) {
            ForEach(HomeTestSubject.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .disabled(state.checking)
        pictures(state)
        HStack(spacing: 8) {
            Button("Check") { controller.checkHomeTest(subject) }
                .buttonStyle(.borderedProminent)
                .disabled(state.checking || controller.homeTestUnavailable != nil)
            if state.checking {
                let getReady = subject == .otherPerson ? "Swap seats now." : "Hold it up now."
                ProgressView().controlSize(.small)
                Text(state.startingIn.map { getReady + " Starting in \($0)…" } ?? state.glance?.instruction ?? "Looking…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        if let reason = controller.homeTestUnavailable {
            Text(reason).foregroundStyle(.secondary)
        } else if let result = state.result {
            Text(result).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
        if !state.tally.isEmpty { tally(state.tally) }
        HStack {
            Spacer()
            Button("Done", action: done).keyboardShortcut(.cancelAction)
        }
    }

    /// The save switch, and once tries are saved, how many with Show in Finder and Delete Test Pictures.
    @ViewBuilder private func pictures(_ state: HomeTestState) -> some View {
        Toggle("Save camera pictures from each try",
               isOn: Binding(get: { state.savePictures }, set: { controller.setSaveTestPictures($0) }))
            .disabled(state.checking)
        if state.savedTries > 0 {
            HStack(spacing: 12) {
                Text(state.savedTries == 1 ? "1 try saved" : "\(state.savedTries) tries saved").foregroundStyle(.secondary)
                Button("Show in Finder", action: controller.showTestPictures)
                Button("Delete Test Pictures") { confirmingDelete = true }.disabled(state.checking)
            }
            .font(.caption)
            .buttonStyle(.link)
            .padding(.leading, 20)
            .confirmationDialog("Delete all test pictures?", isPresented: $confirmingDelete) {
                Button("Delete Test Pictures", role: .destructive, action: controller.deleteTestPictures)
            } message: {
                Text("Every saved try is deleted.")
            }
        }
    }

    private func tally(_ tally: [HomeTestSubject: HomeTestState.Tally]) -> some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                GridRow {
                    Text("")
                    Text("Tries").gridColumnAlignment(.trailing)
                    Text("Let in").gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(HomeTestSubject.allCases.filter { tally[$0] != nil }, id: \.self) { kind in
                    GridRow {
                        Text(kind.title)
                        Text("\(tally[kind]?.tries ?? 0)")
                        Text("\(tally[kind]?.letIn ?? 0)")
                    }
                }
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// Checks the password as Settings does. The typed text is cleared at once, right or wrong.
    private func unlock() {
        guard !passwordText.isEmpty, !checkingPassword else { return }
        let text = passwordText
        passwordText = ""
        checkingPassword = true
        passwordError = nil
        Task {
            do {
                try await controller.unlockHomeTest(text)
            } catch is CancellationError {
            } catch {
                passwordError = error.localizedDescription
            }
            checkingPassword = false
        }
    }
}
