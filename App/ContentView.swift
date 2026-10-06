import SwiftUI

/// 根视图：按「欢迎页 → 引导流程 → 主界面」三段决定展示什么。
struct ContentView: View {

    @ObservedObject var setup: SetupCoordinator
    @State private var showModeSwitch = false

    var body: some View {
        Group {
            if !setup.hasSeenWelcome {
                WelcomeView {
                    setup.markWelcomeSeen()
                }
                .transition(.opacity)
            } else if setup.isCompleted {
                MapHomeView(setup: setup)
                    .transition(.opacity)
            } else {
                SetupFlowView(setup: setup)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: setup.hasSeenWelcome)
        .animation(.easeInOut(duration: 0.28), value: setup.isCompleted)
        .onChange(of: setup.isCompleted) { completed in
            RuntimeLogger.info("APP", "Lifecycle", "界面切换", details: [
                "screen": completed ? "主界面" : "引导流程",
            ])
        }
    }
}

#Preview {
    ContentView(setup: SetupCoordinator())
}
