import XCTest
@testable import Nemo

final class DiarizerTests: XCTestCase {

    private func fp(_ values: [Float]) -> VoiceFingerprint {
        VoiceFingerprint(features: values, voicedSeconds: 1.0)
    }
    private let a: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 7.5]
    private var b: [Float] { a.map { $0 + 8 } }   // clearly different voice

    func testIdenticalFingerprintsClusterTogether() {
        let d = SpeakerDiarizer(threshold: 1.5)
        let id1 = d.assign(fp(a))
        let id2 = d.assign(fp(a))
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(d.profiles.count, 1)
    }

    func testLenientThresholdMergesDistinctVoices() {
        let d = SpeakerDiarizer(threshold: 1000)
        XCTAssertEqual(d.assign(fp(a)), d.assign(fp(b)))
        XCTAssertEqual(d.profiles.count, 1)
    }

    func testStrictThresholdSplitsDistinctVoices() {
        let d = SpeakerDiarizer(threshold: 0.01)
        let id1 = d.assign(fp(a))
        let id2 = d.assign(fp(b))
        XCTAssertNotEqual(id1, id2)
        XCTAssertEqual(d.profiles.count, 2)
    }

    func testSeedRestoresProfilesAndContinuesIds() {
        let d = SpeakerDiarizer(threshold: 0.01)
        d.seed([(id: 5, centroid: a, count: 3)])
        XCTAssertEqual(d.profiles.count, 1)
        XCTAssertEqual(d.profiles.first?.id, 5)
        // A clearly-different voice under a strict threshold founds a new speaker numbered 6.
        XCTAssertEqual(d.assign(fp(b)), 6)
    }

    func testCentroidIsRunningMean() {
        let d = SpeakerDiarizer(threshold: 1000)   // force both into one cluster
        _ = d.assign(fp(a))
        _ = d.assign(fp(b))
        let centroid = d.profiles[0].centroid
        // Mean of a and b is a + 4 on every dimension.
        for k in 0..<a.count {
            XCTAssertEqual(centroid[k], (a[k] + b[k]) / 2, accuracy: 1e-3)
        }
    }
}
