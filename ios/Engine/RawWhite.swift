import Foundation

/// P558 (Parameters.clipPlateau / clipWhiteToPlateau, BlockScan's samples): a stream that clips under its declared white leaves its
/// blown areas short of 1 - not flagged clipped, the merge's highlight path off (its ultrashort frames unused), the white balance
/// tinting them. The iPad's 14-bit buffer clips near 15930 while the DNG's white x 4 is 16380. The reference frame's clip plateau,
/// when under the white by more than its tolerance and above twice the black, is the shot's white (scam_dev "raw_white_plateau 0":
/// as before).
enum RawWhite {
    /// BlockScan.of (block 1): per CFA site, 32 x 32 blocks of the site's plane, every fourth row and column of each
    static func histogram(_ raw: Data, width: Int, height: Int) -> (values: [Int], counted: Int) {
        guard raw.count >= width * height * 2 else { return ([Int](repeating: 0, count: 65536), 0) }
        return raw.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            histogram(p.baseAddress!, rowBytes: width * 2, width: width, height: height)
        }
    }

    static func histogram(_ base: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int) -> (values: [Int], counted: Int) {
        let bs = 32, bw = width / 2 / bs, bh = height / 2 / bs
        var values = [Int](repeating: 0, count: 65536), counted = 0
        guard bw > 0, bh > 0 else { return (values, 0) }
        for c in 0..<4 {
            let ox = c % 2, oy = c / 2
            for by in 0..<bh {
                for y in stride(from: 0, to: bs, by: 4) {
                    let row = (base + ((by * bs + y) * 2 + oy) * rowBytes).assumingMemoryBound(to: UInt16.self)
                    for bx in 0..<bw {
                        let at = bx * bs * 2 + ox
                        for x in stride(from: 0, to: bs, by: 4) { values[Int(UInt16(littleEndian: row[at + x * 2]))] += 1 }
                        counted += bs / 4
                    }
                }
            }
        }
        return (values, counted)
    }

    /// The white of a frame: `white` lowered to the frame's clip plateau (clipWhiteToPlateau), with the plateau for the log
    static func of(_ white: Float, black: [Float], histogram h: (values: [Int], counted: Int)) -> (white: Float, plateau: Int) {
        guard enabled else { return (white, 0) }
        let plateau = clipPlateau(h.values, h.counted)
        return (clipped(white: white, black: black, plateau: plateau) ?? white, plateau)
    }

    /// Parameters.clipPlateau: at least 0.2 % of the samples (16 at least) within 0.1 % (2 DN at least) of the top value (the 4th
    /// largest sample), and the band of three times that width under it holding fewer than half as many; 0: no clip
    static func clipPlateau(_ values: [Int], _ n: Int) -> Int {
        guard n >= 16 else { return 0 }
        var top = 0, seen = 0
        var v = values.count - 1
        while v > 0 {
            seen += values[v]
            if seen >= 4 { top = v; break }
            v -= 1
        }
        guard top > 0 else { return 0 }
        let tol = max(2, top / 1000)
        var at = 0, below = 0
        for i in max(0, top - 4 * tol)...min(values.count - 1, top + tol) {
            if i >= top - tol { at += values[i] } else { below += values[i] }
        }
        return at >= max(16, n / 500) && 2 * below < at ? top : 0
    }

    static var enabled: Bool { ScamDevFile.snapshot()["raw_white_plateau"].flatMap { Double($0) }.map { $0 > 0 } ?? true }

    /// Parameters.clipWhiteToPlateau: the new white (the plateau), nil to keep `white`
    static func clipped(white: Float, black: [Float], plateau: Int) -> Float? {
        guard plateau > 0 else { return nil }
        let blackMax = black.max() ?? 0
        let w = Int(white)
        let tol = max(2, w / 1000)
        if plateau >= w - tol || Float(plateau) <= 2 * blackMax { return nil }
        return Float(plateau)
    }
}
