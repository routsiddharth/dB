import AppKit

// MARK: - AppleScript support
//
// This file, together with Resources/dB.sdef and the `NSAppleScriptEnabled` /
// `OSAScriptingDefinition` keys in Info.plist, is what makes:
//
//   tell application "dB"
//     set firefox to first app volume entry whose id is "org.mozilla.firefox"
//     tell firefox
//       set volume 0.5
//     end tell
//   end tell
//
// work. Cocoa Scripting is mostly declarative: the .sdef says the
// application has a to-many "app volume entry" element, and that class has
// "id"/"name"/"volume" properties; from there AppleScript's built-in
// filtering ("whose id is ..."), enumeration ("every app volume entry"), and
// get/set-property machinery all work automatically via Key-Value Coding —
// no command-handling code required. What *is* required is:
//
//   1. `NSApplication.appVolumeEntries` below, so the app (the root
//      scripting object) is KVC-compliant for the element name the sdef
//      declares.
//   2. `AppVolumeEntryScriptingObject`, a small KVC-compliant wrapper per
//      entry, so its properties can be read and its `volume` written.
//   3. `objectSpecifier` / `valueInAppVolumeEntries(withUniqueID:)`, a matched
//      pair that let AppleScript capture a reference to one of these objects
//      (e.g. into the `firefox` variable above) and resolve it again later,
//      and — just as important — let AppleScript convert a *returned* object
//      back into an Apple event descriptor at all. Without a working
//      `objectSpecifier`, even `first app volume entry` on its own fails,
//      since the runtime can't describe the result it's handing back.

/// A single per-app volume slider, exposed to AppleScript as an
/// "app volume entry" element of the application. Wraps a mixer key rather
/// than a snapshot, so property reads always reflect the live mixer state.
@objc(AppVolumeEntryScriptingObject)
@MainActor
final class AppVolumeEntryScriptingObject: NSObject {
    /// The mixer's grouping key for this entry: a bundle identifier (e.g.
    /// "org.mozilla.firefox"), or "system-sounds" for the System Sounds row.
    let key: String
    private weak var mixer: AudioMixer?

    init(key: String, mixer: AudioMixer) {
        self.key = key
        self.mixer = mixer
        super.init()
    }

    private var liveEntry: AppVolumeEntry? {
        mixer?.entries.first { $0.id == key }
    }

    /// AppleScript-visible as "id". Named `identifier` here (not `id`)
    /// because `id` is a reserved type keyword in Objective-C and can't be
    /// used as a property name; dB.sdef maps AppleScript's "id" to this
    /// Cocoa key instead.
    @objc var identifier: String { key }

    @objc var name: String { liveEntry?.name ?? key }

    /// 0.0 (silent) to 1.0 (full, untapped). Setting this calls straight
    /// through to `AudioMixer.setVolume`, the same path the mixer's own
    /// sliders use.

    @objc dynamic func volume() -> Double{
        return Double(liveEntry?.volume ?? 1)
    }

    @objc dynamic func setVolume(_ volume: Double){
        mixer?.setVolume(Float(min(1, max(0, volume))), for: key)
    }


    override var objectSpecifier: NSScriptObjectSpecifier? {
        // NB: this is NOT `NSApplication.shared.classDescription` — that's
        // Foundation's old, unrelated Key-Value Coding class-description
        // property (`NSObject.classDescription` -> `NSClassDescription`) and
        // it never matches the AppleScript suite registered from dB.sdef, so
        // casting it always fails silently. The scripting-specific lookup is
        // `NSScriptClassDescription.classDescription(for:)`, which takes the
        // *class* (not an instance) and consults the sdef-derived registry.
        guard let appDescription = NSScriptClassDescription.init(for: NSApplication.self) else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: appDescription,
            containerSpecifier: nil,
            key: "appVolumeEntries",
            uniqueID: key
        )
    }
}

@MainActor
extension NSApplication {
    /// KVC-compliant accessor for the "app volume entry" element dB.sdef
    /// declares on the application class. Backs `every app volume entry`,
    /// `count app volume entries`, and `whose`/`first ... whose` filtering.
    @objc var appVolumeEntries: [AppVolumeEntryScriptingObject] {
        guard let mixer = AudioMixer.shared else { return [] }
        return mixer.entries.map { AppVolumeEntryScriptingObject(key: $0.id, mixer: mixer) }
    }

    /// Resolves an `NSUniqueIDSpecifier` (the kind `objectSpecifier` above
    /// hands back) to a live scripting object again. This is what lets a
    /// script hold onto a reference across statements, e.g. capture `firefox`
    /// in one line and `tell firefox` on the next.
    @objc(valueInAppVolumeEntriesWithUniqueID:)
    func valueInAppVolumeEntries(withUniqueID uniqueID: Any?) -> AppVolumeEntryScriptingObject? {
        guard let key = uniqueID as? String, let mixer = AudioMixer.shared,
              mixer.entries.contains(where: { $0.id == key }) else {
            return nil
        }
        return AppVolumeEntryScriptingObject(key: key, mixer: mixer)
    }
}
