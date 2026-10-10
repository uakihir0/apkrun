import DiagnosticsCore
import GraphicsBridge
import Metal

/// The initialization stage that failed while constructing ANGLE and VirGL.
public enum GraphicsInitStage: String, Sendable {
    /// EGL display or context setup failed.
    case egl
    /// ANGLE did not provide its Metal device.
    case metal
    /// VirGL initialization failed.
    case virgl
}

/// A typed initialization or renderer-operation failure owned by GraphicsCore.
public enum GraphicsFailure: APKRunError, Equatable {
    /// Renderer initialization failed at `stage`.
    case rendererInitFailed(stage: GraphicsInitStage, detail: String)
    /// A required library is missing from the application runtime.
    case libraryMissing(name: String)
    /// A renderer operation failed. `operation` identifies the attempted API.
    case rendererOperationFailed(operation: String, detail: String)
    /// A display mode is outside the EDID or size limits (graphics.md §6.4).
    case modeUnsupported(mode: DisplayMode)
    /// A configuration-space update failed for a reason other than a generation change.
    case configUpdateFailed(detail: String)

    /// The registered error-catalog domain for graphics failures.
    public static let domain = ErrorDomain.graphics

    /// The stable code for this failure.
    public var code: String {
        switch self {
        case .rendererInitFailed:
            "rendererInitFailed"
        case .libraryMissing:
            "libraryMissing"
        case .rendererOperationFailed:
            "rendererOperationFailed"
        case .modeUnsupported:
            "modeUnsupported"
        case .configUpdateFailed:
            "configUpdateFailed"
        }
    }

    /// The named values recorded in diagnostics for this failure.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .rendererInitFailed(let stage, let detail):
            [
                "stage": .text(stage.rawValue),
                "detail": .text(detail),
            ]
        case .libraryMissing(let name):
            ["name": .text(name)]
        case .rendererOperationFailed(let operation, let detail):
            [
                "operation": .text(operation),
                "detail": .text(detail),
            ]
        case .modeUnsupported(let mode):
            ["mode": .text(mode.description)]
        case .configUpdateFailed(let detail):
            ["detail": .text(detail)]
        }
    }

    static func bridgeDetail(status: Int32) -> String {
        let detailPointer = gb_status_description(status)
        return detailPointer.map(String.init(cString:)) ?? "GraphicsBridge failed."
    }

    static func initializationFailure(status: Int32) -> GraphicsFailure {
        let detail = bridgeDetail(status: status)
        return switch Int(status) {
        case GB_E_RUNTIME_DIRECTORY_MISSING:
            .libraryMissing(name: "VirGLRuntime")
        case GB_E_LIBRARY_MISSING_VIRGL:
            .libraryMissing(name: "libvirglrenderer.1.dylib")
        case GB_E_LIBRARY_MISSING_EPOXY:
            .libraryMissing(name: "libepoxy.0.dylib")
        case GB_E_LIBRARY_MISSING_EGL:
            .libraryMissing(name: "libEGL.dylib")
        case GB_E_LIBRARY_MISSING_GLES:
            .libraryMissing(name: "libGLESv2.dylib")
        case GB_E_EGL_INITIALIZATION:
            .rendererInitFailed(stage: .egl, detail: detail)
        case GB_E_METAL_DEVICE:
            .rendererInitFailed(stage: .metal, detail: detail)
        case GB_E_VIRGL_INITIALIZATION, GB_E_RENDERER_ALREADY_EXISTS,
            GB_E_INVALID_ARGUMENT:
            .rendererInitFailed(stage: .virgl, detail: detail)
        default:
            .rendererOperationFailed(operation: "initialize", detail: detail)
        }
    }

    static func operationFailure(
        status: Int32,
        operation: String
    ) -> GraphicsFailure {
        .rendererOperationFailed(
            operation: operation,
            detail: bridgeDetail(status: status)
        )
    }
}

/// The maximum version and byte count reported for one capset.
public struct GraphicsCapsetInfo: Equatable, Sendable {
    /// The highest capset version supported by VirGL.
    public let maxVersion: UInt32
    /// The maximum number of bytes required to fill this capset.
    public let maxSizeBytes: UInt32

    /// Creates capset metadata from a renderer's reported limits.
    public init(maxVersion: UInt32, maxSizeBytes: UInt32) {
        self.maxVersion = maxVersion
        self.maxSizeBytes = maxSizeBytes
    }
}

/// Standard virglrenderer capset identifiers.
public enum GraphicsCapset: Sendable {
    /// The original VirGL capset.
    public static let virgl: UInt32 = UInt32(GB_CAPSET_VIRGL)
    /// The VirGL 2 capset.
    public static let virgl2: UInt32 = UInt32(GB_CAPSET_VIRGL2)
}
