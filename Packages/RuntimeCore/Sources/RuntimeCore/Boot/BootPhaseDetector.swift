import DiagnosticsCore
import Foundation

/// Turns console output into boot phases and boot failures (runtime-daemon.md §3.3).
///
/// Phases are monotonic: a phase may be skipped when its signal is not seen,
/// but never re-entered, and the first signal for a phase wins. After a
/// failure the detector reports nothing more.
struct BootPhaseDetector: Sendable {
    /// What one chunk of console output changed.
    enum Event: Equatable, Sendable {
        case entered(BootPhase, marker: PerfMarker)
        case failed(RuntimeBootFailure)
    }

    private(set) var phase: BootPhase?
    private(set) var failure: RuntimeBootFailure?
    private var pending = Data()

    /// Consumes console bytes; returns the phases entered and any failure, in order.
    mutating func consume(_ bytes: Data) -> [Event] {
        guard failure == nil, !bytes.isEmpty else {
            return []
        }
        var events: [Event] = []
        if phase == nil {
            phase = .kernel
            events.append(.entered(.kernel, marker: BootSignals.kernelMarker))
        }
        pending.append(bytes)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            events += consume(line: line)
            if failure != nil {
                break
            }
        }
        return events
    }

    /// Applies one ADB poll. The phases it enters are reported in boot order, and a phase already
    /// entered from the console is not entered again. ADB never enters `.kernel`: the console does.
    mutating func observe(adb state: AdbBootState) -> [Event] {
        guard failure == nil else {
            return []
        }
        var events: [Event] = []
        if state.systemServerStarted, (phase ?? .kernel) < .systemServer {
            phase = .systemServer
            events.append(.entered(.systemServer, marker: .systemServerReady))
        }
        if state.bootCompleted, (phase ?? .kernel) < .bootCompleted {
            phase = .bootCompleted
            events.append(.entered(.bootCompleted, marker: .bootCompleted))
        }
        return events
    }

    private mutating func consume(line: String) -> [Event] {
        if line.contains(BootSignals.kernelPanic) {
            failure = .kernelPanic
            return [.failed(.kernelPanic)]
        }
        if let range = line.range(of: BootSignals.androidBootFailed) {
            let detail = line[range.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: ": \r"))
            let failure = RuntimeBootFailure.androidBootFailed(detail: String(detail.prefix(200)))
            self.failure = failure
            return [.failed(failure)]
        }
        var events: [Event] = []
        for signal in BootSignals.phases where signal.phase > (phase ?? .kernel) {
            if line.contains(signal.fragment) {
                phase = signal.phase
                events.append(.entered(signal.phase, marker: signal.marker))
            }
        }
        return events
    }
}
