import AppKit
import XCTest
@testable import FaceIDUnlock

final class ProcessInstanceTests: XCTestCase {
    func testCurrentProcessIdentityIsAvailableAndStableWithoutLaunchServicesMetadata() throws {
        // Swift's command-line test process is not launched through LaunchServices.
        XCTAssertNil(NSRunningApplication.current.launchDate)
        let first = try ProcessInstance.read(pid: getpid())
        let second = try ProcessInstance.read(pid: getpid())
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.pid, getpid())
    }

    func testMissingShortOversizedAndMismatchedPIDRecordsAreRejected() {
        for count in [-1, 0, MemoryLayout<proc_bsdinfo>.size - 1, MemoryLayout<proc_bsdinfo>.size + 1] {
            XCTAssertThrowsError(try ProcessInstance.read(pid: 42) { _, info in
                info = self.record(pid: 42)
                return Int32(count)
            })
        }
        XCTAssertThrowsError(try ProcessInstance.read(pid: 42) { _, info in
            info = self.record(pid: 43)
            return Int32(MemoryLayout<proc_bsdinfo>.size)
        })
        XCTAssertThrowsError(try ProcessInstance.read(pid: 0))
    }

    func testInvalidStartTupleIsRejectedWithoutFallback() {
        for pair: (UInt64, UInt64) in [(0, 1), (1, 1_000_000), (1, UInt64.max)] {
            XCTAssertThrowsError(try ProcessInstance.read(pid: 42) { _, info in
                info = self.record(pid: 42, seconds: pair.0, microseconds: pair.1)
                return Int32(MemoryLayout<proc_bsdinfo>.size)
            })
        }
    }

    func testSamePIDWithChangedStartIsRejectedAfterInspection() {
        for changed: (UInt64, UInt64) in [(101, 500), (100, 501)] {
            var reads = 0
            var inspected = false
            XCTAssertThrowsError(try ProcessInstance.verifying(pid: 42, readInfo: { _, info in
                reads += 1
                info = reads == 1 ? self.record(pid: 42) : self.record(pid: 42, seconds: changed.0, microseconds: changed.1)
                return Int32(MemoryLayout<proc_bsdinfo>.size)
            }, inspect: { _ in
                inspected = true
                return "trusted inspection result"
            })) {
                guard case ProcessInstanceError.changed = $0 else { return XCTFail("Expected changed process rejection") }
            }
            XCTAssertTrue(inspected)
            XCTAssertEqual(reads, 2)
        }
    }

    func testMissingFinalRecordRejectsInspectionResult() {
        var reads = 0
        XCTAssertThrowsError(try ProcessInstance.verifying(pid: 42, readInfo: { _, info in
            reads += 1
            info = self.record(pid: 42)
            return reads == 1 ? Int32(MemoryLayout<proc_bsdinfo>.size) : 0
        }, inspect: { _ in "trusted inspection result" }))
        XCTAssertEqual(reads, 2)
    }

    func testStableInstanceReturnsInspectionResultAfterBothReads() throws {
        var events: [String] = []
        let result = try ProcessInstance.verifying(pid: 42, readInfo: { _, info in
            events.append("read")
            info = self.record(pid: 42)
            return Int32(MemoryLayout<proc_bsdinfo>.size)
        }, inspect: { instance in
            events.append("inspect")
            XCTAssertEqual(instance.startSeconds, 100)
            XCTAssertEqual(instance.startMicroseconds, 500)
            return "trusted inspection result"
        })
        XCTAssertEqual(result, "trusted inspection result")
        XCTAssertEqual(events, ["read", "inspect", "read"])
    }

    private func record(pid: UInt32, seconds: UInt64 = 100, microseconds: UInt64 = 500) -> proc_bsdinfo {
        var info = proc_bsdinfo()
        info.pbi_pid = pid
        info.pbi_start_tvsec = seconds
        info.pbi_start_tvusec = microseconds
        return info
    }

}
