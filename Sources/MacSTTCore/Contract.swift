import Foundation

public enum EngineKind: String, Codable, Sendable, CaseIterable {
    case speechTranscriber
    case dictationTranscriber
}

public enum FailureDomain: String, Codable, Sendable {
    case capability
    case permission
    case asset
    case audio
    case speech
    case invariant
}

public enum Recoverability: String, Codable, Sendable {
    case retryableOnce
    case requiresUserAction
    case terminalForSession
    case terminalForRuntime
}

public struct MacSTTFailure: Error, Codable, Equatable, Sendable {
    public var code: String
    public var domain: FailureDomain
    public var stage: String
    public var recoverability: Recoverability
    public var messageKey: String
    public var redactedDetail: String?
    public var userAction: String?

    public init(
        code: String,
        domain: FailureDomain,
        stage: String,
        recoverability: Recoverability,
        messageKey: String,
        redactedDetail: String? = nil,
        userAction: String? = nil
    ) {
        self.code = code
        self.domain = domain
        self.stage = stage
        self.recoverability = recoverability
        self.messageKey = messageKey
        self.redactedDetail = redactedDetail
        self.userAction = userAction
    }
}

extension MacSTTFailure: LocalizedError {
    public var errorDescription: String? {
        redactedDetail.map { "\(messageKey) (\($0))" } ?? messageKey
    }
}

public enum ContractError: Error, Equatable, Sendable {
    case invalidSegmentRange
    case transcriptFinalConflict
    case transcriptFinalMutation
    case overlappingFinalSegments
    case nonFinalSegmentAtFreeze
    case transcriptTooLarge
}

public struct SegmentKey: Hashable, Codable, Sendable, Comparable {
    public var startSample: Int64
    public var durationSamples: Int64

    public init(startSample: Int64, durationSamples: Int64) {
        self.startSample = startSample
        self.durationSamples = durationSamples
    }

    public var endSample: Int64 {
        let (sum, overflow) = startSample.addingReportingOverflow(durationSamples)
        return overflow ? Int64.max : sum
    }

    public static func < (lhs: SegmentKey, rhs: SegmentKey) -> Bool {
        if lhs.startSample != rhs.startSample { return lhs.startSample < rhs.startSample }
        return lhs.durationSamples < rhs.durationSamples
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var id: String
    public var generation: UInt64
    public var startSample: Int64
    public var durationSamples: Int64
    public var revision: UInt32
    public var isFinal: Bool
    public var text: String

    public init(
        generation: UInt64,
        startSample: Int64,
        durationSamples: Int64,
        revision: UInt32,
        isFinal: Bool,
        text: String
    ) {
        self.id = "\(startSample):\(durationSamples)"
        self.generation = generation
        self.startSample = startSample
        self.durationSamples = durationSamples
        self.revision = revision
        self.isFinal = isFinal
        self.text = text
    }

    public var key: SegmentKey {
        SegmentKey(startSample: startSample, durationSamples: durationSamples)
    }
}

public struct FrozenTranscript: Equatable, Sendable {
    public var raw: String
    public var segments: [TranscriptSegment]

    public init(raw: String, segments: [TranscriptSegment]) {
        self.raw = raw
        self.segments = segments
    }
}
