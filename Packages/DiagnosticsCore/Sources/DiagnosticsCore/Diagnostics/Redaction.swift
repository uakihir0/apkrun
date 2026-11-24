import Foundation

/// The identities and secrets a report must not contain (diagnostics.md §6.3–§6.4).
/// The service fills this once per report from the host environment and the
/// Keychain; the values are used to remove text and are never written out.
public struct RedactionIdentity: Sendable {
    /// The user's home directory, without a trailing slash.
    public var homeDirectory: String
    /// `NSUserName()` — becomes `<user>`.
    public var userName: String
    /// `NSFullUserName()` — becomes `<user-name>`.
    public var fullUserName: String
    /// `SCDynamicStoreCopyComputerName` — becomes `<computer>`.
    public var computerName: String
    /// `SCDynamicStoreCopyLocalHostName` — becomes `<computer>`.
    public var localHostName: String
    /// Home-directory paths that are kept verbatim (with the home part still
    /// reduced to `~`): the APKRun support and log directories and the app.
    public var preservedPaths: [String]
    /// Hosts whose URLs keep their path (APKRun's own endpoints).
    public var preservedURLHosts: [String]
    /// Exact secret values to hunt for (update provider tokens). Matched in
    /// raw, URL-encoded, base64, and UTF-16 forms.
    public var knownSecrets: [String]

    /// Creates an identity; every field may be empty on machines that cannot
    /// provide it.
    public init(
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName(),
        fullUserName: String = NSFullUserName(),
        computerName: String = "",
        localHostName: String = "",
        preservedPaths: [String] = [],
        preservedURLHosts: [String] = [],
        knownSecrets: [String] = []
    ) {
        self.homeDirectory = homeDirectory
        self.userName = userName
        self.fullUserName = fullUserName
        self.computerName = computerName
        self.localHostName = localHostName
        self.preservedPaths = preservedPaths
        self.preservedURLHosts = preservedURLHosts
        self.knownSecrets = knownSecrets
    }
}

/// Counts of the rules that fired while one report was redacted; the keys go
/// into `manifest.json` (`diagnostics.md` §8.2).
public typealias RedactionCounts = [String: Int]

/// The layer 3 and 4 rules of diagnostics.md §6 applied to every text file
/// that enters a diagnostics bundle. One instance serves one report so
/// placeholders stay stable and the counts accumulate.
public final class Redactor: @unchecked Sendable {
    /// `RedactionRules.version`; any rule change increases it.
    public static let rulesVersion = 1

    private let identity: RedactionIdentity
    private let lock = NSLock()
    private var counts: RedactionCounts = [:]
    private var placeholders: [String: String] = [:]
    private var nextPlaceholder: [String: Int] = [:]

    /// The layer-4 patterns and their manifest rule names.
    private static let secretPatterns: [(rule: String, pattern: String, dotAll: Bool)] = [
        (
            "pem",
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----[^\s]*"#,
            true
        ),
        ("jwt", #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, false),
        (
            "token",
            #"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}|ya29\.[0-9A-Za-z_-]+|AIza[0-9A-Za-z_-]{35}|AKIA[0-9A-Z]{16}|xox[abprs]-[0-9A-Za-z-]{10,}"#,
            false
        ),
        (
            "secret",
            #"(?i)\b(?:authorization|bearer|token|access_token|refresh_token|id_token|api[_-]?key|secret|client_secret|password|passwd|pwd|cookie|set-cookie|session)\b\s*[:=]\s*[^\s,;"']+"#,
            false
        ),
        // A base64 run of 64+ characters that is not a plain hex digest.
        ("base64", #"(?=[A-Za-z0-9+/=]*[^0-9a-fA-F])[A-Za-z0-9+/]{64,}={0,2}"#, false),
    ]

    /// Creates a redactor for one report.
    public init(identity: RedactionIdentity) {
        self.identity = identity
    }

    /// The accumulated redaction counts for `manifest.json`.
    public var redactionCounts: RedactionCounts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// A placeholder stable within this report (`<serial-1>`, `<uuid-1>`, …)
    /// for bootconfig and instance values (diagnostics.md §6.2).
    public func placeholder(for value: String, kind: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = placeholders[value] {
            return existing
        }
        let index = (nextPlaceholder[kind] ?? 0) + 1
        nextPlaceholder[kind] = index
        let name = "<\(kind)-\(index)>"
        placeholders[value] = name
        return name
    }

    /// Applies the layer 3 and 4 rules to one text file's contents.
    public func redact(_ input: String) -> String {
        var text = input
        lock.lock()
        defer { lock.unlock() }

        // Layer 3, ordered so names are gone before patterns see the text.
        text = reduceHomePaths(text)
        for (name, replacement) in [
            (identity.fullUserName, "<user-name>"),
            (identity.userName, "<user>"),
            (identity.computerName, "<computer>"),
            (identity.localHostName, "<computer>"),
        ] where !name.isEmpty {
            let occurrences = text.components(separatedBy: name).count - 1
            if occurrences > 0 {
                text = text.replacingOccurrences(of: name, with: replacement)
                bump("user", by: occurrences)
            }
        }
        text = reduceURLs(text)
        text = replace(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: text, rule: "email", with: "<email>")
        text = replace(
            #"(?i)\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b"#, in: text, rule: "mac", with: "<mac>")
        text = reduceIPs(text)
        text = reduceContentURIs(text)

        // Layer 4: patterns first, known secrets last so their exact bytes are
        // still findable when earlier rules leave them intact.
        for (rule, pattern, dotAll) in Self.secretPatterns {
            let options: NSRegularExpression.Options = dotAll ? [.dotMatchesLineSeparators] : []
            text = replace(pattern, in: text, rule: rule, with: "<redacted:\(rule)>", options: options)
        }
        for secret in identity.knownSecrets where !secret.isEmpty {
            for form in secretForms(secret) {
                let occurrences = text.components(separatedBy: form).count - 1
                if occurrences > 0 {
                    text = text.replacingOccurrences(of: form, with: "<redacted:knownSecret>")
                    bump("knownSecret", by: occurrences)
                }
            }
        }
        return text
    }

    /// The layer 4 re-scan of diagnostics.md §6.5: true when the (redacted)
    /// bytes still contain a known secret in any form, meaning the file must
    /// be dropped with `redactionFailed`.
    public func containsKnownSecret(in data: Data) -> Bool {
        for secret in identity.knownSecrets where !secret.isEmpty {
            for form in secretForms(secret) {
                guard let needle = form.data(using: .utf8), !needle.isEmpty else { continue }
                if data.range(of: needle) != nil {
                    return true
                }
            }
            for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
                guard let needle = secret.data(using: encoding), !needle.isEmpty else { continue }
                if data.range(of: needle) != nil {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Private

    private func bump(_ rule: String, by amount: Int = 1) {
        counts[rule, default: 0] += amount
    }

    /// The raw, URL-encoded, and base64 forms of a known secret (UTF-16 is a
    /// byte-level form and is checked by `containsKnownSecret(in:)`).
    private func secretForms(_ secret: String) -> [String] {
        var forms = [secret]
        if let encoded = secret.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ), encoded != secret {
            forms.append(encoded)
        }
        if let data = secret.data(using: .utf8) {
            let b64 = data.base64EncodedString()
            if b64 != secret {
                forms.append(b64)
            }
        }
        return forms
    }

    /// Replaces every regex match and counts it under [rule].
    private func replace(
        _ pattern: String,
        in text: String,
        rule: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        bump(rule, by: matches.count)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: replacement)
    }

    /// Home-directory paths become `~/…/<last component>` unless the path is
    /// on the preserved list, in which case only the home part becomes `~`
    /// (diagnostics.md §6.3).
    private func reduceHomePaths(_ text: String) -> String {
        let home = identity.homeDirectory
        guard !home.isEmpty else { return text }
        var result = text
        // Preserved roots keep their suffix and run first: their paths may
        // contain spaces ("Application Support"), which the general rule
        // below cannot match. The boundary after the root keeps a sibling
        // like "/…/APKRun2" out.
        for preserved in identity.preservedPaths where preserved.hasPrefix(home) {
            guard
                let regex = try? NSRegularExpression(
                    pattern: NSRegularExpression.escapedPattern(for: preserved)
                        + #"(?=[/\s"'\\]|$)"#
                )
            else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, range: range)
            guard !matches.isEmpty else { continue }
            var rebuilt = ""
            var cursor = result.startIndex
            for match in matches {
                guard let matchRange = Range(match.range, in: result) else { continue }
                rebuilt += result[cursor..<matchRange.lowerBound]
                rebuilt += "~" + result[matchRange].dropFirst(home.count)
                bump("path")
                cursor = matchRange.upperBound
            }
            rebuilt += result[cursor...]
            result = rebuilt
        }
        let escaped = NSRegularExpression.escapedPattern(for: home)
        guard
            let regex = try? NSRegularExpression(
                pattern: escaped + #"[^\s"'\\]*"#
            )
        else { return result }
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, range: range)
        guard !matches.isEmpty else { return result }
        var collapsed = ""
        var cursor = result.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let path = String(result[matchRange])
            collapsed += result[cursor..<matchRange.lowerBound]
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/.,;:)]}"))
            let last = trimmed.split(separator: "/").last.map(String.init) ?? "…"
            collapsed += "~/…/" + last
            bump("path")
            cursor = matchRange.upperBound
        }
        collapsed += result[cursor...]
        return collapsed
    }

    /// URLs lose path, query, fragment, and user info; APKRun's own endpoint
    /// hosts keep theirs (diagnostics.md §6.3).
    private func reduceURLs(_ text: String) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"\b([a-zA-Z][a-zA-Z0-9+.-]*)://([^\s/)"'<>\]]+)([^\s)"'<>\]]*)"#
            )
        else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard
                let whole = Range(match.range, in: text),
                let schemeRange = Range(match.range(at: 1), in: text),
                let hostRange = Range(match.range(at: 2), in: text)
            else { continue }
            let scheme = text[schemeRange]
            let host = text[hostRange]
            result += text[cursor..<whole.lowerBound]
            // Skip non-http schemes with opaque bodies (e.g. content://) —
            // they have their own rule.
            if scheme == "content" || scheme == "file" || scheme == "mailto" {
                result += text[whole]
            } else if identity.preservedURLHosts.contains(where: { host.hasPrefix($0) }) {
                result += text[whole]
            } else {
                result += "\(scheme)://\(host)/…"
                bump("url")
            }
            cursor = whole.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// IPv4 and IPv6 literals except loopback, link-local, and the VM's NAT
    /// subnet become `<ip>` (diagnostics.md §6.3).
    private func reduceIPs(_ text: String) -> String {
        var result = text
        result = replaceIPMatches(
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, in: result,
            isAllowed: { ip in
                ip.hasPrefix("127.") || ip.hasPrefix("169.254.")
                    || ip.hasPrefix("192.168.64.")
            })
        result = replaceIPMatches(
            #"(?i)\b(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}\b"#, in: result,
            isAllowed: { ip in
                let lower = ip.lowercased()
                return lower == "::1" || lower.hasPrefix("fe80:") || lower.hasPrefix(":")
            })
        return result
    }

    private func replaceIPMatches(
        _ pattern: String,
        in text: String,
        isAllowed: (String) -> Bool
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let ip = String(text[matchRange])
            result += text[cursor..<matchRange.lowerBound]
            if isAllowed(ip) {
                result += ip
            } else {
                result += "<ip>"
                bump("ip")
            }
            cursor = matchRange.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// `content://` URIs keep their authority and lose their path
    /// (diagnostics.md §6.3).
    private func reduceContentURIs(_ text: String) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"content://([a-zA-Z0-9._-]+)[^\s)"'<>\]]*"#
            )
        else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard
                let whole = Range(match.range, in: text),
                let authorityRange = Range(match.range(at: 1), in: text)
            else { continue }
            result += text[cursor..<whole.lowerBound]
            result += "content://\(text[authorityRange])/…"
            bump("contentURI")
            cursor = whole.upperBound
        }
        result += text[cursor...]
        return result
    }
}
