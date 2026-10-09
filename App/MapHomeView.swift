import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// 地图主界面。
///
/// 这是应用的核心页面，承担四件事：
///   1. 地图选点（搜索 / 点击 / 长按 / 拖地图中心）
///   2. 虚拟定位开关
///   3. 收藏位置管理
///   4. 环境状态展示与快捷入口
struct MapHomeView: View {

    @Environment(\.scenePhase) private var scenePhase
    /// 主题强调色。和 `theme.accent` 是同一个值，走环境是为了让
    /// 子视图（`FavoriteChip`）也能拿到，不必逐层传。
    @Environment(\.themeAccent) private var accent

    @ObservedObject var setup: SetupCoordinator
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var thirdParty = ThirdPartyProxyManager.shared
    @ObservedObject private var runtimeMode = RuntimeModeStore.shared
    @ObservedObject private var remoteConfiguration = AppRemoteConfigurationStore.shared
    /// 配色主题。主按钮的强调色、玻璃的染色都从这里取。
    @ObservedObject private var theme = ThemeStore.shared
    #if !PURE_BUILD
    @ObservedObject private var license = LicenseManager.shared
    #endif

    @StateObject private var state = MapLocationState()
    @StateObject private var favorites = FavoriteLocationStore()
    @StateObject private var mapBridge = MapViewBridge()
    @StateObject private var realLocation = RealLocationProvider()
    /// 「虚拟定位生效没有」的校验。「实时位置」按钮共用一个回读通道，
    /// 但校验走的是强制现取（`forceFresh`），不会拿缓存里的旧坐标下结论。
    @ObservedObject private var verifier = SpoofEffectVerifier.shared

    /// 屏幕下沿的安全区高度（Home 指示条那一条）。
    ///
    /// 底部卡片要距屏幕**物理**下沿 12pt（见 `bottomPanel`），而安全区是
    /// 「下不去」的，所以需要知道这条有多高，才能把卡片内容重新垫回指示条
    /// 上方（`bottomPanelContentInset`）。
    ///
    /// **不能靠 SwiftUI 的 `GeometryReader` 读**：外层 ZStack 为了量到屏幕
    /// 下沿整体忽略了下边安全区，而一个视图**一旦忽略安全区，它量到的
    /// `proxy.safeAreaInsets` 就报 0**（安全区已经被自己吃掉了）。
    /// 1.0.12 那版就踩在这里 —— 面板贴底时读数恒为 0，被 `max(14, ·)` 兜住，
    /// 看不出问题；1.0.13 改成悬浮卡片后主按钮离下沿只剩 26pt，正好压在
    /// Home 指示条上，界面测试（`LayoutAndAppearanceUITests`）才把它抓出来。
    /// 所以直接问窗口要，那个值不受 SwiftUI 的 ignore 影响。
    @State private var bottomSafeInset: CGFloat = 0

    @State private var searchText = ""
    @State private var searchResults: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?

    /// 搜索结果列表的实际内容高度，用于把滚动区域卡在「内容高度」与上限之间。
    @State private var searchResultsHeight: CGFloat = 0

    @State private var activeSheet: HomeSheet?
    @State private var editingFavorite: FavoriteLocationStore.FavoriteLocation?
    @State private var editName = ""
    @State private var showSaveFavorite = false
    @State private var newFavoriteName = ""

    /// 收藏夹管理页。状态行右端那个圆形按钮打开。
    @State private var showFavorites = false

    /// 地图图层。默认标准图，用户可在地图左上角切换。
    @State private var mapType: MapTypeOption = .standard

    @State private var banner: BannerMessage?
    @State private var bannerDismissTask: Task<Void, Never>?

    /// 「开启虚拟定位成功之后，去把定位服务关一下再打开」这条引导。
    ///
    /// **跨启动持久化**：用户点过「不再提示」就永远不再弹（见 `SpoofGuideStore`）。
    /// 1.0.11 及以前这件事用两个 `@State` 记，而 `@State` 的生命周期就是视图
    /// ——冷启动必然归零，于是每次打开 App 都弹一遍。
    @ObservedObject private var guide = SpoofGuideStore.shared

    /// 引导卡片是否正在显示。
    @State private var showsGuide = false

    /// 图层菜单是否展开。点图层按钮开合；点地图、选完图层、或搜索结果出来时收起。
    @State private var showsLayerMenu = false

    @State private var geocodeTask: Task<Void, Never>?
    @State private var coordinateSystemProbeTask: Task<Void, Never>?

    private enum HomeSheet: String, Identifiable {
        case settings, logs
        var id: String { rawValue }
    }

    private struct SearchResult: Identifiable {
        let id = UUID()
        let name: String
        let subtitle: String
        let pair: CoordinateConverter.CoordinatePair
    }

    private struct BannerMessage: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let style: InlineAlert.Style
    }

    /// 搜索结果列表的高度上限。超过就滚动。
    ///
    /// 280pt 是「一眼能扫完、又不会把地图全挡住」的折中：约 6 条两行结果，
    /// 或者 12 条单行结果。
    private static let searchResultsMaxHeight: CGFloat = 280

    /// 量取搜索结果内容的实际高度。
    private struct SearchResultsHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer
            overlayLayer
            // 「开启成功后去关一下定位服务」的引导。放在最上层，自带遮罩。
            if showsGuide {
                SpoofGuideOverlay(
                    onOpenSettings: {
                        guide.noteOpenSettings()
                        SystemSettingsNavigator.openLocationServices()
                        // 跳过去之后就把本层收掉，别让用户从系统设置回来时
                        // 还被一张遮罩挡着；但**不写持久化**，下次开启还会提醒。
                        withAnimation(.easeInOut(duration: 0.2)) { showsGuide = false }
                    },
                    onDismissForever: {
                        guide.dismissForever()
                        withAnimation(.easeInOut(duration: 0.2)) { showsGuide = false }
                    }
                )
                .zIndex(1)
                .transition(.opacity)
            }
        }
        // 底部卡片要**距屏幕物理下沿 12pt**（1.0.13 起从「贴底 sheet」改回
        // 悬浮卡片，四周留边、四角圆角，见 `bottomPanel`），而安全区是
        // "下不去"的：覆盖层守在安全区里，卡片的下沿就只能停在指示条上面。
        //
        // 所以让这一层整体忽略**下边**的安全区，卡片才量得到屏幕物理下沿；
        // 顶边不动（搜索框不能顶到刘海下面去）。卡片自己再把这条留白垫回来，
        // 见 `bottomPanelContentInset`。
        //
        // 曾经试过「面板自己用负 padding 往下顶」：玻璃确实画到了屏幕边缘，
        // 但**命中区没有跟着出去**（负 padding 只影响绘制、不扩父视图的命中
        // 范围），结果面板最下面那一条点下去会穿透成地图选点。界面测试
        // `LayoutAndAppearanceUITests` 里有一条专门盯这个。
        .ignoresSafeArea(edges: .bottom)
        // 安全区高度在 `handleAppear` / `handleScenePhase` 里问窗口要
        // （见 `refreshBottomSafeInset`），**不能用 GeometryReader 量**：
        // 上面这行 `ignoresSafeArea` 一加，视图自己量到的下边安全区恒为 0。
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView(setup: setup, state: state)
            case .logs:
                DiagnosticsView(state: state)
            }
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesView(favorites: favorites) { favorite in
                applyFavorite(favorite)
            }
        }
        .sheet(item: $editingFavorite) { favorite in
            renameFavoriteSheet(favorite)
        }
        .alert(AppLocalization.string("保存为收藏"), isPresented: $showSaveFavorite) {
            TextField(AppLocalization.string("名称"), text: $newFavoriteName)
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("保存")) { saveFavorite() }
        } message: {
            Text(AppLocalization.string("为当前选点取一个便于识别的名字。"))
        }
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: scenePhase) { newPhase in
            handleScenePhase(newPhase)
        }
        .onChange(of: state.selection) { _ in
            state.persist()
            refreshDisplayName()
            // 目标点换了，之前的校验结论就不作数了，重新跑一轮。
            if state.isEnabled, let pair = state.selection {
                startVerification(pair: pair)
            }
        }
        .onChange(of: verifier.status) { status in
            switch status {
            case .effective:
                showBanner(status.explanation, style: .info)
            case .ineffective:
                showBanner(status.explanation, style: .warning)
            default:
                break
            }
        }
        .onChange(of: state.isEnabled) { _ in
            state.persist()
        }
        .onChange(of: state.accuracy) { _ in
            state.persist()
            pushConfigurationToBackend()
        }
        .onChange(of: state.motionDriftRadius) { _ in
            state.persist()
            pushConfigurationToBackend()
        }
    }

    // MARK: - 地图层

    private var mapLayer: some View {
        MapViewRepresentable(
            bridge: mapBridge,
            selectedPair: state.selection,
            coordinateSystem: $state.mapCoordinateSystem,
            viewportMeters: $state.viewportMeters,
            mapType: mapType.mkMapType,
            showsBluePoint: true,
            onTapCoordinate: { coordinate in
                handleMapTap(coordinate)
            },
            onRegionChanged: { meters in
                state.viewportMeters = meters
            }
        )
        // 全面屏：地图铺满整块屏幕，状态栏与 Home 指示条底下也是地图。
        //
        // 1.0.7 及以前只 `.ignoresSafeArea(edges: .bottom)`，顶上那条安全区
        // 就空出来了——空的区域露出的是窗口底色，浅色模式下就是一条白带，
        // 状态栏（时间 / 信号 / 电量）像贴在一条白条上，和下面的地图断开。
        //
        // 这里让地图层忽略**全部**边（只写 `.bottom` 就会在顶上留出那条白带）。
        // ZStack 里的覆盖层不受兄弟节点影响，仍然按安全区排布，所以搜索框
        // 不会顶到刘海或状态栏下面去。
        //
        // 底边是唯一的例外：外层 ZStack 为了「底部卡片距屏幕物理下沿 12pt」
        // 忽略了下边安全区（见 `body`），代价是覆盖层底部那一条也一起下去了
        // ——卡片自己用 `bottomPanelContentInset` 把内容垫回 Home 指示条上方，
        // 其余覆盖层都在上边，不受影响。
        .ignoresSafeArea()
    }

    // MARK: - 覆盖层

    private var overlayLayer: some View {
        VStack(spacing: 0) {
            topBar
            if let banner {
                InlineAlert(text: banner.text, style: banner.style, presentation: .mapBanner)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if remoteConfiguration.systemVersionBlocked {
                InlineAlert(
                    text: AppLocalization.string(
                        "当前系统版本（%@）可能已禁用对定位服务的拦截，功能可能不生效。",
                        UIDevice.current.systemVersion
                    ),
                    style: .warning
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            Spacer()
            // 图层与「实时位置」两个圆浮标：贴右侧、压在底部卡片**正上方**。
            //
            // 1.0.12 及以前它们都在底部面板里（图层是右下角竖排三连、实时位置
            // 是主按钮右边的小胶囊）。挪出来是因为面板里那两处把主按钮挤窄了，
            // 而「换个图层看看」「跳到我的真实位置」都是看图时的动作，跟面板里
            // 「选点 / 收藏 / 开关虚拟定位」不是一类事，分开摆更像地图应用。
            //
            // 搜索结果展开时收起，避免两个浮层叠在一起。
            if searchResults.isEmpty {
                mapFloatingControls
            }
            bottomPanel
        }
        .animation(.easeInOut(duration: 0.2), value: banner)
    }

    /// 地图右下角、底部卡片上方的两个圆浮标。
    ///
    /// 「圆钮」是这一版地图页的统一语言：顶部的设置、这里的图层与实时位置，
    /// 都是 44×44 的正圆（`mapGlassCapsule()` 套在正方形上就是个圆）。
    /// 1.0.12 及以前这里是竖排三个扁方块按钮、顶部又是一个圆角方形齿轮，
    /// 两套形状混在一起，看着不像一家人。
    ///
    /// 位置：**贴右侧、压在底部卡片正上方**（不是右上角）。水平内边距 20
    /// = 卡片外边距 12 + 8，比卡片向右收一点，看起来是「卡片上方的浮标」
    /// 而不是跟卡片对齐的按钮。
    private var mapFloatingControls: some View {
        // 顶对齐：图层菜单从按钮**向左**长出来，它比按钮高，顶端对齐后展开的
        // 起点正好贴着按钮上沿，看上去就是「从这颗按钮里弹出来的」。
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 0)

            if showsLayerMenu {
                layerMenu
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            VStack(spacing: 10) {
                layerButton
                realLocationFloatingButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .transition(.opacity)
    }

    /// 图层浮标。点一下向左弹出菜单。
    private var layerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showsLayerMenu.toggle() }
        } label: {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(showsLayerMenu ? theme.accent : Color.primary)
                .frame(width: 44, height: 44)
                .mapGlassCapsule(nested: false)
                .contentShape(Circle())
        }
        .glassPressEffect(scale: 0.9)
        .accessibilityLabel(AppLocalization.string("图层"))
        .accessibilityValue(mapType.displayName)
    }

    /// 图层菜单：从图层按钮向左弹出的卡片。
    ///
    /// **不用系统 `Menu`**：它的圆角由系统定，给不了 `menuCornerRadius`，
    /// 样式也不跟配色主题走。自绘一张卡片反而能和其他浮层是一套东西。
    ///
    /// 收起方式有三种：再点一次图层按钮、选中某个图层、点地图（见 `handleMapTap`）。
    private var layerMenu: some View {
        VStack(spacing: 0) {
            ForEach(MapTypeOption.allCases) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mapType = option
                        showsLayerMenu = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: option.systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 22)

                        Text(option.displayName)
                            .font(.subheadline.weight(.medium))

                        Spacer(minLength: 0)

                        if mapType == option {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .foregroundStyle(mapType == option ? theme.accent : Color.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.displayName)
                .accessibilityAddTraits(mapType == option ? [.isSelected] : [])
            }
        }
        .frame(width: 168)
        .mapGlassSurface(cornerRadius: GlassMetrics.menuCornerRadius)
    }

    /// 「实时位置」浮标：纯图标圆钮，与图层浮标**同款**（玻璃底 + 主色图标）。
    ///
    /// 点一下把地图跳到设备当前真实位置，并**把视野收进到街道尺度**
    /// （`MapLocationState.defaultViewportMeters`）。
    /// 长按回到已选点——选点才是这个应用的主角，所以「回到选点」比
    /// 「回到真实位置」更次级，放在长按上。
    ///
    /// 1.0.13 初版这里是**蓝底白图标**的实心圆，本意是用「全屏唯一的实心按钮」
    /// 拉开层次；实际看起来那颗蓝跟其余玻璃圆钮不是一套东西，右侧一列两粒
    /// 就它扎眼。改成同款玻璃圆钮，靠图标（准星 = 「把我放到我这儿」）区分。
    private var realLocationFloatingButton: some View {
        Button {
            goToRealLocation()
        } label: {
            Group {
                if realLocation.isLocating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.accent)
                } else {
                    Image(systemName: "location.viewfinder")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
            }
            .frame(width: 44, height: 44)
            .mapGlassCapsule(nested: false)
            .contentShape(Circle())
        }
        .glassPressEffect(scale: 0.9)
        .disabled(realLocation.isLocating)
        .accessibilityLabel(AppLocalization.string("实时位置"))
        .accessibilityHint(AppLocalization.string("长按回到已选点"))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in centerOnSelection() }
        )
    }

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField(AppLocalization.string("搜索地点或地址"), text: $searchText)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                        .onSubmit { performSearch() }
                        .onChange(of: searchText) { newValue in
                            // 输入变化时做防抖，避免每敲一个字符就发一次请求。
                            scheduleSearch(for: newValue)
                        }

                    if isSearching {
                        ProgressView().controlSize(.small)
                    } else if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                                // 触摸目标放大到 30×30：图标本身只有 ~20pt，
                                // 稍微点偏一点就落到搜索框的玻璃上——更糟的情况是
                                // 透过玻璃落到地图上，变成一次地图选点。
                                // 30 是这一行的极限：行高由它决定（30 + 上下各 6
                                // 的内边距 = 42），再大整个搜索栏就会被撑高。
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLocalization.string("清空"))
                    }
                }
                // 行高固定 30：清除按钮是 30×30（触摸目标），放大镜与输入框
                // 都比它矮。给一个 minHeight 之后，「有没有 X」都不会改变行高，
                // 搜索栏不会在开始输入的一瞬间跳一下。
                .frame(minHeight: 30)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                // 胶囊 + 不嵌套：这是直接浮在地图上的独立浮层（不是玻璃面板
                // 内部的元素），传 `nested: false` 才会拿到真正的玻璃。
                // 1.0.13 起地图页顶部统一「搜索胶囊 + 设置圆钮」。
                .mapGlassCapsule(nested: false)

                Button {
                    activeSheet = .settings
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        // 44×44 是 iOS 的最小可靠触摸尺寸。原来是 42×42，肉眼看不出
                        // 差别，但用户反馈「设置很难点进去」——近两年机型的边缘手势
                        // 会把最外侧十几像素吃掉，宁可多给两像素。
                        .frame(width: 44, height: 44)
                        // **正圆**：1.0.13 起地图页的浮层统一用「圆钮」语言
                        // （图层、实时位置也是正圆）。以前这里是个 20pt 圆角的
                        // 方形，跟旁边那几颗圆钮并排时一眼就能看出不是一套。
                        // `mapGlassCapsule()` 套在 44×44 的正方形上画出来就是圆。
                        .mapGlassCapsule(nested: false)
                        // 玻璃本身没有 hit area，图标那点像素才是热区；
                        // 显式给整块定形，避免「点边角没反应」。
                        .contentShape(Circle())
                }
                // 按下缩一下再弹回：玻璃有 `.interactive()`，内容也跟着动，
                // 点下去才有「按到了」的感觉。
                .glassPressEffect(scale: 0.92)
                .accessibilityLabel(AppLocalization.string("设置"))
            }

            if !searchResults.isEmpty {
                searchResultsList
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// 搜索结果列表。
    ///
    /// **必须能滚动。** 一次最多返回 12 条结果，每条约 46pt 起（有第二行副标题
    /// 的话更高）。以前这里只有一个 `VStack` 配 `.frame(maxHeight: 280)` ——
    /// `.frame` 只限制容器尺寸，**不会产生滚动**，于是 VStack 照排下去，超出
    /// 280pt 的部分直接被裁掉。表现就是用户报的「下面跳出来的选项显示不完整」，
    /// 而且被裁掉的那几条根本点不到（它们仍在布局里，只是画不出来）。
    ///
    /// 高度取「内容高度」与上限的较小值，而不是直接给 `maxHeight`：
    /// `ScrollView` 在滚动轴上是贪心的，只给上限的话，两条结果也会撑出一大块
    /// 空玻璃，看起来像个 bug。
    private var searchResultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(searchResults) { result in
                    Button {
                        applySearchResult(result)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(accent)
                                .font(.title3)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if result.id != searchResults.last?.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SearchResultsHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )
        }
        .onPreferenceChange(SearchResultsHeightKey.self) { height in
            searchResultsHeight = height
        }
        .frame(height: min(max(searchResultsHeight, 1), Self.searchResultsMaxHeight))
        .mapGlassSurface()
    }

    // MARK: - 底部面板

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if let error = searchError {
                InlineAlert(text: error, style: .error)
            }

            if state.selection != nil {
                selectionCard
            }

            if !favorites.favorites.isEmpty {
                favoritesRow
            }

            // 状态类信息（运行模式 / 证书 / Wi-Fi 代理 / 生效校验）摆在主按钮
            // **上方**，主按钮压在最下面 —— 它是这一屏唯一的行动点，用户明确
            // 要求「开启虚拟定位还是弄到最下面」。
            statusRow
            if state.isEnabled {
                verificationRow
            }
            primaryActionButton
        }
        .padding(.horizontal, panelContentInset)
        .padding(.top, panelContentInset)
        .padding(.bottom, bottomPanelContentInset)
        // **四角全圆**、四周留边 12：1.0.13 起这张面板从「贴底 sheet」改回
        // **悬浮大卡片**（对齐参考图里的 Apple 地图），所以走 `mapGlassSurface()`
        // 而不是只圆上沿的 `mapGlassSheet()`。
        .mapGlassSurface(cornerRadius: GlassMetrics.mapPanelCornerRadius)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// 卡片内容四周的留边。
    ///
    /// **24 是算出来的，不是随手定的**：卡片里那两个容器（主按钮、已选位置
    /// 面板）的圆角都要跟卡片**同心**，即 44 − 留边；而主按钮高 46pt，
    /// 圆角超过半高 23 就没意义了（系统会把它夹回胶囊），于是
    ///
    ///     留边 ≥ mapPanelCornerRadius − 23 = 21
    ///
    /// 原来左右留 14 / 下面留 28（避 Home 指示条）—— 先不说 14 根本不够，
    /// 四边还各不相同，同一圈缝从侧面绕到拐角就变宽，所以怎么摆都不像同心。
    /// 取 24 同时满足两件事：≥ 21，且 ≥ 22（= 指示条安全区 34 − 卡片留边 12）。
    private let panelContentInset: CGFloat = 24

    /// 卡片**里层**容器的圆角：跟大卡片同心（44 − 24 = 20）。
    ///
    /// 主按钮和「已选位置」面板共用它 —— 两者都贴着卡片的拐角，各挑一个档位
    /// 就会各偏一个圆心。注意 20 恰好等于 `mapCornerRadius`，但**不是**那一档：
    /// 那一档是「浮在地图上的小块」，这里是「跟卡片同心推出来的值」，改留边
    /// 它会跟着变，所以别换成常量。
    private var panelInnerCornerRadius: CGFloat {
        GlassMetrics.concentric(outer: GlassMetrics.mapPanelCornerRadius,
                                inset: panelContentInset)
    }

    /// 卡片内容与卡片下沿之间的留白。
    ///
    /// 默认就等于左右留边（`panelContentInset`），这样主按钮的左右下三边到
    /// 卡片外沿的距离一致，同心才成立。只有 Home 指示条那 34pt 安全区**比
    /// 留边还深**时才往上让 —— 那时按钮会被指示条压住（看着能点、实际点不到），
    /// 宁可牺牲一点同心。当前所有带指示条的机型都够不到这条分支。
    private var bottomPanelContentInset: CGFloat {
        max(panelContentInset, bottomSafeInset - 12)
    }

    /// 已选位置卡片：左边地名与两行坐标，右边竖排两个入口。
    ///
    /// 两个圆钮摆在**坐标右侧、上下各一个**：它们和坐标一样都属于
    /// 「这一屏顺手戳一下」的入口，贴着刚读完的坐标放，视线不必横穿整行；
    /// 两个 30pt 圆钮加间距正好 66pt，与「标题 + 两行坐标」的高度相当，
    /// 不会把卡片撑高。
    ///
    /// 注意这两个入口只在有选点时出现（整张卡片就是这个时候才有的）。
    /// 没有选点时它们不会消失，而是落回状态行右端——否则用户手里明明有收藏、
    /// 也能看到收藏条，却找不到打开收藏夹管理页的入口。
    private var selectionCard: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                // 收藏按钮紧跟在地名后面：点地名旁边就能收藏/取消，
                // 比原来放在整行最右侧要少一次跨屏移动，单手操作更顺。
                HStack(spacing: 6) {
                    Text(state.displayName.isEmpty ? AppLocalization.string("已选位置") : state.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    if state.selection != nil {
                        Button {
                            if let pair = state.selection {
                                if let existing = favorites.contains(pair: pair) {
                                    favorites.remove(id: existing.id)
                                    showBanner(AppLocalization.string("已取消收藏"), style: .info)
                                } else {
                                    newFavoriteName = state.displayName
                                    showSaveFavorite = true
                                }
                            }
                        } label: {
                            let isFavorite = state.selection.map { favorites.contains(pair: $0) != nil } ?? false
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.subheadline)
                                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 0)
                }

                if let pair = state.selection {
                    // 国内用户在导航类应用里看到的通常是 GCJ-02，
                    // 但写进定位服务的是 WGS-84，所以两个都展示出来。
                    // 复制按钮直接跟在坐标后面 —— 原来单独占一行放两个
                    // 「复制坐标」按钮，既占纵向空间又要在两行坐标之间来回
                    // 对照，现在点哪行复制哪行。
                    //
                    // 精度选择器原本挂在右侧，现已删掉：它和「设置 → 连接状态
                    // → 定位模拟」里那个是同一个值（都绑 state.accuracy），
                    // 两处并存只会让人怀疑哪边算数。精度的完整档位留在设置里。
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(String(format: "GCJ-02  %.6f, %.6f",
                                        pair.gcj02.latitude, pair.gcj02.longitude))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            CoordinateCopyIcon(
                                accessibilityLabel: "GCJ-02",
                                value: String(format: "%.6f,%.6f",
                                              pair.gcj02.latitude, pair.gcj02.longitude)
                            )
                        }

                        HStack(spacing: 6) {
                            Text(String(format: "WGS-84  %.6f, %.6f",
                                        pair.wgs84.latitude, pair.wgs84.longitude))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            CoordinateCopyIcon(
                                accessibilityLabel: "WGS-84",
                                value: String(format: "%.6f,%.6f",
                                              pair.wgs84.latitude, pair.wgs84.longitude)
                            )
                        }
                    }
                }
            }

            if state.selection != nil {
                // 两颗圆钮上下排开，**共同撑满左边「地址 + 两行坐标」的高度**：
                // 30 + 6 + 30 = 66，正好和那三行的总高（约 61~66）相当，
                // 卡片不会一边高一边矮。
                VStack(spacing: 6) {
                    favoritesCircle(size: 30)
                    diagnosticsCircle(size: 30)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: panelInnerCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var favoritesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(favorites.favorites) { favorite in
                    FavoriteChip(
                        favorite: favorite,
                        isSelected: favorites.selectedFavoriteID == favorite.id
                    ) {
                        applyFavorite(favorite)
                    } onLongPress: {
                        editingFavorite = favorite
                        editName = favorite.name
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 38)
    }

    /// 状态行：只剩环境状态胶囊。
    ///
    /// 「运行日志与诊断」和「收藏夹」两个入口已经移进选点卡片，摆在坐标右侧
    /// （上下各一个），这里不再放常驻按钮。
    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusPill(
                icon: runtimeMode.mode == .localProxy ? "wifi.router" : "shield.lefthalf.filled",
                text: runtimeMode.mode.displayName,
                color: .blue
            )

            if runtimeMode.mode == .localProxy {
                StatusPill(
                    icon: proxy.certificateTrustState.isTrusted ? "checkmark.shield.fill" : "shield.slash",
                    text: proxy.certificateTrustState.displayText,
                    color: proxy.certificateTrustState.isTrusted ? .green : .orange
                )
                // 蜂窝下「Wi-Fi 代理」这一格没有意义：手动代理只挂在某个 Wi-Fi 上，
                // 蜂窝根本没这个入口。这时直接把原因摆出来（用户一眼就知道为什么
                // 开不起来），好过显示一个永远不会变绿的「未配置」。
                if proxy.networkTransport.blocksInAppProxy {
                    StatusPill(
                        icon: "wifi.slash",
                        text: AppLocalization.string("未连接 Wi-Fi"),
                        color: .orange
                    )
                } else {
                    StatusPill(
                        icon: proxy.wiFiProxyState == .configured ? "link" : "link.badge.plus",
                        text: proxy.wiFiProxyState.displayText,
                        color: proxy.wiFiProxyState == .configured ? .green : .orange
                    )
                }
            } else {
                StatusPill(
                    icon: thirdParty.state.isUsable ? "link" : "link.badge.plus",
                    text: thirdParty.state.displayText,
                    color: thirdParty.state.isUsable ? .green : .orange
                )
            }

            Spacer(minLength: 0)

            // 没选点时选点卡片整块不显示，那两个入口就没了着落。而收藏条
            // （favoritesRow）这时仍然可见——用户看得见自己的收藏，却没有入口
            // 打开收藏夹管理页。所以留一条退路：无选点时把两个圆钮放回状态行
            // 右端，横排。有选点时它们是竖排的，位置本身就在提示该点哪个。
            if state.selection == nil {
                HStack(spacing: 6) {
                    favoritesCircle(size: 30)
                    diagnosticsCircle(size: 30)
                }
            }
        }
    }

    /// 生效校验行。
    ///
    /// 只在虚拟定位开着时出现：结论 + 一句人话 + 一个「重新验证」。
    ///
    /// 为什么要单独占一行而不是塞进上面的状态行：那一行已经有「运行模式 /
    /// 证书 / Wi-Fi 代理」三个胶囊，再加一个在窄机型上会挤到换行；
    /// 而且这三条说的是「链路配好了没有」，这条说的是「真的生效了没有」，
    /// 结论性质不同，摆在新的一行更清楚。
    private var verificationRow: some View {
        HStack(spacing: 8) {
            StatusPill(
                icon: verifier.status.pillIcon,
                text: verifier.status.pillText,
                color: verifier.status.pillColor
            )

            Text(verificationSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                reverify()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text(AppLocalization.string("重新验证"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(verifier.isVerifying ? Color.secondary : accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(verifier.isVerifying)
            .accessibilityLabel(AppLocalization.string("重新验证"))
        }
    }

    /// 校验行右侧的一句人话。展开的完整说明留给横幅，这里只放最短的提示。
    private var verificationSummary: String {
        switch verifier.status {
        case .idle:
            return ""
        case .verifying:
            return AppLocalization.string("正在校验…")
        case .effective(let date):
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return String(format: AppLocalization.string("已验证 %@"), formatter.string(from: date))
        case .ineffective(.locationUnavailable):
            return AppLocalization.string("定位服务或权限未开")
        case .ineffective(.stillRealLocation):
            return AppLocalization.string("关开定位服务再验证")
        }
    }

    /// 手动再校验一次。
    private func reverify() {
        guard let pair = state.selection else { return }
        startVerification(pair: pair)
    }

    /// 校验虚拟定位是否真的生效（开启后自动跑一次，「重新验证」也走这里）。
    ///
    /// 目标点取**与地图同一套坐标**：回读到的坐标和地图上画蓝点用的是同一
    /// 来源（见 `goToRealLocation` 的说明），两套混着比会平白多出几百米。
    private func startVerification(pair: CoordinateConverter.CoordinatePair) {
        verifier.start(
            target: pair.coordinate(for: state.mapCoordinateSystem),
            provider: realLocation
        )
    }

    /// 收藏夹入口。
    ///
    /// 图标用 `bookmark` 而不是 `star`：地名旁边那个星标做的是「收藏/取消
    /// 当前点」，两者现在并排在同一张卡片里，两个一模一样的星形做两件事
    /// 必然点错。
    private func favoritesCircle(size: CGFloat) -> some View {
        mapCircleButton(
            systemImage: "bookmark.fill",
            accessibilityLabel: AppLocalization.string("收藏位置"),
            size: size,
            badge: favorites.favorites.count
        ) {
            showFavorites = true
        }
    }

    /// 运行日志与诊断入口。
    private func diagnosticsCircle(size: CGFloat) -> some View {
        mapCircleButton(
            systemImage: "doc.text.magnifyingglass",
            accessibilityLabel: AppLocalization.string("运行日志与诊断"),
            size: size
        ) {
            activeSheet = .logs
        }
    }

    /// 选点卡片与状态行共用的小圆钮。
    ///
    /// `badge` 为 0 时不画角标——收藏夹空着还挂个「0」只是噪声。
    private func mapCircleButton(
        systemImage: String,
        accessibilityLabel: String,
        size: CGFloat,
        badge: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: size, height: size)
                    .mapGlassCapsule()
                    .contentShape(Circle())

                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(accent))
                        .offset(x: 3, y: -3)
                }
            }
        }
        .glassPressEffect(scale: 0.9)
        .accessibilityLabel(accessibilityLabel)
    }

    /// 底部唯一的主按钮：**占满整行**、实心强调色、46pt 高。
    ///
    /// 1.0.12 及以前它是「实心主按钮 + 实时位置小胶囊」并排，各占一半宽；
    /// 实时位置挪到右侧浮标之后这里只剩它一个，于是改成整行。
    ///
    /// 换成「实心 + 白字」是有意的：面板里其余元素都是玻璃，只有它是
    /// 「按下去就做事」的那一颗，用实心度把主次分开。
    ///
    /// 圆角取**同心值**（`panelInnerCornerRadius` = 44 − 24 = 20），跟着大卡片的
    /// 拐角走。1.0.12 及以前它是「46pt 胶囊」（`buttonCornerRadius` = 半高 23），
    /// 而离卡片边只有 14pt：44 − 14 = 30 才同心，23 差了一截，两条弧的圆心错开
    /// 7pt，拐角那条缝一头宽一头窄 —— 所以看起来「不跟面板同心」。
    /// 同心值 20 小于半高，不会被系统夹回胶囊。
    private var primaryActionButton: some View {
        Button {
            toggleSpoofing()
        } label: {
            HStack(spacing: 7) {
                if state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: state.isEnabled ? "stop.circle.fill" : "location.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(state.isEnabled
                     ? AppLocalization.string("停止虚拟定位")
                     : AppLocalization.string("开启虚拟定位"))
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: panelInnerCornerRadius,
                                 style: .continuous)
                    .fill(spoofButtonTint)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: panelInnerCornerRadius,
                                 style: .continuous)
            )
        }
        .glassPressEffect(scale: 0.97)
        .disabled(state.selection == nil || state.isBusy)
        // 未选点时按钮是灰的（点了也没用），再压一点不透明度让「不可用」
        // 一眼看得出来 —— 白字压在灰底上对比本来就不高。
        .opacity(state.selection == nil ? 0.6 : 1)
        .accessibilityLabel(state.isEnabled
                            ? AppLocalization.string("停止虚拟定位")
                            : AppLocalization.string("开启虚拟定位"))
    }

    /// 主按钮的着色：未选点时置灰（点了也没用），开启后用红色表示「再点就是关」。
    ///
    /// 关闭态取主题强调色而不是 `accent`：后者读的是资源目录里的
    /// 静态色，跟不了运行时切换的 `.tint`，选完主题这个按钮会留在系统蓝上。
    private var spoofButtonTint: Color {
        guard state.selection != nil else { return .secondary }
        return state.isEnabled ? .red : theme.accent
    }

    /// 回到当前选中的虚拟位置。
    private func centerOnSelection() {
        guard let pair = state.selection else {
            showBanner(AppLocalization.string("请先在地图上选择位置"), style: .warning)
            return
        }
        mapBridge.center(
            on: pair.coordinate(for: state.mapCoordinateSystem),
            meters: MapLocationState.defaultViewportMeters
        )
        showBanner(AppLocalization.string("已回到选点"), style: .info)
    }

    /// 读取设备真实位置并把地图移过去。
    ///
    /// **坐标体系是这里最容易错的一处。** `CLLocationManager` 在国内给回的
    /// 坐标已经是 GCJ-02，而地图上的蓝点就是拿同一个坐标画出来的——两者
    /// 本来就对得上。早先这里一律按 WGS-84 解释、再换算成地图体系去居中，
    /// 相当于又加了一次 500 米左右的偏移，表现就是「点了实时位置，准心
    /// 不在屏幕中间，跑偏了」。
    ///
    /// 正确做法：把回调坐标当成**当前地图体系**的坐标，交给 `CoordinatePair`
    /// 去补另一套。这样居中用的坐标与蓝点完全一致。
    private func goToRealLocation() {
        realLocation.requestOnce { result in
            switch result {
            case .success(let coordinate):
                // 与地图点选同一条判据：境内按 GCJ-02 解释，境外按 WGS-84。
                let pair: CoordinateConverter.CoordinatePair
                switch CoordinateConverter.mapSystem(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ) {
                case .gcj02:
                    pair = CoordinateConverter.CoordinatePair(
                        gcj02Latitude: coordinate.latitude,
                        gcj02Longitude: coordinate.longitude
                    )
                case .wgs84:
                    pair = CoordinateConverter.CoordinatePair(
                        wgs84Latitude: coordinate.latitude,
                        wgs84Longitude: coordinate.longitude
                    )
                }

                // 缩小到街道尺度再居中。
                //
                // 1.0.9 及以前这里只平移（meters 传 nil），理由是「系统地图点
                // 定位也是保持当前比例」。实际用起来不对：地图缩得比较远时
                // 点一下只是把蓝点挪到屏幕中间，**看不出自己到底在哪**，
                // 用户的原话是「点了也不把地图放大」。
                //
                // 现在固定收到 defaultViewportMeters（200 米，与选点、恢复视野
                // 同一档）：这个应用的操作尺度就是「一个楼、一个路口」，
                // 200 米正好是能认出街区的范围。`MapViewBridge.center` 内部
                // 还有 200 米的下限，所以缩得比 200 米更近的视野不会被动拉远。
                mapBridge.center(
                    on: pair.coordinate(for: state.mapCoordinateSystem),
                    meters: MapLocationState.defaultViewportMeters
                )
                showBanner(AppLocalization.string("已定位到当前真实位置"), style: .info)

            case .failure(let failure):
                showBanner(failure.errorDescription
                           ?? AppLocalization.string("获取真实位置失败"), style: .warning)
            }
        }
    }

    // MARK: - 生命周期

    private func handleAppear() {
        restoreLastSelection()
        RuntimeLogger.info("APP", "Home", "主界面已显示")

        // 底部卡片要靠这个值把内容垫回 Home 指示条上方（见底部相关注释）。
        refreshBottomSafeInset()

        // 主动读一次接入方式。网络路径没变化时监听不会回调，不主动拉的话
        // 冷启动后状态会一直停在「未知」，蜂窝下的拦截就不会生效。
        proxy.refreshNetworkTransport()

        // 进入主界面就刷新一次环境状态，让用户立刻看到还差什么。
        Task {
            if runtimeMode.mode == .thirdParty {
                await thirdParty.refresh()
            } else if proxy.syncStatusWithReality() {
                await proxy.verifyCertificateTrust()
                await proxy.verifyWiFiProxy()
            }
        }

        // 探测 MapKit 当前使用的坐标体系。
        probeCoordinateSystem()

        // 如果之前是开启状态，尝试恢复代理并把配置推回去。
        if state.isEnabled, let pair = state.selection {
            Task { await restoreActiveState(pair: pair) }
            // 开着就顺手校验一次：重启后回到主界面，面板上直接给出「现在到底
            // 生效没有」，而不是空着一个「未验证」。没拿到定位权限就不主动
            // 发起——冷启动当场弹系统授权框太突兀。
            if realLocation.isAuthorized {
                startVerification(pair: pair)
            }
        }

        #if UI_TEST_HOOKS
        applyUITestLaunchArguments()
        #endif
    }

    #if UI_TEST_HOOKS
    /// 界面测试用的注入入口。
    ///
    /// 引导弹窗只在「开启虚拟定位成功」之后才弹，而模拟器上开虚拟定位要
    /// Wi-Fi 代理 + 证书信任，端到端跑不起来（会先弹「证书尚未被信任」）。
    /// 所以给界面测试留两个启动参数，让它能把弹窗稳定调出来 —— 不然这条
    /// 用例只能常年 `XCTSkip`，等于没测。
    ///
    /// 只在 **Debug** 编译（`UI_TEST_HOOKS` 编译条件，见 `project.yml`），
    /// Release/出包产物里这段代码根本不存在。
    /// 两个参数的分工见 `Tests/README-ui-tests.md`。
    private func applyUITestLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTestResetGuideAndShow") {
            guide.reset()
            withAnimation(nil) { showsGuide = true }
            RuntimeLogger.info("APP", "SpoofGuide", "界面测试注入：重置并显示引导")
        } else if arguments.contains("-uiTestShowGuideIfNeeded") {
            presentGuideIfNeeded()
        }
    }
    #endif

    private func handleDisappear() {
        searchTask?.cancel()
        geocodeTask?.cancel()
        coordinateSystemProbeTask?.cancel()
        state.persist()
        RuntimeLogger.debug("APP", "Home", "主界面已隐藏")
    }

    private func restoreLastSelection() {
        guard state.selection != nil else { return }
        if let pair = state.selection {
            mapBridge.center(on: pair.coordinate(for: state.mapCoordinateSystem), animated: false)
            refreshDisplayName()
        }
    }

    /// 恢复上一次的开启状态：重启代理并把坐标推回去。
    ///
    /// 注意 MapLocationState 初始化时会把 isEnabled 置为 false，
    /// 这里处理的是「同一次运行中从设置页返回」这种情况。
    private func restoreActiveState(pair: CoordinateConverter.CoordinatePair) async {
        switch runtimeMode.mode {
        case .localProxy:
            // 保活和代理是一对：少了它，代理能起来但活不过一次切后台。
            // 这里放在启动之前，`start()` 是幂等的，已经在跑时只做一次检查。
            BackgroundKeepAlive.shared.start()

            if !proxy.status.isRunning {
                do {
                    try await proxy.start(
                        latitude: pair.wgs84.latitude,
                        longitude: pair.wgs84.longitude,
                        enabled: true,
                        accuracy: state.accuracy,
                        motionRadius: state.motionDriftRadius
                    )
                } catch {
                    state.disable()
                    showBanner(error.localizedDescription, style: .error)
                }
            }
        case .thirdParty:
            await thirdParty.save(
                pair: pair,
                accuracy: state.accuracy,
                motionRadius: state.motionDriftRadius
            )
        }
    }

    // MARK: - 生命周期

    /// 回到前台时自愈。
    ///
    /// 应用一旦被 iOS 挂起，进程内的拦截代理就不再接受新连接；而 Wi-Fi 里的
    /// 手动代理配置还指着 127.0.0.1:8888，于是定位请求全部落空，系统随即退回
    /// 真实定位——这正是「用着用着跳回真实位置」最常见的原因。
    ///
    /// 关键点：`proxy.status` 是我们自己维护的状态，进程被挂起时它**不会**
    /// 变成 `.stopped`，所以这里必须实际探一次代理是否还活着，不能只看状态。
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // 进后台前的最后一次自救。音频一旦被别的应用抢走，播放停掉，
            // 进程随后就被系统挂起——那一刻之后我们再也跑不了任何代码，
            // 所以「检查播放是否还活着」只能放在这里。
            guard state.isEnabled, runtimeMode.mode == .localProxy else { return }
            BackgroundKeepAlive.shared.resumeIfNeeded()

        case .active:
            // 回前台顺手校准一次安全区（读数走窗口，见 refreshBottomSafeInset）。
            refreshBottomSafeInset()
            recoverAfterForeground()

        default:
            break
        }
    }

    /// 读一次屏幕下沿的安全区高度（Home 指示条那一条）。
    ///
    /// 问**窗口**要，不问 SwiftUI：外层 ZStack 为了让底部卡片量到屏幕物理
    /// 下沿，整体忽略了下边安全区，而视图一旦忽略安全区，自己量到的
    /// `proxy.safeAreaInsets` 就是 0（详见 `bottomSafeInset` 的说明）。
    ///
    /// 本工程只支持竖屏（`Info.plist` 里只有 `UIInterfaceOrientationPortrait`），
    /// 这个值读完就稳定；仍然在每次回前台时重读一遍，覆盖分屏/外接屏之类
    /// 尺寸变化的极端情况。
    private func refreshBottomSafeInset() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        let inset = window.safeAreaInsets.bottom
        if bottomSafeInset != inset {
            bottomSafeInset = inset
        }
    }

    /// 回到前台自愈。
    ///
    /// 应用一旦被 iOS 挂起，进程内的拦截代理就不再接受新连接；而 Wi-Fi 里的
    /// 手动代理配置还指着 127.0.0.1:8888，于是定位请求全部落空，系统随即退回
    /// 真实定位——这正是「用着用着跳回真实位置」最常见的原因。
    ///
    /// 关键点：`proxy.status` 是我们自己维护的状态，进程被挂起时它**不会**
    /// 变成 `.stopped`，所以这里必须实际探一次代理是否还活着，不能只看状态。
    /// 保活同理——`isAlive` 问的是播放器，而不是我们记的布尔标志。
    private func recoverAfterForeground() {
        guard state.isEnabled, runtimeMode.mode == .localProxy else { return }

        if !BackgroundKeepAlive.shared.isAlive {
            RuntimeLogger.warn("APP", "KeepAlive", "回前台时保活已失效，重新拉起")
            BackgroundKeepAlive.shared.start()
        }

        Task {
            await proxy.verifyWiFiProxy()
            guard proxy.wiFiProxyState != .configured else { return }

            RuntimeLogger.warn("APP", "Proxy", "回到前台时代理无响应，重新启动")
            proxy.stop()

            // 停掉之后 `status` 变成 `.stopped`，`restoreActiveState` 会把它重新拉起来。
            guard runtimeMode.mode == .localProxy, let pair = state.selection else { return }
            await restoreActiveState(pair: pair)

            await proxy.verifyWiFiProxy()
            if proxy.wiFiProxyState != .configured {
                showBanner(AppLocalization.string("Wi-Fi 代理未生效，请检查代理配置"), style: .error)
            }
        }
    }

    // MARK: - 交互

    private func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        // 点地图先收起图层菜单：菜单是浮在地图上的临时浮层，点别处就算取消。
        if showsLayerMenu {
            withAnimation(.easeInOut(duration: 0.15)) { showsLayerMenu = false }
        }

        // 按「点落在哪个区域」解释这枚坐标，**不按探测出来的体系**。
        //
        // 境内的地图数据一定是 GCJ-02，境外一定是 WGS-84，而换算在境外是
        // 恒等 —— 这条规则不依赖任何启发式判断（判据见
        // `CoordinateConverter.mapSystem`）。1.0.10 走的是探测结果，而探测的
        // 锚点取错了（把高德的 GCJ 值当成了 WGS-84），境内被恒定判成 WGS-84，
        // 于是每个选点写进定位服务的坐标都差一个 GCJ 偏移（数百米），
        // 表现就是「地图选点跟定位出来的位置有偏差」。
        switch CoordinateConverter.mapSystem(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ) {
        case .gcj02:
            state.select(gcj02Latitude: coordinate.latitude, gcj02Longitude: coordinate.longitude)
        case .wgs84:
            state.select(wgs84Latitude: coordinate.latitude, wgs84Longitude: coordinate.longitude)
        }
        pushConfigurationToBackend()
    }

    private func applySearchResult(_ result: SearchResult) {
        state.select(result.pair, name: result.name)
        mapBridge.center(on: result.pair.coordinate(for: state.mapCoordinateSystem))
        searchResults = []
        searchText = result.name
        pushConfigurationToBackend()
    }

    private func applyFavorite(_ favorite: FavoriteLocationStore.FavoriteLocation) {
        state.select(favorite.pair, name: favorite.name)
        favorites.selectedFavoriteID = favorite.id
        mapBridge.center(on: favorite.pair.coordinate(for: state.mapCoordinateSystem))
        pushConfigurationToBackend()
    }

    private func saveFavorite() {
        guard let pair = state.selection else { return }
        let favorite = favorites.add(pair: pair, name: newFavoriteName)
        favorites.selectedFavoriteID = favorite.id
        newFavoriteName = ""
        showBanner(AppLocalization.string("已收藏"), style: .info)
    }

    private func toggleSpoofing() {
        guard let pair = state.selection else {
            showBanner(AppLocalization.string("请先在地图上选择位置"), style: .warning)
            return
        }

        // 授权闸门：只在「要开启」时拦，关闭永远放行 —— 否则用户到期后
        // 连关都关不掉，虚拟定位会一直挂在系统代理上。
        // 纯净版没有授权这回事，整段不参与编译。
        #if !PURE_BUILD
        if !state.isEnabled && !license.isUsable {
            showBanner(licenseBlockMessage, style: .error)
            return
        }
        #endif

        Task {
            await state.withBusyAsync {
                if state.isEnabled {
                    await stopSpoofing()
                } else {
                    await startSpoofing(pair: pair)
                }
            }
        }
    }

    #if !PURE_BUILD
    /// 被授权拦住时的提示文案，按状态给出不同的下一步。
    ///
    /// 路径必须跟着设置页的分组走：1.0.4 把卡密入口收进了「账号」，
    /// 文案里还写「设置 → 授权」的话，用户会去一个不存在的地方找。
    private var licenseBlockMessage: String {
        switch license.status {
        case .trialExpired:
            return AppLocalization.string("试用已结束，请在「设置 → 账号」输入卡密后继续使用")
        case .expired:
            return AppLocalization.string("卡密已过期，请在「设置 → 账号」续期后继续使用")
        default:
            return AppLocalization.string("尚未激活，请在「设置 → 账号」输入卡密或确认网络连接")
        }
    }
    #endif

    private func startSpoofing(pair: CoordinateConverter.CoordinatePair) async {
        switch runtimeMode.mode {
        case .localProxy:
            // 蜂窝下必须拦：应用内代理靠「当前 Wi-Fi 的手动代理设置」生效，
            // iOS 没有给蜂窝配 HTTP 代理的入口。不拦的话代理一样能起来、
            // 开关一样会亮、界面还提示「已开启」，但没有任何流量经过本机，
            // 定位纹丝不动 —— 这是最难排查的一类假成功。
            guard proxy.canUseInAppProxy else {
                RuntimeLogger.warn("APP", "Proxy", "蜂窝网络下拒绝开启应用内代理", details: [
                    "transport": proxy.networkTransport.debugName,
                ])
                showBanner(
                    AppLocalization.string("当前使用移动网络，应用内代理只在 Wi-Fi 下生效。请先连接 Wi-Fi，再开启虚拟定位。"),
                    style: .error
                )
                return
            }

            do {
                try await proxy.start(
                    latitude: pair.wgs84.latitude,
                    longitude: pair.wgs84.longitude,
                    enabled: true,
                    accuracy: state.accuracy,
                    motionRadius: state.motionDriftRadius
                )
                BackgroundKeepAlive.shared.start()
                state.enable()

                // 启动后立刻验证链路，问题早发现比定位不生效再排查省事。
                await proxy.verifyCertificateTrust()
                await proxy.verifyWiFiProxy()

                if proxy.certificateTrustState == .notTrusted {
                    showBanner(AppLocalization.string("证书尚未被信任，定位不会生效"), style: .error)
                } else if proxy.wiFiProxyState != .configured {
                    showBanner(AppLocalization.string("Wi-Fi 代理未生效，请检查代理配置"), style: .error)
                } else {
                    showBanner(AppLocalization.string("虚拟定位已开启"), style: .info)
                    presentGuideIfNeeded()
                    // 开关亮了不等于生效：立刻回读一次确认真伪，结论摆在
                    // 面板上（用户不用再去别的 App 里对照位置）。
                    startVerification(pair: pair)
                }
            } catch {
                showBanner(error.localizedDescription, style: .error)
            }

        case .thirdParty:
            let success = await thirdParty.save(
                pair: pair,
                accuracy: state.accuracy,
                motionRadius: state.motionDriftRadius
            )
            if success {
                state.enable()
                showBanner(AppLocalization.string("坐标已写入客户端"), style: .info)
                presentGuideIfNeeded()
                startVerification(pair: pair)
            } else {
                showBanner(AppLocalization.string("写入失败，请检查客户端模块是否生效"), style: .error)
            }
        }
    }

    /// 开启成功后弹一次「去把定位服务关一下再打开」的引导。
    ///
    /// 定位服务把上一次的坐标缓存在系统进程里，刚开启虚拟定位时地图
    /// 往往还是旧位置。关掉总开关再打开会强制重新查询，这一步不做的话
    /// 用户很容易以为功能没生效。
    ///
    /// 只在**开启成功之后**弹（关闭时不弹）。还弹不弹由 `SpoofGuideStore`
    /// 决定 —— 用户点过「不再提示」就永远不再弹，这件事与定位服务当前
    /// 开着还是关着**无关**。
    private func presentGuideIfNeeded() {
        guard guide.shouldPresent else { return }
        withAnimation(.easeInOut(duration: 0.2)) { showsGuide = true }
    }

    private func stopSpoofing() async {
        // 关掉虚拟定位，校验结论也就作废了（不然面板上会挂着一个
        // 绿色的「已生效」，而位置早就放开了）。
        verifier.reset()

        switch runtimeMode.mode {
        case .localProxy:
            // 先关开关再停代理，避免关闭过程中的请求仍被改写。
            proxy.updateCoordinates(
                latitude: 0, longitude: 0,
                enabled: false,
                accuracy: state.accuracy,
                motionRadius: 0
            )
            proxy.stop()
            BackgroundKeepAlive.shared.stop()
            state.disable()
            showBanner(AppLocalization.string("已停止虚拟定位，请同时关闭 Wi-Fi 代理"), style: .warning)

        case .thirdParty:
            await thirdParty.clear()
            state.disable()
            showBanner(AppLocalization.string("已清除客户端坐标"), style: .info)
        }
    }

    private func pushConfigurationToBackend() {
        guard runtimeMode.mode == .localProxy, proxy.status.isRunning else { return }
        let pair = state.selection
        proxy.updateCoordinates(
            latitude: pair?.wgs84.latitude ?? 0,
            longitude: pair?.wgs84.longitude ?? 0,
            enabled: state.isEnabled,
            accuracy: state.accuracy,
            motionRadius: state.motionDriftRadius
        )
    }

    // MARK: - 地名反查

    private func refreshDisplayName() {
        guard let pair = state.selection else { return }
        geocodeTask?.cancel()
        geocodeTask = Task {
            let location = CLLocation(
                latitude: pair.wgs84.latitude,
                longitude: pair.wgs84.longitude
            )
            let geocoder = CLGeocoder()
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(
                    location,
                    preferredLocale: Locale(identifier: AppLocalization.resolvedLanguageCode)
                )
                guard !Task.isCancelled, let placemark = placemarks.first else { return }
                let name = [placemark.name, placemark.locality, placemark.administrativeArea]
                    .compactMap { $0 }
                    .first ?? ""
                if !name.isEmpty {
                    state.displayName = name
                }
            } catch {
                // 反查失败不影响选点，静默处理。
                RuntimeLogger.debug("APP", "Home", "地名反查失败", details: [
                    "error": (error as NSError).localizedDescription,
                ])
            }
        }
    }

    // MARK: - 搜索

    private func scheduleSearch(for text: String) {
        searchTask?.cancel()
        searchError = nil

        // 搜索结果一出来，右下角那两个浮标（连同展开的图层菜单）就会被收起
        // ——菜单的状态得跟着归零，否则结果清空后它会自己冒出来。
        if showsLayerMenu {
            withAnimation(.easeInOut(duration: 0.15)) { showsLayerMenu = false }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }

        searchTask = Task {
            // 防抖：等 400ms，如果用户继续输入就取消这次搜索。
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(query: trimmed)
        }
    }

    private func performSearch() {
        searchTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask = Task { await runSearch(query: trimmed) }
    }

    private func runSearch(query: String) async {
        await MainActor.run { isSearching = true }
        defer { Task { @MainActor in isSearching = false } }

        // 同时查两套坐标体系：境外的 Apple 服务器用 WGS-84 返回，
        // 国内点位需要补上偏移后才能在 GCJ-02 地图上显示正确。
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = mapBridge.currentRegion

        do {
            let response = try await MKLocalSearch(request: request).start()
            let results = response.mapItems.prefix(12).compactMap { item -> SearchResult? in
                let coordinate = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

                // Apple 在国内返回的是 GCJ-02，境外是 WGS-84，按点落在哪个
                // 区域分流 —— 和地图点选用的是同一条判据，两处不会再走偏。
                let pair: CoordinateConverter.CoordinatePair
                switch CoordinateConverter.mapSystem(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ) {
                case .wgs84:
                    pair = CoordinateConverter.CoordinatePair(
                        wgs84Latitude: coordinate.latitude,
                        wgs84Longitude: coordinate.longitude
                    )
                case .gcj02:
                    pair = CoordinateConverter.CoordinatePair(
                        gcj02Latitude: coordinate.latitude,
                        gcj02Longitude: coordinate.longitude
                    )
                }

                let subtitle = [item.placemark.locality, item.placemark.administrativeArea]
                    .compactMap { $0 }
                    .joined(separator: " ")

                return SearchResult(
                    name: item.name ?? query,
                    subtitle: subtitle,
                    pair: pair
                )
            }

            await MainActor.run {
                searchResults = Array(results)
                if results.isEmpty {
                    searchError = AppLocalization.string("没有找到匹配的地点")
                }
            }
        } catch {
            await MainActor.run {
                searchResults = []
                searchError = AppLocalization.string("搜索失败：%@", (error as NSError).localizedDescription)
            }
        }
    }

    // MARK: - 坐标体系探测

    /// 判断 MapKit 当前返回的是 GCJ-02 还是 WGS-84，**只为确认与留痕**。
    ///
    /// 做成「查一个已知坐标的固定锚点，看它更接近哪一套」：拿真实搜索接口
    /// 确认地图数据源还是国内那一套（高德）。判定结果会被区域判据卡一道
    /// （见 `CoordinateConverter.inferSystem`），**判成 WGS-84 时视为探错**、
    /// 保留原值 —— 坐标怎么解释由 `CoordinateConverter.mapSystem` 决定，
    /// 不经过这里。
    ///
    /// ## 锚点为什么必须换算一次
    ///
    /// `tiananmenGCJ02` 那对数字（116.397499, 39.908722）是**高德给天安门的
    /// GCJ-02 输出**，不是 WGS-84。1.0.10 及以前直接把它当 `referenceWGS84`
    /// 传了进来，漏掉文档里「反算出对应的 WGS-84 坐标」那一步，于是两个候选
    /// 落点几乎重合在「高德那个点」上：地图返回 GCJ 坐标时反而离「WGS-84
    /// 候选」更近，境内设备被**恒定判成 WGS-84**。
    ///
    /// 这里的报错很隐蔽 —— 界面上的选点标记仍然落在手指按下的地方（它用的
    /// 是同一个错误值，自洽），但写进定位服务的目标坐标整体偏了数百米。
    private func probeCoordinateSystem() {
        coordinateSystemProbeTask?.cancel()
        coordinateSystemProbeTask = Task {
            let anchor = CoordinateConverter.tiananmenWGS84

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = "天安门"
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude),
                latitudinalMeters: 3000,
                longitudinalMeters: 3000
            )

            do {
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled, let item = response.mapItems.first else { return }

                let probe = CoordinateConverter.inferSystem(
                    mapCoordinate: item.placemark.coordinate,
                    referenceWGS84: CLLocationCoordinate2D(
                        latitude: anchor.latitude,
                        longitude: anchor.longitude
                    )
                )

                if probe.contradictsRegion {
                    // 探成 WGS-84 而锚点在境内 —— 一定是探测本身错了，
                    // 不是地图换了体系。记一条日志，值保持原样。
                    RuntimeLogger.warn("APP", "Home", "坐标体系探测与区域判据矛盾，判定作废", details: [
                        "mapCoordinate": "\(item.placemark.coordinate.latitude),\(item.placemark.coordinate.longitude)",
                        "distanceToWGS84": String(format: "%.0f", probe.distanceToWGS84),
                        "distanceToGCJ02": String(format: "%.0f", probe.distanceToGCJ02),
                        "expected": probe.expectedSystem.diagnosticName,
                    ])
                    return
                }

                guard let inferred = probe.inferredSystem, probe.isConclusive else {
                    RuntimeLogger.debug("APP", "Home", "坐标体系探测结果不明确，保留原值", details: [
                        "distanceToWGS84": String(format: "%.0f", probe.distanceToWGS84),
                        "distanceToGCJ02": String(format: "%.0f", probe.distanceToGCJ02),
                        "separation": String(format: "%.0f", probe.separation),
                    ])
                    return
                }

                await MainActor.run {
                    if state.mapCoordinateSystem != inferred {
                        RuntimeLogger.info("APP", "Home", "坐标体系判定更新", details: [
                            "system": inferred.diagnosticName,
                        ])
                        state.mapCoordinateSystem = inferred
                    }
                }
            } catch {
                RuntimeLogger.debug("APP", "Home", "坐标体系探测失败", details: [
                    "error": (error as NSError).localizedDescription,
                ])
            }
        }
    }

    // MARK: - 提示与重命名

    private func showBanner(_ text: String, style: InlineAlert.Style) {
        bannerDismissTask?.cancel()
        withAnimation {
            banner = BannerMessage(text: text, style: style)
        }
        bannerDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation { banner = nil }
            }
        }
    }

    private func renameFavoriteSheet(_ favorite: FavoriteLocationStore.FavoriteLocation) -> some View {
        NavigationView {
            Form {
                Section {
                    TextField(AppLocalization.string("名称"), text: $editName)
                }
                Section {
                    Button(role: .destructive) {
                        favorites.remove(id: favorite.id)
                        editingFavorite = nil
                    } label: {
                        Label(AppLocalization.string("删除该收藏"), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(AppLocalization.string("编辑收藏"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("取消")) { editingFavorite = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("保存")) {
                        favorites.rename(id: favorite.id, to: editName)
                        editingFavorite = nil
                    }
                }
            }
        }
    }
}

// MARK: - 小组件

/// 坐标行末尾的复制图标。
///
/// 只画一个图标、不带文字标签 —— 因为它紧跟在对应坐标后面，
/// 「复制这一行」的语义已经由位置本身表达了。原来的胶囊按钮带
/// 「GCJ-02」「WGS-84」文字，既占宽度又和左边的坐标标签重复。
private struct CoordinateCopyIcon: View {

    let accessibilityLabel: String
    let value: String?

    @State private var copied = false

    var body: some View {
        Button {
            guard let value else { return }
            UIPasteboard.general.string = value
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(value == nil)
        .accessibilityLabel(AppLocalization.string("复制%@坐标", accessibilityLabel))
    }
}

private struct FavoriteChip: View {

    let favorite: FavoriteLocationStore.FavoriteLocation
    let isSelected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    @Environment(\.themeAccent) private var accent

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "star.fill" : "star")
                    .font(.caption2)
                Text(favorite.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                isSelected ? accent.opacity(0.18) : Color(.quaternarySystemFill),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? accent : Color.primary)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in onLongPress() }
        )
    }
}

private struct StatusPill: View {

    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
}
