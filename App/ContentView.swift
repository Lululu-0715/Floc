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

// #Preview 宏需要编译期加载 PreviewsMacros 插件。Release 构建在 -O 下本来就
// 不产出预览，Xcode 也会打一句 "Disabling previews ... expected -Onone"，
// 但宏展开仍会发生；在受限环境（CI、沙箱）里插件进程起不来就会直接编译失败：
//   external macro implementation type 'PreviewsMacros.SwiftUIView' could not be found
// 加上 #if DEBUG 之后出包路径完全不碰这个宏，只有 Xcode 预览/调试时才展开。
#if DEBUG
#Preview {
    ContentView(setup: SetupCoordinator())
}
#endif
