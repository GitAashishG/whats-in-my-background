import AppKit
import SwiftUI

@main
struct BackgroundDeskApp: App {
    @StateObject private var model = DeskModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        Window("What’s in My Background", id: "dashboard") {
            Dashboard(model: model)
                .frame(minWidth: 600, minHeight: 330)
                .onAppear { model.refresh() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
                .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
                    if phase == .active { model.refresh() }
                }
        }
        .defaultSize(width: 740, height: 455)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Jobs") { model.refresh() }.keyboardShortcut("r").disabled(model.busy)
            }
        }
    }
}
