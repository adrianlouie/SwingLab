import SwiftUI
import SwiftData

@main
struct SwingLabApp: App {
    @StateObject private var profileStore = ProfileStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(profileStore)
                .tint(Theme.fairway)
        }
        .modelContainer(for: SwingRecord.self)
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Swings", systemImage: "figure.golf") }
            PracticeView()
                .tabItem { Label("Practice", systemImage: "dot.radiowaves.left.and.right") }
            ProgressTrendsView()
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
