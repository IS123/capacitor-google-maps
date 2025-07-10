import Foundation
import Capacitor
import GoogleMaps

public struct GoogleMapConfig: Codable {
    let width: Double
    let height: Double
    let x: Double
    let y: Double
    let center: LatLng
    let zoom: Double
    let styles: String?
    var mapId: String?
    var mapType: GMSMapViewType = .normal

    init(fromJSObject: JSObject) throws {
        guard let width = fromJSObject["width"] as? Double else {
            throw GoogleMapErrors.invalidArguments("GoogleMapConfig object is missing the required 'width' property")
        }

        guard let height = fromJSObject["height"] as? Double else {
            throw GoogleMapErrors.invalidArguments("GoogleMapConfig object is missing the required 'height' property")
        }

        guard let x = fromJSObject["x"] as? Double else {
            throw GoogleMapErrors.invalidArguments("GoogleMapConfig object is missing the required 'x' property")
        }

        guard let y = fromJSObject["y"] as? Double else {
            throw GoogleMapErrors.invalidArguments("GoogleMapConfig object is missing the required 'y' property")
        }

        guard let zoom = fromJSObject["zoom"] as? Double else {
            throw GoogleMapErrors.invalidArguments("GoogleMapConfig object is missing the required 'zoom' property")
        }

        guard let latLngObj = fromJSObject["center"] as? JSObject else {
            throw GoogleMapErrors.invalidArguments("GoogleMapConfig object is missing the required 'center' property")
        }

        guard let lat = latLngObj["lat"] as? Double, let lng = latLngObj["lng"] as? Double else {
            throw GoogleMapErrors.invalidArguments("LatLng object is missing the required 'lat' and/or 'lng' property")
        }

        self.width = round(width)
        self.height = round(height)
        self.x = x
        self.y = y
        self.zoom = zoom
        self.center = LatLng(lat: lat, lng: lng)
        if let stylesArray = fromJSObject["styles"] as? JSArray, let jsonData = try? JSONSerialization.data(withJSONObject: stylesArray, options: []) {
            self.styles = String(data: jsonData, encoding: .utf8)
        } else {
            self.styles = nil
        }

        self.mapId = fromJSObject["iOSMapId"] as? String
        
        if let mapTypeId = fromJSObject["mapTypeId"] as? String {
            self.mapType = mapTypeFromString(mapTypeId)
        }
    }

    // Manually encode properties, especially `mapType`
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(center, forKey: .center)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(styles, forKey: .styles)
        try container.encode(mapId, forKey: .mapId)

        // Convert `mapType` to String for encoding
        let mapTypeString = mapTypeToString(mapType)
        try container.encode(mapTypeString, forKey: .mapType)
    }

    // Manually decode properties, especially `mapType`
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try container.decode(Double.self, forKey: .width)
        self.height = try container.decode(Double.self, forKey: .height)
        self.x = try container.decode(Double.self, forKey: .x)
        self.y = try container.decode(Double.self, forKey: .y)
        self.center = try container.decode(LatLng.self, forKey: .center)
        self.zoom = try container.decode(Double.self, forKey: .zoom)
        self.styles = try container.decodeIfPresent(String.self, forKey: .styles)
        self.mapId = try container.decodeIfPresent(String.self, forKey: .mapId)

        // Decode `mapType` from String
        let mapTypeString = try container.decode(String.self, forKey: .mapType)
        self.mapType = mapTypeFromString(mapTypeString)
    }

    // Convert String to GMSMapViewType
    private func mapTypeFromString(_ mapType: String) -> GMSMapViewType {
        switch mapType.lowercased() {
        case "normal":
            return .normal
        case "hybrid":
            return .hybrid
        case "satellite":
            return .satellite
        case "terrain":
            return .terrain
        case "none":
            return .none
        default:
            print("Unknown mapType '\(mapType)', defaulting to normal.")
            return .normal
        }
    }

    // Convert GMSMapViewType to String
    private func mapTypeToString(_ mapType: GMSMapViewType) -> String {
        switch mapType {
        case .normal:
            return "normal"
        case .hybrid:
            return "hybrid"
        case .satellite:
            return "satellite"
        case .terrain:
            return "terrain"
        case .none:
            return "none"
        @unknown default:
            return "normal"
        }
    }

    // Define coding keys for custom encoding/decoding
    enum CodingKeys: String, CodingKey {
        case width
        case height
        case x
        case y
        case center
        case zoom
        case styles
        case mapId
        case mapType
    }
}
