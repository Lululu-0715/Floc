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

    @ObservedObject var setup: SetupCoordinator
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var thirdParty = ThirdPartyProxyManager.shared
    @ObservedObject private var runtimeMode = RuntimeModeStore.shared
    @ObservedObject private var remoteConfiguration = AppRemoteConfigurationStore.shared
    @ObservedObject private var license = LicenseManager.shared

    @StateObject private var state = MapLocationState()
    @StateObject private var favorites = FavoriteLocationStore()
    @StateObject private var mapBridge = MapViewBridge()
    @StateObject private var realLocation = RealLocationProvider()

    @State private var searchText = ""
    @State private var searchResults: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?

    @State private var activeSheet: HomeSheet?
    @State private var editingFavorite: FavoriteLocationStore.FavoriteLocation?
    @State private var editName = ""
    @State private var showSaveFavorite = false
    @State private var newFavoriteName = ""

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

    var body: some View {
        ZStack(alignment: .top) {
            mapLayer
            overlayLayer
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView(setup: setup, state: state, favorites: favorites)
            case .logs:
                DiagnosticsView(state: state)
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
        .ignoresSafeArea(edges: .bottom)
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
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .mapGlassSurface()

                Button {
                    activeSheet = .settings
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 42, height: 42)
                        .mapGlassSurface()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("设置"))
            }

            if !searchResults.isEmpty {
                searchResultsList
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var searchResultsList: some View {
        VStack(spacing: 0) {
            ForEach(searchResults) { result in
                Button {
                    applySearchResult(result)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(Color.accentColor)
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
        .mapGlassSurface()
        .frame(maxHeight: 280)
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
        .mapGlassSurface()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    // 精度选择器现在挂在两行坐标的右侧，不再单独占一行：
                    // 它是低频选项，压在右下角既顺手又不增加面板高度。
                    HStack(alignment: .center, spacing: 10) {
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

                        Spacer(minLength: 0)

                        accuracyPicker
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: GlassMetrics.mapCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    /// 精度选择器。原来单独占一行，现在挪到两行坐标的最右侧，
    /// 底部面板因此少一行高度。
    private var accuracyPicker: some View {
        Picker(AppLocalization.string("精度"), selection: $state.accuracy) {
            Text("10 m").tag(10)
            Text("25 m").tag(25)
            Text("50 m").tag(50)
            Text("100 m").tag(100)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel(AppLocalization.string("精度"))
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
                StatusPill(
                    icon: proxy.wiFiProxyState == .configured ? "link" : "link.badge.plus",
                    text: proxy.wiFiProxyState.displayText,
                    color: proxy.wiFiProxyState == .configured ? .green : .orange
                )
            } else {
                StatusPill(
                    icon: thirdParty.state.isUsable ? "link" : "link.badge.plus",
                    text: thirdParty.state.displayText,
                    color: thirdParty.state.isUsable ? .green : .orange
                )
            }

            Spacer()

            Button {
                activeSheet = .logs
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
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
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(spoofButtonTint)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .mapGlassSurface()
                .contentShape(RoundedRectangle(cornerRadius: GlassMetrics.mapCornerRadius,
                                               style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(state.selection == nil || state.isBusy)
            .accessibilityLabel(state.isEnabled
                                ? AppLocalization.string("停止虚拟定位")
                                : AppLocalization.string("开启虚拟定位"))

            realLocationButton
        }
    }

    /// 主按钮的着色：未选点时置灰（点了也没用），开启后用红色表示「再点就是关」。
    private var spoofButtonTint: Color {
        guard state.selection != nil else { return .secondary }
        return state.isEnabled ? .red : .accentColor
    }

    /// 「实时位置」按钮。
    ///
    /// 点一下把地图跳回设备当前真实位置（并拉到 200 米，和初始视野一致）；
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
            .foregroundStyle(Color.accentColor)
            .frame(width: 62, height: 44)
            .mapGlassSurface()
            .contentShape(RoundedRectangle(cornerRadius: GlassMetrics.mapCornerRadius,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
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
    /// 定位回调给的是 WGS-84，必须按当前地图体系换算后再居中，
    /// 否则国内会偏出几百米——和选点走的是同一套换算。
    /// 缩放固定到 200 米，和进应用时的初始视野保持一致。
    private func goToRealLocation() {
        realLocation.requestOnce { result in
            switch result {
            case .success(let coordinate):
                let pair = CoordinateConverter.CoordinatePair(
                    wgs84Latitude: coordinate.latitude,
                    wgs84Longitude: coordinate.longitude
                )
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
        guard phase == .active else { return }
        guard state.isEnabled, runtimeMode.mode == .localProxy else { return }

        // 保活可能被系统中断（音频会话被其他应用抢占等），回前台重新拉起。
        // `start()` 是幂等的，已在运行时会直接返回。
        BackgroundKeepAlive.shared.start()

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
        // MapKit 返回的坐标属于当前地图体系，交给对应构造器换算另一套。
        switch state.mapCoordinateSystem {
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
        if !state.isEnabled && !license.isUsable {
            showBanner(licenseBlockMessage, style: .error)
            return
        }

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

    /// 被授权拦住时的提示文案，按状态给出不同的下一步。
    private var licenseBlockMessage: String {
        switch license.status {
        case .trialExpired:
            return AppLocalization.string("试用已结束，请在「设置 → 授权」输入卡密后继续使用")
        case .expired:
            return AppLocalization.string("卡密已过期，请在「设置 → 授权」续期后继续使用")
        default:
            return AppLocalization.string("尚未激活，请在「设置 → 授权」输入卡密或确认网络连接")
        }
    }

    private func startSpoofing(pair: CoordinateConverter.CoordinatePair) async {
        switch runtimeMode.mode {
        case .localProxy:
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

                // Apple 在国内返回的是 GCJ-02，境外是 WGS-84，用国境判断来分流。
                let pair: CoordinateConverter.CoordinatePair
                if CoordinateConverter.isOutOfChina(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ) {
                    pair = CoordinateConverter.CoordinatePair(
                        wgs84Latitude: coordinate.latitude,
                        wgs84Longitude: coordinate.longitude
                    )
                } else {
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

    /// 判断 MapKit 当前返回的是 GCJ-02 还是 WGS-84。
    ///
    /// 做法：去查一个已知坐标的固定锚点，把返回坐标分别按两套体系解释，
    /// 与真实坐标偏移更小的那个即为当前体系。这是启发式方法，取不到结果时
    /// 保留上一次的判断。
    private func probeCoordinateSystem() {
        coordinateSystemProbeTask?.cancel()
        coordinateSystemProbeTask = Task {
            let anchorLatitude = 39.908722
            let anchorLongitude = 116.397499

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = "天安门"
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: anchorLatitude, longitude: anchorLongitude),
                latitudinalMeters: 3000,
                longitudinalMeters: 3000
            )

            do {
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled, let item = response.mapItems.first else { return }

                let probe = CoordinateConverter.inferSystem(
                    mapCoordinate: item.placemark.coordinate,
                    referenceWGS84: CLLocationCoordinate2D(
                        latitude: anchorLatitude,
                        longitude: anchorLongitude
                    )
                )

                guard let inferred = probe.inferredSystem, probe.isConclusive else {
                    RuntimeLogger.debug("APP", "Home", "坐标体系探测结果不明确，保留原值")
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
                isSelected ? Color.accentColor.opacity(0.18) : Color(.quaternarySystemFill),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
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
