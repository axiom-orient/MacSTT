@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import Foundation
import MacSTTCore
import Speech

private struct TranscriptionUpdate: Sendable {
    let text: String
    let range: CMTimeRange
    let finalizationTime: CMTime
    let isFinal: Bool
}

public actor AppleSpeechRuntime {
    public typealias EventSink = @Sendable (SpeechRuntimeEvent) -> Void

    private let diagnostics: Diagnostics
    private let converter = AudioBufferConverter()

    private var generation: UInt64 = 0
    private var preparation: SpeechPreparation?
    private var eventSink: EventSink?
    private var analyzer: SpeechAnalyzer?
    private var selectedEngine: EngineSelection?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var resultTask: Task<Void, Error>?
    private var captureTask: Task<Void, Never>?
    private var captureDriver: AudioCaptureDriver?
    private var assembler: TranscriptAssembler?
    private var preview = BoundedTranscriptPreview(limit: 512)
    // The UI preview is intentionally small, but a range-freeze fallback must
    // not turn a long utterance into a 512-character tail. Keep a separate
    // bounded recovery projection within the transcript byte budget.
    private var recoveryPreview = TranscriptRecoveryBuffer(
        limit: TranscriptAssembler.maxTranscriptUTF8Bytes / 4
    )
    private var recoveryTranscript: String?
    private var revisions: [SegmentKey: UInt32] = [:]
    private var pendingFailure: MacSTTFailure?
    private var acceptingResults = false
    private var timescale: CMTimeScale = 16_000
    private var meterPacketCounter: UInt8 = 0
    private var preparationWatchdog: Task<Void, Never>?
    private var finalizationWatchdog: Task<Void, Never>?
    private var preparationInFlight = false
    private var preparationToken: UInt64 = 0
    private var preparationFailure: MacSTTFailure?
    private var cancellationTask: Task<Void, Never>?
    private var finishingToken: UInt64?
    private let preparationTimeout: Duration

    private static let finalizationTimeout: Duration = .seconds(10)

    public init(
        diagnostics: Diagnostics = Diagnostics(),
        preparationTimeout: Duration = .seconds(120)
    ) {
        self.diagnostics = diagnostics
        self.preparationTimeout = preparationTimeout
    }

    public func prepare(
        generation: UInt64,
        requestedLocale: String,
        deviceUID: String? = nil,
        eventSink: @escaping EventSink
    ) async throws -> SpeechPreparation {
        guard analyzer == nil, captureDriver == nil, !preparationInFlight,
              cancellationTask == nil, finishingToken == nil else {
            throw failure(
                code: "SESSION_ALREADY_ACTIVE", domain: .invariant, stage: "prepare",
                recoverability: .terminalForSession, detail: nil
            )
        }

        let token = nextPreparationToken()
        self.generation = generation
        self.eventSink = eventSink
        preparation = nil
        pendingFailure = nil
        preparationFailure = nil
        acceptingResults = true
        preparationInFlight = true
        startPreparationWatchdog(token: token, generation: generation)

        do {
            let driver = AudioCaptureDriver()
            let microphoneFormat = try driver.inputFormat(deviceUID: deviceUID)
            captureDriver = driver
            try ensurePreparationCurrent(token)
            let requested = Locale(identifier: requestedLocale)
            try ensurePreparationCurrent(token)
            guard let selection = await resolveEngine(for: requested) else {
                throw failure(
                    code: "UNSUPPORTED_LOCALE_OR_DEVICE", domain: .capability, stage: "capability",
                    recoverability: .requiresUserAction, detail: requestedLocale
                )
            }
            try ensurePreparationCurrent(token)
            selectedEngine = selection

            let prepared = SpeechPreparation(
                requestedLocale: requestedLocale,
                resolvedLocale: selection.locale.identifier(.bcp47),
                engineKind: selection.kind
            )
            preparation = prepared
            assembler = TranscriptAssembler(generation: generation)
            preview.reset()
            recoveryPreview.reset()
            recoveryTranscript = nil
            revisions.removeAll(keepingCapacity: true)

            let modules = selection.modules
            try ensurePreparationCurrent(token)
            try await SpeechAssetReadiness.installIfNeeded(
                modules: modules,
                locale: selection.locale,
                stage: "prepare",
                validate: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.ensurePreparationCurrent(token)
                }
            )
            try ensurePreparationCurrent(token)
            await SpeechAssetReadiness.reserveInstalledModelIfPossible(
                locale: selection.locale, diagnostics: diagnostics)
            try ensurePreparationCurrent(token)

            try ensurePreparationCurrent(token)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules,
                considering: microphoneFormat
            ) else {
                throw failure(
                    code: "SPEECH_AUDIO_FORMAT_UNAVAILABLE", domain: .asset, stage: "prepare",
                    recoverability: .retryableOnce, detail: selection.locale.identifier(.bcp47)
                    )
            }
            try ensurePreparationCurrent(token)
            analyzerFormat = format
            timescale = Self.safeTimescale(format.sampleRate)

            let (inputStream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(
                bufferingPolicy: .bufferingOldest(12))
            inputContinuation = continuation

            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .userInitiated, modelRetention: .lingering)
            )
            self.analyzer = analyzer
            try await analyzer.prepareToAnalyze(in: format)
            try ensurePreparationCurrent(token)

            switch selection {
            case .speech(let transcriber, _):
                resultTask = consumeResults(transcriber.results, generation: generation) {
                    TranscriptionUpdate(
                        text: String($0.text.characters),
                        range: $0.range,
                        finalizationTime: $0.resultsFinalizationTime,
                        isFinal: $0.isFinal
                    )
                }
            case .dictation(let transcriber, _):
                resultTask = consumeResults(transcriber.results, generation: generation) {
                    TranscriptionUpdate(
                        text: String($0.text.characters),
                        range: $0.range,
                        finalizationTime: $0.resultsFinalizationTime,
                        isFinal: $0.isFinal
                    )
                }
            }

            try await analyzer.start(inputSequence: inputStream)
            try ensurePreparationCurrent(token)
            preparationInFlight = false
            preparationWatchdog?.cancel()
            preparationWatchdog = nil
            diagnostics.lifecycle("speech prepared generation=\(generation) engine=\(selection.kind.rawValue)")
            return prepared
        } catch is CancellationError {
            await cancelInternal(expectedToken: token)
            throw CancellationError()
        } catch {
            guard preparationToken == token else { throw CancellationError() }
            let knownFailure = (error as? MacSTTFailure) ?? preparationFailure ?? pendingFailure
            await cancelInternal(expectedToken: token)
            if let knownFailure { throw knownFailure }
            throw failure(
                code: "SPEECH_PREPARATION_FAILED", domain: .speech, stage: "prepare",
                recoverability: .retryableOnce, detail: error.localizedDescription
            )
        }
    }

    public func startCapture(deviceUID: String?) throws {
        guard let driver = captureDriver, analyzer != nil, analyzerFormat != nil, captureTask == nil,
              !preparationInFlight, cancellationTask == nil, finishingToken == nil,
              acceptingResults else {
            throw failure(
                code: "SESSION_NOT_PREPARED", domain: .invariant, stage: "capture-start",
                recoverability: .terminalForSession, detail: nil
            )
        }

        let stream = try driver.start(deviceUID: deviceUID)
        captureDriver = driver
        let currentGeneration = generation
        captureTask = Task { [weak self] in
            do {
                for try await packet in stream {
                    defer { packet.release() }
                    try Task.checkCancellation()
                    await self?.ingest(packet, generation: currentGeneration)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.recordCaptureFailure(error, generation: currentGeneration)
            }
        }
        diagnostics.lifecycle("capture started generation=\(generation)")
    }

    public func finish() async throws -> SpeechCompletion {
        guard let analyzer, let preparation, !preparationInFlight,
              cancellationTask == nil, finishingToken == nil else {
            throw failure(
                code: "SESSION_NOT_ACTIVE", domain: .invariant, stage: "finish",
                recoverability: .terminalForSession, detail: nil
            )
        }

        let token = preparationToken
        finishingToken = token
        defer { if finishingToken == token { finishingToken = nil } }
        do {
            try ensureFinishingCurrent(token)
            captureDriver?.stop()
            if let captureTask { await captureTask.value }
            try ensureFinishingCurrent(token)
            if let pendingFailure { throw pendingFailure }

            inputContinuation?.finish()
            startFinalizationWatchdog(token: token)
            defer {
                if preparationToken == token {
                    finalizationWatchdog?.cancel()
                    finalizationWatchdog = nil
                }
            }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try ensureFinishingCurrent(token)
            if let resultTask {
                do {
                    try await resultTask.value
                    try ensureFinishingCurrent(token)
                } catch is CancellationError {
                    throw failure(code: "SPEECH_RESULT_DRAIN_CANCELLED", domain: .speech, stage: "result-drain", recoverability: .terminalForSession, detail: nil)
                } catch {
                    try ensureFinishingCurrent(token)
                    if let pendingFailure { throw pendingFailure }
                    throw error
                }
            }
            if let pendingFailure { throw pendingFailure }
            guard let finalAssembler = self.assembler else {
                throw failure(
                    code: "TRANSCRIPT_ASSEMBLER_MISSING", domain: .invariant, stage: "finalize",
                    recoverability: .terminalForSession, detail: nil
                )
            }
            let frozen: FrozenTranscript
            do {
                frozen = try finalAssembler.freeze()
            } catch {
                // SpeechTranscriber can publish a final range whose time window
                // overlaps an earlier range after progressive revisions. Keep
                // the bounded live preview usable when the strict range model
                // cannot be materialized, while retaining an explicit diagnostic
                // that the range evidence was not complete.
                guard let recovered = currentTranscript(),
                      !recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw error
                }
                diagnostics.failure(
                    code: "TRANSCRIPT_RANGE_FREEZE_FALLBACK",
                    stage: "finalize",
                    detail: Self.transcriptFreezeErrorCode(error)
                )
                frozen = FrozenTranscript(raw: recovered, segments: [])
            }
            let completion = SpeechCompletion(preparation: preparation, transcript: frozen)
            cleanup()
            diagnostics.lifecycle(
                "speech finalized generation=\(generation) segments=\(frozen.segments.count)"
            )
            return completion
        } catch {
            guard preparationToken == token else { throw CancellationError() }
            let preserved = currentTranscript()
            let preservedFailure = pendingFailure
            await cancelInternal(expectedToken: token)
            if preparationToken == token { recoveryTranscript = preserved }
            if let preservedFailure { throw preservedFailure }
            if let typed = error as? MacSTTFailure { throw typed }
            if error is CancellationError {
                throw failure(
                    code: "SPEECH_RESULT_DRAIN_CANCELLED", domain: .speech, stage: "result-drain",
                    recoverability: .terminalForSession, detail: nil
                )
            }
            throw failure(
                code: "SPEECH_FINALIZATION_FAILED", domain: .speech, stage: "finalize",
                recoverability: .terminalForSession, detail: error.localizedDescription
            )
        }
    }

    /// Returns the best transcript currently owned by this session, including a snapshot
    /// retained across finish failure cleanup. A complete range-based snapshot is preferred;
    /// the bounded visible tail is used only when volatile overlapping ranges cannot freeze.
    public func availableTranscript() async -> String? {
        currentTranscript() ?? recoveryTranscript
    }

    public func cancel() async {
        await cancelInternal()
    }

    private func nextPreparationToken() -> UInt64 {
        preparationToken = preparationToken == .max ? 1 : preparationToken + 1
        return preparationToken
    }

    private func ensurePreparationCurrent(_ token: UInt64) throws {
        guard preparationToken == token else { throw CancellationError() }
        if let preparationFailure { throw preparationFailure }
        try Task.checkCancellation()
        guard preparationInFlight, cancellationTask == nil else {
            throw CancellationError()
        }
    }

    private func ensureFinishingCurrent(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard preparationToken == token, finishingToken == token, cancellationTask == nil else {
            throw CancellationError()
        }
    }

    private func resolveEngine(for locale: Locale) async -> EngineSelection? {
        if SpeechTranscriber.isAvailable,
           let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: resolved, preset: .timeIndexedProgressiveTranscription)
            return .speech(transcriber, resolved)
        }

        if let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: resolved, preset: .progressiveLongDictation)
            return .dictation(transcriber, resolved)
        }
        return nil
    }

    private func startPreparationWatchdog(token: UInt64, generation: UInt64) {
        preparationWatchdog?.cancel()
        let timeout = preparationTimeout
        preparationWatchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.handlePreparationTimeout(token: token, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func handlePreparationTimeout(token: UInt64, generation: UInt64) async {
        guard preparationInFlight, preparationToken == token, self.generation == generation,
              pendingFailure == nil
        else { return }

        let timeout = failure(
            code: "SPEECH_PREPARATION_TIMEOUT", domain: .speech, stage: "prepare",
            recoverability: .retryableOnce, detail: nil
        )
        preparationFailure = timeout
        recordFailure(timeout)
        preparationInFlight = false
        preparationWatchdog = nil
        captureDriver?.cancel()
        captureTask?.cancel()
        inputContinuation?.finish()
        resultTask?.cancel()
        if let analyzer { await analyzer.cancelAndFinishNow() }
    }

    private func startFinalizationWatchdog(token: UInt64) {
        finalizationWatchdog?.cancel()
        finalizationWatchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.finalizationTimeout)
                guard !Task.isCancelled else { return }
                await self?.handleFinalizationTimeout(token: token)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func handleFinalizationTimeout(token: UInt64) async {
        guard preparationToken == token, finishingToken == token, cancellationTask == nil else { return }
        recordFailure(failure(
            code: "SPEECH_FINALIZATION_TIMEOUT", domain: .speech, stage: "finalize",
            recoverability: .terminalForSession, detail: nil
        ))
        await analyzer?.cancelAndFinishNow()
    }

    private func ingest(_ packet: CapturedAudioBuffer, generation incomingGeneration: UInt64) {
        guard incomingGeneration == generation, acceptingResults,
              let analyzerFormat, let inputContinuation
        else { return }

        do {
            let converted = try converter.convert(packet.buffer, to: analyzerFormat)
            switch inputContinuation.yield(AnalyzerInput(buffer: converted)) {
            case .enqueued:
                meterPacketCounter = meterPacketCounter == .max ? 1 : meterPacketCounter + 1
                if meterPacketCounter.isMultiple(of: 3) {
                    eventSink?(.level(generation: generation, value: Self.normalizedLevel(converted)))
                }
            case .dropped:
                recordFailure(failure(
                    code: "ANALYZER_INPUT_OVERFLOW", domain: .speech, stage: "analyzer-input",
                    recoverability: .terminalForSession, detail: nil
                ))
            case .terminated:
                if pendingFailure == nil, acceptingResults {
                    recordFailure(failure(
                        code: "ANALYZER_INPUT_TERMINATED", domain: .speech, stage: "analyzer-input",
                        recoverability: .terminalForSession, detail: nil
                    ))
                }
            @unknown default:
                recordFailure(failure(
                    code: "ANALYZER_INPUT_UNKNOWN", domain: .speech, stage: "analyzer-input",
                    recoverability: .terminalForSession, detail: nil
                ))
            }
        } catch {
            recordCaptureFailure(error, generation: incomingGeneration)
        }
    }

    private func accept(
        text: String,
        range: CMTimeRange,
        finalizationTime: CMTime,
        isFinal: Bool,
        generation incomingGeneration: UInt64
    ) {
        guard acceptingResults, incomingGeneration == generation, var assembler else { return }
        let start = Self.samples(range.start, timescale: timescale)
        let end = Self.samples(CMTimeRangeGetEnd(range), timescale: timescale)
        guard start >= 0, end >= start else {
            recordFailure(failure(
                code: "TRANSCRIPT_RANGE_INVALID", domain: .speech, stage: "result",
                recoverability: .terminalForSession, detail: nil
            ))
            return
        }
        let key = SegmentKey(startSample: start, durationSamples: end - start)
        let revision = revisions[key, default: 0]
        guard revision != .max else {
            recordFailure(failure(
                code: "TRANSCRIPT_REVISION_OVERFLOW", domain: .invariant, stage: "result",
                recoverability: .terminalForSession, detail: nil
            ))
            return
        }
        do {
            let accepted = try assembler.apply(TranscriptSegment(
                generation: incomingGeneration,
                startSample: key.startSample,
                durationSamples: key.durationSamples,
                revision: revision,
                isFinal: isFinal,
                text: text
            ))
            let finalizedThrough = Self.samples(finalizationTime, timescale: timescale)
            if finalizedThrough >= 0 { assembler.finalize(throughSample: finalizedThrough) }
            self.assembler = assembler
            // Burn the revision only once the assembler has taken the segment, so
            // a rejected or throwing apply does not leave a hole in the sequence.
            revisions[key] = revision + 1
            guard accepted else { return }
            let visible = isFinal
                ? preview.appendFinal(text, key: key)
                : preview.replace(with: text, key: key)
            if isFinal {
                recoveryPreview.appendFinal(text, key: key)
            } else {
                recoveryPreview.replace(with: text, key: key)
            }
            eventSink?(.preview(generation: incomingGeneration, text: visible))
        } catch {
            recordFailure(failure(
                code: "TRANSCRIPT_ASSEMBLY_FAILED", domain: .speech, stage: "result",
                recoverability: .terminalForSession, detail: String(describing: error)
            ))
        }
    }

    private func recordCaptureFailure(_ error: Error, generation incomingGeneration: UInt64) {
        guard incomingGeneration == generation else { return }
        if let typed = error as? MacSTTFailure { recordFailure(typed) }
        else {
            recordFailure(failure(
                code: "AUDIO_CAPTURE_FAILED", domain: .audio, stage: "capture",
                recoverability: .terminalForSession, detail: error.localizedDescription
            ))
        }
    }

    private func recordSpeechFailure(_ error: Error, generation incomingGeneration: UInt64) {
        guard incomingGeneration == generation, !(error is CancellationError) else { return }
        recordFailure(failure(
            code: "SPEECH_ANALYSIS_FAILED", domain: .speech, stage: "analysis",
            recoverability: .terminalForSession, detail: error.localizedDescription
        ))
    }

    private func recordFailure(_ error: MacSTTFailure) {
        guard acceptingResults, pendingFailure == nil else { return }
        pendingFailure = error
        acceptingResults = false
        diagnostics.failure(code: error.code, stage: error.stage, detail: error.redactedDetail)
        eventSink?(.failure(generation: generation, error))
    }

    private func cancelInternal(expectedToken: UInt64? = nil) async {
        if let expectedToken, preparationToken != expectedToken { return }
        if let cancellationTask {
            await cancellationTask.value
            return
        }
        // Revoke admission synchronously before the owned task can suspend.
        preparationInFlight = false
        acceptingResults = false
        preparationWatchdog?.cancel()
        preparationWatchdog = nil
        let task = Task { await self.drainAndCleanup() }
        cancellationTask = task
        await task.value
        cancellationTask = nil
    }

    private func drainAndCleanup() async {
        captureDriver?.cancel()
        captureTask?.cancel()
        if let captureTask { await captureTask.value }
        inputContinuation?.finish()
        if let analyzer { await analyzer.cancelAndFinishNow() }
        resultTask?.cancel()
        if let resultTask { _ = await resultTask.result }
        finalizationWatchdog?.cancel()
        finalizationWatchdog = nil
        cleanup()
    }

    private func cleanup() {
        finishingToken = nil
        preparationInFlight = false
        captureDriver = nil
        captureTask = nil
        inputContinuation = nil
        resultTask = nil
        analyzer = nil
        selectedEngine = nil
        analyzerFormat = nil
        assembler = nil
        recoveryTranscript = nil
        revisions.removeAll(keepingCapacity: false)
        preview.reset()
        recoveryPreview.reset()
        pendingFailure = nil
        eventSink = nil
        acceptingResults = false
        meterPacketCounter = 0
        preparationWatchdog?.cancel()
        preparationWatchdog = nil
        finalizationWatchdog?.cancel()
        finalizationWatchdog = nil
        converter.reset()
    }

    private func currentTranscript() -> String? {
        let result = TranscriptRecovery.capture(
            assembler: assembler,
            preview: recoveryPreview.current
        )
        if let freezeError = result.freezeError {
            diagnostics.failure(
                code: "PARTIAL_TRANSCRIPT_FREEZE_FAILED",
                stage: "failure-preservation",
                detail: freezeError
            )
        }
        return result.transcript
    }

    private func consumeResults<Results: AsyncSequence>(
        _ results: Results,
        generation incomingGeneration: UInt64,
        project: @escaping @Sendable (Results.Element) -> TranscriptionUpdate
    ) -> Task<Void, Error> where Results: Sendable, Results.Element: Sendable {
        Task { [weak self] in
            do {
                for try await result in results {
                    try Task.checkCancellation()
                    let update = project(result)
                    // The sequence remains bound to the generation that created it.
                    await self?.accept(
                        text: update.text,
                        range: update.range,
                        finalizationTime: update.finalizationTime,
                        isFinal: update.isFinal,
                        generation: incomingGeneration
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await self?.recordSpeechFailure(error, generation: incomingGeneration)
                throw error
            }
        }
    }

    private func failure(
        code: String,
        domain: FailureDomain,
        stage: String,
        recoverability: Recoverability,
        detail: String?
    ) -> MacSTTFailure {
        MacSTTFailure(
            code: code, domain: domain, stage: stage, recoverability: recoverability,
            messageKey: code.lowercased(), redactedDetail: detail
        )
    }

    private static func transcriptFreezeErrorCode(_ error: Error) -> String {
        switch error as? ContractError {
        case .invalidSegmentRange: "invalid-segment-range"
        case .transcriptFinalConflict: "transcript-final-conflict"
        case .transcriptFinalMutation: "transcript-final-mutation"
        case .overlappingFinalSegments: "overlapping-final-segments"
        case .nonFinalSegmentAtFreeze: "non-final-segment-at-freeze"
        case .transcriptTooLarge: "transcript-too-large"
        default: "unknown"
        }
    }

    private static func safeTimescale(_ sampleRate: Double) -> CMTimeScale {
        let rounded = Int64(sampleRate.rounded())
        return CMTimeScale(max(1, min(rounded, Int64(Int32.max))))
    }

    private static func samples(_ time: CMTime, timescale: CMTimeScale) -> Int64 {
        guard time.isValid, !time.isIndefinite else { return -1 }
        return CMTimeConvertScale(time, timescale: timescale, method: .roundTowardZero).value
    }

    private static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return 0 }
        let sampleCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0
        for channel in 0..<channelCount {
            var channelSum: Float = 0
            vDSP_svesq(channels[channel], 1, &channelSum, vDSP_Length(sampleCount))
            sum += channelSum
        }
        let rms = sqrt(sum / Float(max(1, sampleCount * channelCount)))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (decibels + 55) / 55))
    }
}

private enum EngineSelection {
    case speech(SpeechTranscriber, Locale)
    case dictation(DictationTranscriber, Locale)

    var locale: Locale {
        switch self {
        case .speech(_, let locale), .dictation(_, let locale): locale
        }
    }
    var kind: EngineKind {
        switch self {
        case .speech: .speechTranscriber
        case .dictation: .dictationTranscriber
        }
    }
    var modules: [any SpeechModule] {
        switch self {
        case .speech(let transcriber, _): [transcriber]
        case .dictation(let transcriber, _): [transcriber]
        }
    }
}
