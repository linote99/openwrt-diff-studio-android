// Strings.swift
// Runtime language switching over Localizable.strings.
//
// The app ships `en.lproj/Localizable.strings` and
// `zh-Hans.lproj/Localizable.strings`; keys are the English strings
// (mirroring Java's n(zh, en)). AppState.tr() resolves the key in the
// bundle for the currently selected language, falling back to the key
// itself (English) when a translation is missing.

import Foundation

public enum Strings {
    public static func bundle(forEnglish english: Bool) -> Bundle {
        let lang = english ? "en" : "zh-Hans"
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }

    public static func localized(_ key: String, english: Bool) -> String {
        NSLocalizedString(key, tableName: nil, bundle: bundle(forEnglish: english), value: key, comment: "")
    }
}
