import SwiftUI
import XCTest
@testable import SCAMERA

/// The camera's layout at the screens it runs on (iPhone SE .. Pro Max, iPad mini .. iPad Pro 13, iPhone Duo folded and open),
/// rendered with ImageRenderer into PNGs for the CI artifact «ui-snapshots» (the preview layer itself renders empty). Not a
/// pixel test: the pictures are looked at when the layout changes (owner 2026-11-17: the look tray and the lens strip broke on the
/// iPad and the iPhone 15 Pro).
@MainActor
final class LayoutSnapshots: XCTestCase {
    struct Screen {
        let name: String
        let size: CGSize
        let regular: Bool
    }

    static let screens: [Screen] = [
        Screen(name: "iphone-se", size: CGSize(width: 375, height: 667), regular: false),
        Screen(name: "iphone-15-pro", size: CGSize(width: 393, height: 852), regular: false),
        Screen(name: "iphone-15-pro-max", size: CGSize(width: 430, height: 932), regular: false),
        // iPhone Duo: the outer 5.4" and the inner 7.6" folding display share the aspect ratio (apple.com/iphone-duo); the points
        // are estimated from the diagonals, both size classes for the inner one
        Screen(name: "iphone-duo-outer", size: CGSize(width: 375, height: 812), regular: false),
        Screen(name: "iphone-duo-inner-compact", size: CGSize(width: 528, height: 1143), regular: false),
        Screen(name: "iphone-duo-inner-regular", size: CGSize(width: 528, height: 1143), regular: true),
        Screen(name: "ipad-mini", size: CGSize(width: 744, height: 1133), regular: true),
        Screen(name: "ipad-air", size: CGSize(width: 820, height: 1180), regular: true),
        Screen(name: "ipad-pro-13", size: CGSize(width: 1032, height: 1376), regular: true),
    ]

    private static let dir: URL = {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scam-snapshots")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        print("SNAPSHOT DIR: \(d.path)")
        return d
    }()

    private func save<V: View>(_ view: V, size: CGSize, regular: Bool, name: String) {
        let content = view
            .environment(\.horizontalSizeClass, regular ? .regular : .compact)
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.uiImage, let png = image.pngData() else {
            XCTFail("\(name): nothing rendered")
            return
        }
        let url = Self.dir.appendingPathComponent(name + ".png")
        XCTAssertNoThrow(try png.write(to: url))
        print("SNAPSHOT \(name) \(Int(size.width))x\(Int(size.height)) -> \(url.lastPathComponent)")
    }

    func testCameraScreens() {
        let camera = CameraModel()
        for s in Self.screens {
            save(CameraView(camera: camera), size: s.size, regular: s.regular, name: "camera-" + s.name)
        }
    }

    /// The look tray and the segmented control in the column the camera gives them on each screen (CameraView.Stage)
    func testLookTray() {
        for s in Self.screens {
            let stage = CameraView.Stage(s.size, tablet: s.regular)
            let width = max(200, stage.column - 20)
            save(VStack(spacing: 16) {
                CameraSegmented(labels: ["LUT", "Фильтр", "Плёнка", "Цвет"], selected: 2, dots: [true, false, false, false], onPick: { _ in })
                LutTray(onAll: { _ in })
                Spacer(minLength: 0)
            }
            .frame(width: width)
            .padding(.top, 20), size: CGSize(width: s.size.width, height: s.size.height * 0.75), regular: s.regular, name: "tray-" + s.name)
        }
    }
}
