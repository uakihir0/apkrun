import VirtioDeviceCore

/// The renderer work that a request needs. It runs on the render thread, in order.
/// It returns a failure to log, or `nil`. The guest's response is already decided.
typealias VirGLRenderWork = @Sendable (any VirGLEngine) -> GraphicsFailure?

/// The answer to one 2D or 3D request: the response, and the renderer work it needs, if any.
struct GPUCommandReply: Sendable {
    var response: VirtioGPUResponseBody
    var renderWork: VirGLRenderWork?
}

/// The guest's 2D and 3D state, kept on the device queue (graphics.md §4.2 to §4.4, §5.4).
///
/// The session validates every request against the tables before it answers. It
/// never calls the renderer. Renderer work is returned as a closure, and the device
/// queues it. The one exception is `TRANSFER_FROM_HOST_3D`: the guest needs the
/// bytes before its response, so the session waits for the render thread.
final class GuestGPUSession {
    /// Which resource path the device runs (graphics.md §9).
    enum Path: Equatable, Sendable {
        /// The EDID-only device: no 2D or 3D commands.
        case edidOnly
        /// The `guestSwiftshader` profile: host-memory 2D resources.
        case twoD
        /// The `drmVirgl` profile: resources and contexts owned by virglrenderer.
        case virgl
    }

    let path: Path
    private let backend: VirGLBackend?
    private let capsets: [VirGLCapset]
    private let counters: GraphicsCounterBox
    private(set) var resources = ResourceTable()
    private var contexts = ContextTable()
    private var backings: [UInt32: GuestBacking] = [:]
    /// The host memory of 2D-profile resources, laid out as the guest lays out the resource.
    private var shadows: [UInt32: [UInt8]] = [:]
    /// The resource that each scanout shows, as `SET_SCANOUT` bound it.
    private var scanoutBindings: [Int: UInt32] = [:]

    /// - Parameters:
    ///   - path: The resource path the device runs.
    ///   - backend: The renderer, for `.virgl`. It is `nil` otherwise.
    ///   - counters: The device's counters.
    init(path: Path, backend: VirGLBackend?, counters: GraphicsCounterBox) {
        self.path = path
        self.backend = backend
        self.capsets = backend?.capsets ?? []
        self.counters = counters
    }

    /// Forgets the guest's resources, contexts, backing, and bindings. The host scanout configuration is not
    /// part of the session, so it survives.
    func reset() {
        resources.reset()
        contexts.reset()
        backings.removeAll(keepingCapacity: false)
        shadows.removeAll(keepingCapacity: false)
        scanoutBindings.removeAll(keepingCapacity: false)
    }

    /// Answers a 2D or 3D request, or an error for a command this path does not implement.
    func reply(to request: VirtioGPURequest, context: VirtioDeviceContext) -> GPUCommandReply {
        let header = request.header
        switch request.body {
        case .resourceCreate2D(let resourceID, let format, let width, let height):
            return createResource2D(id: resourceID, format: format, width: width, height: height)
        case .resourceUnref(let resourceID):
            return unref(resourceID)
        case .setScanout(let rect, let scanoutID, let resourceID):
            return setScanout(rect: rect, scanout: scanoutID, resource: resourceID)
        case .resourceFlush(let rect, let resourceID):
            return flush(rect: rect, resource: resourceID)
        case .transferToHost2D(let rect, let offset, let resourceID):
            return transferToHost2D(rect: rect, offset: offset, resource: resourceID, context: context)
        case .resourceAttachBacking(let resourceID, let entries):
            return attachBacking(resource: resourceID, entries: entries, context: context)
        case .resourceDetachBacking(let resourceID):
            return detachBacking(resource: resourceID)
        case .getCapsetInfo(let index):
            return capsetInfo(index: index)
        case .getCapset(let id, let version):
            return capset(id: id, version: version)
        case .ctxCreate(_, let debugName):
            return createContext(id: header.contextID, debugName: debugName)
        case .ctxDestroy:
            return destroyContext(id: header.contextID)
        case .ctxAttachResource(let resourceID):
            return attachResource(context: header.contextID, resource: resourceID)
        case .ctxDetachResource(let resourceID):
            return detachResource(context: header.contextID, resource: resourceID)
        case .resourceCreate3D(let arguments):
            return createResource3D(arguments)
        case .transferToHost3D(let transfer):
            return transfer3D(transfer, header: header, context: context, direction: .toHost)
        case .transferFromHost3D(let transfer):
            return transfer3D(transfer, header: header, context: context, direction: .fromHost)
        case .submit3D(let commandStream):
            return submit(commandStream, context: header.contextID)
        default:
            return failed(.unspec)
        }
    }

    // MARK: - Helpers

    private func failed(_ code: VirtioGPUErrorCode) -> GPUCommandReply {
        GPUCommandReply(response: .error(code), renderWork: nil)
    }

    private func succeeded(renderWork: VirGLRenderWork? = nil) -> GPUCommandReply {
        GPUCommandReply(response: .okNoData, renderWork: renderWork)
    }

    /// Wraps a renderer call that may throw. Its failure is returned to the render thread's logger.
    private func work(
        _ body: @escaping @Sendable (any VirGLEngine) throws(GraphicsFailure) -> Void
    ) -> VirGLRenderWork {
        { engine in
            do throws(GraphicsFailure) {
                try body(engine)
                return nil
            } catch {
                return error
            }
        }
    }

    private var is2DCapable: Bool {
        path == .twoD || path == .virgl
    }

    // MARK: - 2D commands

    private func createResource2D(id: UInt32, format: UInt32, width: UInt32, height: UInt32) -> GPUCommandReply {
        guard is2DCapable else { return failed(.unspec) }
        do {
            switch path {
            case .virgl:
                try resources.createVirgl2D(id: id, format: format, width: width, height: height)
                let arguments = VirGLResourceArguments(
                    resourceID: id,
                    target: 2,
                    format: format,
                    bind: Self.renderTargetBind,
                    width: width,
                    height: height,
                    depth: 1,
                    arraySize: 1,
                    lastLevel: 0,
                    sampleCount: 0,
                    flags: 0
                )
                return succeeded(
                    renderWork: work { engine throws(GraphicsFailure) in
                        try engine.createResource(arguments)
                    })
            case .twoD, .edidOnly:
                try resources.createHost2D(id: id, format: format, width: width, height: height)
                return succeeded()
            }
        } catch {
            return failed(error.errorCode)
        }
    }

    /// VIRGL_BIND_RENDER_TARGET, which the 2D resources of the Linux driver use.
    private static let renderTargetBind: UInt32 = 1 << 1

    private func unref(_ id: UInt32) -> GPUCommandReply {
        guard is2DCapable else { return failed(.unspec) }
        do {
            try resources.unref(id: id)
        } catch {
            return failed(error.errorCode)
        }
        backings.removeValue(forKey: id)
        shadows.removeValue(forKey: id)
        for (scanout, bound) in scanoutBindings where bound == id {
            scanoutBindings.removeValue(forKey: scanout)
        }
        guard path == .virgl else { return succeeded() }
        return succeeded(renderWork: { engine in
            engine.unrefResource(id: id)
            return nil
        })
    }

    private func setScanout(rect: VirtioGPURect, scanout: UInt32, resource: UInt32) -> GPUCommandReply {
        guard is2DCapable else { return failed(.unspec) }
        guard scanout < UInt32(VirtioGPUProtocol.scanoutCount) else {
            return failed(.invalidScanoutID)
        }
        if resource == 0 {
            scanoutBindings.removeValue(forKey: Int(scanout))
            return succeeded()
        }
        guard let bound = resources.resource(id: resource) else {
            return failed(.invalidResourceID)
        }
        guard Self.isInside(rect, width: bound.width, height: bound.height) else {
            return failed(.invalidParameter)
        }
        scanoutBindings[Int(scanout)] = resource
        return succeeded()
    }

    private func flush(rect: VirtioGPURect, resource: UInt32) -> GPUCommandReply {
        guard is2DCapable else { return failed(.unspec) }
        guard let flushed = resources.resource(id: resource) else {
            return failed(.invalidResourceID)
        }
        guard Self.isInside(rect, width: flushed.width, height: flushed.height) else {
            return failed(.invalidParameter)
        }
        // No pool is attached until #023, so a flush completes without a blit (graphics.md §6.1).
        return succeeded()
    }

    private func transferToHost2D(
        rect: VirtioGPURect,
        offset: UInt64,
        resource: UInt32,
        context: VirtioDeviceContext
    ) -> GPUCommandReply {
        guard is2DCapable else { return failed(.unspec) }
        guard let target = resources.resource(id: resource) else {
            return failed(.invalidResourceID)
        }
        guard Self.isInside(rect, width: target.width, height: target.height) else {
            return failed(.invalidParameter)
        }
        let geometry: TransferGeometry
        do {
            geometry = try TransferGeometry(
                resource: target,
                level: 0,
                stride: 0,
                layerStride: 0,
                box: VirtioGPUBox(x: rect.x, y: rect.y, z: 0, width: rect.width, height: rect.height, depth: 1),
                offset: offset
            )
        } catch {
            return failed(error.errorCode)
        }
        guard geometry.runCount <= TransferGeometry.maximumRuns else {
            return failed(.invalidParameter)
        }
        let gathered: [UInt8]
        do {
            gathered = try gather(target: target, geometry: geometry)
        } catch {
            return failed(.invalidParameter)
        }
        counters.update { $0.guestUploadBytes += UInt64(gathered.count) }

        switch path {
        case .twoD:
            // A host-memory copy of the rectangle, counted as a CPU pixel copy (graphics.md §9).
            var shadow = shadows[resource] ?? [UInt8](repeating: 0, count: Int(target.byteEstimate))
            var copied: UInt64 = 0
            var outOfRange = false
            geometry.forEachRun { run in
                let start = Int(run.offset)
                let end = start + run.length
                guard end <= shadow.count, end <= gathered.count else {
                    outOfRange = true
                    return
                }
                shadow.replaceSubrange(start..<end, with: gathered[start..<end])
                copied += UInt64(run.length)
            }
            guard !outOfRange else {
                return failed(.invalidParameter)
            }
            shadows[resource] = shadow
            counters.update {
                $0.cpuPixelCopies += 1
                $0.cpuPixelCopyBytes += copied
            }
            return succeeded()
        case .virgl:
            let transfer = VirGLTransfer(
                resourceID: resource,
                contextID: 0,
                level: 0,
                stride: geometry.stride,
                layerStride: geometry.layerStride,
                x: rect.x,
                y: rect.y,
                z: 0,
                width: rect.width,
                height: rect.height,
                depth: 1
            )
            return succeeded(
                renderWork: work { engine throws(GraphicsFailure) in
                    var data = gathered
                    try engine.transferWrite(transfer, data: &data)
                })
        case .edidOnly:
            return failed(.unspec)
        }
    }

    private func attachBacking(
        resource: UInt32,
        entries: [VirtioGPUMemoryEntry],
        context: VirtioDeviceContext
    ) -> GPUCommandReply {
        guard is2DCapable else { return failed(.unspec) }
        var views: [GuestMemory] = []
        var mappingFailed = false
        do {
            try resources.attachBacking(id: resource, entries: entries) { entry in
                do throws(VirtioFailure) {
                    let range = GuestPhysicalRange(address: entry.address, length: UInt64(entry.length))
                    views.append(try context.mapGuestMemory(range))
                    return true
                } catch {
                    mappingFailed = true
                    return false
                }
            }
        } catch {
            return failed(error.errorCode)
        }
        guard !mappingFailed, views.count == entries.count else {
            return failed(.invalidParameter)
        }
        backings[resource] = GuestBacking(entries: entries, views: views)
        return succeeded()
    }

    private func detachBacking(resource: UInt32) -> GPUCommandReply {
        guard is2DCapable else { return failed(.unspec) }
        do {
            try resources.detachBacking(id: resource)
        } catch {
            return failed(error.errorCode)
        }
        backings.removeValue(forKey: resource)
        return succeeded()
    }

    // MARK: - Capsets

    private func capsetInfo(index: UInt32) -> GPUCommandReply {
        guard path == .virgl else { return failed(.unspec) }
        guard index < UInt32(capsets.count) else { return failed(.invalidParameter) }
        let capset = capsets[Int(index)]
        return GPUCommandReply(
            response: .okCapsetInfo(
                id: capset.id,
                maxVersion: capset.version,
                maxSize: UInt32(capset.bytes.count)
            ),
            renderWork: nil
        )
    }

    private func capset(id: UInt32, version: UInt32) -> GPUCommandReply {
        guard path == .virgl else { return failed(.unspec) }
        guard let capset = capsets.first(where: { $0.id == id }), capset.version == version else {
            return failed(.invalidParameter)
        }
        return GPUCommandReply(response: .okCapset(data: capset.bytes), renderWork: nil)
    }

    // MARK: - Contexts

    private func createContext(id: UInt32, debugName: [UInt8]) -> GPUCommandReply {
        guard path == .virgl else { return failed(.unspec) }
        do {
            try contexts.create(id: id)
        } catch {
            return failed(error.errorCode)
        }
        let name = Self.contextName(debugName)
        return succeeded(
            renderWork: work { engine throws(GraphicsFailure) in
                try engine.createContext(id: id, name: name)
            })
    }

    /// The name of a context: its debug name up to the first NUL, decoded as UTF-8 with replacement.
    static func contextName(_ bytes: [UInt8]) -> String {
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private func destroyContext(id: UInt32) -> GPUCommandReply {
        guard path == .virgl else { return failed(.unspec) }
        do {
            try contexts.destroy(id: id)
        } catch {
            return failed(error.errorCode)
        }
        return succeeded(
            renderWork: work { engine throws(GraphicsFailure) in
                try engine.destroyContext(id: id)
            })
    }

    private func attachResource(context: UInt32, resource: UInt32) -> GPUCommandReply {
        guard path == .virgl else { return failed(.unspec) }
        guard contexts.contains(context) else { return failed(.invalidContextID) }
        guard resources.resource(id: resource) != nil else { return failed(.invalidResourceID) }
        return succeeded(
            renderWork: work { engine throws(GraphicsFailure) in
                try engine.attachResource(context: context, resource: resource)
            })
    }

    private func detachResource(context: UInt32, resource: UInt32) -> GPUCommandReply {
        guard path == .virgl else { return failed(.unspec) }
        guard contexts.contains(context) else { return failed(.invalidContextID) }
        guard resources.resource(id: resource) != nil else { return failed(.invalidResourceID) }
        return succeeded(
            renderWork: work { engine throws(GraphicsFailure) in
                try engine.detachResource(context: context, resource: resource)
            })
    }

    // MARK: - 3D resources, transfers, and submission

    private func createResource3D(_ arguments: VirtioGPUResourceCreate3D) -> GPUCommandReply {
        guard path == .virgl else { return failed(.unspec) }
        do {
            try resources.create3D(arguments)
        } catch {
            return failed(error.errorCode)
        }
        let renderArguments = VirGLResourceArguments(
            resourceID: arguments.resourceID,
            target: arguments.target,
            format: arguments.format,
            bind: arguments.bind,
            width: arguments.width,
            height: arguments.height,
            depth: arguments.depth,
            arraySize: arguments.arraySize,
            lastLevel: arguments.lastLevel,
            sampleCount: arguments.sampleCount,
            flags: arguments.flags
        )
        return succeeded(
            renderWork: work { engine throws(GraphicsFailure) in
                try engine.createResource(renderArguments)
            })
    }

    private enum TransferDirection {
        case toHost
        case fromHost
    }

    private func transfer3D(
        _ transfer: VirtioGPUTransfer3D,
        header: VirtioGPUControlHeader,
        context: VirtioDeviceContext,
        direction: TransferDirection
    ) -> GPUCommandReply {
        guard path == .virgl else { return failed(.unspec) }
        if header.contextID != 0, !contexts.contains(header.contextID) {
            return failed(.invalidContextID)
        }
        guard let target = resources.resource(id: transfer.resourceID) else {
            return failed(.invalidResourceID)
        }
        let geometry: TransferGeometry
        do {
            geometry = try TransferGeometry(
                resource: target,
                level: transfer.level,
                stride: transfer.stride,
                layerStride: transfer.layerStride,
                box: transfer.box,
                offset: transfer.offset
            )
        } catch {
            return failed(error.errorCode)
        }
        let renderTransfer = VirGLTransfer(
            resourceID: transfer.resourceID,
            contextID: header.contextID,
            level: transfer.level,
            stride: geometry.stride,
            layerStride: geometry.layerStride,
            x: transfer.box.x,
            y: transfer.box.y,
            z: transfer.box.z,
            width: transfer.box.width,
            height: transfer.box.height,
            depth: transfer.box.depth
        )

        switch direction {
        case .toHost:
            guard geometry.runCount <= TransferGeometry.maximumRuns else {
                return failed(.invalidParameter)
            }
            let gathered: [UInt8]
            do {
                gathered = try gather(target: target, geometry: geometry)
            } catch {
                return failed(.invalidParameter)
            }
            counters.update { $0.guestUploadBytes += UInt64(gathered.count) }
            return succeeded(
                renderWork: work { engine throws(GraphicsFailure) in
                    var data = gathered
                    try engine.transferWrite(renderTransfer, data: &data)
                })
        case .fromHost:
            return readBack(renderTransfer, geometry: geometry, target: target)
        }
    }

    /// The `TRANSFER_FROM_HOST_3D` path. The render thread reads the box before the response is written, because the
    /// guest needs the bytes in its memory. A failure is therefore visible to the guest.
    private func readBack(
        _ transfer: VirGLTransfer,
        geometry: TransferGeometry,
        target: GPUResource
    ) -> GPUCommandReply {
        let extent: UInt64
        do {
            extent = try geometry.extent()
        } catch {
            return failed(error.errorCode)
        }
        guard let backing = backings[target.id] else {
            return failed(.invalidParameter)
        }
        guard geometry.offset + extent <= backing.totalLength else {
            return failed(.invalidParameter)
        }
        guard geometry.runCount <= TransferGeometry.maximumRuns else {
            return failed(.invalidParameter)
        }
        let count = Int(extent)
        let outcome: ReadBackOutcome? = backend?.sync { engine in
            var data = [UInt8](repeating: 0, count: count)
            do throws(GraphicsFailure) {
                try engine.transferRead(transfer, into: &data)
                return ReadBackOutcome(bytes: data, failed: false)
            } catch {
                return ReadBackOutcome(bytes: [], failed: true)
            }
        }
        guard let outcome, !outcome.failed else {
            return failed(.unspec)
        }
        var copied: UInt64 = 0
        var writeFailed = false
        geometry.forEachRun { run in
            let start = Int(run.offset)
            let end = start + run.length
            guard end <= outcome.bytes.count else {
                writeFailed = true
                return
            }
            do {
                try backing.write(outcome.bytes[start..<end], at: run.offset + geometry.offset)
            } catch {
                writeFailed = true
                return
            }
            copied += UInt64(run.length)
        }
        guard !writeFailed else {
            return failed(.invalidParameter)
        }
        counters.update {
            $0.guestReadbacks += 1
            $0.guestReadbackBytes += copied
        }
        return succeeded()
    }

    private func submit(_ commandStream: [UInt8], context: UInt32) -> GPUCommandReply {
        guard path == .virgl else { return failed(.unspec) }
        guard contexts.contains(context) else { return failed(.invalidContextID) }
        guard commandStream.count % 4 == 0 else { return failed(.invalidParameter) }
        guard !commandStream.isEmpty else { return succeeded() }
        return succeeded(
            renderWork: work { engine throws(GraphicsFailure) in
                try engine.submit(context: context, commands: commandStream)
            })
    }

    // MARK: - Geometry and memory

    /// The bytes from the origin to the extent of the box, read from the backing.
    private func gather(target: GPUResource, geometry: TransferGeometry) throws -> [UInt8] {
        let extent = try geometry.extent()
        guard let backing = backings[target.id] else {
            throw GuestBackingFailure.outOfBacking
        }
        guard geometry.offset + extent <= backing.totalLength else {
            throw GuestBackingFailure.outOfBacking
        }
        return try backing.read(offset: geometry.offset, count: Int(extent))
    }

    /// True when `rect` lies inside a `width` × `height` resource.
    private static func isInside(_ rect: VirtioGPURect, width: UInt32, height: UInt32) -> Bool {
        guard rect.width >= 1, rect.height >= 1 else { return false }
        let (right, rightOverflow) = rect.x.addingReportingOverflow(rect.width)
        let (bottom, bottomOverflow) = rect.y.addingReportingOverflow(rect.height)
        return !rightOverflow && !bottomOverflow && right <= width && bottom <= height
    }
}

/// The bytes that a render-thread readback returned, or the fact that it failed.
private struct ReadBackOutcome: Sendable {
    let bytes: [UInt8]
    let failed: Bool
}
