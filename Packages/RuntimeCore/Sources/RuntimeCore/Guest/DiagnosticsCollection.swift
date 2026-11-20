import DiagnosticsCore
import Foundation
import GuestProtocol

/// One collected diagnostics item (guest-protocol.md §7.1 operation 73,
/// diagnostics.md §5). `payload` is the bulk transfer's contents, present with
/// `ok` only.
public struct GuestDiagnosticsItem: Sendable, Equatable {
    /// How the item's collection ended.
    public enum Status: String, Sendable, Equatable {
        /// The payload was collected.
        case ok
        /// The agent does not know the item; never a request failure.
        case unsupported
        /// The output exceeded the 16 MiB per-item cap.
        case tooLarge
        /// The collection failed.
        case failed
    }

    /// The requested item.
    public let item: GPDiagnosticsItem
    /// Its collection status.
    public let status: Status
    /// The payload of the bulk transfer, truncated at `maxBytes`.
    public let payload: Data?
    /// Whether the agent cut the payload at `maxBytes`.
    public let truncated: Bool

    /// Creates a collected item.
    public init(
        item: GPDiagnosticsItem,
        status: Status,
        payload: Data? = nil,
        truncated: Bool = false
    ) {
        self.item = item
        self.status = status
        self.payload = payload
        self.truncated = truncated
    }
}

extension DevelopmentGuestAgent {
    /// Collects diagnostics items through guest protocol operation 73: the reply
    /// names a bulk transfer per OK item and its frames arrive on the bulk
    /// channel (diagnostics.md §5, guest-protocol.md §10).
    ///
    /// An item the agent does not know comes back `unsupported`; no item fails
    /// the request itself.
    public func collectDiagnostics(
        items: [GPDiagnosticsItem] = [.dumpsysMeminfo],
        maxBytes: UInt64 = 16 * 1024 * 1024,
        properties: [String] = []
    ) async throws(GuestAgentFailure) -> [GuestDiagnosticsItem] {
        try requireAvailable()
        guard let token = await supervisor.session?.sessionToken else {
            throw .operationFailed(reason: GuestProtocolFailure.disconnected.catalogName)
        }
        // The bulk connection opens before the request so a transfer's frames
        // cannot be missed while the reply is on its way (§10).
        let bulk = GuestConnection(
            endpoint: .guestBulk,
            transport: transport,
            presentedToken: token,
            hostVersion: hostVersion,
            logSink: logSink
        )
        do throws(GuestProtocolFailure) {
            _ = try await bulk.open()
        } catch {
            throw .operation(error)
        }
        defer { Task { await bulk.close() } }

        let result: GPCollectDiagnosticsResult
        do {
            result = try await supervisor.send(
                GuestCollectDiagnostics(items: items, maxBytes: maxBytes, properties: properties)
            )
        } catch {
            throw .operation(error)
        }

        // One entry per answer, in request order.
        var ordered: [GuestDiagnosticsItem] = []
        var pendingTransfers: [UInt64: (item: GPDiagnosticsItem, truncated: Bool, bytes: Data)] = [:]
        for answer in result.items {
            let status: GuestDiagnosticsItem.Status
            switch answer.status {
            case .ok: status = .ok
            case .unsupported: status = .unsupported
            case .tooLarge: status = .tooLarge
            default: status = .failed
            }
            if status == .ok, answer.hasTransferID {
                pendingTransfers[answer.transferID] = (answer.item, answer.truncated, Data())
            } else {
                ordered.append(GuestDiagnosticsItem(item: answer.item, status: status))
            }
        }
        // Items are appended in reply order once their transfer completes. A
        // collect with nothing pending returns here instead of waiting on a
        // channel that carries no frames.
        var completions: [(index: Int, item: GuestDiagnosticsItem)] = []
        if !pendingTransfers.isEmpty {
            // The host enforces the same per-item cap the agent does: a chunk
            // past `min(maxBytes, 16 MiB)` is a protocol violation, not a bigger
            // payload. `maxBytes = 0` asks for the agent's default, 16 MiB
            // (diagnostics.md §6).
            let itemCap = Int(min(maxBytes == 0 ? 16 * 1024 * 1024 : maxBytes, 16 * 1024 * 1024))
            // The deadline applies even while no frame arrives: it ends the
            // stream by closing the connection.
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(70))
                await bulk.close()
            }
            defer { watchdog.cancel() }
            for try await frame in bulk.bulkFrames {
                switch frame.kind {
                case .chunk(let bytes):
                    if var transfer = pendingTransfers[frame.transferID] {
                        transfer.bytes.append(bytes)
                        if transfer.bytes.count > itemCap {
                            pendingTransfers.removeValue(forKey: frame.transferID)
                            completions.append(
                                (
                                    ordered.count,
                                    GuestDiagnosticsItem(
                                        item: transfer.item, status: .failed)
                                ))
                        } else {
                            pendingTransfers[frame.transferID] = transfer
                        }
                    }
                case .end:
                    if let transfer = pendingTransfers.removeValue(forKey: frame.transferID) {
                        completions.append(
                            (
                                ordered.count,
                                GuestDiagnosticsItem(
                                    item: transfer.item,
                                    status: .ok,
                                    payload: transfer.bytes,
                                    truncated: transfer.truncated
                                )
                            ))
                    }
                case .abort:
                    if let transfer = pendingTransfers.removeValue(forKey: frame.transferID) {
                        completions.append(
                            (
                                ordered.count,
                                GuestDiagnosticsItem(item: transfer.item, status: .failed)
                            ))
                    }
                default:
                    continue
                }
                if pendingTransfers.isEmpty {
                    break
                }
            }
        }
        // A transfer that never completed is a failed item.
        for transfer in pendingTransfers.values {
            completions.append(
                (ordered.count, GuestDiagnosticsItem(item: transfer.item, status: .failed)))
        }
        completions.sort { $0.index < $1.index }
        ordered.append(contentsOf: completions.map(\.item))
        return ordered
    }
}
