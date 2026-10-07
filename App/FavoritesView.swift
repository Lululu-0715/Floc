import SwiftUI

/// 收藏位置管理。
///
/// 原来挂在「设置 → 连接状态 → 收藏位置」下面，现在挪到地图页状态行右侧的
/// 圆形收藏夹按钮上。理由：收藏是「选点」的辅助动作，在选点的地方管理最顺手；
/// 设置页里再放一份入口只是重复，而且用户要收藏时得先退出地图。
///
/// 以 sheet 形式呈现，所以自带 `NavigationView` 和「完成」按钮。
struct FavoritesView: View {

    @ObservedObject var favorites: FavoriteLocationStore

    /// 点某一条时把坐标交回地图页去切换选点。
    let onSelect: (FavoriteLocationStore.FavoriteLocation) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirmation = false

    var body: some View {
        NavigationView {
            List {
                if favorites.favorites.isEmpty {
                    Section { emptyState }
                } else {
                    Section {
                        ForEach(favorites.favorites) { favorite in
                            Button {
                                onSelect(favorite)
                                dismiss()
                            } label: {
                                row(favorite)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            offsets
                                .map { favorites.favorites[$0].id }
                                .forEach { favorites.remove(id: $0) }
                        }
                    } header: {
                        SettingsSectionHeader(
                            title: String(
                                format: AppLocalization.string("已收藏 %d 个位置"),
                                favorites.favorites.count
                            )
                        )
                    } footer: {
                        Text(AppLocalization.string("点一条即可切到该位置，左滑可以删除单条。"))
                    }

                    Section {
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            SettingsLabel(
                                systemImage: "trash",
                                title: AppLocalization.string("清空全部收藏"),
                                tint: .red
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(AppLocalization.string("收藏位置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("完成")) { dismiss() }
                }
            }
            .confirmationDialog(
                AppLocalization.string("清空全部收藏？"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(AppLocalization.string("清空"), role: .destructive) {
                    favorites.removeAll()
                }
                Button(AppLocalization.string("取消"), role: .cancel) {}
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "star")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(AppLocalization.string("还没有收藏的位置"))
                .font(SettingsMetrics.titleFont)
            Text(AppLocalization.string("在地图上选好点，点地名旁的星标即可收藏。"))
                .font(SettingsMetrics.subtitleFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func row(_ favorite: FavoriteLocationStore.FavoriteLocation) -> some View {
        let isSelected = favorites.selectedFavoriteID == favorite.id
        return HStack(spacing: SettingsMetrics.iconSpacing) {
            Image(systemName: isSelected ? "star.fill" : "star")
                .font(.subheadline)
                .foregroundStyle(isSelected ? Color.yellow : Color.secondary)
                .frame(width: SettingsMetrics.iconSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.name)
                    .font(SettingsMetrics.titleFont)
                    .foregroundStyle(.primary)
                Text(String(format: "%.6f, %.6f",
                            favorite.pair.wgs84.latitude,
                            favorite.pair.wgs84.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
        .contentShape(Rectangle())
    }
}
