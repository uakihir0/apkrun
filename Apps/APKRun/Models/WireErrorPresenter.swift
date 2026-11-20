import DiagnosticsCore
import Foundation
import RuntimeAPI

/// Renders a `RuntimeAPI.WireError` for SwiftUI surfaces by resolving its
/// catalog entry and `{parameter}` templates, mirroring `ErrorPresenter` for
/// errors that arrive over the wire instead of thrown locally.
enum WireErrorPresenter {
    struct Presented: Equatable {
        var message: String
        var hints: [String]
        var remediation: String?
        var code: String
    }

    /// Whether the wire error is a host-requirements failure that blocks
    /// onboarding with **Quit** (host-ui.md §4): `runtime.hostRequirementsNotMet`
    /// with at least one non-warning item. The memory requirement is a warning.
    static func isBlockingHostCheck(_ error: RuntimeAPI.WireError) -> Bool {
        guard error.code == "runtime.hostRequirementsNotMet" else { return false }
        return (error.listItems ?? []).contains { item in
            item.selector != .variant(code: "runtime.hostRequirementsNotMet", key: "memory")
        }
    }

    static func present(_ error: RuntimeAPI.WireError) -> Presented {
        let entry = ErrorCatalog.entry(for: error.code) ?? ErrorCatalog.unknownEntry
        let message = render(
            template: entry.message?["en"] ?? entry.message?.values.first ?? "APKRun hit a problem.",
            parameters: error.parameters
        )
        var hints: [String] = []
        for item in error.listItems ?? [] {
            hints.append(listItemText(item))
        }
        let remediationTemplate: String? = entry.remediation?["en"] ?? entry.remediation?.values.first
        return Presented(
            message: message,
            hints: hints,
            remediation: remediationTemplate.map {
                render(template: $0, parameters: error.parameters)
            },
            code: error.code
        )
    }

    /// A single list item's text: its catalog variant message with the item's
    /// own parameters applied (host-ui.md §4 host-check rows).
    static func listItemText(_ item: WireErrorListItem) -> String {
        let template: String?
        switch item.selector {
        case .variant(let code, let key):
            template = ErrorCatalog.entry(for: code)?.variants[key]?.message?["en"]
        case .errorCode(let code):
            template = ErrorCatalog.entry(for: code)?.message?["en"]
        case .unknown:
            template = nil
        }
        return render(template: template ?? "An item needs attention.", parameters: item.parameters)
    }

    static func render(template: String, parameters: [String: WireErrorParameter]) -> String {
        var result = template
        let pattern = #"\{([A-Za-z][A-Za-z0-9]*)\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return result }
        let matches = expression.matches(
            in: template,
            range: NSRange(location: 0, length: (template as NSString).length)
        )
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                let wholeRange = Range(match.range(at: 0), in: result),
                let nameRange = Range(match.range(at: 1), in: result),
                let value = parameters[String(result[nameRange])]
            else { continue }
            result.replaceSubrange(wholeRange, with: text(value))
        }
        return result
    }

    private static func text(_ parameter: WireErrorParameter) -> String {
        switch parameter {
        case .text(let value):
            return value
        case .bytes(let value):
            return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        case .count(let value):
            return String(value)
        case .durationMs(let value):
            return "\(value) ms"
        case .fileName(let value):
            return value
        case .unknown:
            return "?"
        }
    }
}
