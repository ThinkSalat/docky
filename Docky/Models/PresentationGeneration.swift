//
//  PresentationGeneration.swift
//  Docky
//
//  A tiny lifecycle epoch for transient windows. AppKit animation
//  completions and delayed callbacks can arrive after a panel has already
//  been reopened. Capturing a token at scheduling time lets callers reject
//  those stale callbacks before they tear down the new presentation.
//

nonisolated struct PresentationGeneration: Equatable {
    nonisolated struct Token: Equatable, Sendable {
        fileprivate let rawValue: UInt64
    }

    private var rawValue: UInt64 = 0

    @discardableResult
    mutating func advance() -> Token {
        rawValue &+= 1
        return Token(rawValue: rawValue)
    }

    func isCurrent(_ token: Token) -> Bool {
        token.rawValue == rawValue
    }
}
