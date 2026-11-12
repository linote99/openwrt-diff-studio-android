// OrderedMap.swift
// Insertion-ordered dictionary — the Swift equivalent of Java's
// LinkedHashMap<String, Object>, which is semantically significant
// throughout the port: file-entry order, manifest key order, blob
// order and Json.canonical(...) output all depend on it.
//
// Semantics preserved from LinkedHashMap:
//  * iteration is in insertion order;
//  * `remove` + re-`put` moves a key to the end;
//  * a shallow copy preserves order.

import Foundation

public struct OrderedMap<Key: Hashable, Value>: Equatable where Value: Equatable {
    public private(set) var keys: [Key] = []
    private var storage: [Key: Value] = [:]

    public init() {}

    public init(_ pairs: [(Key, Value)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public subscript(_ key: Key) -> Value? {
        get { storage[key] }
        set {
            if let value = newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = value
            } else {
                remove(key)
            }
        }
    }

    /// Put, moving an existing key to the end (LinkedHashMap
    /// remove-then-put behaviour used by Json parsing of duplicates
    /// and by Release SHA256SUMS handling).
    public mutating func putMovingToEnd(_ key: Key, _ value: Value) {
        remove(key)
        keys.append(key)
        storage[key] = value
    }

    /// Put without moving an existing key (LinkedHashMap.put).
    public mutating func put(_ key: Key, _ value: Value) {
        if storage[key] == nil { keys.append(key) }
        storage[key] = value
    }

    @discardableResult
    public mutating func remove(_ key: Key) -> Value? {
        guard let value = storage.removeValue(forKey: key) else { return nil }
        keys.removeAll { $0 == key }
        return value
    }

    public func contains(_ key: Key) -> Bool { storage[key] != nil }

    public var pairs: [(Key, Value)] {
        keys.compactMap { k in storage[k].map { (k, $0) } }
    }

    public var values: [Value] { pairs.map { $0.1 } }

    public static func == (lhs: OrderedMap, rhs: OrderedMap) -> Bool {
        lhs.keys == rhs.keys && lhs.pairs.map { $0.1 } == rhs.pairs.map { $0.1 }
    }
}

/// JSON object: an insertion-ordered map from String to JsonValue.
public typealias JsonObject = OrderedMap<String, JsonValue>
