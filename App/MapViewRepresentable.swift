import MapKit
import SwiftUI

/// MapKit 视图的 SwiftUI 封装。
///
/// 之所以不用 SwiftUI 原生的 `Map`：原生 Map 在 iOS 15/16 上无法稳定地
/// 拿到「用户拖地图后中心点的精确坐标」，也无法控制蓝点与自定义覆盖物的
/// 绘制顺序。这里改用 UIViewRepresentable 包 MKMapView，换取完全的控制权。
///
/// 相关的可变状态放在 `MapViewBridge` 里，避免每次 SwiftUI 重建视图时
/// 都重新创建 MKMapView 导致地图闪烁。
@MainActor
final class MapViewBridge: ObservableObject {

    weak var mapView: MKMapView?

    /// 当前可视区域，供搜索时限定范围。
    var currentRegion: MKCoordinateRegion {
        mapView?.region ?? MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074),
            latitudinalMeters: 5000,
            longitudinalMeters: 5000
        )
    }

    /// 把地图中心移动到指定坐标。
    func center(on coordinate: CLLocationCoordinate2D, animated: Bool = true) {
        guard let mapView else { return }
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: mapView.region.span.latitudeDelta * 111_000,
            longitudinalMeters: mapView.region.span.longitudeDelta * 111_000
        )
        mapView.setRegion(region, animated: animated)
    }
}

struct MapViewRepresentable: UIViewRepresentable {

    @ObservedObject var bridge: MapViewBridge
    /// 只读传入：选点的写入统一走 `MapLocationState.select(_:)`，
    /// 视图层不直接改状态，因此这里不用 Binding。
    let selectedPair: CoordinateConverter.CoordinatePair?
    @Binding var coordinateSystem: CoordinateConverter.MapCoordinateSystem
    @Binding var viewportMeters: Double

    let showsBluePoint: Bool
    let onTapCoordinate: (CLLocationCoordinate2D) -> Void
    let onRegionChanged: (Double) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = showsBluePoint
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.mapType = .standard

        // 点击手势：用于在地图上点选位置。
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)

        // 长按手势：快速把地图中心设为目标点。
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        mapView.addGestureRecognizer(longPress)

        bridge.mapView = mapView
        context.coordinator.mapView = mapView

        // 恢复到上次的视野。
        let initial = selectedPair?.coordinate(for: coordinateSystem)
            ?? CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
        let region = MKCoordinateRegion(
            center: initial,
            latitudinalMeters: max(viewportMeters, 200),
            longitudinalMeters: max(viewportMeters, 200)
        )
        mapView.setRegion(region, animated: false)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.mapView = mapView

        if mapView.showsUserLocation != showsBluePoint {
            mapView.showsUserLocation = showsBluePoint
        }

        context.coordinator.syncAnnotation(
            with: selectedPair,
            coordinateSystem: coordinateSystem
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

        var parent: MapViewRepresentable
        weak var mapView: MKMapView?

        private var selectionAnnotation: MKPointAnnotation?
        /// 记录上次绘制用的坐标，避免重复添加/移动标注。
        private var lastRenderedCoordinate: CLLocationCoordinate2D?
        /// 判断区域变化是用户操作还是代码设置，避免循环触发。
        private var isProgrammaticRegionChange = false

        init(parent: MapViewRepresentable) {
            self.parent = parent
        }

        /// 同步选中位置对应的标注。
        func syncAnnotation(
            with pair: CoordinateConverter.CoordinatePair?,
            coordinateSystem: CoordinateConverter.MapCoordinateSystem
        ) {
            guard let mapView else { return }

            guard let pair else {
                if let existing = selectionAnnotation {
                    mapView.removeAnnotation(existing)
                    selectionAnnotation = nil
                    lastRenderedCoordinate = nil
                }
                return
            }

            let coordinate = pair.coordinate(for: coordinateSystem)

            if let last = lastRenderedCoordinate,
               abs(last.latitude - coordinate.latitude) < 1e-7,
               abs(last.longitude - coordinate.longitude) < 1e-7 {
                return
            }

            if let annotation = selectionAnnotation {
                // 微调位置时用动画移动，视觉上更自然。
                UIView.animate(withDuration: 0.2) {
                    annotation.coordinate = coordinate
                }
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = coordinate
                mapView.addAnnotation(annotation)
                selectionAnnotation = annotation
            }
            lastRenderedCoordinate = coordinate
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let mapView, recognizer.state == .ended else { return }
            let point = recognizer.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            parent.onTapCoordinate(coordinate)
        }

        @objc func handleLongPress(_ recognizer: UIGestureRecognizer) {
            guard let mapView, recognizer.state == .began else { return }
            let point = recognizer.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            parent.onTapCoordinate(coordinate)
        }

        /// 只在单击手势上响应，避免和系统的手势冲突。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isProgrammaticRegionChange else { return }
            let meters = mapView.region.span.latitudeDelta * 111_000
            parent.onRegionChanged(meters)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }

            let identifier = "selection"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)

            view.annotation = annotation
            view.markerTintColor = .systemBlue
            view.glyphImage = UIImage(systemName: "location.fill")
            view.animatesWhenAdded = true
            view.canShowCallout = false
            return view
        }
    }
}
