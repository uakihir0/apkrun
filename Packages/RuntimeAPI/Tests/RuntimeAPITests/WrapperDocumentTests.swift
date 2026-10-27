import Foundation
import Testing

@testable import RuntimeAPI

@Test func wrapperDocumentEncodesEveryDocumentedSection() throws {
    let application = try WrapperApplication(
        packageID: #require(RuntimePackageID(rawValue: "com.example.chat")),
        displayName: "Chat"
    )
    let runtime = WrapperRuntime(
        minimumVersion: try #require(WrapperMinimumRuntimeVersion(rawValue: "1.4.0")),
        launcherAPI: try #require(WrapperLauncherAPIVersion(rawValue: "1.3"))
    )
    let document = WrapperDocument(
        kind: .portable,
        application: application,
        runtime: runtime,
        window: try WrapperWindow(
            mode: .standard,
            defaultWidth: 520,
            defaultHeight: 900,
            resizable: true
        ),
        updates: WrapperUpdates(
            authority: .apkrun,
            mode: .notifyOnly,
            provider: .direct(url: "https://updates.example.org/chat/manifest.json")
        ),
        integration: WrapperIntegration(
            clipboard: true,
            notifications: false,
            links: .mac,
            files: true,
            sharedFolders: .readOnly,
            microphone: false
        )
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(document)
    let expectedJSON = """
        {
          "application" : {
            "displayName" : "Chat",
            "packageId" : "com.example.chat"
          },
          "formatVersion" : 1,
          "integration" : {
            "clipboard" : true,
            "files" : true,
            "links" : "mac",
            "microphone" : false,
            "notifications" : false,
            "sharedFolders" : "readOnly"
          },
          "kind" : "portable",
          "runtime" : {
            "launcherAPI" : "1.3",
            "minimumVersion" : "1.4.0"
          },
          "updates" : {
            "authority" : "apkrun",
            "mode" : "notifyOnly",
            "provider" : {
              "configuration" : {
                "url" : "https://updates.example.org/chat/manifest.json"
              },
              "type" : "direct"
            }
          },
          "window" : {
            "defaultHeight" : 900,
            "defaultWidth" : 520,
            "mode" : "standard",
            "resizable" : true
          }
        }
        """
    #expect(data == Data(expectedJSON.utf8))
    #expect(try JSONDecoder().decode(WrapperDocument.self, from: data) == document)
}

@Test func wrapperDocumentOmitsAbsentSectionsAndWritesNullableProvider() throws {
    let document = WrapperDocument(
        kind: .local,
        application: try WrapperApplication(
            packageID: #require(RuntimePackageID(rawValue: "org.example.notes")),
            displayName: "Notes"
        ),
        runtime: WrapperRuntime(
            minimumVersion: try #require(WrapperMinimumRuntimeVersion(rawValue: "0.4.0")),
            launcherAPI: try #require(WrapperLauncherAPIVersion(rawValue: "1.0"))
        ),
        window: try WrapperWindow(
            mode: .standard,
            defaultWidth: 480,
            defaultHeight: 800,
            resizable: true
        ),
        updates: WrapperUpdates(authority: .manual, mode: .automatic),
        integration: WrapperIntegration()
    )

    let data = try JSONEncoder().encode(document)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let updates = try #require(object["updates"] as? [String: Any])
    #expect(object["formatVersion"] as? Int == 1)
    #expect(object["window"] is [String: Any])
    #expect(object["integration"] is [String: Any])
    #expect(updates["authority"] as? String == "manual")
    #expect(updates["mode"] as? String == "automatic")
    #expect(updates.keys.contains("provider"))
    #expect(updates["provider"] is NSNull)
    #expect(try JSONDecoder().decode(WrapperDocument.self, from: data) == document)
}

@Test func wrapperDocumentReaderAcceptsMissingPreferencesButWriterRequiresGeneratedSections() throws {
    let json = """
        {
          "formatVersion": 1,
          "kind": "local",
          "application": { "packageId": "com.example.app", "displayName": "App" },
          "runtime": { "minimumVersion": "1.0.0", "launcherAPI": "1.0" }
        }
        """
    let document = try JSONDecoder().decode(WrapperDocument.self, from: Data(json.utf8))
    #expect(document.window == nil)
    #expect(document.updates == nil)
    #expect(document.integration == nil)
    #expect(throws: WrapperDocumentValidationError.incompleteGeneratedDocument) {
        try JSONEncoder().encode(document)
    }

    let partialWindowJSON = """
        {
          "formatVersion": 1,
          "kind": "local",
          "application": { "packageId": "com.example.app", "displayName": "App" },
          "runtime": { "minimumVersion": "1.0.0", "launcherAPI": "1.0" },
          "window": { "mode": "standard", "defaultWidth": 480 },
          "integration": {}
        }
        """
    let partialWindow = try JSONDecoder().decode(WrapperDocument.self, from: Data(partialWindowJSON.utf8))
    #expect(throws: WrapperDocumentValidationError.incompleteWindowPreferences) {
        try JSONEncoder().encode(partialWindow)
    }
}

@Test func wrapperUpdatesWriterRequiresCompleteSettingsAndApkrunProvider() throws {
    let missingMode = WrapperUpdates(authority: .manual)
    #expect(throws: WrapperDocumentValidationError.incompleteUpdatePreferences) {
        try JSONEncoder().encode(missingMode)
    }

    let missingProvider = WrapperUpdates(authority: .apkrun, mode: .automatic)
    #expect(throws: WrapperDocumentValidationError.missingRequiredUpdateProvider) {
        try JSONEncoder().encode(missingProvider)
    }

    let validManual = WrapperUpdates(authority: .manual, mode: .automatic)
    let data = try JSONEncoder().encode(validManual)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["authority"] as? String == "manual")
    #expect(object["mode"] as? String == "automatic")
    #expect(object["provider"] is NSNull)
}

@Test func wrapperDocumentRejectsUnsupportedFormatVersions() {
    let unsupportedVersion = Data(
        """
        {
          "formatVersion": 2,
          "kind": "local",
          "application": { "packageId": "com.example.app", "displayName": "App" },
          "runtime": { "minimumVersion": "1.0.0", "launcherAPI": "1.0" }
        }
        """.utf8
    )
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(WrapperDocument.self, from: unsupportedVersion)
    }
}

@Test func wrapperDocumentRequiresValidIdentityAndCompatibilityFields() throws {
    let validDocument = """
        {
          "formatVersion": 1,
          "kind": "distribution",
          "application": { "packageId": "com.example.app", "displayName": "App" },
          "runtime": { "minimumVersion": "1.0.0", "launcherAPI": "1.0" }
        }
        """
    let decoded = try JSONDecoder().decode(WrapperDocument.self, from: Data(validDocument.utf8))
    #expect(decoded.kind == .distribution)
    #expect(decoded.application.packageID.rawValue == "com.example.app")
    #expect(decoded.window == nil)
    #expect(decoded.updates == nil)
    #expect(decoded.integration == nil)

    let invalidDocuments = [
        """
        {"formatVersion":1,"kind":"unknown","application":{"packageId":"com.example.app","displayName":"App"},
        "runtime":{"minimumVersion":"1.0.0","launcherAPI":"1.0"}}
        """,
        """
        {"formatVersion":1,"kind":"local","application":{"packageId":"example","displayName":"App"},
        "runtime":{"minimumVersion":"1.0.0","launcherAPI":"1.0"}}
        """,
        """
        {"formatVersion":1,"kind":"local","application":{"packageId":"com.example.app","displayName":""},
        "runtime":{"minimumVersion":"1.0.0","launcherAPI":"1.0"}}
        """,
        """
        {"formatVersion":1,"kind":"local","application":{"packageId":"com.example.app","displayName":"App"},
        "runtime":{"minimumVersion":"01.0.0","launcherAPI":"1.0"}}
        """,
        """
        {"formatVersion":1,"kind":"local","application":{"packageId":"com.example.app","displayName":"App"},
        "runtime":{"minimumVersion":"1.0.0","launcherAPI":"1.00"}}
        """,
        """
        {"formatVersion":1,"kind":"local","application":{"packageId":"com.example.app","displayName":"App"},
        "runtime":{"minimumVersion":"1.0.0","launcherAPI":"1.0"},"window":null}
        """,
        """
        {"formatVersion":1,"kind":"local","application":{"packageId":"com.example.app","displayName":"App"},
        "runtime":{"minimumVersion":"1.0.0","launcherAPI":"1.0"},"updates":[]}
        """,
    ]
    for json in invalidDocuments {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WrapperDocument.self, from: Data(json.utf8))
        }
    }
    #expect(WrapperMinimumRuntimeVersion(rawValue: "1.0") == nil)
    #expect(WrapperLauncherAPIVersion(rawValue: "1") == nil)
    #expect(WrapperLauncherAPIVersion(rawValue: String(repeating: "1", count: 17) + ".0") == nil)
    #expect(throws: WrapperDocumentValidationError.invalidDisplayName) {
        try WrapperApplication(
            packageID: #require(RuntimePackageID(rawValue: "com.example.app")),
            displayName: ""
        )
    }
}

@Test func wrapperPreferencesIgnoreUnknownFieldsAndDropInvalidFieldsIndividually() throws {
    let json = """
        {
          "formatVersion": 1,
          "kind": "local",
          "application": { "packageId": "com.example.app", "displayName": "App", "future": true },
          "runtime": { "minimumVersion": "1.0.0", "launcherAPI": "1.0", "future": true },
          "futureTopLevelKey": "ignored",
          "window": {
            "mode": "futureMode",
            "defaultWidth": 319,
            "defaultHeight": 800,
            "resizable": "yes",
            "future": true
          },
          "updates": {
            "authority": "futureAuthority",
            "mode": "automatic",
            "provider": { "type": "local", "configuration": { "path": "/tmp/repo", "bookmark": "AA==" } },
            "future": true
          },
          "integration": {
            "clipboard": "yes",
            "notifications": false,
            "links": "android",
            "files": 1,
            "sharedFolders": "future",
            "microphone": true,
            "future": true
          }
        }
        """
    let document = try JSONDecoder().decode(WrapperDocument.self, from: Data(json.utf8))

    #expect(document.window?.mode == nil)
    #expect(document.window?.defaultWidth == nil)
    #expect(document.window?.defaultHeight == 800)
    #expect(document.window?.resizable == nil)
    #expect(document.updates?.authority == nil)
    #expect(document.updates?.mode == .automatic)
    #expect(document.updates?.provider == nil)
    #expect(document.integration?.clipboard == nil)
    #expect(document.integration?.notifications == false)
    #expect(document.integration?.links == .android)
    #expect(document.integration?.files == nil)
    #expect(document.integration?.sharedFolders == nil)
    #expect(document.integration?.microphone == true)
}

@Test func wrapperUpdateProviderVariantsUseTheDocumentedFlatConfiguration() throws {
    let providers: [WrapperUpdateProviderRef] = [
        .direct(url: "https://updates.example.org/app/manifest.json"),
        .fdroid(repository: "https://repo.example.org/fdroid", fingerprint: String(repeating: "a", count: 64)),
        .github(repository: "example/app", assetPattern: "*.apk", channel: .prerelease),
    ]
    for provider in providers {
        let data = try JSONEncoder().encode(provider)
        #expect(try JSONDecoder().decode(WrapperUpdateProviderRef.self, from: data) == provider)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] is String)
        #expect(object["configuration"] is [String: Any])
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            WrapperUpdateProviderRef.self,
            from: Data(#"{"type":"local","configuration":{"path":"/tmp/repo","bookmark":"AA=="}}"#.utf8)
        )
    }
}

@Test func wrapperUpdateProviderDecodersEnforcePackageMetadataConstraints() throws {
    let invalidProviders = [
        #"{"type":"direct","configuration":{"url":"http://example.org/manifest.json"}}"#,
        #"{"type":"direct","configuration":{"url":"https://user:secret@example.org/manifest.json"}}"#,
        #"{"type":"fdroid","configuration":{"repository":"https://repo.example.org/repo/","fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#,
        #"{"type":"fdroid","configuration":{"repository":"https://repo.example.org/repo?token=x","fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#,
        #"{"type":"fdroid","configuration":{"repository":"https://repo.example.org/repo#fragment","fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#,
        #"{"type":"fdroid","configuration":{"repository":"https://repo.example.org/repo","fingerprint":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#,
        #"{"type":"github","configuration":{"repository":"-owner/app","assetPattern":"*.apk","channel":"stable"}}"#,
        #"{"type":"github","configuration":{"repository":"owner/..","assetPattern":"*.apk","channel":"stable"}}"#,
        #"{"type":"github","configuration":{"repository":"owner/app/extra","assetPattern":"*.apk","channel":"stable"}}"#,
        #"{"type":"github","configuration":{"repository":"owner/app","assetPattern":"dir/*.apk","channel":"stable"}}"#,
    ]

    for json in invalidProviders {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WrapperUpdateProviderRef.self, from: Data(json.utf8))
        }
    }

    let longURL = "https://example.org/" + String(repeating: "x", count: 2048)
    let longURLJSON = """
        {"type":"direct","configuration":{"url":"\(longURL)"}}
        """
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(WrapperUpdateProviderRef.self, from: Data(longURLJSON.utf8))
    }

    let longPattern = String(repeating: "a", count: 256)
    let longPatternJSON = """
        {"type":"github","configuration":{"repository":"owner/app","assetPattern":"\(longPattern)","channel":"stable"}}
        """
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(WrapperUpdateProviderRef.self, from: Data(longPatternJSON.utf8))
    }

    let malformedProviderJSON = """
        {
          "formatVersion": 1,
          "kind": "local",
          "application": { "packageId": "com.example.app", "displayName": "App" },
          "runtime": { "minimumVersion": "1.0.0", "launcherAPI": "1.0" },
          "updates": {
            "authority": "manual",
            "mode": "automatic",
            "provider": {
              "type": "fdroid",
              "configuration": {
                "repository": "https://repo.example.org/repo/",
                "fingerprint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              }
            }
          }
        }
        """
    let document = try JSONDecoder().decode(WrapperDocument.self, from: Data(malformedProviderJSON.utf8))
    #expect(document.updates?.authority == .manual)
    #expect(document.updates?.mode == .automatic)
    #expect(document.updates?.provider == nil)
}

@Test func wrapperUpdateProviderEncoderRejectsInvalidValues() {
    let invalidProviders: [WrapperUpdateProviderRef] = [
        .direct(url: "https://user@example.org/manifest.json"),
        .fdroid(repository: "https://repo.example.org/repo/", fingerprint: String(repeating: "a", count: 64)),
        .fdroid(repository: "https://repo.example.org/repo", fingerprint: String(repeating: "A", count: 64)),
        .github(repository: "owner/app", assetPattern: "dir/*.apk", channel: .stable),
    ]
    for provider in invalidProviders {
        #expect(throws: WrapperDocumentValidationError.invalidUpdateProvider) {
            try JSONEncoder().encode(provider)
        }
    }
}
