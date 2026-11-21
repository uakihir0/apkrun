import Foundation
import RuntimeAPI

// MARK: - Frozen maintenance endpoint dispatch (runtime-api.md §12)

extension RuntimeHost {
    /// The maintenance coordinator; built on first use so boot stays cheap.
    var maintenanceService: MaintenanceService {
        if let _maintenanceService { return _maintenanceService }
        let service = MaintenanceService(
            markerFile: paths.maintenanceStateFile,
            version: buildIdentity.marketingVersion,
            build: buildIdentity.buildNumberInt,
            publish: { [eventHub] event in
                eventHub.publishMaintenanceEvent(event)
            },
            sessionsProvider: { [weak self] in
                await self?.maintenanceSessionPackageIDs() ?? []
            },
            backgroundTasksProvider: { [weak self] in
                await self?.maintenanceBackgroundTaskPackageIDs() ?? []
            },
            activitiesProvider: { [updateIdleController] in
                await updateIdleController.activeActivities.map {
                    RuntimeAPI.ActivityKind(rawValue: $0.rawValue)
                }
            },
            imageMigratingProvider: { [weak self] in
                await self?.imageMigrating ?? false
            },
            idleAndExit: { [weak self] in
                Task { await self?.requestRestartExit() }
            }
        )
        _maintenanceService = service
        return service
    }

    /// Runs one operation from the frozen `.maintenance` endpoint. The
    /// endpoint answers in every host state (§12.1), so there is no
    /// lifecycle or host-state gate here.
    func maintenanceOperation(
        _ request: MaintenanceControlRequest
    ) async -> MaintenanceControlReply {
        switch request.operation {
        case .maintenanceStatus:
            let status = await maintenanceService.status()
            return MaintenanceControlReply(status: status)
        case .prepareForHostUpdate:
            guard let update = request.hostUpdate else {
                return Self.maintenanceErrorReply(
                    "malformedRequest",
                    message: "prepareForHostUpdate requires hostUpdate.")
            }
            do throws(RuntimeWireError) {
                try await maintenanceService.prepareForHostUpdate(update)
            } catch {
                return Self.maintenanceErrorReply(error)
            }
        case .abortHostUpdate:
            await maintenanceService.abortHostUpdate()
        case .completeHostUpdate:
            await maintenanceService.completeHostUpdate()
        case .restartForUpdate:
            do throws(RuntimeWireError) {
                try await maintenanceService.restartForUpdate(
                    request.restart ?? RestartForUpdateRequest(closeSessions: false))
            } catch {
                return Self.maintenanceErrorReply(error)
            }
        @unknown default:
            return Self.maintenanceErrorReply(
                "unknownOperation",
                message: "The maintenance operation is not supported by this build.")
        }
        return MaintenanceControlReply()
    }

    private static func maintenanceErrorReply(
        _ code: String,
        message: String
    ) -> MaintenanceControlReply {
        MaintenanceControlReply(
            error: RuntimeWireError(domain: "maintenance", code: code, message: message))
    }

    private static func maintenanceErrorReply(_ error: RuntimeWireError) -> MaintenanceControlReply {
        MaintenanceControlReply(error: error)
    }

    private func maintenanceSessionPackageIDs() async -> [RuntimePackageID] {
        guard let service = sessionServiceForIntegrations() else { return [] }
        return await service.maintenanceSessionPackageIDs()
    }

    private func maintenanceBackgroundTaskPackageIDs() async -> [RuntimePackageID] {
        guard let service = sessionServiceForIntegrations() else { return [] }
        return await service.maintenanceBackgroundTaskPackageIDs()
    }

    /// Marks the daemon exit-eligible once idle (`restartPending`, §3.7).
    func requestRestartExit() {
        restartExitRequested = true
    }
}
