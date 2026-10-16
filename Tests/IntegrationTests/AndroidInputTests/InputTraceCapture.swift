import Foundation
import InputCore
import RuntimeCore
import RuntimeHost

/// A bounded diagnostic record of input as it enters and leaves the Mac window.
///
/// The AppKit observer and sink callback run on the main thread for this path; the lock also makes snapshots safe
/// after the queued sink has drained.
final class InputTraceRecorder: @unchecked Sendable {
    static let recordLimit = 2_048

    private let lock = NSLock()
    private var nextOrdinal = 1
    private var rawReceipts: [InputTraceRawReceipt] = []
    private var discardedRawReceipts = 0
    private var translatedEvents: [InputTraceTranslatedEvent] = []
    private var discardedTranslatedEvents = 0

    func recordRawReceipt(eventType: Int, hostTimeNanos: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        append(
            InputTraceRawReceipt(
                ordinal: allocateOrdinal(),
                eventType: eventType,
                hostTimeNanos: hostTimeNanos
            ),
            to: &rawReceipts,
            discarded: &discardedRawReceipts
        )
    }

    func recordTranslated(_ events: [InputEvent]) {
        lock.lock()
        defer { lock.unlock() }
        for event in events {
            let (hostTimeNanos, kindAndPhase) = Self.describe(event)
            append(
                InputTraceTranslatedEvent(
                    ordinal: allocateOrdinal(),
                    hostTimeNanos: hostTimeNanos,
                    kindAndPhase: kindAndPhase
                ),
                to: &translatedEvents,
                discarded: &discardedTranslatedEvents
            )
        }
    }

    func snapshot() -> InputTraceHostSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return InputTraceHostSnapshot(
            rawReceipts: rawReceipts,
            discardedRawReceipts: discardedRawReceipts,
            translatedEvents: translatedEvents,
            discardedTranslatedEvents: discardedTranslatedEvents
        )
    }

    private func allocateOrdinal() -> Int {
        defer { nextOrdinal += 1 }
        return nextOrdinal
    }

    private func append<Record>(
        _ record: Record,
        to records: inout [Record],
        discarded: inout Int
    ) {
        if records.count == Self.recordLimit {
            records.removeFirst()
            discarded += 1
        }
        records.append(record)
    }

    private static func describe(_ event: InputEvent) -> (UInt64, String) {
        switch event {
        case .touch(let touch):
            let phase: String =
                switch touch.phase {
                case .down: "down"
                case .move: "move"
                case .up: "up"
                case .cancel: "cancel"
                }
            return (touch.time.hostNanos, "touch.\(phase)")
        case .mouse(let mouse):
            let action: String =
                switch mouse.action {
                case .hoverEnter: "hoverEnter"
                case .hoverMove: "hoverMove"
                case .hoverExit: "hoverExit"
                case .press: "press"
                case .release: "release"
                }
            return (mouse.time.hostNanos, "mouse.\(action)")
        case .scroll(let scroll):
            return (scroll.time.hostNanos, "scroll")
        case .key(let key):
            return (key.time.hostNanos, key.action == .down ? "key.down" : "key.up")
        case .longPress(_, let time):
            return (time.hostNanos, "longPress")
        case .cancelAll(let time):
            return (time.hostNanos, "cancelAll")
        }
    }
}

struct InputTraceRawReceipt: Codable, Equatable {
    let ordinal: Int
    let eventType: Int
    let hostTimeNanos: UInt64
}

struct InputTraceTranslatedEvent: Codable, Equatable {
    let ordinal: Int
    let hostTimeNanos: UInt64
    let kindAndPhase: String
}

struct InputTraceHostSnapshot: Codable, Equatable {
    let rawReceipts: [InputTraceRawReceipt]
    let discardedRawReceipts: Int
    let translatedEvents: [InputTraceTranslatedEvent]
    let discardedTranslatedEvents: Int
}

struct InputTraceRoutedEvent: Codable, Equatable {
    let batchSequence: UInt64
    let eventIndex: Int
    let hostTimeNanos: UInt64
    let kindAndPhase: String

    init(_ record: InputSentEventHistory.Record) {
        batchSequence = record.batchSequence
        eventIndex = record.eventIndex
        hostTimeNanos = record.hostTimeNanos
        kindAndPhase = record.kindAndPhase
    }
}

struct InputTraceAcknowledgement: Codable, Equatable {
    let batchSequence: UInt64
    let rejectedEvents: UInt32
    let receiveToInjectMicros: UInt32
    let lastEventTimeMillis: UInt64

    init(_ record: InputAcknowledgementHistory.Record) {
        batchSequence = record.batchSequence
        rejectedEvents = record.rejectedEvents
        receiveToInjectMicros = record.receiveToInjectMicros
        lastEventTimeMillis = record.lastEventTimeMillis
    }
}

struct InputTraceLink: Codable {
    let batchSequence: UInt64
    let eventIndex: Int
    let kindAndPhase: String
    let hostTimeNanos: UInt64
    let rawReceiptOrdinals: [Int]
    let translatedEventOrdinals: [Int]
    let acknowledgement: InputTraceAcknowledgement?
    let fixtureTouchRecords: [String]
    let fixtureClickRecords: [String]
    let fixtureDispatch: String
    let clickOutcome: String
}

/// A HelloText button state transition recorded while an explicit debug trace is active.
///
/// These observations use Android elapsed realtime and do not carry a gesture identifier.
struct InputTracePressedTransition: Codable, Equatable {
    let sequence: UInt64
    let sampledAtElapsedRealtimeNanos: UInt64
    let requestedPressed: Bool
    let pressedBefore: Bool
    let pressedAfter: Bool
}

enum InputTraceFixtureClickCorrelation: String, Codable {
    case uniqueUp = "unique_up"
    case ambiguous
}

/// One fixture click callback and the synchronous counter-write timing captured with it.
struct InputTraceFixtureClick: Codable, Equatable {
    let sequence: UInt64
    let clickOrdinal: UInt64
    let storedCounter: Int?
    let saveSucceeded: Bool
    let correlation: InputTraceFixtureClickCorrelation
    let pendingUpCount: UInt64
    let correlatedUpSequence: UInt64?
    let counterIncrementStartedAtElapsedRealtimeNanos: UInt64?
    let counterIncrementDurationNanos: UInt64?
}

/// Typed fixture observations retained alongside the raw lines in a diagnostic trace.
///
/// Pressed transitions and click callbacks remain separate collections: current fixture records cannot safely join
/// them to one another or to MotionEvent uptime timestamps.
struct InputTraceFixtureObservations: Codable, Equatable {
    let pressedTransitions: [InputTracePressedTransition]
    let clicks: [InputTraceFixtureClick]
    let malformedPressedTransitionCount: Int
    let malformedClickCount: Int
}

struct InputTraceStageDiscrepancy: Codable, Equatable {
    let stage: String
    let kindAndPhase: String
    let expectedCount: Int
    let observedCount: Int
    let sourceOrdinals: [Int]
    let observedOrdinals: [Int]
    let observedBatchSequences: [UInt64]
}

struct InputTraceEvidence: Codable {
    let schemaVersion: Int
    let path: String
    let captureMode: String
    let clockDomains: [String: String]
    let limitations: [String]
    let captureStartCounters: String
    let finalCounters: String
    let host: InputTraceHostSnapshot
    let routedEvents: [InputTraceRoutedEvent]
    let discardedRoutedEvents: Int
    let acknowledgements: [InputTraceAcknowledgement]
    let discardedAcknowledgements: Int
    let missingAcknowledgementSequences: [UInt64]
    let joins: [InputTraceLink]
    let stageDiscrepancies: [InputTraceStageDiscrepancy]
    let ambiguousAcknowledgementSequences: [UInt64]
    let unattributedFixtureClickRecords: [String]
    let fixtureTraceLines: [String]
    let fixtureObservations: InputTraceFixtureObservations
    let fixtureTraceRecords: Int?
    let fixtureTraceDiscarded: Int?
    let persistedCounterBefore: Int
    let persistedCounterAfter: Int?
    let persistedCounterDelta: Int?
}
