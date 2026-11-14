import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The camera's own photo (the front lens, a lens without Bayer RAW, a flash shot without a RAW frame, SHDR off) as the settings
/// write a photo, as BurstProcessor's tail writes an SHDR one:
/// - «Формат фото» and its quality: the camera encodes it so already (PhotoCapture asks for the codec of pref_photo_format at
///   pref_jpeg_quality / pref_heic_quality), and a photo that needs nothing more is kept as the camera encoded it (one lossy
///   generation, the camera's own metadata and HDR gain map);
/// - «16:9» (pref_wide169_key): the upright photo's centred 16:9 (Wide169: the long side whole, the short side long x 9 / 16);
/// - the watermark (PhotoWatermark.applyRecorded, its record at the end of the file, P633);
/// - a codec the camera could not give (HEIC asked of a camera without HEVC): written in the asked one.
/// Any of these decodes the photo upright, crops it, draws the watermark and writes it again (ShotProcessor.encode, «Формат фото»
/// with «Цветовое пространство» and «HEIC 10 бит», the camera's metadata kept); the camera's gain map is not carried into such a
/// rewrite (logged with «HDR-фото» on). Anything that fails keeps the camera's photo (logged).
enum CameraPhotoFinish {
    /// `photo` with its processed photo finished; the report gets its lines
    static func finish(_ photo: CapturedPhoto, shotTime: Date) -> CapturedPhoto {
        guard let data = photo.processed, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return photo }
        var result = photo
        let format = PhotoEncoding.current()
        let sourceType = CGImageSourceGetType(source) as String? ?? photo.processedUTI
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        guard width > 0, height > 0 else { return photo }
        // the upright size (EXIF orientations 5 .. 8 turn the picture by 90°)
        let turned = (5...8).contains(orientation)
        let uw = turned ? height : width, uh = turned ? width : height
        let crop = Wide169.on ? wideCrop(uw, uh) : nil
        let watermark = PhotoWatermark.on()
        let recode = sourceType != format.type.identifier
        guard crop != nil || watermark || recode else {
            result.report.append("camera photo: kept as the camera encoded it (\(format.type == .heic ? "HEIC" : "JPEG") "
                                 + "\(Int((format.quality * 100).rounded())))")
            return result
        }
        let started = Date()
        var lines: [String] = []
        do {
            let area = crop ?? CGRect(x: 0, y: 0, width: uw, height: uh)
            let cw = Int(area.width), ch = Int(area.height)
            guard var rgba = upright(source, maxSide: max(width, height), area: area, uw: uw, uh: uh, format: format) else {
                throw EngineError.decode("the camera's photo could not be decoded")
            }
            if let crop { lines.append("camera photo: 16:9 (P118) \(Int(crop.width))x\(Int(crop.height)) of \(uw)x\(uh)") }
            var metadata = properties
            // the pixels are upright now and in the photo's colour space (the encoder writes orientation 1 and the dimensions)
            for key in [kCGImagePropertyOrientation, kCGImagePropertyProfileName, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] {
                metadata[key as String] = nil
            }
            if var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                exif[kCGImagePropertyExifColorSpace as String] = format.displayP3 ? 65535 : 1
                metadata[kCGImagePropertyExifDictionary as String] = exif
            }
            var record: SCAMWatermarkRecord?
            if watermark {
                record = PhotoWatermark.applyRecorded(&rgba, width: cw, height: ch, metadata: properties, dng: nil, shotTime: shotTime,
                                                      log: { lines.append($0) }).record
            }
            var file = try ShotProcessor.encode(rgba: rgba, width: cw, height: ch, metadata: metadata, orientation: 1, format: format,
                                                gainMap: nil, log: { lines.append($0) })
            if let record { file = PhotoWatermark.appendRecord(record, to: file, log: { lines.append($0) }) }
            if StoredPrefs.bool("pref_ultrahdr_key", false) {
                lines.append("camera photo: rewritten, the camera's HDR gain map is not carried (SDR)")
            }
            lines.append("camera photo: written as \(format.type == .heic ? "HEIC" : "JPEG") \(Int((format.quality * 100).rounded())) "
                         + "\(cw)x\(ch), \(file.count) bytes in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            result.processed = file
            result.processedUTI = format.type.identifier
        } catch {
            lines.append("camera photo: kept as the camera encoded it, the rewrite failed: \(error.localizedDescription)")
        }
        result.report += lines
        return result
    }

    /// Wide169 on the upright photo: the long side whole, the short side long x 9 / 16 (even), centred; nil when the photo is
    /// already as wide
    static func wideCrop(_ w: Int, _ h: Int) -> CGRect? {
        let long = max(w, h), short = min(w, h)
        let keep = (long * 9 / 16) & ~1
        guard keep > 0, keep < short else { return nil }
        let first = ((short - keep) / 2) & ~1
        return w >= h ? CGRect(x: 0, y: first, width: w, height: keep) : CGRect(x: first, y: 0, width: keep, height: h)
    }

    /// The photo decoded upright (ImageIO's transform of its orientation, the whole size), `area` of it (top-left origin) drawn into
    /// RGBA8 rows top-down in the photo's colour space
    private static func upright(_ source: CGImageSource, maxSide: Int, area: CGRect, uw: Int, uh: Int,
                                format: PhotoEncoding.Format) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = PhotoEncoding.colorSpace(format) else { return nil }
        let cw = Int(area.width), ch = Int(area.height)
        guard cw > 0, ch > 0 else { return nil }
        var rgba = Data(count: cw * ch * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            // pixel for pixel (ImageIO gives the whole upright size); a different size would be scaled to it
            context.interpolationQuality = image.width == uw && image.height == uh ? .none : .high
            // CoreGraphics' origin is the bottom left: the image's top edge goes to the context's top plus the area's first row
            context.draw(image, in: CGRect(x: -area.minX, y: CGFloat(ch) + area.minY - CGFloat(uh), width: CGFloat(uw), height: CGFloat(uh)))
            return true
        }
        return drawn ? rgba : nil
    }
}
