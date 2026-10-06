import Foundation

/// 收藏位置的存储。
///
/// 用 JSON 数组整体写入 App Group 的 UserDefaults。收藏量级很小（几十条），
/// 不需要引入数据库。
@MainActor
final class FavoriteLocationStore: ObservableObject {

    struct FavoriteLocation: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var pair: CoordinateConverter.CoordinatePair
        var createdAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            pair: CoordinateConverter.CoordinatePair,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.pair = pair
            self.createdAt = createdAt
        }
    }

    /// 收藏条数上限，避免无序增长。
    static let maximumCount = 50

    @Published private(set) var favorites: [FavoriteLocation] = []

    /// 当前被选中的收藏（用于界面上高亮）。变更即写盘，重启后能恢复。
    @Published var selectedFavoriteID: UUID? {
        didSet { persistSelection() }
    }

    private let defaults: UserDefaults
    private let storageKey = "favoriteLocations"
    private let selectionKey = "favoriteSelectedID"

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        load()
    }

    var selectedFavorite: FavoriteLocation? {
        guard let selectedFavoriteID else { return nil }
        return favorites.first { $0.id == selectedFavoriteID }
    }

    /// 添加一条收藏。名称留空时自动生成「位置 N」。
    @discardableResult
    func add(
        pair: CoordinateConverter.CoordinatePair,
        name: String
    ) -> FavoriteLocation {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty
            ? AppLocalization.string("位置 %d", favorites.count + 1)
            : trimmed

        let favorite = FavoriteLocation(name: finalName, pair: pair)
        favorites.insert(favorite, at: 0)

        if favorites.count > Self.maximumCount {
            let removed = favorites.suffix(favorites.count - Self.maximumCount)
            favorites.removeLast(favorites.count - Self.maximumCount)
            RuntimeLogger.info("APP", "Favorites", "超出上限，移除最旧的收藏", details: [
                "removed": String(removed.count),
            ])
        }

        persist()
        RuntimeLogger.info("APP", "Favorites", "已添加收藏", details: ["name": finalName])
        return favorite
    }

    /// 删除一条收藏。
    func remove(id: UUID) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        let removed = favorites.remove(at: index)
        if selectedFavoriteID == id {
            selectedFavoriteID = nil
        }
        persist()
        RuntimeLogger.info("APP", "Favorites", "已删除收藏", details: ["name": removed.name])
    }

    /// 重命名。
    func rename(id: UUID, to newName: String) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        favorites[index].name = trimmed
        persist()
    }

    /// 判断某个坐标是否已被收藏。
    func contains(pair: CoordinateConverter.CoordinatePair) -> FavoriteLocation? {
        favorites.first { $0.pair.matchesWGS84(
            latitude: pair.wgs84.latitude,
            longitude: pair.wgs84.longitude
        ) }
    }

    /// 清空全部收藏。
    func removeAll() {
        favorites.removeAll()
        selectedFavoriteID = nil
        persist()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            favorites = try JSONDecoder().decode([FavoriteLocation].self, from: data)
        } catch {
            RuntimeLogger.warn("APP", "Favorites", "收藏数据解析失败，已重置", details: [
                "error": error.localizedDescription,
            ])
            favorites = []
        }

        // 恢复上次选中的收藏。对应条目可能已被删除，所以要再核对一次存在性。
        if let raw = defaults.string(forKey: selectionKey), let id = UUID(uuidString: raw) {
            selectedFavoriteID = favorites.contains { $0.id == id } ? id : nil
        }
    }

    private func persistSelection() {
        defaults.set(selectedFavoriteID?.uuidString, forKey: selectionKey)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(favorites)
            defaults.set(data, forKey: storageKey)
        } catch {
            RuntimeLogger.error("APP", "Favorites", "收藏数据写入失败", details: [
                "error": error.localizedDescription,
            ])
        }
    }
}
