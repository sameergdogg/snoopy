import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("Simulator") {
                    Picker("Device", selection: Binding(
                        get: { controller.selectedDevice },
                        set: { controller.selectedDevice = $0; controller.refreshApps() })) {
                        ForEach(controller.devices) { d in
                            Text("\(d.name) · \(d.runtime)").tag(Optional(d))
                        }
                        if controller.devices.isEmpty { Text("No booted simulators").tag(Optional<SimDevice>.none) }
                    }
                    .labelsHidden()
                    Button { controller.refreshDevices() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.buttonStyle(.borderless).font(.caption)
                }

                Section("App to capture") {
                    if controller.apps.isEmpty {
                        Text("No user apps installed").foregroundStyle(.secondary).font(.caption)
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
                }
            }
            .listStyle(.sidebar)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Button { controller.launchSelected() } label: {
                    Label("Run with Snoopy", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.selectedApp == nil)

                Button { controller.copyXcodeHint() } label: {
                    Label("Copy Xcode env vars", systemImage: "doc.on.doc").font(.caption)
                }.buttonStyle(.borderless)

                Text(controller.store.statusLine)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(12)
        }
    }
}
