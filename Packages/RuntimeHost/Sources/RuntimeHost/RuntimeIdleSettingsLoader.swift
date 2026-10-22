import CoreFoundation
import Foundation
import RuntimeCore

enum RuntimeIdleSettingsLoader {
    enum Failure: Error, Equatable {
        case malformed
        case unsupportedSchema(Int)
        case invalidSetting(String)
    }

    static func load(from fileURL: URL) throws -> RuntimeIdleSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .default
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw Failure.malformed
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data),
            let settings = root as? [String: Any]
        else {
            throw Failure.malformed
        }

        guard let rawSchemaVersion = settings["schemaVersion"] as? NSNumber,
            CFGetTypeID(rawSchemaVersion) != CFBooleanGetTypeID(),
            CFNumberIsFloatType(rawSchemaVersion) == false,
            let schemaVersion = Int(exactly: rawSchemaVersion.int64Value)
        else {
            throw Failure.malformed
        }
        if schemaVersion > 1 {
            throw Failure.unsupportedSchema(schemaVersion)
        }
        guard schemaVersion == 1 else { throw Failure.malformed }
        let runtime: [String: Any]
        if let rawRuntime = settings["runtime"] {
            guard let values = rawRuntime as? [String: Any] else {
                throw Failure.invalidSetting("runtime")
            }
            runtime = values
        } else {
            runtime = [:]
        }
        let suspendMinutes = try integerSetting(
            runtime["idleSuspendMinutes"],
            name: "runtime.idleSuspendMinutes",
            defaultValue: RuntimeIdleSettings.default.idleSuspendMinutes
        )
        let stopMinutes = try integerSetting(
            runtime["idleStopMinutes"],
            name: "runtime.idleStopMinutes",
            defaultValue: RuntimeIdleSettings.default.idleStopMinutes
        )
        let startPolicy: RuntimeIdleSettings.StartPolicy
        if let rawValue = runtime["startPolicy"] as? String {
            guard let value = RuntimeIdleSettings.StartPolicy(rawValue: rawValue) else {
                throw Failure.invalidSetting("runtime.startPolicy")
            }
            startPolicy = value
        } else if runtime["startPolicy"] == nil {
            startPolicy = RuntimeIdleSettings.default.startPolicy
        } else {
            throw Failure.invalidSetting("runtime.startPolicy")
        }

        do {
            return try RuntimeIdleSettings(
                idleSuspendMinutes: suspendMinutes,
                idleStopMinutes: stopMinutes,
                startPolicy: startPolicy
            )
        } catch let failure {
            switch failure {
            case .timerMinutesOutOfRange(let name):
                throw Failure.invalidSetting(name)
            }
        }
    }

    private static func integerSetting(
        _ value: Any?,
        name: String,
        defaultValue: Int
    ) throws -> Int {
        guard let value else { return defaultValue }
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            CFNumberIsFloatType(number) == false,
            let integer = Int(exactly: number.int64Value)
        else {
            throw Failure.invalidSetting(name)
        }
        return integer
    }
}
