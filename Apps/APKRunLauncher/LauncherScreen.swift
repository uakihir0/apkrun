import Foundation

enum LauncherAction: Equatable, Sendable {
    case getAPKRun
    case openAPKRun
    case checkForUpdates
    case updateMacApp
    case tryAgain
}

enum LauncherScreen: Equatable, Sendable {
    case starting(appName: String)
    case required(appName: String)
    case setup(appName: String)
    case minimumRuntime(appName: String, version: String)
    case launcherTooOld(appName: String)
    case approvalPending(appName: String)
    case approvalDenied(appName: String)
    case notInstalled(appName: String)
    case damaged(appName: String)
    case translocated(appName: String)
    case runtimeError(appName: String, message: String, remediation: String)

    var appName: String {
        switch self {
        case .starting(let appName),
            .required(let appName),
            .setup(let appName),
            .minimumRuntime(let appName, _),
            .launcherTooOld(let appName),
            .approvalPending(let appName),
            .approvalDenied(let appName),
            .notInstalled(let appName),
            .damaged(let appName),
            .translocated(let appName),
            .runtimeError(let appName, _, _):
            appName
        }
    }

    var presentation: LauncherScreenPresentation {
        switch self {
        case .starting(let appName):
            LauncherScreenPresentation(
                message: LauncherStrings.text("launcher.starting.message", arguments: [appName]),
                primaryAction: nil,
                detail: LauncherStrings.text("launcher.starting.detail")
            )
        case .required(let appName):
            LauncherScreenPresentation(
                message: LauncherStrings.text("launcher.required.message", arguments: [appName]),
                primaryAction: .getAPKRun
            )
        case .setup:
            LauncherScreenPresentation(
                message: LauncherStrings.text("launcher.setup.message"),
                primaryAction: .openAPKRun
            )
        case .minimumRuntime(let appName, let version):
            LauncherScreenPresentation(
                message: LauncherStrings.text(
                    "launcher.minimumRuntime.message",
                    arguments: [appName, version]
                ),
                primaryAction: .checkForUpdates
            )
        case .launcherTooOld(let appName):
            LauncherScreenPresentation(
                message: LauncherStrings.text("launcher.tooOld.message", arguments: [appName]),
                primaryAction: .updateMacApp
            )
        case .approvalPending(let appName):
            LauncherScreenPresentation(
                message: LauncherStrings.text("launcher.approvalPending.message", arguments: [appName]),
                primaryAction: .openAPKRun
            )
        case .approvalDenied(let appName):
            LauncherScreenPresentation(
                message: LauncherStrings.text("launcher.approvalDenied.message", arguments: [appName]),
                primaryAction: .openAPKRun
            )
        case .notInstalled(let appName):
            LauncherScreenPresentation(
                message: LauncherStrings.text("launcher.notInstalled.message", arguments: [appName]),
                primaryAction: .openAPKRun
            )
        case .damaged(let appName):
            LauncherScreenPresentation(
                message: LauncherStrings.text("launcher.damaged.message", arguments: [appName]),
                primaryAction: .openAPKRun
            )
        case .translocated(let appName):
            LauncherScreenPresentation(
                message: LauncherStrings.text("launcher.translocated.message", arguments: [appName]),
                primaryAction: nil
            )
        case .runtimeError(_, let message, let remediation):
            LauncherScreenPresentation(
                message: message,
                primaryAction: .tryAgain,
                secondaryAction: .openAPKRun,
                detail: remediation
            )
        }
    }
}

struct LauncherScreenPresentation: Equatable, Sendable {
    let message: String
    let primaryAction: LauncherAction?
    let secondaryAction: LauncherAction?
    let detail: String?

    init(
        message: String,
        primaryAction: LauncherAction?,
        secondaryAction: LauncherAction? = nil,
        detail: String? = nil
    ) {
        self.message = message
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.detail = detail
    }
}
