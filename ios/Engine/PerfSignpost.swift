import os

/// os_signpost intervals of the stages speed work measures (Instruments: os_signpost, subsystem com.scamera.ios, category PERF):
/// session start, burst capture, burst processing (NCH, merge + post, encode), library save, GPU warm-up.
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.scamera.ios", category: "PERF")

    @inline(__always)
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    @inline(__always)
    static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try await body()
    }
}
