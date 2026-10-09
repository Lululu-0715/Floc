import CoreLocation
import MapKit
import SwiftUI

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

    /// 「去把定位服务关一下再打开」的提示。
    ///
    /// 每次启动最多弹一次：定位服务有自己的一层缓存，第一次开启虚拟定位
    /// 基本都要踢一下才会刷新，但每开一次弹一次就成骚扰了。想再看的话
    /// 设置 → 关于 → 用户指南里有完整步骤。
    @State private var showLocationRefreshPrompt = false
    @State private var didShowLocationRefreshPrompt = false

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
        }
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
        .alert(AppLocalization.string("让位置立刻刷新"), isPresented: $showLocationRefreshPrompt) {
            Button(AppLocalization.string("打开定位服务设置")) {
                SystemSettingsNavigator.openLocationServices()
            }
            Button(AppLocalization.string("我知道了"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("如果地图还显示原来的位置：打开「设置 → 隐私与安全性 → 定位服务」，把总开关关掉，等 5–10 秒再打开。一次不行就多试几次，定位缓存需要被踢掉才会重新取坐标。"))
        }
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: scenePhase) { newPhase in
            handleScenePhase(newPhase)
        }
        .onChange(of: state.selection) { _ in
            state.persist()
            refreshDisplayName()
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
        // 这里**只让地图层**忽略安全区。ZStack 里的覆盖层（搜索框、图层
        // 切换、底部面板）不受兄弟节点影响，仍然按安全区排布，所以搜索框
        // 不会顶到刘海或状态栏下面去——底边同理：底部面板一直让开 Home
        // 指示条，靠的就是这条性质。
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
            // 搜索结果展开时就收起图层切换，避免两个浮层挤在一起。
            if searchResults.isEmpty {
                HStack(alignment: .top) {
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .transition(.opacity)
            }
            Spacer()
            // 图层/地球/显示器三连放在地图右下角、底部面板上方。
            // 放右下是因为这三个按钮是「看图」用的，和底部面板的操作区
            // 分开摆放，右手单手够得着，也不会压住左下角的地图内容。
            if searchResults.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    mapTypeSwitcher
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
            bottomPanel
        }
        .animation(.easeInOut(duration: 0.2), value: banner)
    }

    /// 地图右下角的玻璃图层切换（竖排）。
    ///
    /// 竖排是有意的：横排时三个图标占满一行，会和上方的地图内容抢横向空间；
    /// 竖排后每个按钮 36×34，热区够大又不压地图。
    /// 圆角与材质全部走 `mapGlassSurface()`，和地图页其他浮层保持一致。
    private var mapTypeSwitcher: some View {
        VStack(spacing: 2) {
            ForEach(MapTypeOption.allCases) { option in
                GlassSegmentButton(
                    systemImage: option.systemImage,
                    accessibilityLabel: option.displayName,
                    isSelected: mapType == option,
                    itemSize: CGSize(width: 36, height: 34)
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mapType = option
                    }
                }
            }
        }
        .padding(4)
        .mapGlassSurface()
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
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .mapGlassSurface()

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
                        .mapGlassSurface()
                        // 玻璃本身没有 hit area，图标那点像素才是热区；
                        // 显式给整块定形，避免「点边角没反应」。
                        .contentShape(RoundedRectangle(cornerRadius: GlassMetrics.mapCornerRadius,
                                                       style: .continuous))
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

            statusRow
            actionButtons
        }
        .padding(14)
        .mapGlassSurface(cornerRadius: GlassMetrics.mapPanelCornerRadius)
        // 左右 16pt，和地图页其他浮层（搜索框、提示条、图层切换）对齐 ——
        // 它们本来就是这个数。1.0.6 一度收到 6pt，想把面板往外推到屏幕圆角
        // 附近，结果面板左右两条边和上面那些浮层对不齐，看起来像是"贴边了"。
        // 真正要贴近的是**下边**，横向上跟页面节奏保持一致才不别扭。
        //
        // 底边这 2pt 是相对「安全区下沿」而不是屏幕物理下沿 —— 面板仍然让开
        // 那条 Home 指示条，只是把它和屏幕下沿之间的距离压到最小（1.0.7 是 4pt，
        // 用户希望再压紧一档）。
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
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
                VStack(spacing: 6) {
                    favoritesCircle(size: 30)
                    diagnosticsCircle(size: 30)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: GlassMetrics.mapCornerRadius, style: .continuous)
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

    /// 底部两个动作按钮。
    ///
    /// 两个都走 `mapGlassSurface()`，与上方的搜索框、设置按钮是同一套外观，
    /// 而且**各自独立成卡片**（原来是「实心主按钮 + 淡蓝小按钮」拼在一行，
    /// 和地图页其他浮层看起来不是一套东西）。
    ///
    /// 层级改由**颜色**区分而不是面积：主按钮用强调色/红色，实时位置用
    /// 次级灰。这样两者长得一样，轻重仍然分得清。
    /// 高度固定 44pt——iOS 的最小可靠点击高度，够用且不臃肿。
    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                toggleSpoofing()
            } label: {
                HStack(spacing: 7) {
                    if state.isBusy {
                        ProgressView().controlSize(.small)
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
                .foregroundStyle(spoofButtonTint)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .mapGlassCapsule()
                .contentShape(Capsule(style: .continuous))
            }
            .glassPressEffect(scale: 0.95)
            .disabled(state.selection == nil || state.isBusy)
            .accessibilityLabel(state.isEnabled
                                ? AppLocalization.string("停止虚拟定位")
                                : AppLocalization.string("开启虚拟定位"))

            realLocationButton
        }
    }

    /// 主按钮的着色：未选点时置灰（点了也没用），开启后用红色表示「再点就是关」。
    ///
    /// 关闭态取主题强调色而不是 `accent`：后者读的是资源目录里的
    /// 静态色，跟不了运行时切换的 `.tint`，选完主题这个按钮会留在系统蓝上。
    private var spoofButtonTint: Color {
        guard state.selection != nil else { return .secondary }
        return state.isEnabled ? .red : theme.accent
    }

    /// 「实时位置」按钮。
    ///
    /// 点一下把地图跳到设备当前真实位置，并**把视野收进到街道尺度**
    /// （`MapLocationState.defaultViewportMeters`）。
    /// 长按回到已选点——选点才是这个应用的主角，所以「回到选点」比
    /// 「回到真实位置」更次级，放在长按上。
    private var realLocationButton: some View {
        Button {
            goToRealLocation()
        } label: {
            VStack(spacing: 1) {
                if realLocation.isLocating {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "location.viewfinder")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(AppLocalization.string("实时位置"))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(theme.accent)
            .frame(width: 62, height: 44)
            .mapGlassCapsule()
            .contentShape(Capsule(style: .continuous))
        }
        .glassPressEffect(scale: 0.95)
        .disabled(realLocation.isLocating)
        .accessibilityLabel(AppLocalization.string("实时位置"))
        .accessibilityHint(AppLocalization.string("长按回到已选点"))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in centerOnSelection() }
        )
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
        }
    }

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
            recoverAfterForeground()

        default:
            break
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
                    presentLocationRefreshPromptIfNeeded()
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
                presentLocationRefreshPromptIfNeeded()
            } else {
                showBanner(AppLocalization.string("写入失败，请检查客户端模块是否生效"), style: .error)
            }
        }
    }

    /// 开启成功后提示一次「去关一下定位服务再打开」。
    ///
    /// 定位服务把上一次的坐标缓存在系统进程里，刚开启虚拟定位时地图
    /// 往往还是旧位置。关掉总开关再打开会强制重新查询，这一步不做的话
    /// 用户很容易以为功能没生效。
    private func presentLocationRefreshPromptIfNeeded() {
        guard !didShowLocationRefreshPrompt else { return }
        didShowLocationRefreshPrompt = true
        showLocationRefreshPrompt = true
    }

    private func stopSpoofing() async {
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
