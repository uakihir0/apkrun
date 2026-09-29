import DiagnosticsCore

enum ExitCodes {
    static let success = 0
    static let failure = 1
    static let partial = 2
    static let warnings = 3
    static let notFound = 4
    static let refused = 5
    static let usage = 64
    static let unavailable = 69
    static let internalError = 70
    static let tryAgain = 75
    static let interrupted = 130

    static func code(for error: any Error) -> Int {
        guard let error = error as? any APKRunError else {
            return internalError
        }
        return ErrorCatalog.cliExit(for: error)
    }

    static func code(for qualifiedCode: String) -> Int {
        ErrorCatalog.cliExit(for: qualifiedCode) ?? failure
    }
}
