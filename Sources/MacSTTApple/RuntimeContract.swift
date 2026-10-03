import MacSTTCore

public struct SpeechPreparation: Sendable, Equatable {
    public let requestedLocale: String
    public let resolvedLocale: String
    public let engineKind: EngineKind

    public init(requestedLocale: String, resolvedLocale: String, engineKind: EngineKind) {
        self.requestedLocale = requestedLocale
        self.resolvedLocale = resolvedLocale
        self.engineKind = engineKind
    }
}

public enum SpeechRuntimeEvent: Sendable, Equatable {
    case preview(generation: UInt64, text: String)
    case level(generation: UInt64, value: Float)
    case failure(generation: UInt64, MacSTTFailure)
}

public struct SpeechCompletion: Sendable, Equatable {
    public let preparation: SpeechPreparation
    public let transcript: FrozenTranscript

    public init(preparation: SpeechPreparation, transcript: FrozenTranscript) {
        self.preparation = preparation
        self.transcript = transcript
    }
}
