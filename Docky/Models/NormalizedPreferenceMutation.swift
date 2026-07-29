//
//  NormalizedPreferenceMutation.swift
//  Docky
//
//  Pure mutation planning for preferences whose public value is normalized
//  before it is persisted.
//

import Foundation

/// Describes one normalized preference assignment.
///
/// Swift property observers do not recursively run when the property is
/// reassigned from its own `didSet`. The caller must therefore both install
/// `normalizedValue` and complete persistence in the original observer pass.
nonisolated struct NormalizedPreferenceMutation<Value>: Equatable, Sendable
where Value: Equatable & Sendable {
    let normalizedValue: Value
    let shouldPersist: Bool

    init(
        oldValue: Value,
        proposedValue: Value,
        normalize: (Value) -> Value
    ) {
        let normalizedValue = normalize(proposedValue)
        self.normalizedValue = normalizedValue
        self.shouldPersist = normalizedValue != oldValue
    }
}
