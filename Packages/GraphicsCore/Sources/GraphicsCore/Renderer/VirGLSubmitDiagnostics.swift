#if APKRUN_TEST_READBACK
    import Foundation

    /// One `submit` that virglrenderer rejected, as the replay test sees it (IR-830). The normal path reports only the
    /// bridge status, which hides the value that virglrenderer returned and the messages it logged.
    struct VirGLSubmitRejection: Equatable, Sendable {
        /// The value that `virgl_renderer_submit_cmd` returned, such as `EINVAL` (22), or `Int32.min` when the bridge
        /// rejected the call before virglrenderer ran.
        let virglResult: Int32
        /// The messages that virglrenderer logged during the call, in order, without the trailing newline.
        let messages: [String]
    }

    /// Collects the messages that the renderer logs. virglrenderer keeps one log handler for the process, and the
    /// bridge admits one live renderer, so the messages seen here are those of the renderer that owns this sink. The
    /// callbacks and the reads run on its render thread.
    final class VirGLMessageSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        func record(_ message: String) {
            let line = message.hasSuffix("\n") ? String(message.dropLast()) : message
            lock.withLock { stored.append(line) }
        }

        /// Returns the messages recorded since the previous call, and clears them.
        func takeMessages() -> [String] {
            lock.withLock {
                let taken = stored
                stored = []
                return taken
            }
        }
    }
#endif
