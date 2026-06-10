import AppKit
import CoreAudio
import Foundation
import os

struct AppVolumeEntry: Identifiable, Equatable {
    let id: String          // grouping key (root bundle ID, or "system-sounds")
    let name: String
    let icon: NSImage?
    let isSystemSounds: Bool
    var volume: Float
    var objectIDs: [AudioObjectID]

    static func == (lhs: AppVolumeEntry, rhs: AppVolumeEntry) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.volume == rhs.volume
            && lhs.objectIDs == rhs.objectIDs && lhs.icon === rhs.icon
    }
}

/// An app dB has seen at least once, for the "Manage Apps" settings list.
struct KnownApp: Identifiable, Equatable {
    let id: String          // grouping key
    let name: String
    let icon: NSImage?
    let isHidden: Bool
}

@MainActor
final class AudioMixer: ObservableObject {
    private static let logger = Logger(subsystem: "com.siddharthrout.dB", category: "AudioMixer")
    private static let volumesDefaultsKey = "perAppVolumes"
    private static let hiddenKeysDefaultsKey = "hiddenAppKeys"
    private static let knownAppsDefaultsKey = "knownAppNames"
    private static let systemSoundsKey = "system-sounds"

    @Published private(set) var entries: [AppVolumeEntry] = []
    @Published var lastError: String?
    /// Keys the user has chosen to hide from the quick-view mixer.
    @Published private(set) var hiddenKeys: Set<String>
    /// Every app dB has ever shown (key -> last known display name), persisted
    /// so the user can manage and un-hide apps even when they aren't running.
    @Published private(set) var knownAppNames: [String: String]

    private var taps: [String: ProcessTap] = [:]
    private var savedVolumes: [String: Float]
    /// Keys that have produced audio at some point during this session; they
    /// stay visible in the mixer until the owning process goes away.
    private var sessionActive: Set<String> = []
    private var refreshTimer: Timer?
    private var iconCache: [String: NSImage] = [:]

    init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.volumesDefaultsKey) as? [String: Double] ?? [:]
        savedVolumes = raw.mapValues { Float($0) }
        hiddenKeys = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKeysDefaultsKey) ?? [])
        knownAppNames = UserDefaults.standard.dictionary(forKey: Self.knownAppsDefaultsKey) as? [String: String] ?? [:]

        refresh()
        installListeners()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Volume control

    func setVolume(_ volume: Float, for key: String) {
        guard let index = entries.firstIndex(where: { $0.id == key }) else { return }
        entries[index].volume = volume

        savedVolumes[key] = volume
        if volume == 1 {
            savedVolumes.removeValue(forKey: key)
        }
        persistVolumes()

        if let tap = taps[key] {
            tap.gain = volume
        } else if volume != 1 {
            createTap(for: entries[index])
        }
    }

    func resetVolume(for key: String) {
        guard let index = entries.firstIndex(where: { $0.id == key }) else { return }
        entries[index].volume = 1
        savedVolumes.removeValue(forKey: key)
        persistVolumes()
        taps[key]?.invalidate()
        taps.removeValue(forKey: key)
    }

    // MARK: - Hiding apps

    /// All apps dB has ever shown, for the management list — sorted by name,
    /// each flagged with its current hidden state.
    var manageableApps: [KnownApp] {
        knownAppNames.map { key, name in
            KnownApp(id: key, name: name, icon: managementIcon(for: key), isHidden: hiddenKeys.contains(key))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setHidden(_ hidden: Bool, for key: String) {
        if hidden {
            hiddenKeys.insert(key)
        } else {
            hiddenKeys.remove(key)
        }
        UserDefaults.standard.set(Array(hiddenKeys), forKey: Self.hiddenKeysDefaultsKey)
        refresh()
    }

    /// Forget an app entirely (remove from the registry and un-hide it). It will
    /// reappear in the registry if it plays audio again.
    func forget(key: String) {
        knownAppNames.removeValue(forKey: key)
        hiddenKeys.remove(key)
        persistKnownApps()
        UserDefaults.standard.set(Array(hiddenKeys), forKey: Self.hiddenKeysDefaultsKey)
        refresh()
    }

    /// Best-effort icon for the management list, even when the app isn't running.
    private func managementIcon(for key: String) -> NSImage? {
        if key == Self.systemSoundsKey { return nil }
        if let cached = iconCache[key] { return cached }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: key).first,
           let icon = app.icon {
            iconCache[key] = icon
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            iconCache[key] = icon
            return icon
        }
        return nil
    }

    // MARK: - Discovery

    func refresh() {
        struct Group {
            var objectIDs: [AudioObjectID] = []
            var pids: [pid_t] = []
            var isRunningOutput = false
        }

        var groups: [String: Group] = [:]
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for object in CoreAudioUtils.processObjectList() {
            guard let pid = CoreAudioUtils.pid(of: object), pid != pid_t(ownPID) else { continue }
            let bundleID = CoreAudioUtils.bundleID(of: object)
            let key = groupKey(bundleID: bundleID, pid: pid)
            var group = groups[key] ?? Group()
            group.objectIDs.append(object)
            group.pids.append(pid)
            if CoreAudioUtils.isRunningOutput(object) {
                group.isRunningOutput = true
            }
            groups[key] = group
        }

        var newEntries: [AppVolumeEntry] = []
        var knownChanged = false
        for (key, group) in groups {
            if group.isRunningOutput {
                sessionActive.insert(key)
            }

            let hasCustomVolume = (savedVolumes[key] ?? 1) != 1
            let isSystem = key == Self.systemSoundsKey

            // Decide visibility by what kind of process owns the audio stream:
            //  - System Sounds: always.
            //  - .regular apps (Spotify, Chrome, …): show whenever they hold an
            //    audio stream, even paused — so you can pre-set their volume.
            //  - .accessory agents (Control Center, menu bar apps): only while
            //    actually playing, to avoid clutter.
            //  - daemons with no app / .prohibited (CoreSpeech, avconferenced): hide.
            // A user-set custom volume always keeps a row visible.
            let isPlaying = group.isRunningOutput || sessionActive.contains(key)
            let eligible: Bool
            if isSystem || hasCustomVolume {
                eligible = true
            } else {
                switch appActivationPolicy(for: key, pids: group.pids) {
                case .regular: eligible = true
                case .accessory: eligible = isPlaying
                default: eligible = false
                }
            }
            guard eligible else { continue }

            let (name, icon) = displayInfo(for: key, pids: group.pids)

            // Record every legitimate app in the persistent registry so it can
            // be managed (hidden / un-hidden) from settings later.
            if knownAppNames[key] != name {
                knownAppNames[key] = name
                knownChanged = true
            }

            // The user has hidden this app from the quick-view mixer. Its tap
            // (if any) is left untouched so a custom volume keeps applying.
            if hiddenKeys.contains(key) { continue }

            newEntries.append(AppVolumeEntry(
                id: key,
                name: name,
                icon: icon,
                isSystemSounds: isSystem,
                volume: savedVolumes[key] ?? 1,
                objectIDs: group.objectIDs.sorted()
            ))
        }
        if knownChanged { persistKnownApps() }

        newEntries.sort {
            if $0.isSystemSounds != $1.isSystemSounds { return $0.isSystemSounds }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if newEntries != entries {
            entries = newEntries
        }

        // Drop session/tap state for processes that went away.
        let liveKeys = Set(groups.keys)
        sessionActive.formIntersection(liveKeys)
        for (key, tap) in taps where !liveKeys.contains(key) {
            tap.invalidate()
            taps.removeValue(forKey: key)
        }

        syncTaps()
    }

    /// Ensure each entry with a non-default volume has a tap covering exactly
    /// its current set of process objects (e.g. new browser helper processes).
    private func syncTaps() {
        for entry in entries {
            let wantsTap = (savedVolumes[entry.id] ?? 1) != 1
            let existing = taps[entry.id]
            if let existing {
                if !wantsTap { continue } // keep passthrough tap until reset/quit
                if existing.processObjectIDs != entry.objectIDs, !entry.objectIDs.isEmpty {
                    existing.invalidate()
                    taps.removeValue(forKey: entry.id)
                    createTap(for: entry)
                }
            } else if wantsTap, !entry.objectIDs.isEmpty {
                createTap(for: entry)
            }
        }
    }

    private func createTap(for entry: AppVolumeEntry) {
        guard !entry.objectIDs.isEmpty else { return }
        do {
            let tap = try ProcessTap(
                processObjectIDs: entry.objectIDs,
                name: entry.name,
                initialGain: savedVolumes[entry.id] ?? entry.volume
            )
            taps[entry.id] = tap
            lastError = nil
        } catch {
            Self.logger.error("Tap creation failed for \(entry.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    private func rebuildAllTaps() {
        let keys = Array(taps.keys)
        for key in keys {
            taps[key]?.invalidate()
            taps.removeValue(forKey: key)
        }
        syncTaps()
    }

    // MARK: - Grouping & display

    private func groupKey(bundleID: String?, pid: pid_t) -> String {
        let processName = CoreAudioUtils.processName(pid: pid)?.lowercased() ?? ""
        let lowerBundle = bundleID?.lowercased() ?? ""
        if lowerBundle.contains("systemsound") || processName.contains("systemsound") || processName == "coreaudiod" {
            return Self.systemSoundsKey
        }

        guard var bundleID, !bundleID.isEmpty else {
            return "pid-name:\(processName.isEmpty ? "unknown-\(pid)" : processName)"
        }

        // Map browser/runtime helper bundles to their parent app.
        let explicit: [String: String] = [
            "com.apple.WebKit.GPU": "com.apple.Safari",
            "com.apple.WebKit.WebContent": "com.apple.Safari",
        ]
        if let mapped = explicit[bundleID] {
            return mapped
        }
        var components = bundleID.components(separatedBy: ".")
        while let last = components.last, components.count > 2,
              last.lowercased().contains("helper") || last.lowercased() == "renderer" || last.lowercased() == "plugin" {
            components.removeLast()
        }
        bundleID = components.joined(separator: ".")
        return bundleID
    }

    private func displayInfo(for key: String, pids: [pid_t]) -> (String, NSImage?) {
        if key == Self.systemSoundsKey {
            return ("System Sounds", nil)
        }
        if let cached = iconCache[key], let app = runningApp(for: key, pids: pids) {
            return (app.localizedName ?? key, cached)
        }
        if let app = runningApp(for: key, pids: pids) {
            let icon = app.icon
            if let icon { iconCache[key] = icon }
            return (app.localizedName ?? key, icon)
        }
        if key.hasPrefix("pid-name:") {
            return (String(key.dropFirst("pid-name:".count)), nil)
        }
        return (key.components(separatedBy: ".").last ?? key, nil)
    }

    /// The activation policy of the app that owns this audio group, or nil when
    /// no `NSRunningApplication` resolves (pure daemons like corespeechd).
    private func appActivationPolicy(for key: String, pids: [pid_t]) -> NSApplication.ActivationPolicy? {
        runningApp(for: key, pids: pids)?.activationPolicy
    }

    private func runningApp(for key: String, pids: [pid_t]) -> NSRunningApplication? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: key).first {
            return app
        }
        for pid in pids {
            if let app = NSRunningApplication(processIdentifier: pid) {
                return app
            }
        }
        return nil
    }

    // MARK: - Listeners & persistence

    private func installListeners() {
        var processListAddr = CoreAudioUtils.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(CoreAudioUtils.systemObject, &processListAddr, .main) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }

        var defaultDeviceAddr = CoreAudioUtils.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CoreAudioUtils.systemObject, &defaultDeviceAddr, .main) { [weak self] _, _ in
            Task { @MainActor in self?.rebuildAllTaps() }
        }
    }

    private func persistVolumes() {
        UserDefaults.standard.set(
            savedVolumes.mapValues { Double($0) },
            forKey: Self.volumesDefaultsKey
        )
    }

    private func persistKnownApps() {
        UserDefaults.standard.set(knownAppNames, forKey: Self.knownAppsDefaultsKey)
    }
}
