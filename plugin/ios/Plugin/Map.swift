import Foundation
import GoogleMaps
import Capacitor
import GoogleMapsUtils
import SVGKit

public struct LatLng: Codable {
    let lat: Double
    let lng: Double
}

class GMViewController: UIViewController {
    var mapViewBounds: [String: Double]!
    var GMapView: GMSMapView!
    var cameraPosition: [String: Double]!
    var minimumClusterSize: Int?
    var mapId: String?
    var mapType: GMSMapViewType = .normal {
        didSet {
            GMapView?.mapType = mapType
        }
    }

    private var clusterManager: GMUClusterManager?

    var clusteringEnabled: Bool {
        return clusterManager != nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let camera = GMSCameraPosition.camera(withLatitude: cameraPosition["latitude"] ?? 0, longitude: cameraPosition["longitude"] ?? 0, zoom: Float(cameraPosition["zoom"] ?? 12))
        let frame = CGRect(x: mapViewBounds["x"] ?? 0, y: mapViewBounds["y"] ?? 0, width: mapViewBounds["width"] ?? 0, height: mapViewBounds["height"] ?? 0)
        if let id = mapId {
            let gmsId = GMSMapID(identifier: id)
            self.GMapView = GMSMapView(frame: frame, mapID: gmsId, camera: camera)
        } else {
            self.GMapView = GMSMapView(frame: frame, camera: camera)
        }

        self.view = GMapView
    }

    func initClusterManager(_ minClusterSize: Int?) {
        guard let mapView = self.GMapView else {
            print("GMapView is nil! Cluster manager cannot be initialized.")
            return
        }
        let iconGenerator = GMUDefaultClusterIconGenerator()
        let algorithm = GMUNonHierarchicalDistanceBasedAlgorithm()
        let renderer = GMUDefaultClusterRenderer(mapView: self.GMapView, clusterIconGenerator: iconGenerator)
        self.minimumClusterSize = minClusterSize
        if let minClusterSize = minClusterSize {
            renderer.minimumClusterSize = UInt(minClusterSize)
        }
        self.clusterManager = GMUClusterManager(map: self.GMapView, algorithm: algorithm, renderer: renderer)
    }

    func destroyClusterManager() {
        self.clusterManager = nil
    }

    func addMarkersToCluster(markers: [GMSMarker]) {
        if let clusterManager = clusterManager {
            clusterManager.add(markers)
            clusterManager.cluster()
        }
    }

    func removeMarkersFromCluster(markers: [GMSMarker]) {
        if let clusterManager = clusterManager {
            markers.forEach { marker in
                clusterManager.remove(marker)
            }
            clusterManager.cluster()
        }
    }
}

// swiftlint:disable type_body_length
public class Map {
    var id: String
    var config: GoogleMapConfig
    var mapViewController: GMViewController
    var targetViewController: UIView?
    var markers = [Int: GMSMarker]()
    var polygons = [Int: GMSPolygon]()
    var circles = [Int: GMSCircle]()
    var polylines = [Int: GMSPolyline]()
    var markerIcons = [String: UIImage]()
    var mIds = [String: Int]()
    private var addMarkersGeneration: Int = 0
    private var pendingOverlayTask: URLSessionDataTask?
    private var currentGroundOverlay: GMSGroundOverlay?
    var isDestroyed: Bool = false
    var destroyCompletion: (() -> Void)?

    // Selection properties
    private var selectionType: String?
    var selectionActive: Bool = false
    private var shapeOverlayView: UIView?
    private var startPoint: CLLocationCoordinate2D?
    private var selectionLine: GMSPolyline?
    private var selectionPoints: [CLLocationCoordinate2D]?
    private var selectionSquare: GMSPolygon?

    // swiftlint:disable identifier_name
    public static let MAP_TAG = 99999
    // swiftlint:enable identifier_name

    // swiftlint:disable weak_delegate
    private var delegate: CapacitorGoogleMapsPlugin

    init(id: String, config: GoogleMapConfig, delegate: CapacitorGoogleMapsPlugin) {
        self.id = id
        self.config = config
        self.delegate = delegate
        self.mapViewController = GMViewController()
        self.mapViewController.mapId = config.mapId
        self.mapViewController.mapType = config.mapType

        self.render()
    }

    func render() {
        DispatchQueue.main.async {
            guard !self.isDestroyed else {
                return
            }

            self.mapViewController.mapViewBounds = [
                "width": self.config.width,
                "height": self.config.height,
                "x": self.config.x,
                "y": self.config.y
            ]

            self.mapViewController.cameraPosition = [
                "latitude": self.config.center.lat,
                "longitude": self.config.center.lng,
                "zoom": self.config.zoom
            ]

            self.targetViewController = self.getTargetContainer(refWidth: self.config.width, refHeight: self.config.height)

            if let target = self.targetViewController {
                target.tag = Map.MAP_TAG
                target.removeAllSubview()
                self.mapViewController.view.frame = target.bounds
                target.addSubview(self.mapViewController.view)
                self.mapViewController.GMapView.delegate = self.delegate
            }
            self.mapViewController.mapType = self.config.mapType

            if let styles = self.config.styles {
                guard let gMapView = self.mapViewController.GMapView else {
                    CAPLog.print("GMapView is nil, cannot set map style")
                    return
                }
                do {
                    gMapView.mapStyle = try GMSMapStyle(jsonString: styles)
                } catch {
                    CAPLog.print("Invalid Google Maps styles")
                }
            }

            guard !self.isDestroyed else {
                return
            }

            self.delegate.notifyListeners("onMapReady", data: [
                "mapId": self.id
            ])
        }
    }

    func updateRender(mapBounds: CGRect) {
        DispatchQueue.main.sync {
            let newWidth = round(Double(mapBounds.width))
            let newHeight = round(Double(mapBounds.height))
            let isWidthEqual = round(Double(self.mapViewController.view.bounds.width)) == newWidth
            let isHeightEqual = round(Double(self.mapViewController.view.bounds.height)) == newHeight

            if !isWidthEqual || !isHeightEqual {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.mapViewController.view.frame.size.width = newWidth
                self.mapViewController.view.frame.size.height = newHeight
                CATransaction.commit()
            }
            if selectionType == "shape", let overlay = shapeOverlayView {
                overlay.frame = self.mapViewController.view.frame
            }
        }
    }

    func rebindTargetContainer(mapBounds: CGRect) {
        DispatchQueue.main.sync {
            if let target = self.getTargetContainer(refWidth: round(Double(mapBounds.width)), refHeight: round(Double(mapBounds.height))) {
                self.targetViewController = target
                target.tag = Map.MAP_TAG
                target.removeAllSubview()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.mapViewController.view.frame.size.width = mapBounds.width
                self.mapViewController.view.frame.size.height = mapBounds.height
                CATransaction.commit()
                target.addSubview(self.mapViewController.view)
                if self.selectionType == "shape" {
                    self.updateShapeOverlay(show: true)
                }
            }
        }
    }

    private func getTargetContainer(refWidth: Double, refHeight: Double) -> UIView? {
        if let bridge = self.delegate.bridge {
            for item in bridge.webView!.getAllSubViews() {
                let isScrollView = item.isKind(of: NSClassFromString("WKChildScrollView")!) || item.isKind(of: NSClassFromString("WKScrollView")!)
                let isBridgeScrollView = item.isEqual(bridge.webView?.scrollView)

                if isScrollView && !isBridgeScrollView {
                    (item as? UIScrollView)?.isScrollEnabled = true

                    let height = Double((item as? UIScrollView)?.contentSize.height ?? 0)
                    let width = Double((item as? UIScrollView)?.contentSize.width ?? 0)
                    let actualHeight = round(height / 2)

                    let isWidthEqual = width == self.config.width
                    let isHeightEqual = actualHeight == self.config.height

                    if isWidthEqual && isHeightEqual && item.tag < self.targetViewController?.tag ?? Map.MAP_TAG {
                        return item
                    }
                }
            }
        }

        return nil
    }

    func destroy() {
        DispatchQueue.main.async {
            self.isDestroyed = true
            self.shapeOverlayView?.removeFromSuperview()
            self.shapeOverlayView = nil

            self.mapViewController.GMapView?.delegate = nil
            self.mapViewController.GMapView?.removeFromSuperview()
            self.mapViewController.GMapView = nil
            self.targetViewController?.tag = 0
            self.mapViewController.view?.removeFromSuperview()
            self.enableTouch()

            self.destroyCompletion?()
            self.destroyCompletion = nil
        }
    }

    func destroyWithCompletion(completion: @escaping () -> Void) {
        if self.isDestroyed {
            completion()
            return
        }

        self.destroyCompletion = completion
        self.destroy()
    }

    func enableTouch() {
        DispatchQueue.main.async {
            if let target = self.targetViewController, let itemIndex = WKWebView.disabledTargets.firstIndex(of: target) {
                WKWebView.disabledTargets.remove(at: itemIndex)
            }
        }
    }

    func disableTouch() {
        DispatchQueue.main.async {
            if let target = self.targetViewController, !WKWebView.disabledTargets.contains(target) {
                WKWebView.disabledTargets.append(target)
            }
        }
    }

    func addMarker(marker: Marker, cleanAllMarkers: Bool = true) throws -> Int {
        var markerHash = 0

        runOnMainThread {
            if cleanAllMarkers == true {
                self.removeAllMarkers()
            }

            let newMarker = self.buildMarker(marker: marker)

            if self.mapViewController.clusteringEnabled {
                self.mapViewController.addMarkersToCluster(markers: [newMarker])
            } else {
                newMarker.map = self.mapViewController.GMapView
            }

            self.markers[newMarker.hash.hashValue] = newMarker

            markerHash = newMarker.hash.hashValue

            if let mId = marker.mId {
                self.mIds[mId] = markerHash
            }
        }

        return markerHash
    }

    func addGroundOverlay(overlay: GroundOverlay) {
        pendingOverlayTask?.cancel()
        pendingOverlayTask = nil

        _ = overlay.createGroundOverlay(completion: { [weak self] newOverlay in
            guard let self = self, !self.isDestroyed else { return }
            guard let newOverlay = newOverlay else {
                print("Error while creating GroundOverlay")
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isDestroyed,
                      let mapView = self.mapViewController.GMapView else { return }
                self.currentGroundOverlay?.map = nil
                newOverlay.opacity = 1.0
                newOverlay.bearing = 0
                newOverlay.map = mapView
                self.currentGroundOverlay = newOverlay
            }
        })
    }

    func addMarkers(markers: [Marker], completion: @escaping ([Int]) -> Void) {
        addMarkersGeneration += 1
        let currentGeneration = addMarkersGeneration

        var index = 0
        let total = markers.count
        let batchSize = 10
        let delay = 0.01

        var currentMids: [String] = []
        var googleMapsMarkers: [GMSMarker] = []
        var markerHashes: [Int] = []
        var isCompleted = false

        func finish(_ ids: [Int]) {
            if isCompleted {
                return
            }
            isCompleted = true
            completion(ids)
        }

        func addNextBatch() {
            var _markers: [GMSMarker] = []
            if currentGeneration != self.addMarkersGeneration {
                finish(markerHashes)
                return
            }

            if index >= total {
                if currentGeneration == self.addMarkersGeneration {
                    let difference = Set(self.mIds.keys).subtracting(currentMids)
                    let mIdsToRemove = Array(difference)

                    do {
                        try self.removeMarkersBymId(mIds: mIdsToRemove)
                    } catch {
                        print("addMarkersInBatches() cleanup error: \(error)")
                    }
                }

                finish(markerHashes)

                return
            }

            let batchEnd = min(index + batchSize, total)

            DispatchQueue.main.async {
                if currentGeneration != self.addMarkersGeneration {
                    finish(markerHashes)
                    return
                }

                for i in index..<batchEnd {
                    let markerData = markers[i]

                    if let mId = markerData.mId,
                       let markerHash = self.mIds[mId],
                       let _ = self.markers[markerHash] {
                        currentMids.append(mId)
                        self.updateMarker(markerId: markerHash, newMarker: markerData)
                        continue
                    }

                    let newMarker = self.buildMarker(marker: markerData)

                    if self.mapViewController.clusteringEnabled {
                        _markers.append(newMarker)
                        googleMapsMarkers.append(newMarker)
                    } else {
                        newMarker.map = self.mapViewController.GMapView
                    }

                    let hash = newMarker.hash.hashValue
                    self.markers[hash] = newMarker
                    markerHashes.append(hash)

                    if let mId = markerData.mId {
                        currentMids.append(mId)
                        self.mIds[mId] = hash
                    }
                }

                if self.mapViewController.clusteringEnabled {
                    self.mapViewController.addMarkersToCluster(markers: _markers)
                }

                index = batchEnd

                if currentGeneration != self.addMarkersGeneration {
                    finish(markerHashes)
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    addNextBatch()
                }
            }
        }

        addNextBatch()
    }

    func isCoordinatesDifferent(coords1: LatLng, coords2: CLLocationCoordinate2D) -> Bool {
        let newLat = Double(coords1.lat)
        let newLng = Double(coords1.lng)
        let existingLat = coords2.latitude
        let existingLng = coords2.longitude

        if existingLat != newLat || existingLng != newLng {
            return true
        }

        return false
    }

    func updateMarker(markerId: Int, newMarker: Marker) -> Void {
        guard let marker = self.markers[markerId] else {
            print("updateMarker(): no marker found for \(markerId) id")

            return
        }

        runOnMainThread {
            if self.isCoordinatesDifferent(
                coords1: newMarker.coordinate,
                coords2: marker.position
            ) {
                marker.position = CLLocationCoordinate2D(
                    latitude: newMarker.coordinate.lat,
                    longitude: newMarker.coordinate.lng
                )
            }

            if let userData = marker.userData as? String,
               let iconUrl = newMarker.iconUrl,
                userData != iconUrl {
                self.updateMarkerIcon(markerId: markerId, iconUrl: iconUrl, iconSize: newMarker.iconSize)
            }
        }
    }

    func addPolygons(polygons: [Polygon]) throws -> [Int] {
        var polygonHashes: [Int] = []

        DispatchQueue.main.sync {
            polygons.forEach { polygon in
                let newPolygon = self.buildPolygon(polygon: polygon)
                newPolygon.map = self.mapViewController.GMapView

                self.polygons[newPolygon.hash.hashValue] = newPolygon

                polygonHashes.append(newPolygon.hash.hashValue)
            }
        }

        return polygonHashes
    }

    func addCircles(circles: [Circle]) throws -> [Int] {
        var circleHashes: [Int] = []

        DispatchQueue.main.sync {
            circles.forEach { circle in
                let newCircle = self.buildCircle(circle: circle)
                newCircle.map = self.mapViewController.GMapView

                self.circles[newCircle.hash.hashValue] = newCircle

                circleHashes.append(newCircle.hash.hashValue)
            }
        }

        return circleHashes
    }

    func addPolylines(lines: [Polyline]) throws -> [Int] {
        var polylineHashes: [Int] = []

        DispatchQueue.main.sync {
            lines.forEach { line in
                let newLine = self.buildPolyline(line: line)
                newLine.map = self.mapViewController.GMapView

                self.polylines[newLine.hash.hashValue] = newLine

                polylineHashes.append(newLine.hash.hashValue)
            }
        }

        return polylineHashes
    }

    func enableClustering(_ minClusterSize: Int?) {
        if !self.mapViewController.clusteringEnabled {
            DispatchQueue.main.sync {
                self.mapViewController.initClusterManager(minClusterSize)

                // add existing markers to the cluster
                if !self.markers.isEmpty {
                    var existingMarkers: [GMSMarker] = []
                    for (_, marker) in self.markers {
                        marker.map = nil
                        existingMarkers.append(marker)
                    }

                    self.mapViewController.addMarkersToCluster(markers: existingMarkers)
                }
            }
        } else if self.mapViewController.minimumClusterSize != minClusterSize {
            self.mapViewController.destroyClusterManager()
            enableClustering(minClusterSize)
        }
    }

    func disableClustering() {
        DispatchQueue.main.sync {
            self.mapViewController.destroyClusterManager()

            // add existing markers back to the map
            if !self.markers.isEmpty {
                for (_, marker) in self.markers {
                    marker.map = self.mapViewController.GMapView
                }
            }
        }
    }

    func removeMarker(id: Int) throws {
        if let marker = self.markers[id] {
            DispatchQueue.main.async {
                if self.mapViewController.clusteringEnabled {
                    self.mapViewController.removeMarkersFromCluster(markers: [marker])
                }

                if let mId = self.mIds.first(where: {$0.value == id})?.key {
                    self.mIds.removeValue(forKey: mId)
                }

                marker.map = nil
                self.markers.removeValue(forKey: id)

            }
        } else {
            throw GoogleMapErrors.markerNotFound
        }
    }

    func removeMarkerBymId(mId: String) throws {
        guard let markerHash = self.mIds[mId] else {
            throw GoogleMapErrors.markerNotFound
        }

        if let marker = self.markers[Int(markerHash)] {
            DispatchQueue.main.async {
                if self.mapViewController.clusteringEnabled {
                    self.mapViewController.removeMarkersFromCluster(markers: [marker])
                }

                marker.map = nil
                self.markers.removeValue(forKey: markerHash)

            }
        } else {
            throw GoogleMapErrors.markerNotFound
        }
    }

    func removePolygons(ids: [Int]) throws {
        DispatchQueue.main.sync {
            ids.forEach { id in
                if let polygon = self.polygons[id] {
                    polygon.map = nil
                    self.polygons.removeValue(forKey: id)
                }
            }
        }
    }

    func removeCircles(ids: [Int]) throws {
        DispatchQueue.main.sync {
            ids.forEach { id in
                if let circle = self.circles[id] {
                    circle.map = nil
                    self.circles.removeValue(forKey: id)
                }
            }
        }
    }

    func removePolylines(ids: [Int]) throws {
        DispatchQueue.main.sync {
            ids.forEach { id in
                if let line = self.polylines[id] {
                    line.map = nil
                    self.polylines.removeValue(forKey: id)
                }
            }
        }
    }

    func setCamera(config: GoogleMapCameraConfig) throws {
        guard let gMapView = self.mapViewController.GMapView else {
            print("GMapView is nil")
            return // or handle the nil case appropriately
        }

        let currentCamera = gMapView.camera

        let lat = config.coordinate?.lat ?? currentCamera.target.latitude
        let lng = config.coordinate?.lng ?? currentCamera.target.longitude

        let zoom = config.zoom ?? currentCamera.zoom
        let bearing = config.bearing ?? Double(currentCamera.bearing)
        let angle = config.angle ?? currentCamera.viewingAngle

        let animate = config.animate ?? false

        DispatchQueue.main.sync {
            let newCamera = GMSCameraPosition(latitude: lat, longitude: lng, zoom: zoom, bearing: bearing, viewingAngle: angle)

            if animate {
                self.mapViewController.GMapView.animate(to: newCamera)
            } else {
                self.mapViewController.GMapView.camera = newCamera
            }
        }

    }

    func getMapType() -> GMSMapViewType {
        return self.mapViewController.GMapView.mapType
    }

    func setMapType(mapType: GMSMapViewType) throws {
         guard let gMapView = self.mapViewController.GMapView else {
            return
        }

        DispatchQueue.main.async {
            gMapView.mapType = mapType
        }
    }

    func enableIndoorMaps(enabled: Bool) throws {
        DispatchQueue.main.sync {
            if let gMapView = self.mapViewController.GMapView {
                gMapView.isIndoorEnabled = enabled
            } else {
                print("Error: GMapView is nil.")
            }
        }
    }

    func enableTrafficLayer(enabled: Bool) throws {
        DispatchQueue.main.sync {
            if let gMapView = self.mapViewController.GMapView {
                gMapView.isTrafficEnabled = enabled
            } else {
                print("Error: GMapView is nil.")
            }
        }
    }

    func enableAccessibilityElements(enabled: Bool) throws {
        DispatchQueue.main.sync {
            if let gMapView = self.mapViewController.GMapView {
                gMapView.accessibilityElementsHidden = enabled
            } else {
                print("Error: GMapView is nil.")
            }
        }
    }

    func enableCurrentLocation(enabled: Bool) throws {
        DispatchQueue.main.sync {
            if let gMapView = self.mapViewController.GMapView {
                gMapView.isMyLocationEnabled = enabled
            } else {
                print("Error: GMapView is nil.")
            }
        }
    }

    func setPadding(padding: GoogleMapPadding) throws {
        DispatchQueue.main.sync {
            let mapInsets = UIEdgeInsets(top: CGFloat(padding.top), left: CGFloat(padding.left), bottom: CGFloat(padding.bottom), right: CGFloat(padding.right))
            self.mapViewController.GMapView.padding = mapInsets
        }
    }

    func removeMarkers(ids: [Int]) throws {
        DispatchQueue.main.sync {
            var markers: [GMSMarker] = []
            for id in ids {
                if let marker = self.markers[id] {
                    marker.map = nil

                    if let mId = self.mIds.first(where: {$0.value == id})?.key {
                        self.mIds.removeValue(forKey: mId)
                    }

                    self.markers.removeValue(forKey: id)
                    markers.append(marker)
                }
            }

            if self.mapViewController.clusteringEnabled {
                self.mapViewController.removeMarkersFromCluster(markers: markers)
            }
        }
    }

    func removeMarkersBymId(mIds: [String]) throws {
        runOnMainThread {
            var markers: [GMSMarker] = []

            for mId in mIds {
                guard let markerHash = self.mIds[mId] else {
                    print("_removeMarkersBymId(): Error: no marker found with mId: \(mId)")
                    continue
                }

                if let marker = self.markers[markerHash] {
                    marker.map = nil

                    self.markers.removeValue(forKey: markerHash)
                    self.mIds.removeValue(forKey: mId)

                    markers.append(marker)
                }
            }

            if self.mapViewController.clusteringEnabled {
                self.mapViewController.removeMarkersFromCluster(markers: markers)
            }
        }
    }

    func getMapLatLngBounds() -> GMSCoordinateBounds? {
        return GMSCoordinateBounds(region: self.mapViewController.GMapView.projection.visibleRegion())
    }

    func fitBounds(bounds: GMSCoordinateBounds, padding: CGFloat) {
        DispatchQueue.main.sync {
            let cameraUpdate = GMSCameraUpdate.fit(bounds, withPadding: padding)
            self.mapViewController.GMapView.animate(with: cameraUpdate)
        }
    }

    private func getFrameOverflowBounds(frame: CGRect, mapBounds: CGRect) -> [CGRect] {
        var intersections: [CGRect] = []

        // get top overflow
        if mapBounds.origin.y < frame.origin.y {
            let height = frame.origin.y - mapBounds.origin.y
            let width = mapBounds.width
            intersections.append(CGRect(x: 0, y: 0, width: width, height: height))
        }

        // get bottom overflow
        if (mapBounds.origin.y + mapBounds.height) > (frame.origin.y + frame.height) {
            let height = (mapBounds.origin.y + mapBounds.height) - (frame.origin.y + frame.height)
            let width = mapBounds.width
            intersections.append(CGRect(x: 0, y: mapBounds.height, width: width, height: height))
        }

        return intersections
    }

    private func buildCircle(circle: Circle) -> GMSCircle {
        let newCircle = GMSCircle()
        newCircle.title = circle.title
        newCircle.strokeColor = circle.strokeColor
        newCircle.strokeWidth = circle.strokeWidth
        newCircle.fillColor = circle.fillColor
        newCircle.position = CLLocationCoordinate2D(latitude: circle.center.lat, longitude: circle.center.lng)
        newCircle.radius = CLLocationDistance(circle.radius)
        newCircle.isTappable = circle.tappable ?? false
        newCircle.zIndex = circle.zIndex
        newCircle.userData = circle.tag

        return newCircle
    }

    private func buildPolygon(polygon: Polygon) -> GMSPolygon {
        let newPolygon = GMSPolygon()
        newPolygon.title = polygon.title
        newPolygon.strokeColor = polygon.strokeColor
        newPolygon.strokeWidth = polygon.strokeWidth
        newPolygon.fillColor = polygon.fillColor
        newPolygon.isTappable = polygon.tappable ?? false
        newPolygon.geodesic = polygon.geodesic ?? false
        newPolygon.zIndex = polygon.zIndex
        newPolygon.userData = polygon.tag

        var shapeIndex = 0
        let outerShape = GMSMutablePath()
        var holes: [GMSMutablePath] = []

        polygon.shapes.forEach { shape in
            if shapeIndex == 0 {
                shape.forEach { coord in
                    outerShape.add(CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lng))
                }
            } else {
                let holeShape = GMSMutablePath()
                shape.forEach { coord in
                    holeShape.add(CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lng))
                }

                holes.append(holeShape)
            }

            shapeIndex += 1
        }

        newPolygon.path = outerShape
        newPolygon.holes = holes

        return newPolygon
    }

    private func buildPolyline(line: Polyline) -> GMSPolyline {
        let newPolyline = GMSPolyline()
        newPolyline.title = line.title
        newPolyline.strokeColor = line.strokeColor
        newPolyline.strokeWidth = line.strokeWidth
        newPolyline.isTappable = line.tappable ?? false
        newPolyline.geodesic = line.geodesic ?? false
        newPolyline.zIndex = line.zIndex
        newPolyline.userData = line.tag

        let path = GMSMutablePath()
        line.path.forEach { coord in
            path.add(CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lng))
        }

        newPolyline.path = path

        if line.styleSpans.count > 0 {
            var spans: [GMSStyleSpan] = []

            line.styleSpans.forEach { span in
                if let segments = span.segments {
                    spans.append(GMSStyleSpan(color: span.color, segments: segments))
                } else {
                    spans.append(GMSStyleSpan(color: span.color))
                }
            }

            newPolyline.spans = spans
        }

        return newPolyline
    }

    private func buildMarker(marker: Marker) -> GMSMarker {
        let newMarker = GMSMarker()

        newMarker.position = CLLocationCoordinate2D(latitude: marker.coordinate.lat, longitude: marker.coordinate.lng)
        newMarker.title = marker.title
        newMarker.snippet = marker.snippet
        newMarker.isFlat = marker.isFlat ?? false
        newMarker.opacity = marker.opacity ?? 1
        newMarker.isDraggable = marker.draggable ?? false
        newMarker.zIndex = marker.zIndex

        if let iconAnchor = marker.iconAnchor {
            newMarker.groundAnchor = iconAnchor
        }

        // If icon (base64) is already set, assign it directly
        if let base64Icon = marker.icon {
            newMarker.icon = getResizedIcon(base64Icon, marker.iconSize)
        }
        // Otherwise, proceed with the URL or color options
        else if let iconUrl = marker.iconUrl {
            newMarker.userData = iconUrl
            if let iconImage = self.markerIcons[iconUrl] {
                newMarker.icon = getResizedIcon(iconImage, marker.iconSize)
            } else {
                if iconUrl.starts(with: "data:image/svg+xml;base64,") {
                    let base64String = iconUrl.replacingOccurrences(of: "data:image/svg+xml;base64,", with: "")

                    DispatchQueue.main.async {
                        if let svgData = Data(base64Encoded: base64String),
                           let svgString = String(data: svgData, encoding: .utf8),
                           let svgImage = svgToImage(svgString: svgString, size: marker.iconSize) {
                            self.markerIcons[iconUrl] = svgImage
                            newMarker.icon = svgImage
                        } else {
                            print("Failed to decode SVG Base64 or render image")
                        }
                    }
                }
                else if iconUrl.starts(with: "https:") {
                    if let url = URL(string: iconUrl) {
                        URLSession.shared.dataTask(with: url) { (data, _, _) in
                            DispatchQueue.main.async {
                                if let data = data, let iconImage = UIImage(data: data) {
                                    self.markerIcons[iconUrl] = iconImage
                                    newMarker.icon = getResizedIcon(iconImage, marker.iconSize)
                                }
                            }
                        }.resume()
                    }
                } else if let iconImage = UIImage(named: "public/\(iconUrl)") {
                    self.markerIcons[iconUrl] = iconImage
                    newMarker.icon = getResizedIcon(iconImage, marker.iconSize)
                } else {
                    var detailedMessage = ""

                    if iconUrl.hasSuffix(".svg") {
                        detailedMessage = "SVG not supported."
                    }

                    print("CapacitorGoogleMaps Warning: could not load image '\(iconUrl)'. \(detailedMessage)  Using default marker icon.")
                }
            }
        } else {
            if let color = marker.color {
                newMarker.icon = GMSMarker.markerImage(with: color)
            }
        }

        return newMarker
    }

    func updateMarkerIcon(mId: String? = nil, markerId: Int? = nil, iconUrl: String, iconSize: CGSize? = nil, iconImage: UIImage? = nil) -> Void {
        DispatchQueue.main.async {
            var marker: GMSMarker?
            if let mId = mId,
               let markerHash = self.mIds[mId] {
                marker = self.markers[markerHash] ?? nil
            } else if let markerId = markerId {
                marker = self.markers[markerId] ?? nil
            } else {
                print("updateMarkerIcon(): You should pass mId or markerId")
                return
            }

            guard let marker = marker else {
                print("updateMarkerIcon(): Marker not found, mId: \(mId ?? "nil"), markerId: \(String(describing: markerId))")
                return
            }

            marker.userData = iconUrl

            // Use provided iconSize, fall back to current icon size to preserve dimensions
            let effectiveIconSize = iconSize ?? marker.icon?.size

            // 1. Direct image provided (from plugin's imageCache)
            if let iconImage = iconImage {
                self.applyIconAndRefresh(marker: marker, icon: getResizedIcon(iconImage, effectiveIconSize))
            }
            // 2. Found in map's markerIcons cache (by URL)
            else if let cachedImage = self.markerIcons[iconUrl] {
                self.applyIconAndRefresh(marker: marker, icon: getResizedIcon(cachedImage, effectiveIconSize))
            }
            // 3. SVG base64
            else if iconUrl.starts(with: "data:image/svg+xml;base64,") {
                let base64String = iconUrl.replacingOccurrences(of: "data:image/svg+xml;base64,", with: "")

                if let svgData = Data(base64Encoded: base64String),
                   let svgString = String(data: svgData, encoding: .utf8),
                   let svgImage = svgToImage(svgString: svgString, size: effectiveIconSize) {
                    self.markerIcons[iconUrl] = svgImage
                    self.applyIconAndRefresh(marker: marker, icon: svgImage)
                } else {
                    print("Failed to decode SVG Base64 or render image")
                }
            }
            // 4. Remote URL
            else if iconUrl.starts(with: "https:") {
                if let url = URL(string: iconUrl) {
                    URLSession.shared.dataTask(with: url) { (data, _, _) in
                        DispatchQueue.main.async {
                            if let data = data, let iconImage = UIImage(data: data) {
                                self.markerIcons[iconUrl] = iconImage
                                self.applyIconAndRefresh(marker: marker, icon: getResizedIcon(iconImage, effectiveIconSize))
                            }
                        }
                    }.resume()
                }
            }
            // 5. Local file
            else if let fileImage = UIImage(named: "public/\(iconUrl)") {
                self.markerIcons[iconUrl] = fileImage
                self.applyIconAndRefresh(marker: marker, icon: getResizedIcon(fileImage, effectiveIconSize))
            } else {
                print("updateMarkerIcon(): Icon not found for '\(iconUrl)'. No cached image provided.")
            }
        }
    }

    private func applyIconAndRefresh(marker: GMSMarker, icon: UIImage?) {
        let oldHash = marker.hash.hashValue
        print("[updateMarkerIcon] applyIconAndRefresh: oldHash=\(oldHash), position=\(marker.position), clusteringEnabled=\(self.mapViewController.clusteringEnabled)")

        // Create a new marker with the same properties but new icon
        let newMarker = GMSMarker()
        newMarker.position = marker.position
        newMarker.title = marker.title
        newMarker.snippet = marker.snippet
        newMarker.isFlat = marker.isFlat
        newMarker.opacity = marker.opacity
        newMarker.isDraggable = marker.isDraggable
        newMarker.zIndex = marker.zIndex
        newMarker.groundAnchor = marker.groundAnchor
        newMarker.userData = marker.userData
        newMarker.icon = icon

        // Remove old marker from map/cluster
        if self.mapViewController.clusteringEnabled {
            self.mapViewController.removeMarkersFromCluster(markers: [marker])
            print("[updateMarkerIcon] removed old marker from cluster")
        }
        marker.map = nil

        // Add new marker to map/cluster
        if self.mapViewController.clusteringEnabled {
            self.mapViewController.addMarkersToCluster(markers: [newMarker])
            print("[updateMarkerIcon] added new marker to cluster")
        } else {
            newMarker.map = self.mapViewController.GMapView
            print("[updateMarkerIcon] added new marker directly to map")
        }

        // Update markers dictionary
        self.markers.removeValue(forKey: oldHash)
        let newHash = newMarker.hash.hashValue
        self.markers[newHash] = newMarker

        // Update mIds mapping to point to the new marker hash
        if let mId = self.mIds.first(where: { $0.value == oldHash })?.key {
            self.mIds[mId] = newHash
            print("[updateMarkerIcon] updated mId '\(mId)': \(oldHash) -> \(newHash)")
        }

        print("[updateMarkerIcon] applyIconAndRefresh done: newHash=\(newHash), icon size=\(icon?.size ?? .zero)")

        // Force the idle map to render by triggering a real (but imperceptible) zoom animation.
        // The SDK only renders when its animation loop is active.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let mapView = self.mapViewController.GMapView else { return }
            let originalZoom = mapView.camera.zoom
            mapView.animate(toZoom: originalZoom + 0.01)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                mapView.animate(toZoom: originalZoom)
            }
        }
    }

    func removeAllMarkers() -> Void {
        let allMarkers = Array(self.markers.values)

        if self.mapViewController.clusteringEnabled {
            self.mapViewController.removeMarkersFromCluster(markers: allMarkers)
        }

        for markerId in self.mIds.values {
            if let marker = self.markers[markerId] {
                marker.map = nil
            }
        }

        self.markers.removeAll()
        self.mIds.removeAll()
    }

    // MARK: - Map Bounds
    func getMapBounds() -> CGRect {
        guard let targetView = targetViewController else {
            return CGRect.zero
        }
        guard let webView = delegate.bridge?.webView else {
            return targetView.frame
        }
        return targetView.convert(targetView.bounds, to: webView)
    }

    // MARK: - Selection Methods
    func getSelectionType() -> String? {
        return selectionType
    }

    func setMarkersDraggable(mIds mIdsList: [String], draggable: Bool) {
        runOnMainThread {
            for mId in mIdsList {
                guard let hash = self.mIds[mId], let gmsMarker = self.markers[hash] else { continue }
                gmsMarker.isDraggable = draggable
            }
        }
    }

    func setAllMarkersDraggable(draggable: Bool) {
        runOnMainThread {
            for gmsMarker in self.markers.values {
                gmsMarker.isDraggable = draggable
            }
        }
    }

    func setSelectionType(_ type: String?) {
        selectionType = type
        let isShape = type == "shape"
        setSelectionScrollLock(lockSingleFinger: isShape)
        updateShapeOverlay(show: false)
        updateContainerScrollEnabled(enable: !isShape)
    }

    /// 1 палець — lock (малювання), 2+ — unlock (zoom/scroll).
    func applyScrollLockForTouchCount(_ touchCount: Int) {
        guard selectionType == "shape" else { return }
        let lock = touchCount <= 1
        setSelectionScrollLock(lockSingleFinger: lock)
        updateContainerScrollEnabled(enable: !lock)
    }

    /// Контейнер карти (WKChildScrollView). У shape mode: enable тільки для 2+ пальців (викликається з плагіна).
    func setContainerScrollEnabled(_ enable: Bool) {
        updateContainerScrollEnabled(enable: enable)
    }

    private func updateContainerScrollEnabled(enable: Bool) {
        runOnMainThread {
            if let scroll = self.targetViewController as? UIScrollView {
                scroll.isScrollEnabled = enable
            }
        }
    }

    /// Overlay перехоплює 1 палець (lasso). Для 2+ — custom hitTest повертає nil, touch йде на карту (zoom).
    private func updateShapeOverlay(show: Bool) {
        runOnMainThread {
            guard let target = self.targetViewController,
                  let mapView = self.mapViewController.view else { return }
            if show {
                if self.shapeOverlayView == nil {
                    let overlay = UIView(frame: mapView.frame)
                    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    overlay.backgroundColor = .clear
                    overlay.isUserInteractionEnabled = true
                    overlay.isMultipleTouchEnabled = true
                    target.addSubview(overlay)
                    target.bringSubviewToFront(overlay)
                    self.shapeOverlayView = overlay
                } else {
                    self.shapeOverlayView?.frame = mapView.frame
                }
            } else {
                self.shapeOverlayView?.removeFromSuperview()
                self.shapeOverlayView = nil
            }
        }
    }

    func setSelectionScrollLock(lockSingleFinger: Bool) {
        guard let gMapView = mapViewController.GMapView else { return }
        gMapView.settings.scrollGestures = !lockSingleFinger
    }

    func startSelection(at location: CGPoint) {
        guard let mapView = mapViewController.GMapView,
              let targetView = targetViewController else {
            return
        }

        guard let webView = delegate.bridge?.webView else {
            return
        }

        let locationInTargetView = webView.convert(location, to: targetView)
        let locationInMapView = mapView.convert(locationInTargetView, from: targetView)
        let coordinate = mapView.projection.coordinate(for: locationInMapView)

        startPoint = coordinate
        selectionActive = true

        if selectionType == "shape" {
            if selectionPoints == nil {
                selectionPoints = []
            }
            if let startPoint = startPoint {
                selectionPoints?.append(startPoint)
            }
        }
    }

    func handleSelectionMove(at location: CGPoint) -> Bool {
        guard selectionActive else {
            return false
        }

        guard let mapView = mapViewController.GMapView,
              let startPoint = startPoint,
              let targetView = targetViewController else {
            clearSelection()
            return false
        }

        guard selectionActive else {
            return false
        }

        guard let webView = delegate.bridge?.webView else {
            return false
        }

        let locationInTargetView = webView.convert(location, to: targetView)
        let locationInMapView = mapView.convert(locationInTargetView, from: targetView)
        let endCoordinate = mapView.projection.coordinate(for: locationInMapView)

        if selectionType == "square" {
            let p1 = startPoint
            let p2 = CLLocationCoordinate2D(latitude: startPoint.latitude, longitude: endCoordinate.longitude)
            let p3 = endCoordinate
            let p4 = CLLocationCoordinate2D(latitude: endCoordinate.latitude, longitude: startPoint.longitude)

            let path = GMSMutablePath()
            path.add(p1)
            path.add(p2)
            path.add(p3)
            path.add(p4)

            if selectionSquare == nil {
                selectionSquare = GMSPolygon(path: path)
                selectionSquare?.fillColor = UIColor(red: 20/255, green: 1.0, blue: 0, alpha: 0.22)
                selectionSquare?.strokeColor = UIColor(red: 20/255, green: 1.0, blue: 0, alpha: 1.0)
                selectionSquare?.strokeWidth = 2.0
                selectionSquare?.map = mapView
            } else {
                selectionSquare?.path = path
            }
        } else {
            // Shape selection
            if selectionLine == nil {
                selectionPoints?.append(endCoordinate)

                let path = GMSMutablePath()
                path.add(startPoint)
                path.add(endCoordinate)

                selectionLine = GMSPolyline(path: path)
                selectionLine?.strokeColor = UIColor(red: 20/255, green: 1.0, blue: 0, alpha: 1.0)
                selectionLine?.strokeWidth = 2.0
                selectionLine?.map = mapView
            } else {
                if let points = selectionPoints {
                    var updatedPoints = points
                    updatedPoints.append(endCoordinate)
                    selectionPoints = updatedPoints

                    let path = GMSMutablePath()
                    updatedPoints.forEach { path.add($0) }
                    selectionLine?.path = path
                }
            }
        }

        return true // Return true to consume the touch event and prevent scrolling
    }

    func handleSelectionEnd(at location: CGPoint) -> Bool {
        guard let mapView = mapViewController.GMapView,
              let targetView = targetViewController else {
            print("handleSelectionEnd: mapView or targetView is nil")
            return false
        }

        // Convert location from webView coordinates to mapView coordinates
        guard let webView = delegate.bridge?.webView else {
            return false
        }

        // First convert from webView to targetView
        let locationInTargetView = webView.convert(location, to: targetView)
        // Then get the point in mapView's coordinate system
        let locationInMapView = mapView.convert(locationInTargetView, from: targetView)

        // Immediately clear selection shapes to stop drawing
        selectionSquare?.map = nil
        selectionSquare = nil
        selectionLine?.map = nil
        selectionLine = nil

        if selectionType == "square" {
            let endCoordinate = mapView.projection.coordinate(for: locationInMapView)

            if let startPoint = startPoint {
                let inside = getMarkersInsideSquare(
                    startLng: startPoint.longitude,
                    startLat: startPoint.latitude,
                    endLng: endCoordinate.longitude,
                    endLat: endCoordinate.latitude
                )

                let mIdsArray = inside
                var payload = JSObject()
                payload["mapId"] = self.id
                payload["mIds"] = mIdsArray

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate.notifyListeners("onSelectionEnd", data: payload)
                }
            }
        } else {
            // Shape selection
            if let points = selectionPoints, !points.isEmpty {
                // Ignore simple taps/short drags in shape mode.
                // A valid lasso requires at least 3 points.
                guard points.count >= 3 else {
                    selectionPoints = nil
                    startPoint = nil
                    selectionActive = false
                    return false
                }

                // Close the polygon by adding the first point at the end (like Android)
                var closed = points
                if let firstPoint = points.first {
                    closed.append(firstPoint)
                }

                let path = GMSMutablePath()
                closed.forEach { path.add($0) }

                let polygon = GMSPolygon(path: path)
                polygon.strokeWidth = 2.0
                polygon.strokeColor = UIColor(red: 20/255, green: 1.0, blue: 0, alpha: 1.0)
                polygon.fillColor = UIColor(red: 20/255, green: 1.0, blue: 0, alpha: 0.2)
                polygon.map = mapView

                // Use original points (without closing) for containsLocation check
                let originalPath = GMSMutablePath()
                points.forEach { originalPath.add($0) }
                // Close the path for containsLocation check
                if let firstPoint = points.first {
                    originalPath.add(firstPoint)
                }

                let inside = markers.filter { marker in
                    let markerPosition = marker.value.position
                    return GMSGeometryContainsLocation(markerPosition, originalPath, true)
                }.compactMap { markerEntry in
                    let markerId = markerEntry.key
                    return mIds.first(where: { $0.value == markerId })?.key
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) {
                    polygon.map = nil
                }

                // Send original points (without closing point) in payload
                let pointsArray = points.map { point -> JSObject in
                    var pointObj = JSObject()
                    pointObj["lat"] = point.latitude
                    pointObj["lng"] = point.longitude
                    return pointObj
                }

                var payload = JSObject()
                payload["mapId"] = self.id
                payload["mIds"] = inside
                payload["selectionPoints"] = pointsArray

                selectionPoints = nil

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate.notifyListeners("onSelectionEnd", data: payload)
                }
            }
        }

        // Clear start point
        startPoint = nil

        selectionActive = false
        return false
    }

    func clearSelection() {
        selectionActive = false
        startPoint = nil
        selectionPoints = nil

        // Immediately remove selection shapes from map
        selectionSquare?.map = nil
        selectionSquare = nil
        selectionLine?.map = nil
        selectionLine = nil

        setSelectionScrollLock(lockSingleFinger: false)
    }

    private func getMarkersInsideSquare(
        startLng: Double,
        startLat: Double,
        endLng: Double,
        endLat: Double
    ) -> [String] {
        let left = min(startLng, endLng)
        let right = max(startLng, endLng)
        let top = max(startLat, endLat)
        let bottom = min(startLat, endLat)

        return markers.filter { marker in
            let pos = marker.value.position
            return pos.latitude >= bottom && pos.latitude <= top &&
                   pos.longitude >= left && pos.longitude <= right
        }.compactMap { markerEntry in
            // markerEntry is (key: Int, value: GMSMarker)
            // Find mId by markerId (the key)
            let markerId = markerEntry.key
            return mIds.first(where: { $0.value == markerId })?.key
        }
    }

    func dispatchTouchEvents(events: [UITouch]) {
        // In iOS, we can't directly dispatch UITouch events like in Android
        // This would need to be handled through JavaScript bridge or native gesture recognizers
        // For now, this is a placeholder
    }
}

private func getResizedIcon(_ iconImage: UIImage, _ iconSize: CGSize?) -> UIImage? {
    if let iconSize = iconSize {
        return iconImage.resizeImageTo(size: iconSize)
    } else {
        return iconImage
    }
}

extension WKWebView {
    static var disabledTargets: [UIView] = []

    override open func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        var hitView = super.hitTest(point, with: event)

        if let tempHitView = hitView, WKWebView.disabledTargets.contains(tempHitView) {
            return nil
        }

        if let typeClass = NSClassFromString("WKChildScrollView"), let tempHitView = hitView, tempHitView.isKind(of: typeClass) {
            for item in tempHitView.subviews.reversed() {
                let convertPoint = item.convert(point, from: self)
                if let hitTestView = item.hitTest(convertPoint, with: event) {
                    hitView = hitTestView
                    break
                }
            }
        }

        return hitView
    }
}

extension UIView {
    private static var allSubviews: [UIView] = []

    private func viewArray(root: UIView) -> [UIView] {
        var index = root.tag
        for view in root.subviews {
            if view.tag == Map.MAP_TAG {
                // view already in use as in map
                continue
            }

            // tag the index depth of the uiview
            view.tag = index

            if view.isKind(of: UIView.self) {
                UIView.allSubviews.append(view)
            }
            _ = viewArray(root: view)

            index += 1
        }
        return UIView.allSubviews
    }

    fileprivate func getAllSubViews() -> [UIView] {
        UIView.allSubviews = []
        return viewArray(root: self).reversed()
    }

    fileprivate func removeAllSubview() {
        subviews.forEach {
            $0.removeFromSuperview()
        }
    }
}

extension UIImage {
    func resizeImageTo(size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        self.draw(in: CGRect(origin: CGPoint.zero, size: size))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return resizedImage
    }
}

func svgToImage(svgString: String, size: CGSize? = nil) -> UIImage? {
    guard let data = svgString.data(using: .utf8),
          let svgImage = SVGKImage(data: data) else {
        print("Failed to parse SVG")
        return nil
    }

    if let size = size {
        return svgImage.uiImage.resizeImageTo(size: size)
    } else {
        return svgImage.uiImage
    }
}

func runOnMainThread(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
        block()
    } else {
        DispatchQueue.main.sync {
            block()
        }
    }
}
