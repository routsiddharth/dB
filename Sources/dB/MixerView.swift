import AppKit
import ServiceManagement
import SwiftUI

struct MixerView: View {
    @EnvironmentObject private var mixer: AudioMixer
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 14)

            if mixer.entries.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(mixer.entries) { entry in
                        AppVolumeRow(entry: entry)
                        if entry.id != mixer.entries.last?.id {
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if let error = mixer.lastError {
                Divider().padding(.horizontal, 14)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 320)
        .padding(.bottom, 8)
        .onAppear { mixer.refresh() }
    }

    private var header: some View {
        HStack {
            Text("Sound Mixer")
                .font(.headline)
            Spacer()
            Menu {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Divider()
                Button("Quit dB") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No apps are playing audio")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct AppVolumeRow: View {
    @EnvironmentObject private var mixer: AudioMixer
    let entry: AppVolumeEntry

    private var volumeBinding: Binding<Float> {
        Binding(
            get: { entry.volume },
            set: { mixer.setVolume($0, for: entry.id) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                iconView
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text("\(Int((entry.volume * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Slider(value: volumeBinding, in: 0...1)
                    .controlSize(.small)
                Button {
                    mixer.resetVolume(for: entry.id)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(entry.volume == 1 ? .tertiary : .secondary)
                .disabled(entry.volume == 1)
                .help("Reset to 100%")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var iconView: some View {
        if entry.isSystemSounds {
            Image(systemName: "bell.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.secondary.opacity(0.18))
                )
        } else if let icon = entry.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }
}
