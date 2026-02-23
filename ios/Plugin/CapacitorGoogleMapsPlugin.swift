// swiftlint:disable file_length
import Foundation
import Capacitor
import GoogleMaps
import GoogleMapsUtils
import WebKit

extension GMSMapViewType {
    static func fromString(mapType: String) -> GMSMapViewType {
        switch mapType {
        case "Normal":
            return .normal
        case "Hybrid":
            return .hybrid
        case "Satellite":
            return .satellite
        case "Terrain":
            return .terrain
        case "None":
            return .none
        default:
            print("CapacitorGoogleMaps Warning: unknown mapView type '\(mapType)'.  Defaulting to normal.")
            return .normal
        }
    }
    static func toString(mapType: GMSMapViewType) -> String {
        switch mapType {
        case .normal:
            return "Normal"
        case .hybrid:
            return "Hybrid"
        case .satellite:
            return "Satellite"
        case .terrain:
            return "Terrain"
        case .none:
            return "None"
        default:
            return "Normal"
        }
    }
}

extension CGRect {
    static func fromJSObject(_ jsObject: JSObject) throws -> CGRect {
        guard let width = jsObject["width"] as? Double else {
            throw GoogleMapErrors.invalidArguments("bounds object is missing the required 'width' property")
        }

        guard let height = jsObject["height"] as? Double else {
            throw GoogleMapErrors.invalidArguments("bounds object is missing the required 'height' property")
        }

        guard let x = jsObject["x"] as? Double else {
            throw GoogleMapErrors.invalidArguments("bounds object is missing the required 'x' property")
        }

        guard let y = jsObject["y"] as? Double else {
            throw GoogleMapErrors.invalidArguments("bounds object is missing the required 'y' property")
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// swiftlint:disable type_body_length
@objc(CapacitorGoogleMapsPlugin)
public class CapacitorGoogleMapsPlugin: CAPPlugin, GMSMapViewDelegate {
    private var maps = [String: Map]()
    private var isInitialized = false
    private var locationManager = CLLocationManager()
    private var cachedTouchEvents: [String: [UITouch]] = [:]
    private var touchEnabled: [String: Bool] = [:]
    private var longPressGestureRecognizer: UILongPressGestureRecognizer?
    private var longPressHandled: [String: Bool] = [:] // Track if long press was already handled for each map

    func checkLocationPermission() -> String {
        let locationState: String

        switch self.locationManager.authorizationStatus {
        case .notDetermined:
            locationState = "prompt"
        case .restricted, .denied:
            locationState = "denied"
        case .authorizedAlways, .authorizedWhenInUse:
            locationState = "granted"
        @unknown default:
            locationState = "prompt"
        }

        return locationState
    }

    public override func load() {
        super.load()

        // Setup touch handling on webView
        if let webView = self.bridge?.webView {
            setupTouchHandling(on: webView)
        }
    }

    private func setupTouchHandling(on webView: UIView) {
        let touchInterceptor = TouchInterceptorGestureRecognizer(
            touchHandler: { [weak self] gesture in
                guard let self = self else { return false }
                return self.handleTouchEvent(gesture: gesture)
            },
            longPressHandler: { [weak self] location in
                self?.handleLongPressAtLocation(location)
            },
            scrollBlockHandler: { [weak self] block in
                guard let self = self else { return }
                // Block/unblock scrolling for all maps that have selectionType set
                for (_, map) in self.maps {
                    if map.getSelectionType() != nil {
                        if let gMapView = map.mapViewController.GMapView {
                            gMapView.settings.scrollGestures = !block
                        }
                    }
                }
                if let wkWebView = self.bridge?.webView as? WKWebView {
                    wkWebView.scrollView.isScrollEnabled = !block
                }
            }
        )
        touchInterceptor.cancelsTouchesInView = false
        touchInterceptor.delegate = self
        webView.addGestureRecognizer(touchInterceptor)

        // Setup long press gesture recognizer separately as backup
        longPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGestureRecognizer?.minimumPressDuration = 0.5
        longPressGestureRecognizer?.cancelsTouchesInView = false
        longPressGestureRecognizer?.delegate = self
        longPressGestureRecognizer?.delaysTouchesBegan = false
        longPressGestureRecognizer?.delaysTouchesEnded = false

        if let longPress = longPressGestureRecognizer {
            webView.addGestureRecognizer(longPress)
        }
    }

    private func isAnySelectionActive() -> Bool {
        return maps.values.contains { $0.selectionActive }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }

        guard let webView = self.bridge?.webView else { return }
        let location = gesture.location(in: webView)

        handleLongPressAtLocation(location)
    }

    func handleLongPressAtLocation(_ location: CGPoint) {
        print("handleLongPressAtLocation called at: \(location)")

        for (id, map) in maps {
            if touchEnabled[id] == false {
                print("handleLongPressAtLocation: touchEnabled[\(id)] is false")
                continue
            }

            let mapRect = map.getMapBounds()
            print("handleLongPressAtLocation: mapRect=\(mapRect), contains=\(mapRect.contains(location))")

            if mapRect.contains(location) {
                if let selectionType = map.getSelectionType() {
                    // Only start selection if it's not already active (prevent double activation)
                    guard !map.selectionActive else {
                        print("handleLongPressAtLocation: selection already active, ignoring")
                        continue // Use continue instead of return to check other maps
                    }

                    // CRITICAL: Check if long press was already handled for this map AND selection is still active
                    // This prevents multiple calls from timer firing multiple times, but allows new long press after selection ends
                    if longPressHandled[id] == true && map.selectionActive {
                        print("handleLongPressAtLocation: long press already handled for map \(id) and selection is active, ignoring")
                        continue
                    }

                    // If selection is not active, reset the flag to allow new long press
                    if !map.selectionActive {
                        longPressHandled[id] = false
                    }

                    // Start selection on long press - call synchronously on main thread
                    print("Touch event handler long press Start Selection at location: \(location), selectionType: \(selectionType)")
                    if Thread.isMainThread {
                        map.startSelection(at: location)
                        longPressHandled[id] = true // Mark as handled
                        print("After startSelection: selectionActive=\(map.selectionActive)")
                        // Note: Scrolling will be disabled during drawing (in .changed case)
                        // But if user lifts finger without drawing, scrolling will be restored in .ended case
                    } else {
                        DispatchQueue.main.sync {
                            map.startSelection(at: location)
                            longPressHandled[id] = true // Mark as handled
                            print("After startSelection: selectionActive=\(map.selectionActive)")
                        }
                    }
                } else {
                    print("handleLongPressAtLocation: selectionType is nil")
                }
            } else {
                print("handleLongPressAtLocation: location not in mapRect")
            }
        }
    }

    private func handleTouchEvent(gesture: UIGestureRecognizer) -> Bool {
        guard let webView = self.bridge?.webView else { return false }

        let location = gesture.location(in: webView)

        // --- Touch ended/cancelled: finish selection if active, always restore scrolling ---
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            for (id, map) in maps {
                if map.selectionActive {
                    map.handleSelectionEnd(at: location)
                    map.clearSelection()
                }
                longPressHandled[id] = false
                cachedTouchEvents[id]?.removeAll()

                // Always restore scrolling on touch end
                if let gMapView = map.mapViewController.GMapView {
                    gMapView.settings.scrollGestures = true
                }
            }
            if let wkWebView = self.bridge?.webView as? WKWebView {
                wkWebView.scrollView.isScrollEnabled = true
            }
            return false
        }

        // --- New touch began: if selection was left active from a previous gesture, clear it ---
        if gesture.state == .began {
            for (_, map) in maps {
                if map.selectionActive {
                    map.clearSelection()
                    if let gMapView = map.mapViewController.GMapView {
                        gMapView.settings.scrollGestures = true
                    }
                }
            }
        }

        // --- Route touches to the appropriate map ---
        for (id, map) in maps {
            if touchEnabled[id] == false { continue }

            let mapRect = map.getMapBounds()
            guard mapRect.contains(location) else { continue }

            // Map has selection type set — check if actively drawing
            if map.getSelectionType() != nil && map.selectionActive && gesture.state == .changed {
                // Active selection drawing: block scrolling and draw
                if let gMapView = map.mapViewController.GMapView {
                    gMapView.settings.scrollGestures = false
                }
                if let wkWebView = self.bridge?.webView as? WKWebView {
                    wkWebView.scrollView.isScrollEnabled = false
                }
                map.handleSelectionMove(at: location)
                return true
            }

            // Not actively drawing — notify listeners for focus tracking
            let devicePixelRatio = UIScreen.main.scale
            let payload: [String: Any] = [
                "x": location.x / CGFloat(devicePixelRatio),
                "y": location.y / CGFloat(devicePixelRatio),
                "mapId": map.id
            ]
            self.notifyListeners("isMapInFocus", data: payload)

            // Allow normal map interaction (scroll, zoom, tap)
            if gesture.state == .began || gesture.state == .changed {
                return true
            }
        }

        return false
    }

	@objc func getMarkersIds(_ call: CAPPluginCall) {
		do {
			guard let id = call.getString("id") else {
				throw GoogleMapErrors.invalidMapId
			}

			guard let map = self.maps[id] else {
				throw GoogleMapErrors.mapNotFound
			}

			call.resolve(map.mIds)
		} catch {
			handleError(call, error: error)
		}
	}

    @objc func create(_ call: CAPPluginCall) {
        do {
            if !isInitialized {
                guard let apiKey = call.getString("apiKey") else {
                    throw GoogleMapErrors.invalidAPIKey
                }

                GMSServices.provideAPIKey(apiKey)
                isInitialized = true
            }

            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let configObj = call.getObject("config") else {
                throw GoogleMapErrors.invalidArguments("config object is missing")
            }

            let forceCreate = call.getBool("forceCreate", false)

            let config = try GoogleMapConfig(fromJSObject: configObj)

            if self.maps[id] != nil {
                if !forceCreate {
                    call.resolve()
                    return
                }

                let removedMap = self.maps.removeValue(forKey: id)

                if removedMap?.isDestroyed == true {
                    DispatchQueue.main.async {
                        let newMap = Map(id: id, config: config, delegate: self)
                        newMap.mapViewController.mapType = config.mapType
                        self.maps[id] = newMap
                        call.resolve()
                    }
                    return
                }

                removedMap?.destroyWithCompletion {
                    DispatchQueue.main.async {
                        if self.maps[id] == nil {
                            let newMap = Map(id: id, config: config, delegate: self)
                            newMap.mapViewController.mapType = config.mapType
                            self.maps[id] = newMap
                        }
                        call.resolve()
                    }
                }
                return
            }

            DispatchQueue.main.sync {
                let newMap = Map(id: id, config: config, delegate: self)
				newMap.mapViewController.mapType = config.mapType
                self.maps[id] = newMap
            }

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func destroy(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let removedMap = self.maps.removeValue(forKey: id) else {
                call.resolve()
                return
            }

            removedMap.destroyWithCompletion {
                call.resolve()
            }
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func enableTouch(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            touchEnabled[id] = true
            map.enableTouch()

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func disableTouch(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            touchEnabled[id] = false
            map.disableTouch()

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func dispatchMapEvent(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            let focus = call.getBool("focus", false) ?? false

            let events = cachedTouchEvents[id]
            if let events = events, !events.isEmpty {
                // In iOS, we need to dispatch events differently
                // Since we can't directly create UITouch, we'll notify through JavaScript
                if focus {
					print("Focus event")
                    // Map is in focus, dispatch to map
                    map.dispatchTouchEvents(events: events)
                } else {
					print("Focus event ELSE")
                    // Map is not in focus, dispatch to webView
                    // Note: In iOS, we can't directly dispatch to webView like in Android
                    // This would need to be handled through JavaScript bridge
                }
                cachedTouchEvents[id]?.removeAll()
            }

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

	let imageCache = NSCache<NSString, UIImage>()

	@objc func hasIcon(_ call: CAPPluginCall) {
		do {
			guard let iconId = call.getString("iconId") else {
				throw GoogleMapErrors.invalidArguments("Missing iconId")
			}

			let hasIcon = imageCache.object(forKey: iconId as NSString) != nil

			call.resolve([
				"hasIcon": hasIcon
			])
		} catch {
			handleError(call, error: error)
		}
	}

	@objc func cacheMarkerIcon(_ call: CAPPluginCall) {
		do {
			guard let id = call.getString("id") else {
				throw GoogleMapErrors.invalidArguments("Missing id")
			}

			guard let base64String = call.getString("base64") else {
				throw GoogleMapErrors.invalidArguments("Missing base64 string")
			}

			// Check if the icon is already cached
			if let _ = imageCache.object(forKey: id as NSString) {
				call.resolve(["status": "already_cached"])
				return
			}

			// Convert the base64 string to UIImage and cache it
			if let data = Data(base64Encoded: base64String), let image = UIImage(data: data) {
				imageCache.setObject(image, forKey: id as NSString)
				call.resolve(["status": "cached"])
			} else {
				throw GoogleMapErrors.invalidArguments("Invalid base64 data")
			}
		} catch {
			handleError(call, error: error)
		}
	}

    @objc func addMarker(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let markerObj = call.getObject("marker") else {
                throw GoogleMapErrors.invalidArguments("marker object is missing")
            }

            let marker = try Marker(fromJSObject: markerObj, imageCache: imageCache)

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            let markerId = try map.addMarker(marker: marker, cleanAllMarkers: marker.clearAllMarkers ?? true)

            call.resolve(["id": String(markerId)])

        } catch {
            handleError(call, error: error)
        }
    }

	@objc func updateMarker(_ call: CAPPluginCall) {
		do {
			guard let id = call.getString("id") else {
				throw GoogleMapErrors.invalidMapId
			}

			guard let markerId = call.getString("markerId"),
				  let markerId = Int(markerId) else {
				throw GoogleMapErrors.invalidArguments("markerId is missing")
			}

			guard let markerObj = call.getObject("marker") else {
				throw GoogleMapErrors.invalidArguments("marker object is missing")
			}

			let marker = try Marker(fromJSObject: markerObj, imageCache: imageCache)

			guard let map = self.maps[id] else {
				throw GoogleMapErrors.mapNotFound
			}

			try map.removeMarker(id: markerId)

			let markerHash = try map.addMarker(marker: marker)

			call.resolve(["id": String(markerHash)])

		} catch {
			handleError(call, error: error)
		}
	}

	@objc func updateMarkerBymId(_ call: CAPPluginCall) {
		do {
			guard let id = call.getString("id") else {
				throw GoogleMapErrors.invalidMapId
			}

			guard let mId = call.getString("mId") else {
				throw GoogleMapErrors.invalidArguments("mId is missing")
			}

			guard let markerObj = call.getObject("marker") else {
				throw GoogleMapErrors.invalidArguments("marker object is missing")
			}

			let marker = try Marker(fromJSObject: markerObj, imageCache: imageCache)

			guard let map = self.maps[id] else {
				throw GoogleMapErrors.mapNotFound
			}

			guard let markerHash = map.mIds[mId] else {
				throw GoogleMapErrors.markerNotFound
			}

			try map.removeMarker(id: markerHash)

			let markerId = try map.addMarker(marker: marker)

			call.resolve(["id": String(markerId)])

		} catch {
			handleError(call, error: error)
		}
	}

	@objc func updateMarkersBymId(_ call: CAPPluginCall) {
		do {
			guard let id = call.getString("id") else {
				throw GoogleMapErrors.invalidMapId
			}

			guard let mIds = call.getArray("mIds") as? [String] else {
				throw GoogleMapErrors.invalidArguments("mIds is missing")
			}

			guard let markersObj = call.getArray("markers") as? [JSObject] else {
				throw GoogleMapErrors.invalidArguments("markers is missing")
			}

			if markersObj.isEmpty {
				throw GoogleMapErrors.invalidArguments("markers requires at least one marker")
			}

			var markers: [Marker] = []

			try markersObj.forEach { markerObj in
				let marker = try Marker(fromJSObject: markerObj, imageCache: imageCache)
				markers.append(marker)
			}

			guard let map = self.maps[id] else {
				throw GoogleMapErrors.mapNotFound
			}

			var markerHashes: [String] = []

			for mId in mIds {
				guard let markerHash = map.mIds[mId],
					  let marker = markers.first(where: { $0.mId == mId }) else {
					print("updateMarkersBymId(): Marker not found \(mId)")
					return
				}

				try map.removeMarker(id: markerHash)

				let markerId = try map.addMarker(marker: marker)

				markerHashes.append(String(markerHash))
			}

			call.resolve(["ids": markerHashes])

		} catch {
			handleError(call, error: error)
		}
	}

	@objc func updateMarkerIcon(_ call: CAPPluginCall) {
		do {
			guard let id = call.getString("id") else {
				throw GoogleMapErrors.invalidMapId
			}

			guard let mId = call.getString("mId") else {
				throw GoogleMapErrors.invalidArguments("mId is missing")
			}

			guard let iconId = call.getString("iconId") else {
				throw GoogleMapErrors.invalidArguments("iconId is missing")
			}

			// iconUrl contains the actual SVG/URL data, used as fallback when imageCache misses
			let iconUrl = call.getString("iconUrl") ?? iconId

			var iconSize: CGSize?
			if let sizeObj = call.getObject("iconSize") {
				if let width = sizeObj["width"] as? Double, let height = sizeObj["height"] as? Double {
					iconSize = CGSize(width: width, height: height)
				}
			}

			guard let map = self.maps[id] else {
				throw GoogleMapErrors.mapNotFound
			}

			// Try to resolve the icon from the plugin's imageCache first
			let cachedIcon = imageCache.object(forKey: iconId as NSString)
			// Pass both the cached image (if any) and the iconUrl for SVG/URL fallback
			map.updateMarkerIcon(mId: mId, iconUrl: iconUrl, iconSize: iconSize, iconImage: cachedIcon)
		} catch {
			handleError(call, error: error)
		}
	}


    @objc func addMarkers(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let markerObjs = call.getArray("markers") as? [JSObject] else {
                throw GoogleMapErrors.invalidArguments("markers array is missing")
            }

            if markerObjs.isEmpty {
                throw GoogleMapErrors.invalidArguments("markers requires at least one marker")
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            var markers: [Marker] = []

            try markerObjs.forEach { marker in
                let marker = try Marker(fromJSObject: marker, imageCache: imageCache)
                markers.append(marker)
            }

			map.addMarkers(markers: markers) { markerHashes in
				call.resolve(["ids": markerHashes.map({ id in
					return String(id)
				})])
			}

        } catch {
            handleError(call, error: error)
        }
    }

    @objc func removeMarkers(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let markerIdStrings = call.getArray("markerIds") as? [String] else {
                throw GoogleMapErrors.invalidArguments("markerIds are invalid or missing")
            }

            if markerIdStrings.isEmpty {
                throw GoogleMapErrors.invalidArguments("markerIds requires at least one marker id")
            }

            let ids: [Int] = try markerIdStrings.map { idString in
                guard let markerId = Int(idString) else {
                    throw GoogleMapErrors.invalidArguments("markerIds are invalid or missing")
                }

                return markerId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            try map.removeMarkers(ids: ids)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

	@objc func removeMarkersBymId(_ call: CAPPluginCall) {
		do {
			guard let id = call.getString("id") else {
				throw GoogleMapErrors.invalidMapId
			}

			guard let mIds = call.getArray("mIds") as? [String] else {
				throw GoogleMapErrors.invalidArguments("mIds are missing")
			}

			if mIds.isEmpty {
				throw GoogleMapErrors.invalidArguments("mIds requires at least one marker id")
			}

			guard let map = self.maps[id] else {
				throw GoogleMapErrors.mapNotFound
			}

			try map.removeMarkersBymId(mIds: mIds)

			call.resolve()
		} catch {
			handleError(call, error: error)
		}
	}

    @objc func removeMarker(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let markerIdString = call.getString("markerId") else {
                throw GoogleMapErrors.invalidArguments("markerId is invalid or missing")
            }

            guard let markerId = Int(markerIdString) else {
                throw GoogleMapErrors.invalidArguments("markerId is invalid or missing")
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            try map.removeMarker(id: markerId)

            call.resolve()

        } catch {
            handleError(call, error: error)
        }
    }

	@objc func removeMarkerBymId(_ call: CAPPluginCall) {
		do {
			guard let id = call.getString("id") else {
				throw GoogleMapErrors.invalidMapId
			}

			guard let mId = call.getString("mId") else {
				throw GoogleMapErrors.invalidArguments("mId is missing")
			}

			guard let map = self.maps[id] else {
				throw GoogleMapErrors.mapNotFound
			}

			try map.removeMarkerBymId(mId: mId)

			call.resolve()

		} catch {
			handleError(call, error: error)
		}
	}

    @objc func addPolygons(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let shapeObjs = call.getArray("polygons") as? [JSObject] else {
                throw GoogleMapErrors.invalidArguments("polygons array is missing")
            }

            if shapeObjs.isEmpty {
                throw GoogleMapErrors.invalidArguments("polygons requires at least one shape")
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            var shapes: [Polygon] = []

            try shapeObjs.forEach { shapeObj in
                let polygon = try Polygon(fromJSObject: shapeObj)
                shapes.append(polygon)
            }

            let ids = try map.addPolygons(polygons: shapes)

            call.resolve(["ids": ids.map({ id in
                return String(id)
            })])
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func addPolylines(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let lineObjs = call.getArray("polylines") as? [JSObject] else {
                throw GoogleMapErrors.invalidArguments("polylines array is missing")
            }

            if lineObjs.isEmpty {
                throw GoogleMapErrors.invalidArguments("polylines requires at least one line")
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            var lines: [Polyline] = []

            try lineObjs.forEach { lineObj in
                let line = try Polyline(fromJSObject: lineObj)
                lines.append(line)
            }

            let ids = try map.addPolylines(lines: lines)

            call.resolve(["ids": ids.map({ id in
                return String(id)
            })])
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func removePolygons(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let polygonIdsStrings = call.getArray("polygonIds") as? [String] else {
                throw GoogleMapErrors.invalidArguments("polygonIds are invalid or missing")
            }

            if polygonIdsStrings.isEmpty {
                throw GoogleMapErrors.invalidArguments("polygonIds requires at least one polygon id")
            }

            let ids: [Int] = try polygonIdsStrings.map { idString in
                guard let polygonId = Int(idString) else {
                    throw GoogleMapErrors.invalidArguments("polygonIds are invalid or missing")
                }

                return polygonId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            try map.removePolygons(ids: ids)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func addCircles(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let circleObjs = call.getArray("circles") as? [JSObject] else {
                throw GoogleMapErrors.invalidArguments("circles array is missing")
            }

            if circleObjs.isEmpty {
                throw GoogleMapErrors.invalidArguments("circles requires at least one circle")
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            var circles: [Circle] = []

            try circleObjs.forEach { circleObj in
                let circle = try Circle(from: circleObj)
                circles.append(circle)
            }

            let ids = try map.addCircles(circles: circles)

            call.resolve(["ids": ids.map({ id in
                return String(id)
            })])
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func removeCircles(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let circleIdsStrings = call.getArray("circleIds") as? [String] else {
                throw GoogleMapErrors.invalidArguments("circleIds are invalid or missing")
            }

            if circleIdsStrings.isEmpty {
                throw GoogleMapErrors.invalidArguments("circleIds requires at least one cicle id")
            }

            let ids: [Int] = try circleIdsStrings.map { idString in
                guard let circleId = Int(idString) else {
                    throw GoogleMapErrors.invalidArguments("circleIds are invalid or missing")
                }

                return circleId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            try map.removeCircles(ids: ids)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func removePolylines(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let polylineIdsStrings = call.getArray("polylineIds") as? [String] else {
                throw GoogleMapErrors.invalidArguments("polylineIds are invalid or missing")
            }

            if polylineIdsStrings.isEmpty {
                throw GoogleMapErrors.invalidArguments("polylineIds requires at least one polyline id")
            }

            let ids: [Int] = try polylineIdsStrings.map { idString in
                guard let polylineId = Int(idString) else {
                    throw GoogleMapErrors.invalidArguments("polylineIds are invalid or missing")
                }

                return polylineId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            try map.removePolylines(ids: ids)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func setCamera(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            guard let configObj = call.getObject("config") else {
                throw GoogleMapErrors.invalidArguments("config object is missing")
            }

            let config = try GoogleMapCameraConfig(fromJSObject: configObj)

            try map.setCamera(config: config)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func getMapType(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            let mapType = GMSMapViewType.toString(mapType: map.getMapType())

            call.resolve([
                "type": mapType
            ])
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func setMapType(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            guard let mapTypeString = call.getString("mapType") else {
                throw GoogleMapErrors.invalidArguments("mapType is missing")
            }

            let mapType = GMSMapViewType.fromString(mapType: mapTypeString)

            try map.setMapType(mapType: mapType)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func enableIndoorMaps(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            guard let enabled = call.getBool("enabled") else {
                throw GoogleMapErrors.invalidArguments("enabled is missing")
            }

            try map.enableIndoorMaps(enabled: enabled)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func enableTrafficLayer(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            guard let enabled = call.getBool("enabled") else {
                throw GoogleMapErrors.invalidArguments("enabled is missing")
            }

            try map.enableTrafficLayer(enabled: enabled)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func enableAccessibilityElements(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            guard let enabled = call.getBool("enabled") else {
                throw GoogleMapErrors.invalidArguments("enabled is missing")
            }

            try map.enableAccessibilityElements(enabled: enabled)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func setPadding(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            guard let configObj = call.getObject("padding") else {
                throw GoogleMapErrors.invalidArguments("padding is missing")
            }

            let padding = try GoogleMapPadding.init(fromJSObject: configObj)

            try map.setPadding(padding: padding)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func enableCurrentLocation(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            guard let enabled = call.getBool("enabled") else {
                throw GoogleMapErrors.invalidArguments("enabled is missing")
            }

            let locationStatus = checkLocationPermission()

            if enabled &&  !(locationStatus == "granted" || locationStatus == "prompt") {
                throw GoogleMapErrors.permissionsDeniedLocation
            }

            try map.enableCurrentLocation(enabled: enabled)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func enableClustering(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            let minClusterSize = call.getInt("minClusterSize")

            map.enableClustering(minClusterSize)
            call.resolve()

        } catch {
            handleError(call, error: error)
        }
    }

    @objc func disableClustering(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            map.disableClustering()
            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func onScroll(_ call: CAPPluginCall) {
        call.unavailable("not supported on iOS")
    }

    @objc func onResize(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            guard let mapBoundsObj = call.getObject("mapBounds") else {
                throw GoogleMapErrors.invalidArguments("map bounds not set")
            }

            let mapBounds = try CGRect.fromJSObject(mapBoundsObj)

            map.updateRender(mapBounds: mapBounds)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func onDisplay(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            guard let mapBoundsObj = call.getObject("mapBounds") else {
                throw GoogleMapErrors.invalidArguments("map bounds not set")
            }

            let mapBounds = try CGRect.fromJSObject(mapBoundsObj)

            map.rebindTargetContainer(mapBounds: mapBounds)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func getMapBounds(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            try DispatchQueue.main.sync {
                guard let bounds = map.getMapLatLngBounds() else {
                    throw GoogleMapErrors.unhandledError("Google Map Bounds could not be found.")
                }

                call.resolve(
                    formatMapBoundsForResponse(
                        bounds: bounds,
                        cameraPosition: map.mapViewController.GMapView.camera
                    )
                )
            }
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func mapBoundsContains(_ call: CAPPluginCall) {
        do {
            guard let boundsObject = call.getObject("bounds") else {
                throw GoogleMapErrors.invalidArguments("Invalid bounds provided")
            }

            guard let pointObject = call.getObject("point") else {
                throw GoogleMapErrors.invalidArguments("Invalid point provided")
            }

            let bounds = try getGMSCoordinateBounds(boundsObject)
            let point = try getCLLocationCoordinate(pointObject)

            call.resolve([
                "contains": bounds.contains(point)
            ])
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func fitBounds(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            guard let boundsObject = call.getObject("bounds") else {
                throw GoogleMapErrors.invalidArguments("Invalid bounds provided")
            }

            let bounds = try getGMSCoordinateBounds(boundsObject)
            let padding = CGFloat(call.getInt("padding", 0))

            map.fitBounds(bounds: bounds, padding: padding)
            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func mapBoundsExtend(_ call: CAPPluginCall) {
        do {
            guard let boundsObject = call.getObject("bounds") else {
                throw GoogleMapErrors.invalidArguments("Invalid bounds provided")
            }

            guard let pointObject = call.getObject("point") else {
                throw GoogleMapErrors.invalidArguments("Invalid point provided")
            }

            let bounds = try getGMSCoordinateBounds(boundsObject)
            let point = try getCLLocationCoordinate(pointObject)

            DispatchQueue.main.sync {
                let newBounds = bounds.includingCoordinate(point)
                call.resolve([
                    "bounds": formatMapBoundsForResponse(newBounds)
                ])
            }
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func takeSnapshot(_ call: CAPPluginCall) {
    // Create snapshot options
		do {
        // Validate map ID and retrieve the map instance
        guard let id = call.getString("id"), let map = maps[id] else {
            throw GoogleMapErrors.invalidMapId
        }

        // Get the format from the call, default to "png" if not provided
        let format = call.getString("format")?.lowercased() ?? "png"
        let quality = call.getInt("quality") ?? 100 // JPEG quality (0-100), ignored for PNG

        // Ensure the mapView exists
        guard let mapView = map.mapViewController.GMapView else {
            call.reject("Map view not found")
            return
        }

        DispatchQueue.main.async {
            // Render the map view into an image
            let renderer = UIGraphicsImageRenderer(size: mapView.bounds.size)
            let image = renderer.image { _ in
                mapView.drawHierarchy(in: mapView.bounds, afterScreenUpdates: true)
            }

            // Convert the image to the desired format
            var base64String: String?
            if format == "png" {
                if let imageData = image.pngData() {
                    base64String = imageData.base64EncodedString()
                }
            } else if format == "jpeg" || format == "jpg" {
                if let imageData = image.jpegData(compressionQuality: CGFloat(quality) / 100.0) {
                    base64String = imageData.base64EncodedString()
                }
            } else {
                call.reject("Invalid format: \(format). Supported formats are 'png' and 'jpeg'")
                return
            }

            // Return the Base64 string or reject the call if conversion failed
            if let base64String = base64String {
                call.resolve(["snapshot": base64String])
            } else {
                call.reject("Failed to convert image to \(format) format")
            }
        }
    } catch {
        handleError(call, error: error)
    }
    }

	  @objc func addGroundOverlay(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            let overlay = try GroundOverlay(call)

            try map.addGroundOverlay(overlay: overlay)

            call.resolve(["mapId": String(id)])

        } catch {
            handleError(call, error: error)
        }
    }

    @objc func setSelectionType(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            let selectionType = call.getString("selectionType")

            map.setSelectionType(selectionType)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func setMarkersDraggable(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            guard let mIds = call.getArray("mIds") as? [String] else {
                throw GoogleMapErrors.invalidArguments("mIds is missing")
            }

            let draggable = call.getBool("draggable") ?? false

            map.setMarkersDraggable(mIds: mIds, draggable: draggable)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    @objc func setAllMarkersDraggable(_ call: CAPPluginCall) {
        do {
            guard let id = call.getString("id") else {
                throw GoogleMapErrors.invalidMapId
            }

            guard let map = self.maps[id] else {
                throw GoogleMapErrors.mapNotFound
            }

            let draggable = call.getBool("draggable") ?? false

            map.setAllMarkersDraggable(draggable: draggable)

            call.resolve()
        } catch {
            handleError(call, error: error)
        }
    }

    private func getGMSCoordinateBounds(_ bounds: JSObject) throws -> GMSCoordinateBounds {
        guard let southwest = bounds["southwest"] as? JSObject else {
            throw GoogleMapErrors.unhandledError("Bounds southwest property not formatted properly.")
        }

        guard let northeast = bounds["northeast"] as? JSObject else {
            throw GoogleMapErrors.unhandledError("Bounds northeast property not formatted properly.")
        }

        return GMSCoordinateBounds(
            coordinate: try getCLLocationCoordinate(southwest),
            coordinate: try getCLLocationCoordinate(northeast)
        )
    }

    private func getCLLocationCoordinate(_ point: JSObject) throws -> CLLocationCoordinate2D {
        guard let lat = point["lat"] as? Double else {
            throw GoogleMapErrors.unhandledError("Point lat property not formatted properly.")
        }

        guard let lng = point["lng"] as? Double else {
            throw GoogleMapErrors.unhandledError("Point lng property not formatted properly.")
        }

        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private func formatMapBoundsForResponse(bounds: GMSCoordinateBounds?, cameraPosition: GMSCameraPosition) -> PluginCallResultData {
        return [
            "southwest": [
                "lat": bounds?.southWest.latitude,
                "lng": bounds?.southWest.longitude
            ],
            "center": [
                "lat": cameraPosition.target.latitude,
                "lng": cameraPosition.target.longitude
            ],
            "northeast": [
                "lat": bounds?.northEast.latitude,
                "lng": bounds?.northEast.longitude
            ]
        ]
    }

    private func formatMapBoundsForResponse(_ bounds: GMSCoordinateBounds) -> PluginCallResultData {
        let centerLatitude = (bounds.southWest.latitude + bounds.northEast.latitude) / 2.0
        let centerLongitude = (bounds.southWest.longitude + bounds.northEast.longitude) / 2.0

        return [
            "southwest": [
                "lat": bounds.southWest.latitude,
                "lng": bounds.southWest.longitude
            ],
            "center": [
                "lat": centerLatitude,
                "lng": centerLongitude
            ],
            "northeast": [
                "lat": bounds.northEast.latitude,
                "lng": bounds.northEast.longitude
            ]
        ]
    }

    private func handleError(_ call: CAPPluginCall, error: Error) {
        let errObject = getErrorObject(error)
        call.reject(errObject.message, "\(errObject.code)", error, [:])
    }

    private func findMapIdByMapView(_ mapView: GMSMapView) -> String {
        for (mapId, map) in self.maps {
            if map.mapViewController.GMapView === mapView {
                return mapId
            }
        }
        return ""
    }

    // --- EVENT LISTENERS ---

    // Implement the map long press event handler
    public func mapView(_ mapView: GMSMapView, didLongPressAt coordinate: CLLocationCoordinate2D) {
        // Create a data object to send to the JavaScript side
        let data = [
            "mapId":  self.findMapIdByMapView(mapView),
            "latitude": coordinate.latitude,
            "longitude": coordinate.longitude
        ] as [String : Any]

        // Notify Capacitor about the long press event
        notifyListeners("onMapLongClick", data: data)
    }

    //Notify on MapLoaded
	public func mapViewDidFinishTileRendering(_ mapView: GMSMapView) {
		// Prepare the data to send
		var data = JSObject()
		data["mapId"] = self.findMapIdByMapView(mapView)

		// Notify the delegate that the map has finished loading
		self.notifyListeners("onMapLoaded", data: data)
	}

    // onCameraIdle
    public func mapView(_ mapView: GMSMapView, idleAt cameraPosition: GMSCameraPosition) {
        let mapId = self.findMapIdByMapView(mapView)
        let map = self.maps[mapId]
        let bounds = map?.getMapLatLngBounds()

        let data: PluginCallResultData = [
            "mapId": mapId,
            "bounds": formatMapBoundsForResponse(
                bounds: bounds,
                cameraPosition: cameraPosition
            ),
            "bearing": cameraPosition.bearing,
            "latitude": cameraPosition.target.latitude,
            "longitude": cameraPosition.target.longitude,
            "tilt": cameraPosition.viewingAngle,
            "zoom": cameraPosition.zoom
        ]

        self.notifyListeners("onBoundsChanged", data: data)
        self.notifyListeners("onCameraIdle", data: data)

        // if let map = map {
        //     _updateVisibleMarkers(mapView: mapView, map: map)
        // }
    }

    // onCameraMoveStarted
    public func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
        self.notifyListeners("onCameraMoveStarted", data: [
            "mapId": self.findMapIdByMapView(mapView),
            "isGesture": gesture
        ])
    }

    // onMapClick
    public func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) {
        self.notifyListeners("onMapClick", data: [
            "mapId": self.findMapIdByMapView(mapView),
            "latitude": coordinate.latitude,
            "longitude": coordinate.longitude
        ])
    }

    // onPolygonClick, onPolylineClick, onCircleClick
    public func mapView(_ mapView: GMSMapView, didTap overlay: GMSOverlay) {
        if let polygon = overlay as? GMSPolygon {
            self.notifyListeners("onPolygonClick", data: [
                "mapId": self.findMapIdByMapView(mapView),
                "polygonId": String(overlay.hash.hashValue),
                "tag": polygon.userData as? String
            ])
        }

        if let circle = overlay as? GMSCircle {
            self.notifyListeners("onCircleClick", data: [
                "mapId": self.findMapIdByMapView(mapView),
                "circleId": String(overlay.hash.hashValue),
                "tag": circle.userData as? String,
                "latitude": circle.position.latitude,
                "longitude": circle.position.longitude,
                "radius": circle.radius
            ])
        }

        if let polyline = overlay as? GMSPolyline {
            self.notifyListeners("onPolylineClick", data: [
                "mapId": self.findMapIdByMapView(mapView),
                "polylineId": String(overlay.hash.hashValue),
                "tag": polyline.userData as? String
            ])
        }
    }

    // onClusterClick, onMarkerClick
    public func mapView(_ mapView: GMSMapView, didTap marker: GMSMarker) -> Bool {
        if let cluster = marker.userData as? GMUCluster {
            var items: [[String: Any?]] = []

            for item in cluster.items {
                items.append([
                    "markerId": String(item.hash.hashValue),
                    "latitude": item.position.latitude,
                    "longitude": item.position.longitude,
                    "title": item.title ?? "",
                    "snippet": item.snippet ?? ""
                ])
            }

            self.notifyListeners("onClusterClick", data: [
                "mapId": self.findMapIdByMapView(mapView),
                "latitude": cluster.position.latitude,
                "longitude": cluster.position.longitude,
                "size": cluster.count,
                "items": items
            ])
        } else {
			let mapId = self.findMapIdByMapView(mapView)
			let map = self.maps[mapId]
			var mId = "none"

			if let map {
				mId = map.mIds.first(where: { $0.value == marker.hash.hashValue })?.key ?? "none"
			}

            self.notifyListeners("onMarkerClick", data: [
                "mapId": mapId,
                "markerId": String(marker.hash.hashValue),
				"mId": mId,
                "latitude": marker.position.latitude,
                "longitude": marker.position.longitude,
                "title": marker.title ?? "",
                "snippet": marker.snippet ?? ""
            ])
        }
        return false
    }

    // onMarkerDragStart
    public func mapView(_ mapView: GMSMapView, didBeginDragging marker: GMSMarker) {
		let mapId = self.findMapIdByMapView(mapView)
		let map = self.maps[mapId]
		var mId = "none"

		if let map {
			mId = map.mIds.first(where: { $0.value == marker.hash.hashValue })?.key ?? "none"
		}

        self.notifyListeners("onMarkerDragStart", data: [
            "mapId": mapId,
			"mId": mId,
            "markerId": String(marker.hash.hashValue),
            "latitude": marker.position.latitude,
            "longitude": marker.position.longitude,
            "title": marker.title ?? "",
            "snippet": marker.snippet ?? ""
        ])
    }

    // onMarkerDrag
    public func mapView(_ mapView: GMSMapView, didDrag marker: GMSMarker) {
		let mapId = self.findMapIdByMapView(mapView)
		let map = self.maps[mapId]
		var mId = "none"

		if let map {
			mId = map.mIds.first(where: { $0.value == marker.hash.hashValue })?.key ?? "none"
		}

        self.notifyListeners("onMarkerDrag", data: [
            "mapId": mapId,
			"mId": mId,
            "markerId": String(marker.hash.hashValue),
            "latitude": marker.position.latitude,
            "longitude": marker.position.longitude,
            "title": marker.title ?? "",
            "snippet": marker.snippet ?? ""
        ])
    }

    // onMarkerDragEnd
    public func mapView(_ mapView: GMSMapView, didEndDragging marker: GMSMarker) {
		let mapId = self.findMapIdByMapView(mapView)
		let map = self.maps[mapId]
		var mId = "none"

		if let map {
			mId = map.mIds.first(where: { $0.value == marker.hash.hashValue })?.key ?? "none"
		}

        self.notifyListeners("onMarkerDragEnd", data: [
            "mapId": mapId,
			"mId": mId,
            "markerId": String(marker.hash.hashValue),
            "latitude": marker.position.latitude,
            "longitude": marker.position.longitude,
            "title": marker.title ?? "",
            "snippet": marker.snippet ?? ""
        ])
    }

    // onClusterInfoWindowClick, onInfoWindowClick
    public func mapView(_ mapView: GMSMapView, didTapInfoWindowOf marker: GMSMarker) {
        if let cluster = marker.userData as? GMUCluster {
            var items: [[String: Any?]] = []

            for item in cluster.items {
                items.append([
                    "markerId": String(item.hash.hashValue),
                    "latitude": item.position.latitude,
                    "longitude": item.position.longitude,
                    "title": item.title ?? "",
                    "snippet": item.snippet ?? ""
                ])
            }

            self.notifyListeners("onClusterInfoWindowClick", data: [
                "mapId": self.findMapIdByMapView(mapView),
                "latitude": cluster.position.latitude,
                "longitude": cluster.position.longitude,
                "size": cluster.count,
                "items": items
            ])
        } else {
            self.notifyListeners("onInfoWindowClick", data: [
                "mapId": self.findMapIdByMapView(mapView),
                "markerId": String(marker.hash.hashValue),
                "latitude": marker.position.latitude,
                "longitude": marker.position.longitude,
                "title": marker.title ?? "",
                "snippet": marker.snippet ?? ""
            ])
        }
    }

    // onMyLocationButtonClick
    public func didTapMyLocationButtonForMapView(for mapView: GMSMapView) -> Bool {
        self.notifyListeners("onMyLocationButtonClick", data: [
            "mapId": self.findMapIdByMapView(mapView)
        ])
        return false
    }

    // onMyLocationClick
    public func mapView(_ mapView: GMSMapView, didTapMyLocation location: CLLocationCoordinate2D) {
        self.notifyListeners("onMyLocationButtonClick", data: [
            "mapId": self.findMapIdByMapView(mapView),
            "latitude": location.latitude,
            "longitude": location.longitude
        ])
    }

    private func _updateVisibleMarkers(mapView: GMSMapView, map: Map) {
        if (map.mapViewController.clusteringEnabled) {
            return
        }

        let visibleRegion = mapView.projection.visibleRegion()

        let bounds = GMSCoordinateBounds(
            coordinate: visibleRegion.farLeft,
            coordinate: visibleRegion.farRight
        ).includingCoordinate(visibleRegion.nearLeft)
         .includingCoordinate(visibleRegion.nearRight)

        if let center = bounds.center() {
            let expandedBounds = _expandBounds(bounds: bounds, center: center, factor: 2.0)

            for (_, marker) in map.markers {
                marker.map = expandedBounds.contains(marker.position) ? mapView : nil
            }
        }
    }

    private func _expandBounds(bounds: GMSCoordinateBounds, center: CLLocationCoordinate2D, factor: Double) -> GMSCoordinateBounds {
        let northEast = bounds.northEast
        let southWest = bounds.southWest

        let newNorthEast = CLLocationCoordinate2D(
            latitude: center.latitude + (northEast.latitude - center.latitude) * factor,
            longitude: center.longitude + (northEast.longitude - center.longitude) * factor
        )

        let newSouthWest = CLLocationCoordinate2D(
            latitude: center.latitude + (southWest.latitude - center.latitude) * factor,
            longitude: center.longitude + (southWest.longitude - center.longitude) * factor
        )

        if (abs(newNorthEast.latitude) >= 90) {
            return bounds
        } else {
            return GMSCoordinateBounds(coordinate: newNorthEast, coordinate: newSouthWest)
        }
    }
}

// snippet from https://www.hackingwithswift.com/example-code/uicolor/how-to-convert-a-hex-color-to-a-uicolor
extension UIColor {
    public convenience init?(hex: String) {
        let r, g, b, a: CGFloat

        if hex.hasPrefix("#") {
            let start = hex.index(hex.startIndex, offsetBy: 1)
            let hexColor = String(hex[start...])

            let scanner = Scanner(string: hexColor)
            var hexNumber: UInt64 = 0
            if hexColor.count == 8 {
                if scanner.scanHexInt64(&hexNumber) {
                    r = CGFloat((hexNumber & 0xff000000) >> 24) / 255
                    g = CGFloat((hexNumber & 0x00ff0000) >> 16) / 255
                    b = CGFloat((hexNumber & 0x0000ff00) >> 8) / 255
                    a = CGFloat(hexNumber & 0x000000ff) / 255

                    self.init(red: r, green: g, blue: b, alpha: a)
                    return
                }
            } else {
                if scanner.scanHexInt64(&hexNumber) {
                    r = CGFloat((hexNumber & 0xff0000) >> 16) / 255
                    g = CGFloat((hexNumber & 0x00ff00) >> 8) / 255
                    b = CGFloat((hexNumber & 0x0000ff) >> 0) / 255

                    self.init(red: r, green: g, blue: b, alpha: 1)
                    return
                }
            }
        }

        return nil
    }
}

extension GMSCoordinateBounds {
    func center() -> CLLocationCoordinate2D? {
        let northEast = self.northEast
        let southWest = self.southWest
        return CLLocationCoordinate2D(
            latitude: (northEast.latitude + southWest.latitude) / 2,
            longitude: (northEast.longitude + southWest.longitude) / 2
        )
    }
}

// Helper function to convert gesture state to string for debugging
private func gestureStateToString(_ state: UIGestureRecognizer.State) -> String {
    switch state {
    case .possible: return "possible"
    case .began: return "began"
    case .changed: return "changed"
    case .ended: return "ended"
    case .cancelled: return "cancelled"
    case .failed: return "failed"
    @unknown default: return "unknown"
    }
}

// MARK: - UIGestureRecognizerDelegate
extension CapacitorGoogleMapsPlugin: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow long press to work simultaneously with touch interceptor
        if gestureRecognizer is UILongPressGestureRecognizer || otherGestureRecognizer is UILongPressGestureRecognizer {
            return true
        }
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Long press should not require failure of touch interceptor
        return false
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Touch interceptor should not require long press to fail
        return false
    }
}

// MARK: - TouchInterceptorGestureRecognizer
class TouchInterceptorGestureRecognizer: UIGestureRecognizer {
    private let touchHandler: (UIGestureRecognizer) -> Bool
    private let longPressHandler: ((CGPoint) -> Void)?
    private let scrollBlockHandler: ((Bool) -> Void)?
    private var longPressTimer: Timer?
    private var longPressLocation: CGPoint = .zero
    private let longPressDuration: TimeInterval = 0.4
    private let longPressDistanceThreshold: CGFloat = 30.0

    // True after long press timer fires and before touch ends
    var longPressActivated: Bool = false

    var isWaitingForLongPress: Bool {
        return longPressTimer != nil
    }

    init(touchHandler: @escaping (UIGestureRecognizer) -> Bool, longPressHandler: ((CGPoint) -> Void)? = nil, scrollBlockHandler: ((Bool) -> Void)? = nil) {
        self.touchHandler = touchHandler
        self.longPressHandler = longPressHandler
        self.scrollBlockHandler = scrollBlockHandler
        super.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view = view else { return }

        let touchCount = event.allTouches?.count ?? touches.count
        if touchCount > 1 || touches.count > 1 {
            return
        }

        longPressLocation = touch.location(in: view)
        longPressActivated = false

        // Do NOT block scrolling here — let the map scroll normally.
        // Scrolling will only be blocked if/when the long press timer fires.

        let timer = Timer(timeInterval: longPressDuration, repeats: false) { [weak self] timer in
            guard let self = self else { return }

            let location = self.longPressLocation
            self.longPressActivated = true

            // Long press detected — NOW block scrolling
            self.scrollBlockHandler?(true)

            self.longPressHandler?(location)

            timer.invalidate()
            self.longPressTimer = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer

        _ = touchHandler(self)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view = view else { return }

        let touchCount = event.allTouches?.count ?? touches.count
        if touchCount > 1 || touches.count > 1 {
            longPressTimer?.invalidate()
            longPressTimer = nil
            if longPressActivated {
                longPressActivated = false
                scrollBlockHandler?(false)
            }
            state = .changed
            _ = touchHandler(self)
            return
        }

        let currentLocation = touch.location(in: view)
        let distance = sqrt(pow(currentLocation.x - longPressLocation.x, 2) + pow(currentLocation.y - longPressLocation.y, 2))

        // If still waiting for long press and moved too far, cancel it
        if longPressTimer != nil && distance > longPressDistanceThreshold {
            longPressTimer?.invalidate()
            longPressTimer = nil
            // No need to unblock scroll — we never blocked it
        }

        state = .changed
        _ = touchHandler(self)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil

        state = .ended
        _ = touchHandler(self)

        // Always unblock scrolling on touch end
        if longPressActivated {
            longPressActivated = false
            scrollBlockHandler?(false)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil

        state = .cancelled
        _ = touchHandler(self)

        // Always unblock scrolling on cancel
        if longPressActivated {
            longPressActivated = false
            scrollBlockHandler?(false)
        }
    }
}
