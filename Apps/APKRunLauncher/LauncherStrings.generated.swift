import Foundation

enum LauncherStrings {
    static let supportedLanguages = ["en", "ja"]

    private static let translations: [String: [String: String]] = [
        "launcher.about.androidVersion": [
            "en": "Android version: %@",
            "ja": "Android バージョン: %@",
        ],
        "launcher.about.androidVersionUnknown": [
            "en": "Android version unavailable",
            "ja": "Android バージョンは不明です",
        ],
        "launcher.about.launcherVersion": [
            "en": "Launcher version %@",
            "ja": "ランチャーバージョン %@",
        ],
        "launcher.about.packageID": [
            "en": "Package ID: %@",
            "ja": "パッケージ ID: %@",
        ],
        "launcher.about.runsWith": [
            "en": "Runs with APKRun %@",
            "ja": "APKRun %@ で動作",
        ],
        "launcher.action.checkForUpdates": [
            "en": "Check for Updates",
            "ja": "アップデートを確認",
        ],
        "launcher.action.getAPKRun": [
            "en": "Get APKRun",
            "ja": "APKRun を入手",
        ],
        "launcher.action.ok": [
            "en": "OK",
            "ja": "OK",
        ],
        "launcher.action.openAPKRun": [
            "en": "Open APKRun",
            "ja": "APKRun を開く",
        ],
        "launcher.action.quit": [
            "en": "Quit",
            "ja": "終了",
        ],
        "launcher.action.tryAgain": [
            "en": "Try Again",
            "ja": "再試行",
        ],
        "launcher.action.updateMacApp": [
            "en": "Update Mac App",
            "ja": "Mac アプリを更新",
        ],
        "launcher.approvalDenied.message": [
            "en": "APKRun did not allow %@ to open.",
            "ja": "APKRun は %@ の起動を許可しませんでした。",
        ],
        "launcher.approvalPending.message": [
            "en": "Waiting for approval in APKRun…",
            "ja": "APKRun での許可を待っています…",
        ],
        "launcher.damaged.message": [
            "en": "%@ is damaged. Create it again in APKRun.",
            "ja": "%@ は破損しています。APKRun で作り直してください。",
        ],
        "launcher.menu.about": [
            "en": "About %@",
            "ja": "%@について",
        ],
        "launcher.menu.actualSize": [
            "en": "Actual Size",
            "ja": "実際のサイズ",
        ],
        "launcher.menu.android": [
            "en": "Android",
            "ja": "Android",
        ],
        "launcher.menu.apkrunHelp": [
            "en": "APKRun Help",
            "ja": "APKRun ヘルプ",
        ],
        "launcher.menu.back": [
            "en": "Back",
            "ja": "戻る",
        ],
        "launcher.menu.bringAllToFront": [
            "en": "Bring All to Front",
            "ja": "すべてを手前に移動",
        ],
        "launcher.menu.closeWindow": [
            "en": "Close Window",
            "ja": "ウインドウを閉じる",
        ],
        "launcher.menu.copy": [
            "en": "Copy",
            "ja": "コピー",
        ],
        "launcher.menu.cut": [
            "en": "Cut",
            "ja": "カット",
        ],
        "launcher.menu.edit": [
            "en": "Edit",
            "ja": "編集",
        ],
        "launcher.menu.file": [
            "en": "File",
            "ja": "ファイル",
        ],
        "launcher.menu.fullScreen": [
            "en": "Enter Full Screen",
            "ja": "フルスクリーンにする",
        ],
        "launcher.menu.help": [
            "en": "Help",
            "ja": "ヘルプ",
        ],
        "launcher.menu.hide": [
            "en": "Hide",
            "ja": "隠す",
        ],
        "launcher.menu.hideOthers": [
            "en": "Hide Others",
            "ja": "ほかを隠す",
        ],
        "launcher.menu.minimize": [
            "en": "Minimize",
            "ja": "しまう",
        ],
        "launcher.menu.paste": [
            "en": "Paste",
            "ja": "ペースト",
        ],
        "launcher.menu.quit": [
            "en": "Quit %@",
            "ja": "%@を終了",
        ],
        "launcher.menu.redo": [
            "en": "Redo",
            "ja": "やり直す",
        ],
        "launcher.menu.reportProblem": [
            "en": "Report a Problem…",
            "ja": "問題を報告…",
        ],
        "launcher.menu.restartApp": [
            "en": "Restart App",
            "ja": "アプリを再起動",
        ],
        "launcher.menu.selectAll": [
            "en": "Select All",
            "ja": "すべてを選択",
        ],
        "launcher.menu.services": [
            "en": "Services",
            "ja": "サービス",
        ],
        "launcher.menu.settings": [
            "en": "Settings…",
            "ja": "設定…",
        ],
        "launcher.menu.showAll": [
            "en": "Show All",
            "ja": "すべてを表示",
        ],
        "launcher.menu.showInAPKRun": [
            "en": "Show in APKRun",
            "ja": "APKRun で表示",
        ],
        "launcher.menu.undo": [
            "en": "Undo",
            "ja": "取り消す",
        ],
        "launcher.menu.view": [
            "en": "View",
            "ja": "表示",
        ],
        "launcher.menu.window": [
            "en": "Window",
            "ja": "ウインドウ",
        ],
        "launcher.menu.zoom": [
            "en": "Zoom",
            "ja": "拡大／縮小",
        ],
        "launcher.menu.zoomIn": [
            "en": "Zoom In",
            "ja": "拡大",
        ],
        "launcher.menu.zoomOut": [
            "en": "Zoom Out",
            "ja": "縮小",
        ],
        "launcher.minimumRuntime.message": [
            "en": "%@ needs APKRun %@ or later.",
            "ja": "%@ を開くには APKRun %@ 以降が必要です。",
        ],
        "launcher.notInstalled.message": [
            "en": "%@ isn't installed in APKRun.",
            "ja": "APKRun に %@ はインストールされていません。",
        ],
        "launcher.required.message": [
            "en": "APKRun is required to open %@.",
            "ja": "%@ を開くには APKRun が必要です。",
        ],
        "launcher.restart.failed.message": [
            "en": "APKRun could not restart %@. Open APKRun and try again.",
            "ja": "%@ を再起動できませんでした。APKRun を開いて、もう一度お試しください。",
        ],
        "launcher.restart.failed.title": [
            "en": "Couldn’t Restart App",
            "ja": "アプリを再起動できませんでした",
        ],
        "launcher.setup.message": [
            "en": "APKRun needs to finish setup.",
            "ja": "APKRun のセットアップを完了してください。",
        ],
        "launcher.starting.detail": [
            "en": "Starting Android…",
            "ja": "Android を起動しています…",
        ],
        "launcher.starting.message": [
            "en": "Starting %@…",
            "ja": "%@ を起動しています…",
        ],
        "launcher.tooOld.message": [
            "en": "This Mac app was made by an older APKRun and needs to be updated.",
            "ja": "この Mac アプリは古い APKRun で作成されました。更新してください。",
        ],
        "launcher.translocated.message": [
            "en": "Move %@ to your Applications folder, then open it again.",
            "ja": "%@ を「アプリケーション」フォルダに移動してから、もう一度開いてください。",
        ],
    ]

    static func text(
        _ key: String,
        locale: Locale = Locale(identifier: Locale.preferredLanguages.first ?? "en"),
        arguments: [CVarArg] = []
    ) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        let template = translations[key]?[language] ?? translations[key]?["en"] ?? key
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: locale, arguments: arguments)
    }

    static func title(for action: LauncherAction) -> String {
        let key: String
        switch action {
        case .getAPKRun:
            key = "launcher.action.getAPKRun"
        case .openAPKRun:
            key = "launcher.action.openAPKRun"
        case .checkForUpdates:
            key = "launcher.action.checkForUpdates"
        case .updateMacApp:
            key = "launcher.action.updateMacApp"
        case .tryAgain:
            key = "launcher.action.tryAgain"
        }
        return text(key)
    }

    static var quit: String { text("launcher.action.quit") }
}
