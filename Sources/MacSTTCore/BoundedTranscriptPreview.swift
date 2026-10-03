/// Character-bounded display projection, distinct from the full UTF-8-bounded transcript.
public struct BoundedTranscriptPreview: Sendable {
    private let limit: Int
    private var value = ""
    private var committedTail = ""
    private var finalizedKeys: Set<SegmentKey> = []

    public init(limit: Int = 512) {
        self.limit = max(64, limit)
    }

    public mutating func replace(with latestText: String, key: SegmentKey? = nil) -> String {
        if let key, finalizedKeys.contains(key) { return value }
        if key != nil {
            let incomingTail = String(latestText.suffix(limit))
            value = String((committedTail + incomingTail).suffix(limit))
        } else {
            value = String(latestText.suffix(limit))
        }
        return value
    }

    public mutating func appendFinal(_ text: String, key: SegmentKey? = nil) -> String {
        if let key {
            guard finalizedKeys.insert(key).inserted else { return value }
            let incomingTail = String(text.suffix(limit))
            committedTail = String((committedTail + incomingTail).suffix(limit))
            value = committedTail
            return value
        }
        let incomingTail = String(text.suffix(limit))
        value = String((value + incomingTail).suffix(limit))
        committedTail = value
        return value
    }

    public var current: String { value }

    public mutating func reset() {
        value = ""
        committedTail = ""
        finalizedKeys.removeAll(keepingCapacity: false)
    }
}
