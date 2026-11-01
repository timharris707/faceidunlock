import Foundation

/// Ignores the first frames while a cold camera adjusts. Ready once exposure has settled and
/// `warmUpMinimum` has passed since the first frame, or once `warmUpMaximum` has passed regardless.
public struct CameraWarmUp: Sendable, Equatable {
    public private(set) var firstFrameAt: TimeInterval?
    public private(set) var readyAt: TimeInterval?

    public init() {}

    public var isReady: Bool { readyAt != nil }

    /// Notes a frame; returns whether it was captured after warm-up and may be used.
    @discardableResult
    public mutating func observeFrame(at time: TimeInterval, exposureSettled: Bool) -> Bool {
        guard time.isFinite else { return false }
        let first = firstFrameAt ?? time
        firstFrameAt = first
        if readyAt == nil {
            if time - first >= MatchSettings.warmUpMaximum {
                readyAt = min(time, first + MatchSettings.warmUpMaximum)
            } else if exposureSettled && time - first >= MatchSettings.warmUpMinimum {
                readyAt = time
            }
        }
        return readyAt.map { time >= $0 } ?? false
    }

    /// Ends warm-up by the clock when frames stall after the first one.
    public mutating func tick(now: TimeInterval) {
        guard readyAt == nil, let firstFrameAt, now - firstFrameAt >= MatchSettings.warmUpMaximum else { return }
        readyAt = firstFrameAt + MatchSettings.warmUpMaximum
    }

    /// When warm-up ended, or the latest it can end if it hasn't: `warmUpMaximum` after the first
    /// frame, or after `start` while no frame has arrived.
    func end(startedAt start: TimeInterval) -> TimeInterval {
        readyAt ?? (firstFrameAt ?? start) + MatchSettings.warmUpMaximum
    }
}
