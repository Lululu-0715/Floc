import XCTest
@testable import Floc

/// 收藏位置存储测试。
///
/// 初始化时注入独立的 `UserDefaults` 实例，测试之间互不干扰。
@MainActor
final class FavoriteLocationStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // 每个测试用独立的 suite，避免污染真实存储
        suiteName = "FavoriteLocationStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> FavoriteLocationStore {
        FavoriteLocationStore(defaults: defaults)
    }

    private func makePair(latitude: Double = 39.908722, longitude: Double = 116.397499)
        -> CoordinateConverter.CoordinatePair {
        CoordinateConverter.CoordinatePair(
            wgs84Latitude: latitude,
            wgs84Longitude: longitude
        )
    }

    // MARK: - 增删

    func testAddFavorite() {
        let store = makeStore()
        store.add(pair: makePair(), name: "天安门")

        XCTAssertEqual(store.favorites.count, 1)
        XCTAssertEqual(store.favorites.first?.name, "天安门")
    }

    func testAddAssignsUniqueIdentifiers() {
        let store = makeStore()
        store.add(pair: makePair(latitude: 39.9, longitude: 116.4), name: "位置一")
        store.add(pair: makePair(latitude: 31.2, longitude: 121.5), name: "位置二")

        let ids = Set(store.favorites.map(\.id))
        XCTAssertEqual(ids.count, 2, "每个收藏应有独立 ID")
    }

    func testAddUsesFallbackNameWhenBlank() {
        let store = makeStore()
        store.add(pair: makePair(), name: "   ")

        XCTAssertFalse(store.favorites[0].name.isEmpty, "空白名称应替换为默认名")
    }

    func testAddTrimsWhitespaceFromName() {
        let store = makeStore()
        store.add(pair: makePair(), name: "  外滩  ")

        XCTAssertEqual(store.favorites[0].name, "外滩")
    }

    func testRemoveFavorite() {
        let store = makeStore()
        store.add(pair: makePair(), name: "待删除")
        let id = store.favorites[0].id

        store.remove(id: id)

        XCTAssertTrue(store.favorites.isEmpty)
    }

    func testRemoveNonexistentIDIsHarmless() {
        let store = makeStore()
        store.add(pair: makePair(), name: "保留")

        store.remove(id: UUID())

        XCTAssertEqual(store.favorites.count, 1, "删除不存在的 ID 不应影响现有数据")
    }

    func testRemoveAll() {
        let store = makeStore()
        store.add(pair: makePair(latitude: 39.9, longitude: 116.4), name: "一")
        store.add(pair: makePair(latitude: 31.2, longitude: 121.5), name: "二")

        store.removeAll()

        XCTAssertTrue(store.favorites.isEmpty)
    }

    // MARK: - 改名

    func testRename() {
        let store = makeStore()
        store.add(pair: makePair(), name: "旧名")

        store.rename(id: store.favorites[0].id, to: "新名")

        XCTAssertEqual(store.favorites[0].name, "新名")
    }

    func testRenameIgnoresBlankName() {
        let store = makeStore()
        store.add(pair: makePair(), name: "原名")

        store.rename(id: store.favorites[0].id, to: "   ")

        XCTAssertEqual(store.favorites[0].name, "原名", "空白名称不应覆盖原名")
    }

    // MARK: - 容量上限

    func testCapacityIsEnforcedAtFifty() {
        let store = makeStore()

        for index in 0..<(FavoriteLocationStore.maximumCount + 10) {
            // 每个位置略微不同，避免被去重
            store.add(
                pair: makePair(
                    latitude: 20.0 + Double(index) * 0.1,
                    longitude: 110.0 + Double(index) * 0.1
                ),
                name: "位置 \(index)"
            )
        }

        XCTAssertEqual(
            store.favorites.count,
            FavoriteLocationStore.maximumCount,
            "收藏数不应超过上限"
        )
    }

    func testCapacityKeepsNewestEntries() {
        let store = makeStore()

        for index in 0..<(FavoriteLocationStore.maximumCount + 5) {
            store.add(
                pair: makePair(
                    latitude: 20.0 + Double(index) * 0.1,
                    longitude: 110.0 + Double(index) * 0.1
                ),
                name: "位置 \(index)"
            )
        }

        let names = Set(store.favorites.map(\.name))
        XCTAssertNil(names.first { $0 == "位置 0" }, "超限时应淘汰最早的条目")
        XCTAssertNotNil(
            names.first { $0 == "位置 \(FavoriteLocationStore.maximumCount + 4)" },
            "最新条目应被保留"
        )
    }

    // MARK: - 查找

    func testContainsFindsMatchingPair() {
        let store = makeStore()
        let pair = makePair()
        store.add(pair: pair, name: "天安门")

        XCTAssertNotNil(store.contains(pair: pair), "应能按坐标找到收藏")
    }

    func testContainsReturnsNilForUnknownPair() {
        let store = makeStore()
        store.add(pair: makePair(), name: "天安门")

        let other = makePair(latitude: 31.230416, longitude: 121.473701)
        XCTAssertNil(store.contains(pair: other), "不同坐标不应匹配")
    }

    // MARK: - 持久化

    func testFavoritesSurviveReinitialization() {
        let pair = makePair()

        do {
            let store = makeStore()
            store.add(pair: pair, name: "持久化测试")
        }

        // 新建实例，应当从同一份 defaults 里读回
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.favorites.count, 1)
        XCTAssertEqual(reloaded.favorites.first?.name, "持久化测试")
        XCTAssertTrue(reloaded.contains(pair: pair) != nil)
    }

    func testSelectedFavoriteResolvesAfterReload() {
        let pair = makePair()

        do {
            let store = makeStore()
            store.add(pair: pair, name: "选中项")
            store.selectedFavoriteID = store.favorites[0].id
        }

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.selectedFavorite?.name, "选中项")
    }

    func testSelectedFavoriteIsNilWhenIDUnknown() {
        let store = makeStore()
        store.selectedFavoriteID = UUID()

        XCTAssertNil(store.selectedFavorite, "未知 ID 应返回 nil 而不是崩溃")
    }

    // MARK: - 双坐标保真

    func testFavoritePreservesBothCoordinateSystems() {
        let store = makeStore()
        let original = makePair()

        store.add(pair: original, name: "双坐标")

        let restored = makeStore().favorites[0].pair
        XCTAssertEqual(restored.wgs84.latitude, original.wgs84.latitude, accuracy: 1e-9)
        XCTAssertEqual(restored.gcj02.latitude, original.gcj02.latitude, accuracy: 1e-9)
        XCTAssertNotEqual(
            restored.wgs84.latitude,
            restored.gcj02.latitude,
            accuracy: 1e-9,
            "两套坐标应当不同"
        )
    }
}
