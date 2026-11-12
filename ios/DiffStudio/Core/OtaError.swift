// OtaError.swift
// Port of com.linote.diffstudio.core.OtaException (Java, MIT).
//
// Java has a single unchecked exception type carrying a Python-style
// message string (e.g. "BadZipFile: ...", "KeyError: ..."). Callers
// distinguish failures by the exact message text, so every message is
// preserved verbatim in the port. The Swift equivalent is a single
// Error type carrying that exact string; it is never normalised or
// localised. ErrorExplain renders a friendly message from it separately.
//
// EOFException in Java is a *different* (checked) failure from
// OtaException; it is preserved here as `OtaError.eof` so callers can
// keep the distinction (e.g. ZipIn/TarIn truncated-entry handling).

import Foundation

public struct OtaError: Error, CustomStringConvertible, Equatable {
    public let message: String
    /// True when this is the Java `EOFException` counterpart (truncated
    /// stream / unexpected end of data), as opposed to an OtaException.
    public let isEOF: Bool

    public init(_ message: String, isEOF: Bool = false) {
        self.message = message
        self.isEOF = isEOF
    }

    public static func eof(_ message: String = "") -> OtaError {
        OtaError(message, isEOF: true)
    }

    public var description: String { message }
}
