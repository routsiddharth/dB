import AppKit
import SwiftUI

@main
struct DBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var mixer = AudioMixer()

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(mixer)
        } label: {
            Text("dB")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the Dock icon even when launched as a bare executable (swift run).
        NSApp.setActivationPolicy(.accessory)
    }
}
