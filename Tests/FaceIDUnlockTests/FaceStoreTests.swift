import FaceIDCore
import Security
import XCTest
@testable import FaceIDUnlock

final class FaceStoreTests: XCTestCase {
    /// Stands in for the keychain item so no test reads or writes the real keychain.
    private final class MemoryItem: SecretItem, @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        init(data: Data? = nil) { self.data = data }
        func read() throws -> Data? { lock.withLock { data } }
        func write(_ data: Data) throws { lock.withLock { self.data = data } }
        func delete() throws { lock.withLock { data = nil } }
    }

    private func embedding(_ seed: Double) -> [Float] {
        FaceMatch.normalized((0..<FaceMatch.dimensions).map { Float(sin(Double($0) * seed + seed)) })!
    }

    private func gallery(_ seed: Double = 1) -> FaceGallery {
        FaceGallery(samples: [.init(pose: .center, embedding: embedding(seed)),
                              .init(pose: .left, embedding: embedding(seed + 0.1)),
                              .init(pose: .right, embedding: embedding(seed + 0.2))])
    }

    func testSavedFaceLoadsBackExactly() throws {
        let store = FaceStore(item: MemoryItem())
        try store.save(gallery())
        XCTAssertEqual(try store.load(), gallery())
    }

    func testNothingSavedLoadsAsNoFace() throws {
        XCTAssertNil(try FaceStore(item: MemoryItem()).load())
    }

    func testSavingAgainReplacesTheFace() throws {
        let store = FaceStore(item: MemoryItem())
        try store.save(gallery(1))
        try store.save(gallery(2))
        XCTAssertEqual(try store.load(), gallery(2))
    }

    func testDeleteRemovesTheFaceAndCanRepeat() throws {
        let store = FaceStore(item: MemoryItem())
        try store.save(gallery())
        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.delete())
    }

    func testDamagedItemIsAnErrorNotAFace() {
        XCTAssertThrowsError(try FaceStore(item: MemoryItem(data: Data("not a face".utf8))).load())
    }

    func testFaceLivesInOneLoginKeychainPasswordItem() {
        let query = FaceStore.keychainItem.query
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.timharris.faceidunlock.face")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "face")
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, false)
    }
}
