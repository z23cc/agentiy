import Foundation

/// Per-connection outbound frame queue with attachment-local bounds (design §5.5).
///
/// Control frames (responses, snapshot stream, notices, `resnapshotRequired`) are always accepted:
/// they are 1:1 with requests or bounded by the snapshot size. Event frames count against a per-session
/// budget (frames and bytes); when a session's budget is exceeded every queued event of that session is
/// dropped and `enqueueEvent` returns `false` so the router can suspend the attachment and send
/// `resnapshotRequired`. Nothing here grows without bound.
package final class AgentSessionHostOutboundQueue: @unchecked Sendable {
    package struct Limits: Equatable {
        package var maxEventFrames: Int
        package var maxEventBytes: Int

        package init(maxEventFrames: Int = 256, maxEventBytes: Int = 4 * 1024 * 1024) {
            self.maxEventFrames = maxEventFrames
            self.maxEventBytes = maxEventBytes
        }
    }

    private struct Item {
        var frame: Data
        var eventSessionID: String?
        var eventCursor: UInt64
    }

    private struct Budget {
        var frames = 0
        var bytes = 0
    }

    package let limits: Limits
    private let condition = NSCondition()
    private var items: [Item] = []
    private var budgets: [String: Budget] = [:]
    private var lastWrittenCursor: [String: UInt64] = [:]
    private var closed = false
    private var finishing = false

    package init(limits: Limits) {
        self.limits = limits
    }

    package func enqueueControl(_ frame: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed, !finishing else { return }
        items.append(Item(frame: frame, eventSessionID: nil, eventCursor: 0))
        condition.signal()
    }

    /// Returns `false` when `sessionID`'s budget overflowed; its queued events have then been dropped.
    package func enqueueEvent(_ frame: Data, sessionID: String, cursor: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !closed, !finishing else { return true }
        var budget = budgets[sessionID] ?? Budget()
        if budget.frames + 1 > limits.maxEventFrames || budget.bytes + frame.count > limits.maxEventBytes {
            dropEventsLocked(sessionID: sessionID)
            return false
        }
        budget.frames += 1
        budget.bytes += frame.count
        budgets[sessionID] = budget
        items.append(Item(frame: frame, eventSessionID: sessionID, eventCursor: cursor))
        condition.signal()
        return true
    }

    /// Removes every queued event frame of one session (detach, overflow, generation change).
    package func dropEvents(sessionID: String) {
        condition.lock()
        defer { condition.unlock() }
        dropEventsLocked(sessionID: sessionID)
    }

    /// Cursor of the last event frame of `sessionID` handed to the socket writer, if any.
    package func lastWrittenEventCursor(sessionID: String) -> UInt64? {
        condition.lock()
        defer { condition.unlock() }
        return lastWrittenCursor[sessionID]
    }

    package var pendingFrameCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return items.count
    }

    /// Blocks until a frame is available; returns `nil` once closed and drained.
    package func dequeue() -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty, !closed, !finishing {
            condition.wait()
        }
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        if let sessionID = item.eventSessionID {
            if var budget = budgets[sessionID] {
                budget.frames = max(0, budget.frames - 1)
                budget.bytes = max(0, budget.bytes - item.frame.count)
                budgets[sessionID] = budget
            }
            lastWrittenCursor[sessionID] = item.eventCursor
        }
        return item.frame
    }

    /// Stops accepting frames; `dequeue` keeps returning the queued ones and then `nil`.
    package func finish() {
        condition.lock()
        defer { condition.unlock() }
        finishing = true
        condition.broadcast()
    }

    package func close() {
        condition.lock()
        defer { condition.unlock() }
        closed = true
        finishing = true
        items.removeAll()
        budgets.removeAll()
        condition.broadcast()
    }

    private func dropEventsLocked(sessionID: String) {
        items.removeAll { $0.eventSessionID == sessionID }
        budgets[sessionID] = nil
    }
}
