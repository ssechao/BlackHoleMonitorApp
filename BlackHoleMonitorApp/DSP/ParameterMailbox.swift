import Foundation
import os.lock

/// Hands parameter values from the main thread to the real-time audio threads.
///
/// The writer (main thread) publishes a complete value under a lock. Readers on
/// audio threads only ever use `os_unfair_lock_trylock`, so they never block:
/// if the writer happens to hold the lock, the reader keeps its previous copy
/// and picks up the new value on the next render cycle.
///
/// Each reader keeps its own `lastVersion`, so several threads (input and
/// output callbacks) can consume the same mailbox independently.
///
/// `Value` should be a plain struct without references (no arrays, strings or
/// classes), so that copying it on the audio thread never retains, releases or
/// frees memory.
final class ParameterMailbox<Value> {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var value: Value
    private var version: UInt64 = 1

    init(_ initial: Value) {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        value = initial
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Writer side (main thread). May block briefly.
    func publish(_ newValue: Value) {
        os_unfair_lock_lock(lock)
        value = newValue
        version &+= 1
        os_unfair_lock_unlock(lock)
    }

    /// Writer side: latest published value.
    var current: Value {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return value
    }

    /// Reader side (audio thread). Never blocks.
    /// - Returns: `true` when `out` was updated with a newer value.
    @discardableResult
    func fetch(into out: inout Value, lastVersion: inout UInt64) -> Bool {
        guard os_unfair_lock_trylock(lock) else { return false }
        defer { os_unfair_lock_unlock(lock) }
        guard version != lastVersion else { return false }
        out = value
        lastVersion = version
        return true
    }
}
