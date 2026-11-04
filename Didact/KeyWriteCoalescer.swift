
import Foundation

final class KeyWriteCoalescer {
    private var pending: [String: Int] = [:]
    private var inFlight: Set<String> = []

    func submit(key: String, value: Int) -> Int? {
        if inFlight.contains(key) {
            pending[key] = value
            return nil
        }
        inFlight.insert(key)
        return value
    }

    func complete(key: String) -> Int? {
        inFlight.remove(key)
        guard let next = pending.removeValue(forKey: key) else { return nil }
        inFlight.insert(key)
        return next
    }

    func cancel(key: String) {
        pending.removeValue(forKey: key)
    }
}
