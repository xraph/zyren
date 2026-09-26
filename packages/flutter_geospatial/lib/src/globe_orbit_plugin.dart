import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'geodesy.dart';
import 'geospatial_plugin.dart';

/// Z-up, centre-facing orbit controls. Input adapters call [rotateBy] and [zoom].
class GlobeOrbitPlugin extends ScenePlugin {
  @override
  String get id => 'geospatial.orbit';
  @override
  Set<String> get dependencies => const {GeospatialPlugin.pluginId};

  final double _initialLongitude, _initialLatitude, _initialDistance;
  double _longitude, _latitude, _distance;
  double _minDistance = 0, _maxDistance = double.infinity;
  bool _rotating;
  PluginContext? _context;
  Registration? _demand;
  final _gestures = <Registration>[];
  Registration? _inputSubscription;
  double _pinchDistance = 0;
  bool get rotating => _rotating;
  set rotating(bool value) {
    if (_rotating == value) return;
    _rotating = value;
    _syncDemand();
    _context?.invalidate();
  }

  void _syncDemand() {
    if (_rotating && _context != null) {
      _demand ??= _context!.acquireFrameDemand();
    } else {
      _demand?.dispose();
      _demand = null;
    }
  }

  final double rotationSpeed;
  GeospatialReference? _reference;
  Geodetic? _focusLocation;
  (Vec3, Vec3, Vec3)? _previousCamera;

  GlobeOrbitPlugin({
    double longitudeDegrees = -25,
    double latitudeDegrees = 22,
    double distance = 22000000,
    bool rotating = true,
    this.rotationSpeed = 4,
  }) : _rotating = rotating,
       _initialLongitude = longitudeDegrees,
       _longitude = longitudeDegrees,
       _initialLatitude = latitudeDegrees,
       _latitude = latitudeDegrees,
       _initialDistance = distance,
       _distance = distance {
    if ([
          longitudeDegrees,
          latitudeDegrees,
          distance,
          rotationSpeed,
        ].any((v) => !v.isFinite) ||
        latitudeDegrees.abs() > 85 ||
        distance <= 0) {
      throw ArgumentError(
        'Orbit values must be finite, distance positive and latitude within 85 degrees.',
      );
    }
  }

  double get longitudeDegrees => _longitude;
  double get latitudeDegrees => _latitude;
  double get distance => _distance;

  void rotateBy(double longitudeDegrees, double latitudeDegrees) {
    if (!longitudeDegrees.isFinite || !latitudeDegrees.isFinite) {
      throw ArgumentError('Orbit angles must be finite.');
    }
    _focusLocation = null;
    _longitude = (_longitude + longitudeDegrees + 180) % 360 - 180;
    _latitude = (_latitude + latitudeDegrees).clamp(-85, 85);
    _context?.invalidate();
  }

  void setDistance(double value) {
    if (!value.isFinite || value <= 0) {
      throw ArgumentError.value(value, 'distance');
    }
    _distance = value.clamp(_minDistance, _maxDistance);
    _context?.invalidate();
  }

  /// Positive factors above one move the camera away from the globe.
  void zoom(double factor) {
    if (!factor.isFinite || factor <= 0) {
      throw ArgumentError.value(factor, 'factor');
    }
    setDistance(_distance * factor);
  }

  void focus(Geodetic location) {
    _context?.invalidate();
    _focusLocation = location;
    rotating = false;
    final reference = _reference;
    if (reference == null) return;
    final position = reference.toEcef(location);
    _longitude = math.atan2(position.y, position.x) * 180 / math.pi;
    _latitude =
        (math.atan2(
                  position.z,
                  math.sqrt(position.x * position.x + position.y * position.y),
                ) *
                180 /
                math.pi)
            .clamp(-85, 85);
  }

  void reset() {
    _focusLocation = null;
    _longitude = _initialLongitude;
    _latitude = _initialLatitude;
    setDistance(_initialDistance);
  }

  @override
  void attach(PluginContext context) {
    _context = context;
    _syncDemand();
    _reference = context.service(geospatialReference);
    final ellipsoid = _reference!.ellipsoid;
    final radius = math.max(ellipsoid.x, math.max(ellipsoid.y, ellipsoid.z));
    _minDistance = radius * 1.05;
    _maxDistance = radius * 20;
    setDistance(_distance);
    final location = _focusLocation;
    if (location != null) focus(location);
    final camera = context.camera;
    _previousCamera = (camera.position, camera.target, camera.up);
    _apply(camera);
    final input = context.input;
    if (input != null) {
      _gestures.add(
        context.scope.keep(input.registerGesture(SceneGesture.scale)),
      );
      _gestures.add(
        context.scope.keep(input.registerGesture(SceneGesture.scroll)),
      );
      _inputSubscription = context.scope.listen(input.events, (event) {
        switch (event.phase) {
          case ScenePointerPhase.scaleStart:
            _pinchDistance = _distance;
            rotating = false;
          case ScenePointerPhase.scaleUpdate:
            rotateBy(-event.delta.x * .25, event.delta.y * .25);
            if (event.scale > 0) setDistance(_pinchDistance / event.scale);
          case ScenePointerPhase.scroll:
            zoom(math.exp(event.delta.y.clamp(-1000, 1000) * .001));
          default:
            break;
        }
      });
    }
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    if (rotating) {
      rotateBy(rotationSpeed * frame.delta.inMicroseconds / 1000000, 0);
    }
    _apply(context.camera);
  }

  void _apply(Camera camera) {
    final lon = _longitude * math.pi / 180, lat = _latitude * math.pi / 180;
    camera.up = const Vec3(0, 0, 1);
    camera.target = Vec3.zero;
    camera.position = Vec3(
      _distance * math.cos(lat) * math.cos(lon),
      _distance * math.cos(lat) * math.sin(lon),
      _distance * math.sin(lat),
    );
  }

  @override
  void detach(PluginContext context) {
    _inputSubscription?.dispose();
    _inputSubscription = null;
    for (final gesture in _gestures.reversed) {
      gesture.dispose();
    }
    _gestures.clear();
    _demand?.dispose();
    _demand = null;
    _context = null;
    final previous = _previousCamera;
    if (previous != null) {
      context.camera.position = previous.$1;
      context.camera.target = previous.$2;
      context.camera.up = previous.$3;
    }
    _previousCamera = null;
    _reference = null;
  }
}
