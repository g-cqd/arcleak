// swift-format-ignore-file
import Foundation

// Continuations stored in a member where the code itself rules out dropping a
// pending one, or where nothing proves a pending one can be there. Each of
// these must stay silent: continuation-overwrite reports only an unconditional
// store with no check anywhere before it.

// Checks the member first and fails the new caller.
final class CheckedFirst {
    private var pending: CheckedContinuation<Int, Error>?

    func value() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            guard pending == nil else {
                continuation.resume(throwing: CancellationError())
                return
            }
            pending = continuation
        }
    }
}

// Resumes the old one before replacing it.
final class ResumesOld {
    private var pending: CheckedContinuation<Int, Error>?

    func value() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            pending?.resume(throwing: CancellationError())
            pending = continuation
        }
    }
}

// Unwraps the old one in a condition.
final class UnwrapsOld {
    private var pending: CheckedContinuation<Int, Never>?

    func value() async -> Int {
        await withCheckedContinuation { continuation in
            if let old = pending { old.resume(returning: 0) }
            pending = continuation
        }
    }
}

// Serialized by another member before the continuation is made.
@MainActor final class SerializedByFlag {
    private var isCapturing = false
    private var pending: CheckedContinuation<Int, Error>?

    func capture() async throws -> Int {
        guard !isCapturing else { throw CancellationError() }
        isCapturing = true
        defer { isCapturing = false }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
        }
    }
}

// Serialized by a condition inside the closure.
final class SerializedInClosure {
    private var busy = false
    private var pending: CheckedContinuation<Int, Never>?

    func value() async -> Int {
        await withCheckedContinuation { continuation in
            if busy { continuation.resume(returning: -1); return }
            pending = continuation
        }
    }
}

// Kept under a key, or appended: each caller has its own.
actor Requests {
    private var waiting: [Int: CheckedContinuation<String, Error>] = [:]
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var next = 0

    func send() async throws -> String {
        next += 1
        let id = next
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
        }
    }

    func enqueue() async {
        await withCheckedContinuation { continuation in
            queue.append(continuation)
        }
    }
}

// Stored only on one branch.
final class Conditional {
    private var pending: CheckedContinuation<Int, Never>?
    var enabled = true

    func value() async -> Int {
        await withCheckedContinuation { continuation in
            if enabled {
                pending = continuation
            } else {
                continuation.resume(returning: 0)
            }
        }
    }
}

// Handed to a function, or kept in a local box: not a member of self.
final class HandedOn {
    private let lock = NSLock()

    func value() async -> Int {
        await withCheckedContinuation { continuation in
            let box = Box(continuation)
            register(box)
        }
    }

    func register(_ box: Box) {}
}

final class Box {
    let continuation: CheckedContinuation<Int, Never>
    init(_ continuation: CheckedContinuation<Int, Never>) { self.continuation = continuation }
}

// A computed property, whose setter decides what happens.
final class ComputedSlot {
    private var storage: [CheckedContinuation<Int, Never>] = []
    private var slot: CheckedContinuation<Int, Never>? {
        get { storage.last }
        set { if let newValue { storage.append(newValue) } }
    }

    func value() async -> Int {
        await withCheckedContinuation { continuation in
            slot = continuation
        }
    }
}
