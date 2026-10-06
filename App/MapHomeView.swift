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

    @ObservedObject var setup: SetupCoordinator
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var thirdParty = ThirdPartyProxyManager.shared
    @ObservedObject private var runtimeMode = RuntimeModeStore.shared
    @ObservedObject private var remoteConfiguration = AppRemoteConfigurationStore.shared

    @StateObject private var state = MapLocationState()
    @StateObject private var favorites = FavoriteLocationStore()
    @StateObject private var mapBridge = MapViewBridge()

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

    /// 地图图层。默认卫星混合图，用户可在地图右上角切换。
    @State private var mapType: MapTypeOption = .hybrid

    @State private var banner: BannerMessage?
    @State private var bannerDismissTask: Task<Void, Never>?

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
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
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
        .onChange(of: state.motionSimulationEnabled) { _ in
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
                InlineAlert(text: banner.text, style: banner.style)
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
                HStack {
                    Spacer(minLength: 0)
                    mapTypeSwitcher
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .transition(.opacity)
            }
            Spacer()
            bottomPanel
        }
        .animation(.easeInOut(duration: 0.2), value: banner)
    }

    /// 地图右上角的玻璃胶囊图层切换。
    private var mapTypeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(MapTypeOption.allCases) { option in
                GlassSegmentButton(
                    systemImage: option.systemImage,
                    accessibilityLabel: option.displayName,
                    isSelected: mapType == option
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mapType = option
                    }
                }
            }
        }
        .padding(4)
        .glassCard(cornerRadius: 20, shadowRadius: 10)
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
                .padding(.vertical, 11)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                Button {
                    activeSheet = .settings
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(width: 42, height: 42)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.displayName.isEmpty ? AppLocalization.string("已选位置") : state.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    if let pair = state.selection {
                        // 国内用户在导航类应用里看到的通常是 GCJ-02，
                        // 但写进定位服务的是 WGS-84，所以两个都展示出来。
                        Text(String(format: "GCJ-02  %.6f, %.6f",
                                    pair.gcj02.latitude, pair.gcj02.longitude))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(String(format: "WGS-84  %.6f, %.6f",
                                    pair.wgs84.latitude, pair.wgs84.longitude))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

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
                        .font(.title3)
                        .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                CoordinateCopyButton(
                    label: "GCJ-02",
                    value: state.selection.map {
                        String(format: "%.6f,%.6f", $0.gcj02.latitude, $0.gcj02.longitude)
                    }
                )
                CoordinateCopyButton(
                    label: "WGS-84",
                    value: state.selection.map {
                        String(format: "%.6f,%.6f", $0.wgs84.latitude, $0.wgs84.longitude)
                    }
                )

                Picker(AppLocalization.string("精度"), selection: $state.accuracy) {
                    Text("10 m").tag(10)
                    Text("25 m").tag(25)
                    Text("50 m").tag(50)
                    Text("100 m").tag(100)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
        .padding(14)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
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

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                toggleSpoofing()
            } label: {
                HStack(spacing: 8) {
                    if state.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: state.isEnabled ? "stop.circle.fill" : "location.fill")
                    }
                    Text(state.isEnabled
                         ? AppLocalization.string("停止虚拟定位")
                         : AppLocalization.string("开启虚拟定位"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .tint(state.isEnabled ? .red : .accentColor)
            .disabled(state.selection == nil || state.isBusy)

            Button {
                guard let pair = state.selection else {
                    showBanner(AppLocalization.string("请先在地图上选择位置"), style: .warning)
                    return
                }
                mapBridge.center(on: pair.coordinate(for: state.mapCoordinateSystem))
            } label: {
                Image(systemName: "location.circle")
                    .font(.title3)
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(.bordered)
            .disabled(state.selection == nil)
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
            } else if proxy.status.isRunning {
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
                        motionEnabled: state.motionSimulationEnabled
                    )
                } catch {
                    state.disable()
                    showBanner(error.localizedDescription, style: .error)
                }
            }
        case .thirdParty:
            await thirdParty.save(pair: pair, accuracy: state.accuracy)
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

    private func startSpoofing(pair: CoordinateConverter.CoordinatePair) async {
        switch runtimeMode.mode {
        case .localProxy:
            do {
                try await proxy.start(
                    latitude: pair.wgs84.latitude,
                    longitude: pair.wgs84.longitude,
                    enabled: true,
                    accuracy: state.accuracy,
                    motionEnabled: state.motionSimulationEnabled
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
                }
            } catch {
                showBanner(error.localizedDescription, style: .error)
            }

        case .thirdParty:
            let success = await thirdParty.save(pair: pair, accuracy: state.accuracy)
            if success {
                state.enable()
                showBanner(AppLocalization.string("坐标已写入客户端"), style: .info)
            } else {
                showBanner(AppLocalization.string("写入失败，请检查客户端模块是否生效"), style: .error)
            }
        }
    }

    private func stopSpoofing() async {
        switch runtimeMode.mode {
        case .localProxy:
            // 先关开关再停代理，避免关闭过程中的请求仍被改写。
            proxy.updateCoordinates(
                latitude: 0, longitude: 0,
                enabled: false,
                accuracy: state.accuracy,
                motionEnabled: false
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
            motionEnabled: state.motionSimulationEnabled
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

private struct CoordinateCopyButton: View {

    let label: String
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
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(.quaternarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(value == nil)
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
