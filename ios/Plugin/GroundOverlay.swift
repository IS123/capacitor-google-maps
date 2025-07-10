import Foundation
import GoogleMaps
import Capacitor

public struct GroundOverlay {
    let bounds: GMSCoordinateBounds
    let imagePath: String
    let maxDimension: Double = 1000
    let latitude: Double
    let longitude: Double
    let width: Double
    let height: Double
    
    init(_ call: CAPPluginCall) throws {
        guard let latitude = call.getDouble("latitude"),
              let longitude = call.getDouble("longitude"),
              let width = call.getDouble("width"),
              let height = call.getDouble("height"),
              let imagePath = call.getString("imagePath")
        else {
            throw NSError(domain: "GroundOverlayError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required parameters"])
        }
        
        self.latitude = latitude;
        self.longitude = longitude;
        self.width = width;
        self.height = height;
        self.imagePath = imagePath;
        
        self.bounds = GroundOverlay.calculateBounds(latitude: self.latitude, longitude: self.longitude, width: self.width, height: self.height)
    }
    
    public func createGroundOverlay() -> GMSGroundOverlay? {
        guard let imageUrl = URL(string: self.imagePath),
              let imageData = try? Data(contentsOf: imageUrl),
              var icon = UIImage(data: imageData) else {
            print("CapacitorGoogleMaps Warning: could not load image: \(self.imagePath)")
            return nil
        }
        
        print("old size \(icon.size.width)x\(icon.size.height)")
        
        if icon.size.height > self.maxDimension || icon.size.width > self.maxDimension {
            icon = self.resizeImage(icon)
        }
        
        print("new size \(icon.size.width)x\(icon.size.height)")

        let newOverlay = GMSGroundOverlay(bounds: self.bounds, icon: icon)
        
        return newOverlay
    }
    
    private static func calculateBounds() {
        
    }
    
    private func resizeImage(_ image: UIImage) -> UIImage {
        let originalSize = image.size
        let width = originalSize.width
        let height = originalSize.height

        if width <= self.maxDimension && height <= self.maxDimension {
            return image
        }

        let scale = self.maxDimension / max(width, height)
        let newSize = CGSize(width: width * scale, height: height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()

        return resizedImage
    }
    
    private static func calculateBounds(latitude: Double, longitude: Double, width: Double, height: Double) -> GMSCoordinateBounds {
        let degreesPerPixel: CLLocationDegrees = 0.000005

        let halfWidthInDegrees = (width * degreesPerPixel) / 2
        let halfHeightInDegrees = (height * degreesPerPixel) / 2

        let southwest = CLLocationCoordinate2D(latitude: latitude - halfHeightInDegrees, longitude: longitude - halfWidthInDegrees)
        let northeast = CLLocationCoordinate2D(latitude: latitude + halfHeightInDegrees, longitude: longitude + halfWidthInDegrees)

        return GMSCoordinateBounds(coordinate: southwest, coordinate: northeast)
    }
}
