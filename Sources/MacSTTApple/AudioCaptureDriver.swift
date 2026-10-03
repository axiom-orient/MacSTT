@preconcurrency import AVFoundation
import Foundation
import MacSTTCore
import Synchronization

enum AudioBufferPoolError: Error, Equatable {
    case exhausted
    case sourceTooLarge
    case layoutMismatch
    case dataMissing
}

final class AudioBufferPool: @unchecked Sendable {
    private let buffers: [AVAudioPCMBuffer]
    private let available: Atomic<UInt64>

    init?(format: AVAudioFormat, frameCapacity: AVAudioFrameCount, capacity: Int) {
        let count = max(4, min(capacity, 48))
        var allocated: [AVAudioPCMBuffer] = []
        allocated.reserveCapacity(count)
        for _ in 0..<count {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                return nil
            }
            allocated.append(buffer)
        }
        buffers = allocated
        available = Atomic((UInt64(1) << UInt64(count)) - 1)
    }

    func copy(_ source: AVAudioPCMBuffer) throws -> CapturedAudioBuffer {
        try copy(format: source.format, frameLength: source.frameLength,
            sourceBuffers: UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList))
    }

    @available(macOS 27.0, *)
    func copy(_ source: AVReadOnlyAudioPCMBuffer) throws -> CapturedAudioBuffer {
        try source.withUnsafeAudioBufferList { list in
            // This view is read only; writes go exclusively to the leased pool buffer.
            try copy(format: source.format, frameLength: AVAudioFrameCount(source.frameLength),
                sourceBuffers: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)))
        }
    }

    private func copy(format: AVAudioFormat, frameLength: AVAudioFrameCount,
        sourceBuffers: UnsafeMutableAudioBufferListPointer) throws -> CapturedAudioBuffer {
        guard let index = acquire() else { throw AudioBufferPoolError.exhausted }
        do {
            let destination = buffers[index]
            guard frameLength <= destination.frameCapacity else {
                throw AudioBufferPoolError.sourceTooLarge
            }
            guard destination.format.isEqual(format) else { throw AudioBufferPoolError.layoutMismatch }
            destination.frameLength = frameLength
            let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
            guard sourceBuffers.count == destinationBuffers.count else {
                throw AudioBufferPoolError.layoutMismatch
            }
            for bufferIndex in sourceBuffers.indices {
                guard let sourceData = sourceBuffers[bufferIndex].mData,
                      let destinationData = destinationBuffers[bufferIndex].mData
                else { throw AudioBufferPoolError.dataMissing }
                let byteCount = Int(sourceBuffers[bufferIndex].mDataByteSize)
                guard byteCount <= Int(destinationBuffers[bufferIndex].mDataByteSize) else {
                    throw AudioBufferPoolError.sourceTooLarge
                }
                memcpy(destinationData, sourceData, byteCount)
                destinationBuffers[bufferIndex].mDataByteSize = sourceBuffers[bufferIndex].mDataByteSize
            }
            return CapturedAudioBuffer(buffer: destination, slot: index, pool: self)
        } catch {
            release(index)
            throw error
        }
    }

    func release(_ index: Int) {
        _ = available.bitwiseOr(UInt64(1) << UInt64(index), ordering: .releasing)
    }

    private func acquire() -> Int? {
        while true {
            let observed = available.load(ordering: .acquiring)
            guard observed != 0 else { return nil }
            let index = observed.trailingZeroBitCount
            let desired = observed & ~(UInt64(1) << UInt64(index))
            let result = available.compareExchange(
                expected: observed,
                desired: desired,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { return index }
        }
    }
}

private final class AudioBufferLease: Sendable {
    private let slot: Int
    private let pool: AudioBufferPool
    private let released = Atomic(false)

    init(slot: Int, pool: AudioBufferPool) {
        self.slot = slot
        self.pool = pool
    }
    func release() {
        if released.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged {
            pool.release(slot)
        }
    }
    deinit { release() }
}

/// Copies share one pooled-buffer lease. Retain a packet while using its samples;
/// after release, no copy may use the buffer. The last packet copy also returns the lease.
public struct CapturedAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    private let lease: AudioBufferLease

    fileprivate init(buffer: AVAudioPCMBuffer, slot: Int, pool: AudioBufferPool) {
        self.buffer = buffer
        lease = AudioBufferLease(slot: slot, pool: pool)
    }

    /// Returns this shared lease once. Repeated calls from any packet copy have no effect.
    public func release() { lease.release() }
}

/// Owns tap-local state. AVAudioEngine invokes one tap callback serially; the
/// pool itself is lock-free because consumers release slots on another executor.
private final class AudioTapProcessor: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<CapturedAudioBuffer, Error>.Continuation
    private let pool: AudioBufferPool
    private let fail: @Sendable (Error) -> Void
    private var failed = false

    init(
        continuation: AsyncThrowingStream<CapturedAudioBuffer, Error>.Continuation,
        pool: AudioBufferPool,
        fail: @escaping @Sendable (Error) -> Void
    ) {
        self.continuation = continuation
        self.pool = pool
        self.fail = fail
    }

    @available(macOS 27.0, *)
    func receive(_ source: AVReadOnlyAudioPCMBuffer) {
        receivePacket { try pool.copy(source) }
    }

    func receive(_ source: AVAudioPCMBuffer) {
        receivePacket { try pool.copy(source) }
    }

    private func receivePacket(_ copy: () throws -> CapturedAudioBuffer) {
        guard !failed else { return }
        do {
            let packet = try copy()
            switch continuation.yield(packet) {
            case .enqueued:
                break
            case .dropped:
                packet.release()
                failed = true
                fail(Self.failure("AUDIO_INGRESS_OVERFLOW", stage: "capture"))
            case .terminated:
                packet.release()
                failed = true
            @unknown default:
                packet.release()
                failed = true
                fail(Self.failure("AUDIO_INGRESS_UNKNOWN", stage: "capture"))
            }
        } catch AudioBufferPoolError.exhausted {
            failed = true
            fail(Self.failure("AUDIO_INGRESS_OVERFLOW", stage: "capture"))
        } catch {
            failed = true
            fail(Self.failure("AUDIO_BUFFER_COPY_FAILED", stage: "capture"))
        }
    }

    private static func failure(_ code: String, stage: String) -> MacSTTFailure {
        MacSTTFailure(
            code: code,
            domain: .audio,
            stage: stage,
            recoverability: .terminalForSession,
            messageKey: code.lowercased()
        )
    }
}

public final class AudioCaptureDriver: @unchecked Sendable {
    // AVAudioEngine may deliver a hardware-sized callback larger than the
    // requested tap size. A slot that cannot hold one callback fails the session
    // on its very first packet, so the floor covers common 4,096 and 8,192-frame
    // buffers and the actual device buffer size raises it when the hardware asks
    // for more. The ceiling keeps the preallocated pool bounded.
    private static let minimumTapFrameCapacity: AVAudioFrameCount = 8_192
    private static let maximumTapFrameCapacity: AVAudioFrameCount = 32_768

    private let engine = AVAudioEngine()
    private let controlQueue = DispatchQueue(label: "dev.ax.macstt.capture.control")
    private let stateLock = NSLock()
    private enum CaptureState {
        case idle
        case running(UUID, AsyncThrowingStream<CapturedAudioBuffer, Error>.Continuation)
        case stopping
    }
    private var state = CaptureState.idle
    private var observer: NSObjectProtocol?

    public init() {}

    /// Configures the same AVAudioEngine that will later receive the tap and
    /// exposes the selected device's natural input format for SpeechAnalyzer's
    /// format negotiation. The engine is still not started at this point.
    public func inputFormat(deviceUID: String?) throws -> AVAudioFormat {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .idle = state else {
            throw failure("AUDIO_CAPTURE_ALREADY_RUNNING", stage: "input-format")
        }
        try AudioDeviceCatalog.configure(engine: engine, deviceUID: deviceUID)
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw failure("AUDIO_INPUT_FORMAT_INVALID", stage: "input-format", userAction: "사용 가능한 마이크가 없습니다. 마이크를 연결하고 시스템 설정의 사운드 → 입력에서 선택한 뒤 다시 말해 주세요.")
        }
        return format
    }

    public func start(
        deviceUID: String?,
        capacity: Int = 24
    ) throws -> AsyncThrowingStream<CapturedAudioBuffer, Error> {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .idle = state else {
            throw failure("AUDIO_CAPTURE_ALREADY_RUNNING", stage: "capture-start")
        }

        try AudioDeviceCatalog.configure(engine: engine, deviceUID: deviceUID)
        let captureID = UUID()
        let boundedCapacity = max(4, min(capacity, 48))
        let (stream, createdContinuation) = AsyncThrowingStream<CapturedAudioBuffer, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(boundedCapacity))

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            createdContinuation.finish(throwing: failure("AUDIO_INPUT_FORMAT_INVALID", stage: "capture-start"))
            throw failure("AUDIO_INPUT_FORMAT_INVALID", stage: "capture-start")
        }
        let tapFrameCapacity = try Self.tapFrameCapacity(for: input, sampleRate: format.sampleRate)
        guard let pool = AudioBufferPool(
            format: format,
            frameCapacity: tapFrameCapacity,
            capacity: boundedCapacity
        ) else {
            let error = failure("AUDIO_POOL_ALLOCATION_FAILED", stage: "capture-start")
            createdContinuation.finish(throwing: error)
            throw error
        }

        let processor = AudioTapProcessor(
            continuation: createdContinuation,
            pool: pool,
            fail: { [weak self] error in self?.failFromCallback(error, captureID: captureID) }
        )
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.failFromCallback(self.failure("AUDIO_DEVICE_CHANGED", stage: "capture"), captureID: captureID)
        }

        do {
            if #available(macOS 27.0, *) {
                try input.installAudioTap(onBus: 0, bufferSize: tapFrameCapacity, format: nil) { buffer, _ in
                    processor.receive(buffer)
                }
            } else {
                input.installTap(onBus: 0, bufferSize: tapFrameCapacity, format: nil) { buffer, _ in
                    processor.receive(buffer)
                }
            }
            engine.prepare()
            try engine.start()
            state = .running(captureID, createdContinuation)
            return stream
        } catch {
            input.removeTap(onBus: 0)
            removeObserver()
            let typed = failure(
                "AUDIO_CAPTURE_START_FAILED",
                stage: "capture-start",
                detail: error.localizedDescription
            )
            createdContinuation.finish(throwing: typed)
            throw typed
        }
    }

    public func stop() {
        finish(throwing: nil)
    }

    public func cancel() {
        finish(throwing: CancellationError())
    }

    private func failFromCallback(_ error: Error, captureID: UUID) {
        finish(throwing: error, expectedCaptureID: captureID)
    }

    /// Claims termination synchronously so the first caller wins, then performs
    /// the teardown on `controlQueue`. `AVAudioEngine.stop()` blocks until the
    /// render thread quiesces; running it inline would stall whichever executor
    /// called us — including a cooperative-pool thread, since the speech actor
    /// stops capture from its own isolation. Consumers observe completion
    /// through the finished stream, not through this call returning.
    private func finish(throwing error: Error?, expectedCaptureID: UUID? = nil) {
        stateLock.lock()
        guard case .running(let captureID, let continuation) = state,
              expectedCaptureID == nil || expectedCaptureID == captureID
        else {
            stateLock.unlock()
            return
        }
        state = .stopping
        stateLock.unlock()

        controlQueue.async { [self] in
            removeObserver()
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            stateLock.lock()
            state = .idle
            stateLock.unlock()
            if let error { continuation.finish(throwing: error) }
            else { continuation.finish() }
        }
    }

    private func removeObserver() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    /// Slot size for the preallocated pool, derived from the device's own buffer
    /// frame size so an aggregate or high-sample-rate interface that hands back
    /// more than the requested frames still fits in a slot.
    private static func tapFrameCapacity(for input: AVAudioInputNode, sampleRate: Double) throws -> AVAudioFrameCount {
        var frames: UInt32 = 0
        if let audioUnit = input.audioUnit {
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioUnitGetProperty(audioUnit, kAudioDevicePropertyBufferFrameSize,
                kAudioUnitScope_Global, 0, &frames, &size)
            if status != noErr { frames = 0 }
        }
        return try tapFrameCapacity(sampleRate: sampleRate, hardwareFrames: frames)
    }

    // SDK 27 requires a tap interval of 100–400 ms. Frame counts depend on the
    // device rate; a fixed 8192 frames violates this at 16 kHz and 96 kHz.
    static func tapFrameCapacity(sampleRate: Double, hardwareFrames: UInt32) throws -> AVAudioFrameCount {
        let minimumDuration = 0.1
        let maximumDuration = 0.4
        let lower = ceil(sampleRate * minimumDuration)
        let upper = min(floor(sampleRate * maximumDuration), Double(maximumTapFrameCapacity))
        guard sampleRate.isFinite, sampleRate > 0, lower >= 1, lower <= upper else {
            throw MacSTTFailure(code: "AUDIO_INPUT_FORMAT_INVALID", domain: .audio, stage: "capture-start",
                recoverability: .requiresUserAction, messageKey: "audio_input_format_invalid")
        }
        let preferred = max(Double(minimumTapFrameCapacity), Double(hardwareFrames) * 2)
        return AVAudioFrameCount(min(upper, max(lower, preferred)))
    }

    private func failure(_ code: String, stage: String, detail: String? = nil, userAction: String? = nil) -> MacSTTFailure {
        MacSTTFailure(
            code: code,
            domain: .audio,
            stage: stage,
            recoverability: code == "AUDIO_DEVICE_CHANGED" ? .retryableOnce : .terminalForSession,
            messageKey: code.lowercased(),
            redactedDetail: detail, userAction: userAction
        )
    }
}
