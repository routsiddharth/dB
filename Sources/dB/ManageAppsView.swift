import AppKit
import SwiftUI

/// Settings window: manage which apps appear in the quick-view mixer.
struct ManageAppsView: View {
    @EnvironmentObject private var mixer: AudioMixer

    private var apps: [KnownApp] { mixer.manageableApps }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Manage Apps")
                    .font(.title2.weight(.semibold))
                Text("Turn an app off to hide it from the menu bar mixer. Its volume keeps applying, and you can turn it back on any time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            if apps.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(apps) { app in
                        row(for: app)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(width: 460, height: 520)
    }

    private func row(for app: KnownApp) -> some View {
        HStack(spacing: 10) {
            icon(for: app)
            Text(app.name)
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: Binding(
                get: { !app.isHidden },
                set: { mixer.setHidden(!$0, for: app.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Forget This App") {
                mixer.forget(key: app.id)
            }
        }
    }

    @ViewBuilder
    private func icon(for app: KnownApp) -> some View {
        if app.id == "system-sounds" {
            Image(systemName: "bell.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.secondary.opacity(0.18))
                )
        } else if let nsImage = app.icon {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No apps yet")
                .font(.headline)
            Text("Apps appear here once they play audio.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
