import XCTest
@testable import SCAMERA

/// PERF_PLAN.md's XCTest metrics: the merge of the bundled real burst crop (GPU through ScamGL) and the CPU passes every SHDR shot
/// runs over a 12 MP frame (the clip plateau histogram, the black floor, the plan's clip / shadow shares). The baselines are the
/// numbers these print in CI; a change is compared against them, not against a fixed limit.
final class PerfTests: XCTestCase {
    private static let width = 4032, height = 3024

    /// A 12 MP 14-bit Bayer frame: a ramp over the black with a clipped band, the iPad buffer's levels (black 2112, clip 15930)
    private static let frame: Data = {
        var d = Data(count: width * height * 2)
        d.withUnsafeMutableBytes { p in
            let v = p.bindMemory(to: UInt16.self)
            for y in 0..<height {
                for x in 0..<width {
                    v[y * width + x] = y < height / 5 ? 15930 : UInt16(2112 + (x * 12000 / width) + (x ^ y) % 23)
                }
            }
        }
        return d
    }()

    private var metrics: [XCTMetric] { [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()] }

    func testMergeOfBurstCrop() throws {
        let bundle = Bundle(for: PerfTests.self)
        guard let burst = bundle.path(forResource: "n124513b", ofType: "nch"),
              let tuningPath = bundle.path(forResource: "replay_tuning", ofType: "txt") else {
            throw XCTSkip("burst crop not bundled (CI adds it)")
        }
        let tuning = try String(contentsOfFile: tuningPath, encoding: .utf8)
        _ = try SCAMMerge.mergeBurst(atPath: burst, tuning: tuning) // the programs compiled once, outside the measure
        measure(metrics: metrics) {
            _ = try? SCAMMerge.mergeBurst(atPath: burst, tuning: tuning)
        }
    }

    func testClipPlateauHistogram() {
        let frame = Self.frame
        measure(metrics: metrics) {
            let h = RawWhite.histogram(frame, width: Self.width, height: Self.height)
            XCTAssertEqual(RawWhite.clipPlateau(h.values, h.counted), 15930)
        }
    }

    func testFrameShares() {
        let frame = Self.frame
        measure(metrics: metrics) {
            let s = FrameMeasure.shares(frame, width: Self.width, height: Self.height, black: [2112, 2112, 2112, 2112], white: 15930)
            XCTAssertGreaterThan(s.clip, 0.15)
        }
    }
}
