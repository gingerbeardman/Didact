//
//  KeyWriteCoalescer.swift
//  Didact
//
//  A per-control, leading-edge latest-value gate for media-key writes. DDC
//  writes take tens of milliseconds, so a held key can produce values faster than
//  the monitor accepts them. The first value is written immediately; while that
//  write is in flight only the newest value is kept, and it is written when the
//  previous write completes. Nothing piles up, and the last value always wins.
//

import Foundation

final class KeyWriteCoalescer {
    private var pending: [String: Int] = [:]
    private var inFlight: Set<String> = []

    /// Returns the value to write now, or nil when a write is already in flight
    /// (the value has been kept as the newest pending one).
    func submit(key: String, value: Int) -> Int? {
        if inFlight.contains(key) {
            pending[key] = value
            return nil
        }
        inFlight.insert(key)
        return value
    }

    /// Called when the in-flight write finishes. Returns the next value to write,
    /// or nil when there is nothing newer.
    func complete(key: String) -> Int? {
        inFlight.remove(key)
        guard let next = pending.removeValue(forKey: key) else { return nil }
        inFlight.insert(key)
        return next
    }

    /// Drop a queued value (e.g. a slider write superseded it). An in-flight
    /// write still completes, but won't be followed by the cancelled value.
    func cancel(key: String) {
        pending.removeValue(forKey: key)
    }
}
