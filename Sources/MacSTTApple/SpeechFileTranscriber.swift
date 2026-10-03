@preconcurrency import AVFoundation
import Foundation
import MacSTTCore
import Speech

public struct SpeechFileTranscript: Sendable, Equatable {
    public let text: String
    public let resolvedLocale: String
    public let durationSeconds: Double
    public let textTruncated: Bool
}

public actor SpeechFileTranscriber {
    public static let maximumInputBytes = 16 * 1_024 * 1_024
    public static let maximumDurationSeconds = 120.0
    public static let maximumTranscriptBytes = 64 * 1_024

    private static let maximumDecodedBytes = 64 * 1_024 * 1_024

    private let diagnostics: Diagnostics
    private var isTranscribing = false

    public init(diagnostics: Diagnostics = Diagnostics()) {
        self.diagnostics = diagnostics
    }

    public func transcribe(data: Data, locale requestedLocale: String) async throws -> SpeechFileTranscript {
        guard !isTranscribing else {
            throw failure(
                code: "SPEECH_FILE_TRANSCRIPTION_BUSY", domain: .invariant, stage: "admit",
                recoverability: .retryableOnce, detail: nil
            )
        }
        isTranscribing = true
        defer { isTranscribing = false }

        guard !data.isEmpty, data.count <= Self.maximumInputBytes else {
            throw failure(
                code: data.isEmpty ? "AUDIO_FILE_EMPTY" : "AUDIO_FILE_TOO_LARGE",
                domain: .audio, stage: "input", recoverability: .requiresUserAction,
                detail: "max-bytes=\(Self.maximumInputBytes)"
            )
        }
        try Task.checkCancellation()

        try InMemoryAudioFile.validate(data, maximumDurationSeconds: Self.maximumDurationSeconds)
        let requested = Locale(identifier: requestedLocale)
        let selection: FileTranscriberSelection
        if SpeechTranscriber.isAvailable,
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        {
            selection = .speech(
                SpeechTranscriber(locale: locale, preset: .transcription), locale)
        } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            selection = .dictation(
                DictationTranscriber(locale: locale, preset: .progressiveLongDictation), locale)
        } else {
            throw failure(
                code: "UNSUPPORTED_LOCALE_OR_DEVICE", domain: .capability, stage: "locale",
                recoverability: .requiresUserAction, detail: requestedLocale
            )
        }

        let modules: [any SpeechModule] = [selection.module]
        do {
            try await SpeechAssetReadiness.installIfNeeded(
                modules: modules,
                locale: selection.locale,
                stage: "file-transcription",
                validate: { try Task.checkCancellation() }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MacSTTFailure {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw failure(
                code: "SPEECH_ASSET_INSTALLATION_FAILED", domain: .asset,
                stage: "file-transcription", recoverability: .requiresUserAction,
                detail: String(reflecting: type(of: error))
            )
        }
        try Task.checkCancellation()
        await SpeechAssetReadiness.reserveInstalledModelIfPossible(
            locale: selection.locale, diagnostics: diagnostics)
        try Task.checkCancellation()

        let availableFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        try Task.checkCancellation()
        guard let analysisFormat = availableFormat else {
            throw failure(
                code: "SPEECH_AUDIO_FORMAT_UNAVAILABLE", domain: .asset,
                stage: "file-transcription", recoverability: .requiresUserAction,
                detail: selection.locale.identifier(.bcp47)
            )
        }
        let decoded = try InMemoryAudioFile.decode(
            data,
            outputFormat: analysisFormat,
            maximumDurationSeconds: Self.maximumDurationSeconds,
            maximumDecodedBytes: Self.maximumDecodedBytes
        )
        let audioBuffer = decoded.buffer
        let decodedDuration = decoded.durationSeconds
        try Task.checkCancellation()

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: .init(priority: .userInitiated, modelRetention: .lingering)
        )
        var resultsTask: Task<(text: String, truncated: Bool), Error>?
        do {
            try await analyzer.prepareToAnalyze(in: analysisFormat)
            try Task.checkCancellation()
            resultsTask = makeResultsTask(selection)
            let input = AsyncThrowingStream<AnalyzerInput, Error> { continuation in
                continuation.yield(AnalyzerInput(buffer: audioBuffer))
                continuation.finish()
            }
            guard let lastSample = try await analyzer.analyzeSequence(input) else {
                throw failure(
                    code: "AUDIO_FILE_EMPTY", domain: .audio, stage: "analyze",
                    recoverability: .requiresUserAction, detail: nil
                )
            }
            try Task.checkCancellation()
            try await analyzer.finalizeAndFinish(through: lastSample)
            try Task.checkCancellation()
            guard let resultsTask else {
                throw failure(
                    code: "SPEECH_RESULT_TASK_MISSING", domain: .invariant, stage: "finalize",
                    recoverability: .terminalForSession, detail: nil
                )
            }
            let transcript = try await withTaskCancellationHandler {
                try await resultsTask.value
            } onCancel: {
                resultsTask.cancel()
            }
            try Task.checkCancellation()
            return SpeechFileTranscript(
                text: transcript.text,
                resolvedLocale: selection.locale.identifier(.bcp47),
                durationSeconds: decodedDuration,
                textTruncated: transcript.truncated
            )
        } catch {
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
            if let resultsTask { _ = await resultsTask.result }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? MacSTTFailure { throw error }
            throw failure(
                code: "SPEECH_FILE_TRANSCRIPTION_FAILED", domain: .speech,
                stage: "file-transcription", recoverability: .retryableOnce,
                detail: String(reflecting: type(of: error))
            )
        }
    }

    private func makeResultsTask(
        _ selection: FileTranscriberSelection
    ) -> Task<(text: String, truncated: Bool), Error> {
        switch selection {
        case .speech(let transcriber, _):
            return Task {
                try await Self.collect(
                    transcriber.results,
                    maximumBytes: Self.maximumTranscriptBytes,
                    text: { String($0.text.characters) },
                    isFinal: { $0.isFinal }
                )
            }
        case .dictation(let transcriber, _):
            return Task {
                try await Self.collect(
                    transcriber.results,
                    maximumBytes: Self.maximumTranscriptBytes,
                    text: { String($0.text.characters) },
                    isFinal: { $0.isFinal }
                )
            }
        }
    }

    private static func collect<Results: AsyncSequence>(
        _ results: Results,
        maximumBytes: Int,
        text projectText: @Sendable (Results.Element) -> String,
        isFinal projectFinality: @Sendable (Results.Element) -> Bool
    ) async throws -> (text: String, truncated: Bool)
    where Results: Sendable, Results.Element: Sendable {
        var text = ""
        var truncated = false
        for try await result in results {
            try Task.checkCancellation()
            guard projectFinality(result), !truncated else { continue }
            let bounded = prefix(projectText(result), maximumBytes: maximumBytes - text.utf8.count)
            text.append(bounded.text)
            truncated = bounded.truncated
        }
        return (text, truncated)
    }

    private static func prefix(_ value: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
        var result = ""
        var usedBytes = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard characterBytes <= maximumBytes - usedBytes else { return (result, true) }
            result.append(character)
            usedBytes += characterBytes
        }
        return (result, false)
    }

    private func failure(
        code: String,
        domain: FailureDomain,
        stage: String,
        recoverability: Recoverability,
        detail: String?
    ) -> MacSTTFailure {
        MacSTTFailure(
            code: code, domain: domain, stage: stage,
            recoverability: recoverability, messageKey: code.lowercased(), redactedDetail: detail
        )
    }
}

private enum FileTranscriberSelection {
    case speech(SpeechTranscriber, Locale)
    case dictation(DictationTranscriber, Locale)

    var module: any SpeechModule {
        switch self {
        case .speech(let transcriber, _): transcriber
        case .dictation(let transcriber, _): transcriber
        }
    }

    var locale: Locale {
        switch self {
        case .speech(_, let locale), .dictation(_, let locale): locale
        }
    }
}
