import SwiftUI

/// 首次启动的三页欢迎页。
///
/// 这里是纯介绍，不做任何配置——真正的配置在随后的 `SetupFlowView` 里。
/// 之所以独立成一个视图而不是塞进引导流程的第一步：引导流程的步骤指示器
/// 会显示「1/4」，而欢迎页不属于任何一个配置步骤，混在一起会误导用户。
///
/// 分页用 `TabView` 的 page 样式，但**指示点自绘**：需要「当前页是长条、
/// 其余是小圆点」这套样式，系统的 `indexDisplayMode` 只能给等大的圆点。
struct WelcomeView: View {

    /// 三页的内容。文案走本地化查表，所以每次渲染时现取。
    private struct Item {
        let systemImage: String
        let title: String
        let subtitle: String
    }

    private var items: [Item] {
        [
            Item(
                systemImage: "location.viewfinder",
                title: AppLocalization.string("欢迎使用 Floc"),
                subtitle: AppLocalization.string("在一张简洁的地图上，选择你的 iPhone 应出现的位置。")
            ),
            Item(
                systemImage: "map",
                title: AppLocalization.string("选择任意地点"),
                subtitle: AppLocalization.string("搜索目的地或点按地图，然后将其保存为目标位置。")
            ),
            Item(
                systemImage: "shield.lefthalf.filled",
                title: AppLocalization.string("一键启用代理"),
                subtitle: AppLocalization.string("安装证书并开启本机代理，即可开始虚拟定位。")
            ),
        ]
    }

    @State private var currentPage = 0

    let onFinish: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            backdrop
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(items.indices, id: \.self) { index in
                        page(items[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomBar
            }
        }
        .onAppear {
            RuntimeLogger.info("APP", "Welcome", "欢迎页已显示")
        }
    }

    // MARK: - 背景

    /// 顶部一层淡蓝渐变，向下淡出到系统背景色。
    ///
    /// 用 `Color.blue` 叠加而不是写死 RGB：深色模式下它会自动变成暗蓝，
    /// 不必为两种外观各维护一套常量。
    private var backdrop: some View {
        LinearGradient(
            stops: [
                .init(color: Color.blue.opacity(0.18), location: 0.0),
                .init(color: Color.blue.opacity(0.05), location: 0.42),
                .init(color: Color.blue.opacity(0.0), location: 0.7),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - 单页

    private func page(_ item: Item) -> some View {
        VStack(spacing: 0) {
            Text("FLOC")
                .font(.caption)
                .tracking(2)
                .foregroundStyle(.secondary)
                .padding(.top, 16)

            VStack(spacing: 0) {
                iconTile(item.systemImage)
                    .padding(.bottom, 30)

                Text(item.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.horizontal, 40)
            }
            // 底部留一段空白把整块内容往上顶约 48pt：垂直居中会显得下沉，
            // 参考图里图标大致落在屏幕上半部偏中。
            .frame(maxHeight: .infinity)
            .padding(.bottom, 96)
        }
        .padding(.horizontal, 24)
    }

    /// 120×120 的渐变图标块，外圈带一层蓝色辉光。
    private func iconTile(_ systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.blue, Color.cyan],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.white)
            )
            .shadow(color: Color.blue.opacity(0.35), radius: 24, y: 10)
    }

    // MARK: - 底部

    private var bottomBar: some View {
        VStack(spacing: 22) {
            pageIndicator
            primaryButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    /// 自绘指示点：当前页是 22pt 的长条，其余是 8pt 的小圆点。
    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == currentPage ? Color.blue : Color.secondary.opacity(0.3))
                    .frame(width: index == currentPage ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentPage)
    }

    private var primaryButton: some View {
        Button {
            advance()
        } label: {
            HStack(spacing: 8) {
                Text(buttonTitle)
                    .fontWeight(.semibold)
                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.blue)
            )
        }
        .buttonStyle(.plain)
    }

    private var buttonTitle: String {
        currentPage < items.count - 1
            ? AppLocalization.string("继续")
            : AppLocalization.string("开始使用")
    }

    private func advance() {
        guard currentPage < items.count - 1 else {
            RuntimeLogger.info("APP", "Welcome", "欢迎页已完成")
            onFinish()
            return
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            currentPage += 1
        }
    }
}
