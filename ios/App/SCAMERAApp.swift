import SwiftUI

@main
struct SCAMERAApp: App {
    @UIApplicationDelegateAdaptor(SCAMERAAppDelegate.self) private var appDelegate
    @State private var camera = CameraModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CameraView(camera: camera)
                .statusBarHidden(true)
                .preferredColorScheme(.dark)
                .modifier(AccentTint())
                .font(.app(17))
                .onAppear { AppFont.applyToUIKit() } // Android Fonts: Roboto Flex everywhere, UIKit's bars too
                .task {
                    // «Включить логирование»: on for the iPhone unless switched off (the switch shows it: Android's default is off)
                    if UserDefaults.standard.dictionary(forKey: PostSettings.prefsKey)?["scamera_full_debug"] == nil {
                        SettingsStore.shared.set("scamera_full_debug", true)
                    }
                    SessionLog.applySetting()
                    // a shot's processing that never finished: the app was ended in it (a crash or iOS taking the memory back)
                    let inflight = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Log").appendingPathComponent(".inflight")
                    if let last = try? String(contentsOf: inflight, encoding: .utf8) {
                        SessionLog.w("App", "the previous run ended during a shot's processing: \(last)")
                        try? FileManager.default.removeItem(at: inflight)
                    }
                    DeviceTurn.shared.start()
                    await camera.start()
                    // P470: the GPU programs before the first shot (a dialog after an install or an update)
                    FirstRunCompile.shared.maybeRun()
                    // the settings tree (0.9 MB of JSON) decoded off the main thread, before the shade or the settings first need it
                    Task.detached(priority: .utility) { _ = SettingsCatalog.shared }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            SessionLog.i("App", "scene \(phase)")
            if phase == .background { FirstRunCompile.saveRecipes() }
        }
    }
}
