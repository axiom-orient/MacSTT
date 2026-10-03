import Foundation

public struct TranscriptAssembler: Sendable {
    public static let maxSegmentCount = 4_096
    public static let maxTranscriptUTF8Bytes = 16 * 1024 * 1024

    public let generation: UInt64

    private var segments: [SegmentKey: TranscriptSegment] = [:]
    private var provisionalKeyByStart: [Int64: SegmentKey] = [:]
    private var textBytes = 0
    private var finalizedThroughSample: Int64 = 0

    public init(generation: UInt64) {
        self.generation = generation
    }

    public var segmentCount: Int { segments.count }

    @discardableResult
    public mutating func apply(_ incoming: TranscriptSegment) throws -> Bool {
        guard incoming.generation == generation else { return false }
        let (_, rangeOverflow) = incoming.startSample.addingReportingOverflow(incoming.durationSamples)
        guard incoming.startSample >= 0,
              incoming.durationSamples >= 0,
              !rangeOverflow,
              incoming.durationSamples > 0 || incoming.text.isEmpty
        else {
            throw ContractError.invalidSegmentRange
        }
        guard incoming.durationSamples > 0 else { return false }

        let key = incoming.key
        // Progressive transcribers can replace a provisional range with a newly
        // segmented range that starts at the same sample. Those ranges describe
        // the same leading audio; retaining both turns a normal revision into an
        // overlapping-final failure at freeze time. A final range is immutable,
        // but provisional ranges at the same start are superseded by the newest
        // non-empty range.
        let superseded = provisionalKeyByStart[key.startSample].flatMap { candidate -> SegmentKey? in
            guard candidate != key, let segment = segments[candidate], !isEffectivelyFinal(segment) else {
                return nil
            }
            return candidate
        }
        guard let existing = segments[key] else {
            try replaceStoredSegment(incoming, superseding: superseded)
            return true
        }
        let existingIsFinal = isEffectivelyFinal(existing)

        if incoming.revision < existing.revision { return false }

        if incoming.revision == existing.revision {
            if incoming.text == existing.text, incoming.isFinal == existing.isFinal { return false }
            if existingIsFinal || incoming.isFinal { throw ContractError.transcriptFinalConflict }
            try replaceStoredSegment(incoming, superseding: superseded)
            return true
        }

        if existingIsFinal, incoming.text != existing.text {
            throw ContractError.transcriptFinalMutation
        }

        var replacement = incoming
        if existingIsFinal { replacement.isFinal = true }
        try replaceStoredSegment(replacement, superseding: superseded)
        return true
    }

    /// Validate the entire replacement before changing any stored range or accounting.
    private mutating func replaceStoredSegment(
        _ replacement: TranscriptSegment, superseding superseded: SegmentKey?
    ) throws {
        let existing = segments[replacement.key]
        let supersededBytes = superseded.flatMap { segments[$0]?.text.utf8.count } ?? 0
        let projectedCount = segments.count - (superseded == nil ? 0 : 1)
            + (existing == nil ? 1 : 0)
        let projectedBytes = textBytes - supersededBytes - (existing?.text.utf8.count ?? 0)
            + replacement.text.utf8.count
        guard projectedCount <= Self.maxSegmentCount,
              projectedBytes <= Self.maxTranscriptUTF8Bytes
        else {
            throw ContractError.transcriptTooLarge
        }
        if let superseded { removeSegment(for: superseded) }
        store(replacement)
        textBytes = projectedBytes
    }

    private mutating func store(_ segment: TranscriptSegment) {
        if let existing = segments[segment.key],
           !existing.isFinal,
           provisionalKeyByStart[existing.startSample] == segment.key {
            provisionalKeyByStart.removeValue(forKey: existing.startSample)
        }
        segments[segment.key] = segment
        if !segment.isFinal {
            provisionalKeyByStart[segment.startSample] = segment.key
        }
    }

    private mutating func removeSegment(for key: SegmentKey) {
        guard let removed = segments.removeValue(forKey: key) else { return }
        if !removed.isFinal, provisionalKeyByStart[removed.startSample] == key {
            provisionalKeyByStart.removeValue(forKey: removed.startSample)
        }
    }

    public mutating func finalize(throughSample sample: Int64) {
        finalizedThroughSample = max(finalizedThroughSample, sample)
    }

    private func isEffectivelyFinal(_ segment: TranscriptSegment) -> Bool {
        segment.isFinal || segment.key.endSample <= finalizedThroughSample
    }

    public func freeze(requireFinal: Bool = true) throws -> FrozenTranscript {
        let ordered = segments.values.sorted { lhs, rhs in lhs.key < rhs.key }
        var previousEnd: Int64 = -1
        var materialized: [TranscriptSegment] = []
        materialized.reserveCapacity(ordered.count)

        for var segment in ordered {
            let effectiveFinal = isEffectivelyFinal(segment)
            if requireFinal, !effectiveFinal {
                throw ContractError.nonFinalSegmentAtFreeze
            }
            segment.isFinal = effectiveFinal

            if previousEnd > segment.startSample, !segment.text.isEmpty {
                throw ContractError.overlappingFinalSegments
            }
            previousEnd = max(previousEnd, segment.key.endSample)
            materialized.append(segment)
        }

        var raw = String()
        raw.reserveCapacity(textBytes)
        for segment in materialized { raw.append(segment.text) }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return FrozenTranscript(raw: raw, segments: materialized)
    }
}
