import XCTest
@testable import MacSTTCore

final class ContractTests: XCTestCase {
    func testFailureAndSegmentContractsRoundTrip() throws {
        let failure = MacSTTFailure(
            code: "SPEECH_ANALYSIS_FAILED",
            domain: .speech,
            stage: "analyze",
            recoverability: .terminalForSession,
            messageKey: "speech_analysis_failed",
            redactedDetail: "SpeechError"
        )
        let failureData = try JSONEncoder().encode(failure)
        XCTAssertEqual(try JSONDecoder().decode(MacSTTFailure.self, from: failureData), failure)

        let segment = TranscriptSegment(
            generation: 1, startSample: 0, durationSamples: 10,
            revision: 0, isFinal: true, text: "hello"
        )
        let segmentData = try JSONEncoder().encode(segment)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptSegment.self, from: segmentData), segment)
    }
}
