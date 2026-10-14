import SwiftUI
import MapKit

/// Wraps an `MKMapView` to show user pins, waypoint circles, and to expose camera + tap callbacks.
///
/// Camera policy (#782): the map never resets the region on its own. It only moves
/// the camera for two explicit triggers, each consumed exactly once:
/// - `fitAllToken` change → `showAnnotations` to fit every pin (initial load + explicit fit button).
/// - `animateToCoord` value change → zoom to that coordinate (user/waypoint selection).
/// Manual pan/zoom in between is never overridden.
struct MapContainer: UIViewRepresentable {
    let users: [User]
    let latestLocations: [Int64: LocationValue]
    let waypoints: [Waypoint]
    let selectedUserId: Int64?
    let selectedWaypoint: (coord: Coord, range: Double)?
    let historicalPosition: Coord?
    let onUserTap: (Int64) -> Void
    let onMapTap: () -> Void
    let onCenterChanged: (Coord) -> Void
    let animateToCoord: Coord?
    /// Increment to request a fit-all-pins. The coordinator consumes each value once.
    let fitAllToken: Int

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.register(UserAnnotationView.self, forAnnotationViewWithReuseIdentifier: "user")
        map.register(WaypointAnnotationView.self, forAnnotationViewWithReuseIdentifier: "waypoint")
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Sync annotations
        let allUserAnnotations = users.compactMap { u -> UserAnnotation? in
            guard let loc = historicalPosition.flatMap({ selectedUserId == u.id ? $0 : latestLocations[u.id]?.coord }) ?? latestLocations[u.id]?.coord else { return nil }
            return UserAnnotation(user: u, coord: loc)
        }
        let waypointAnnotations = waypoints.map { WaypointAnnotation(waypoint: $0) }

        let existing = map.annotations.filter { !($0 is MKUserLocation) }
        map.removeAnnotations(existing)
        map.addAnnotations(allUserAnnotations)
        map.addAnnotations(waypointAnnotations)

        // Circle overlays for waypoint ranges + selected waypoint preview.
        map.removeOverlays(map.overlays)
        for wp in waypoints {
            let circle = MKCircle(center: wp.coord.clLocationCoordinate, radius: wp.range)
            circle.title = "wp"
            map.addOverlay(circle)
        }
        if let sw = selectedWaypoint, sw.range > 0 {
            let circle = MKCircle(center: sw.coord.clLocationCoordinate, radius: sw.range)
            circle.title = "selected"
            map.addOverlay(circle)
        }

        if let target = animateToCoord {
            // Only move for a NEW target: after moving, record it so subsequent
            // updateUIView passes (triggered by every location tick) don't snap
            // the camera back over the user's manual zoom (#782).
            if context.coordinator.lastAnimatedCoord != target {
                context.coordinator.lastAnimatedCoord = target
                let region = MKCoordinateRegion(
                    center: target.clLocationCoordinate,
                    latitudinalMeters: 2000, longitudinalMeters: 2000
                )
                map.setRegion(region, animated: true)
            }
        }

        if context.coordinator.lastFitAllToken != fitAllToken {
            context.coordinator.lastFitAllToken = fitAllToken
            fitAllPins(on: map)
        }
    }

    /// Fits every visible pin (users + waypoints + own location) with padding.
    /// Called on first load and on explicit fit-button taps only — never on ticks.
    private func fitAllPins(on map: MKMapView) {
        var annotations: [any MKAnnotation] = map.annotations.filter { !($0 is MKUserLocation) }
        if let own = map.userLocation.location, CLLocationCoordinate2DIsValid(own.coordinate) {
            let pin = MKPointAnnotation()
            pin.coordinate = own.coordinate
            annotations.append(pin)
        }
        guard !annotations.isEmpty else { return }
        map.showAnnotations(annotations, animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        let parent: MapContainer
        /// Last coordinate we animated to — guards against re-applying the same
        /// target on every updateUIView (location ticks) and snapping back manual zoom.
        var lastAnimatedCoord: Coord?
        /// Last fit-all token consumed. Starts at -1 so the initial token (0)
        /// performs the first-load fit-all (#782).
        var lastFitAllToken: Int = -1
        init(parent: MapContainer) { self.parent = parent }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let u = annotation as? UserAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "user", for: u) as! UserAnnotationView
                v.configure(with: u.user)
                return v
            } else if let w = annotation as? WaypointAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "waypoint", for: w) as! WaypointAnnotationView
                v.configure(with: w.waypoint)
                return v
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let u = view.annotation as? UserAnnotation {
                mapView.deselectAnnotation(view.annotation, animated: false)
                parent.onUserTap(u.user.id)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circle)
                if circle.title == "selected" {
                    r.fillColor = UIColor.systemBlue.withAlphaComponent(0.18)
                    r.strokeColor = UIColor.systemBlue
                } else {
                    r.fillColor = UIColor.systemTeal.withAlphaComponent(0.18)
                    r.strokeColor = UIColor.systemTeal
                }
                r.lineWidth = 2
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let c = mapView.centerCoordinate
            parent.onCenterChanged(Coord(lat: c.latitude, lon: c.longitude))
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let map = recognizer.view as? MKMapView else { return }
            // If user tapped on an annotation, MapKit handles it via didSelect. We only get here for empty taps.
            let point = recognizer.location(in: map)
            for ann in map.annotations {
                if let view = map.view(for: ann), view.frame.contains(point) { return }
            }
            parent.onMapTap()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - Annotations

final class UserAnnotation: NSObject, MKAnnotation {
    let user: User
    let coordinate: CLLocationCoordinate2D
    init(user: User, coord: Coord) {
        self.user = user
        self.coordinate = coord.clLocationCoordinate
    }
}

final class WaypointAnnotation: NSObject, MKAnnotation {
    let waypoint: Waypoint
    let coordinate: CLLocationCoordinate2D
    var title: String? { waypoint.name }
    init(waypoint: Waypoint) {
        self.waypoint = waypoint
        self.coordinate = waypoint.coord.clLocationCoordinate
    }
}

final class UserAnnotationView: MKAnnotationView {
    private let label = UILabel()
    private let imageBackground = UIView()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        imageBackground.frame = bounds
        imageBackground.layer.cornerRadius = 22
        imageBackground.layer.borderWidth = 2
        imageBackground.layer.borderColor = UIColor.systemBlue.cgColor
        imageBackground.backgroundColor = .systemTeal
        imageBackground.clipsToBounds = true
        label.frame = bounds
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 18, weight: .bold)
        addSubview(imageBackground)
        imageBackground.addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with user: User) {
        label.text = String(user.name.first ?? "?")
        // (Future: load image from data:image base64.)
    }
}

final class WaypointAnnotationView: MKAnnotationView {
    private let icon = UIImageView(image: UIImage(systemName: "mappin.circle.fill"))
    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        icon.frame = bounds
        icon.tintColor = .systemTeal
        icon.contentMode = .scaleAspectFit
        addSubview(icon)
        canShowCallout = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(with wp: Waypoint) {}
}
