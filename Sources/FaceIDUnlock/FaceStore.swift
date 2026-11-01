import FaceIDCore
import Foundation
import Security

/// One secret blob: read, replace, delete. The seam that keeps tests away from the real keychain.
protocol SecretItem: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

enum KeychainError: LocalizedError, Equatable {
    case status(OSStatus)
    var errorDescription: String? {
        switch self {
        // Shown when saving a face fails; the UI never says "keychain".
        case .status(let code): return "Your face couldn't be saved (error \(code)). Try again."
        }
    }
}

/// A generic-password item in the login keychain. The app is Developer ID signed without a provisioning
/// profile, so the data-protection keychain is off limits; the legacy item's default access list trusts
/// the app that created it, so reading it back shows no dialog.
struct GenericPasswordItem: SecretItem {
    let service: String
    let account: String

    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: false]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Face ID Unlock"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

/// The saved face, kept as JSON in one login-keychain item.
struct FaceStore: Sendable {
    static let keychainItem = GenericPasswordItem(service: "com.timharris.faceidunlock.face", account: "face")
    private let item: any SecretItem

    init(item: any SecretItem = FaceStore.keychainItem) { self.item = item }

    /// The saved face, or nil when none is saved.
    func load() throws -> FaceGallery? {
        try item.read().map { try JSONDecoder().decode(FaceGallery.self, from: $0) }
    }

    func save(_ gallery: FaceGallery) throws {
        try item.write(JSONEncoder().encode(gallery))
    }

    func delete() throws { try item.delete() }
}
