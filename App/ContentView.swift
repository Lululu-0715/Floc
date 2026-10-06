import SwiftUI

/// 根视图：根据引导状态决定展示引导流程还是主界面。
struct ContentView: View {

    @ObservedObject var setup: SetupCoordinator
    @State private var showModeSwitch = false

    var body: some View {
        Group {
            if setup.isCompleted {
                MapHomeView(setup: setup)
                    .transition(.opacity)
            } else {
                SetupFlowView(setup: setup)
                    .transition(.opacity)
            }
        }
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
