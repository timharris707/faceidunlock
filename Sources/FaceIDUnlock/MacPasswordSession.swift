import AppKit
import Combine
import Foundation
import OpenDirectory

/// Checks a password against the current user's account. Tests replace it so they never call OpenDirectory.
protocol MacPasswordVerifier: Sendable {
    /// True for the right password, false for a wrong one; throws when the check itself can't run.
    func isLoginPassword(_ password: String) throws -> Bool
}

/// Asks OpenDirectory whether the password belongs to the logged-in user. Shows no dialog.
struct OpenDirectoryVerifier: MacPasswordVerifier {
    func isLoginPassword(_ password: String) throws -> Bool {
        let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
        let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        do {
            try record.verifyPassword(password)
            return true
        } catch let error as NSError where error.domain == ODFrameworkErrorDomain
                    && error.code == Int(kODErrorCredentialsInvalid.rawValue) {
            return false
        }
    }
}

enum MacPasswordError: LocalizedError, Equatable {
    case wrongPassword, couldNotCheck
    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "That isn't your Mac password."
        case .couldNotCheck: return "Couldn't check your password. Try again in a minute."
        }
    }
}

/// The Mac password, in memory only, for this login session (decision D1: asked once after each restart).
/// Kept through screen lock, display sleep and system sleep. Erased on quit, on switching to another user,
/// and when the face is forgotten or set up again. Never logged.
@MainActor
final class MacPasswordSession: ObservableObject {
    @Published private(set) var hasPassword = false
    private var bytes: [UInt8] = []
    private var generation = 0
    private let verifier: any MacPasswordVerifier
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// The notification centers are injectable so tests can post to private ones.
    init(verifier: any MacPasswordVerifier = OpenDirectoryVerifier(),
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         app: NotificationCenter = .default) {
        self.verifier = verifier
        let clearing = [(workspace, NSWorkspace.sessionDidResignActiveNotification),
                        (app, NSApplication.willTerminateNotification)]
        observers = clearing.map { center, name in
            // Synchronous on the main thread, so the bytes are gone before quit finishes.
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.forget() }
            })
        }
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    /// Keeps the password only after checking it is the current user's login password.
    /// A wrong password leaves any earlier, checked password in place.
    func save(_ password: String) async throws {
        let started = generation
        try await verify(password)
        // Forgotten (user switch, quit, Forget) while the check ran: don't bring it back.
        guard generation == started else { throw CancellationError() }
        erase()
        bytes = Array(password.utf8)
        hasPassword = true
    }

    /// Checks the password against the account off the main thread, without keeping it or touching the saved one.
    func verify(_ password: String) async throws {
        guard !password.isEmpty else { throw MacPasswordError.wrongPassword }
        let verifier = verifier
        let correct: Bool
        do {
            correct = try await Task.detached { try verifier.isLoginPassword(password) }.value
        } catch {
            throw MacPasswordError.couldNotCheck
        }
        guard correct else { throw MacPasswordError.wrongPassword }
    }

    func withPassword<T>(_ action: ([UInt8]) throws -> T) rethrows -> T {
        try action(bytes)
    }

    func forget() {
        generation += 1
        erase()
    }

    private func erase() {
        bytes.withUnsafeMutableBytes { buffer in
            if let address = buffer.baseAddress { memset_s(address, buffer.count, 0, buffer.count) }
        }
        bytes.removeAll(keepingCapacity: false)
        hasPassword = false
    }
}
