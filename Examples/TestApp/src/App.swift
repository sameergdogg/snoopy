import SwiftUI

@main
struct SnoopyTestApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject var net = Net()
    var body: some View {
        NavigationStack {
            List {
                Section("Actions") {
                    Button("GET JSON")       { net.getJSON() }
                    Button("POST JSON")      { net.postJSON() }
                    Button("Download image") { net.image() }
                    Button("Trigger 404")    { net.notFound() }
                    Button("Delegate stream"){ net.delegateStream() }
                    Button("Run all")        { net.runAll() }
                }
                Section("Log") {
                    ForEach(net.log.reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("Snoopy Test")
            .onAppear { net.runAll() }   // fire traffic immediately on launch
        }
    }
}
