import Foundation

/// A string-keyed map that iterates in insertion order.
///
/// Not a convenience. JavaScript's `Map` iterates in insertion order, and the
/// engine depends on that in two places where a Swift `Dictionary` — whose
/// order is randomised per process launch — would be actively wrong:
///
/// 1. `deriveKeyStats` accumulates floating-point sums while iterating. Float
///    addition is not associative, so a different order is a different answer
///    in the last bits, and the answer would change between launches of the
///    same binary.
/// 2. The weak-bigram ranking sorts by confidence and takes the top three.
///    Ties are common — any two bigrams typed at the same speed tie — and
///    JavaScript's sort is stable, so ties keep insertion order. Which three
///    the user is told to drill depends on it.
///
/// Insertion order here means first appearance, which is what the original
/// produces.
public struct OrderedMap<Value> {
    private(set) public var keys: [String] = []
    private var storage: [String: Value] = [:]

    public init() {}

    public subscript(key: String) -> Value? {
        get { storage[key] }
        set {
            guard let newValue else {
                if storage.removeValue(forKey: key) != nil {
                    keys.removeAll { $0 == key }
                }
                return
            }
            if storage.updateValue(newValue, forKey: key) == nil {
                keys.append(key)
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    /// Entries in insertion order.
    public var entries: [(key: String, value: Value)] { keys.map { ($0, storage[$0]!) } }
    public var values: [Value] { keys.map { storage[$0]! } }
    public func contains(_ key: String) -> Bool { storage[key] != nil }
}

extension OrderedMap: Sequence {
    public func makeIterator() -> AnyIterator<(key: String, value: Value)> {
        var index = 0
        return AnyIterator {
            guard index < keys.count else { return nil }
            defer { index += 1 }
            let key = keys[index]
            return (key, storage[key]!)
        }
    }
}
