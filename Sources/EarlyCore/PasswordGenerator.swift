// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A field's `passwordrules` (Apple's Password Rules syntax), such as
/// `minlength: 12; required: upper; required: digit; allowed: [-_]`.
public struct PasswordRules: Equatable, Sendable {
    public var minLength: Int?
    public var maxLength: Int?
    public var maxConsecutive: Int?
    /// Each set must appear at least once.
    public var required: [Set<Character>] = []
    /// Characters allowed besides the required ones; empty allows the default set.
    public var allowed: Set<Character> = []

    public init() {}

    public static func parse(_ text: String?) -> PasswordRules {
        var rules = PasswordRules()
        guard let text else { return rules }
        for property in text.split(separator: ";") {
            let parts = property.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "minlength": rules.minLength = Int(parts[1]).map { max(0, $0) }
            case "maxlength": rules.maxLength = Int(parts[1]).flatMap { $0 > 0 ? $0 : nil }
            case "max-consecutive": rules.maxConsecutive = Int(parts[1]).flatMap { $0 > 0 ? $0 : nil }
            case "required":
                let set = classes(parts[1])
                if !set.isEmpty { rules.required.append(set) }
            case "allowed": rules.allowed.formUnion(classes(parts[1]))
            default: continue
            }
        }
        return rules
    }

    /// `upper, digit, [-_]`: named classes and bracketed characters.
    static func classes(_ value: String) -> Set<Character> {
        var set = Set<Character>()
        var rest = Substring(value)
        while let first = rest.first {
            if first == "[" {
                // A "]" right after "[" is one of the characters.
                let body = rest.dropFirst()
                let close = body.dropFirst().firstIndex(of: "]") ?? body.endIndex
                set.formUnion(body[body.startIndex..<close])
                rest = close < body.endIndex ? body[body.index(after: close)...] : ""
                continue
            }
            let end = rest.firstIndex(of: ",") ?? rest.endIndex
            switch rest[rest.startIndex..<end].trimmingCharacters(in: .whitespaces).lowercased() {
            case "upper": set.formUnion(PasswordGenerator.upper)
            case "lower": set.formUnion(PasswordGenerator.lower)
            case "digit": set.formUnion(PasswordGenerator.digits)
            case "special": set.formUnion(PasswordGenerator.special)
            case "ascii-printable", "unicode": set.formUnion(PasswordGenerator.asciiPrintable)
            default: break
            }
            rest = end < rest.endIndex ? rest[rest.index(after: end)...] : ""
        }
        return set
    }
}

/// Strong passwords like Safari's (`abcdef-ghij2k-mnoPqr`) where a site's
/// rules allow them, otherwise random ones that follow the rules. Uses the
/// system's cryptographically secure generator.
public enum PasswordGenerator {
    static let upper = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lower = Set("abcdefghijklmnopqrstuvwxyz")
    static let digits = Set("0123456789")
    static let special = Set("-~!@#$%^&*_+=`|(){}[:;\"'<>,.?] ")
    static let asciiPrintable = upper.union(lower).union(digits).union(special)
    /// Characters that are easy to tell apart, for the readable format.
    static let readableLower = Array("abcdefghijkmnopqrstuvwxyz")
    static let readableUpper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let readableDigits = Array("23456789")
    static let fallback = upper.union(lower).union(digits).union("-_!@#$%^&*")
    public static let defaultLength = 20
    /// More than any website needs: a site's rules can't make Early build a
    /// longer one.
    public static let maximumLength = 128
    /// Anything shorter isn't a strong password, so none is offered.
    public static let minimumLength = 8
    static let attempts = 50

    /// A strong password for a field without rules.
    public static func strongPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        return readablePassword(using: &generator)
    }

    /// One that follows a website's rules and the field's length, or nil when
    /// no strong password can: too short, contradictory or impossible rules,
    /// or more than ``maximumLength`` characters.
    public static func strongPassword(rules: PasswordRules, maxLength: Int?) -> String? {
        var generator = SystemRandomNumberGenerator()
        return strongPassword(rules: rules, maxLength: maxLength, using: &generator)
    }

    public static func strongPassword<R: RandomNumberGenerator>(rules: PasswordRules, maxLength: Int?,
                                                               using generator: inout R) -> String? {
        guard let lengths = lengths(rules: rules, maxLength: maxLength) else { return nil }
        let readable = readablePassword(using: &generator)
        if satisfies(readable, rules: rules, maxLength: maxLength) { return readable }
        for _ in 0..<attempts {
            let candidate = randomPassword(rules: rules, lengths: lengths, using: &generator)
            if satisfies(candidate, rules: rules, maxLength: maxLength) { return candidate }
        }
        return nil
    }

    /// The lengths a password may have: the site's and the field's limits
    /// within Early's own. Nil when none is left.
    static func lengths(rules: PasswordRules, maxLength: Int?) -> ClosedRange<Int>? {
        let upper = min(maximumLength, rules.maxLength ?? .max, maxLength.flatMap { $0 > 0 ? $0 : nil } ?? .max)
        let lower = max(minimumLength, rules.minLength ?? 0, rules.required.count)
        return lower <= upper ? lower...upper : nil
    }

    /// Three groups of six: lowercase, one uppercase and at least one digit.
    static func readablePassword<R: RandomNumberGenerator>(using generator: inout R) -> String {
        var characters = (0..<18).map { _ in
            Int.random(in: 0..<4, using: &generator) == 0 ? readableDigits.randomElement(using: &generator)!
                : readableLower.randomElement(using: &generator)!
        }
        let positions = Array(0..<18).shuffled(using: &generator)
        characters[positions[0]] = readableUpper.randomElement(using: &generator)!
        characters[positions[1]] = readableDigits.randomElement(using: &generator)!
        characters[positions[2]] = readableLower.randomElement(using: &generator)!
        return [characters[0..<6], characters[6..<12], characters[12..<18]].map { String($0) }.joined(separator: "-")
    }

    static func randomPassword<R: RandomNumberGenerator>(rules: PasswordRules, lengths: ClosedRange<Int>,
                                                         using generator: inout R) -> String {
        let explicit = rules.allowed.union(rules.required.reduce(into: Set<Character>()) { $0.formUnion($1) })
        let alphabet = Array(explicit.isEmpty ? fallback : explicit)
        let length = min(max(defaultLength, lengths.lowerBound), lengths.upperBound)
        var characters = rules.required.map { Array($0).randomElement(using: &generator)! }
        while characters.count < length { characters.append(alphabet.randomElement(using: &generator)!) }
        return String(characters.shuffled(using: &generator))
    }

    static func satisfies(_ password: String, rules: PasswordRules, maxLength: Int?) -> Bool {
        let count = password.count
        if let limit = maxLength, limit > 0, count > limit { return false }
        if let limit = rules.maxLength, count > limit { return false }
        if let minimum = rules.minLength, count < minimum { return false }
        let characters = Set(password)
        for required in rules.required where characters.isDisjoint(with: required) { return false }
        let explicit = rules.allowed.union(rules.required.reduce(into: Set<Character>()) { $0.formUnion($1) })
        if !explicit.isEmpty, !characters.isSubset(of: explicit) { return false }
        if let limit = rules.maxConsecutive {
            var run = 0
            var previous: Character?
            for character in password {
                run = character == previous ? run + 1 : 1
                previous = character
                if run > limit { return false }
            }
        }
        return true
    }
}
