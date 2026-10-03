import Foundation
import MacSTTCore

struct TranscriptRecoveryBuffer: Sendable {
    private let limit: Int
    private var committedChunks: [String] = []
    private var committedHead = 0
    private var committedCharacterCount = 0
    private var volatileText = ""
    private var finalizedKeys: Set<SegmentKey> = []

    init(limit: Int) { self.limit = max(64, limit) }

    mutating func replace(with text: String, key: SegmentKey) {
        guard !finalizedKeys.contains(key) else { return }
        volatileText = text
    }

    mutating func appendFinal(_ text: String, key: SegmentKey) {
        guard finalizedKeys.insert(key).inserted else { return }
        appendCommitted(text)
        volatileText.removeAll(keepingCapacity: false)
    }

    var current: String {
        let committed = committedHead < committedChunks.count
            ? committedChunks[committedHead...].joined()
            : ""
        guard !volatileText.isEmpty else { return committed }
        let committedLimit = max(0, limit - volatileText.count)
        return String(committed.suffix(committedLimit)) + volatileText
    }

    mutating func reset() {
        committedChunks.removeAll(keepingCapacity: true)
        committedHead = 0
        committedCharacterCount = 0
        volatileText.removeAll(keepingCapacity: false)
        finalizedKeys.removeAll(keepingCapacity: true)
    }

    private mutating func appendCommitted(_ text: String) {
        let chunk = String(text.suffix(limit))
        guard !chunk.isEmpty else { return }
        committedChunks.append(chunk)
        committedCharacterCount += chunk.count
        while committedCharacterCount > limit, committedHead < committedChunks.count {
            let overflow = committedCharacterCount - limit
            let first = committedChunks[committedHead]
            if overflow >= first.count {
                committedCharacterCount -= first.count
                committedHead += 1
            } else {
                committedChunks[committedHead] = String(first.dropFirst(overflow))
                committedCharacterCount -= overflow
            }
        }
        if committedHead >= 64, committedHead * 2 >= committedChunks.count {
            committedChunks.removeFirst(committedHead)
            committedHead = 0
        }
    }
}

struct TranscriptRecoveryResult: Equatable, Sendable {
    let transcript: String?
    let freezeError: String?
}

enum TranscriptRecovery {
    static func capture(
        assembler: TranscriptAssembler?,
        preview: String
    ) -> TranscriptRecoveryResult {
        if let assembler {
            do {
                let frozen = try assembler.freeze(requireFinal: false)
                if !frozen.raw.isEmpty {
                    return TranscriptRecoveryResult(transcript: frozen.raw, freezeError: nil)
                }
            } catch {
                return TranscriptRecoveryResult(
                    transcript: preview.isEmpty ? nil : preview,
                    freezeError: String(describing: error)
                )
            }
        }
        return TranscriptRecoveryResult(
            transcript: preview.isEmpty ? nil : preview,
            freezeError: nil
        )
    }
}
