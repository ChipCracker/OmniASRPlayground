import Foundation

protocol TokenizerPostProcessor {
    func process(_ text: String) -> String
}

struct IdentityPostProcessor: TokenizerPostProcessor {
    func process(_ text: String) -> String { text }
}

/// Removes syllable hyphens inserted by the SyllableEncoder.
struct SyllablePostProcessor: TokenizerPostProcessor {
    func process(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: "")
    }
}
