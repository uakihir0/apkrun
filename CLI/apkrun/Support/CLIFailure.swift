import DiagnosticsCore
import Foundation

enum CLIFailure: APKRunError {
    case confirmationRequired(flag: String)
    case declined
    case invalidPackageName(package: String)
    case invalidSourceSpec(argument: String)
    case invalidArgument(argument: String, reason: String)
    case fileNotAccessible(file: String, FileProblem)
    case developerModeRequired(command: String)
    case logsUnavailable
    case malformedReply(operation: String)
    case versionSkew(version: String, found: String)
    case invalidArguments

    static var domain: ErrorDomain { .cli }

    var code: String {
        switch self {
        case .confirmationRequired:
            "confirmationRequired"
        case .declined:
            "declined"
        case .invalidPackageName:
            "invalidPackageName"
        case .invalidSourceSpec:
            "invalidSourceSpec"
        case .invalidArgument:
            "invalidArgument"
        case .fileNotAccessible:
            "fileNotAccessible"
        case .developerModeRequired:
            "developerModeRequired"
        case .logsUnavailable:
            "logsUnavailable"
        case .malformedReply:
            "malformedReply"
        case .versionSkew:
            "versionSkew"
        case .invalidArguments:
            "invalidArguments"
        }
    }

    var parameters: [String: ErrorParameter] {
        switch self {
        case .confirmationRequired(let flag):
            ["flag": .text(flag)]
        case .declined, .logsUnavailable, .invalidArguments:
            [:]
        case .invalidPackageName(let package):
            ["package": .text(package)]
        case .invalidSourceSpec(let argument):
            ["argument": .text(argument)]
        case .invalidArgument(let argument, let reason):
            ["argument": .text(argument), "reason": .text(reason)]
        case .fileNotAccessible(let file, let problem):
            [
                "file": .fileName(URL(fileURLWithPath: file).lastPathComponent),
                "reason": .text(problem.rawValue),
            ]
        case .developerModeRequired(let command):
            ["command": .text(command)]
        case .malformedReply(let operation):
            ["operation": .text(operation)]
        case .versionSkew(let version, let found):
            ["version": .text(version), "found": .text(found)]
        }
    }
}

enum FileProblem: String, CaseIterable, Codable, Sendable {
    case notFound
    case permissionDenied
    case isDirectory
}
