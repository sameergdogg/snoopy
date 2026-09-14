import SwiftUI
import SnoopyCore

struct SidebarView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var store: CaptureStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section {
                    Picker("Device", selection: $controller.selectedDevice) {
                        ForEach(controller.devices) { d in
                            Text("\(d.name) · \(d.runtime)").tag(Optional(d))
                        }
                        if controller.devices.isEmpty {
                            Text("No booted simulators").tag(Optional<SimDevice>.none)
                        }
                    }
                    .labelsHidden()
                } header: {
                    HStack {
                        Text("Simulator")
                        Spacer()
                        // Refreshing is automatic now (see AppController.startDeviceWatch),
                        // so this is a nudge rather than the only way to notice a new device.
                        if controller.isLoadingDevices {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        } else {
                            Button { Task { await controller.refreshDevices() } } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless).font(.caption2)
                        }
                    }
                }

                Section {
                    if controller.isLoadingApps {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("Reading installed apps…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if controller.apps.isEmpty {
                        Text(controller.selectedDevice == nil
                             ? "Boot a simulator to choose an app"
                             : "No user apps installed")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    ForEach(controller.apps) { app in
                        HStack {
                            Image(systemName: "app.dashed")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                Text(app.bundleId).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if controller.selectedApp == app { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { controller.selectedApp = app }
                    }
                } header: {
                    Text("App to capture")
                }
            }
            .listStyle(.sidebar)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                // "Launch" rather than a second play glyph: the toolbar's record control is
                // what starts and stops capture, and having two play buttons that meant
                // different things was the clearest source of confusion in the old UI.
                Button { Task { await controller.launchSelected() } } label: {
                    HStack {
                        if controller.isLaunching {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.up.forward.app.fill")
                        }
                        Text(controller.isLaunching ? "Launching…" : "Launch with Snoopy")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.selectedApp == nil || controller.isLaunching)

                Button { controller.copyXcodeHint() } label: {
                    Label("Copy Xcode env vars", systemImage: "doc.on.doc").font(.caption)
                }.buttonStyle(.borderless)

                if !store.isRecording {
                    Label("Capture is paused", systemImage: "pause.circle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(12)
        }
    }
}
