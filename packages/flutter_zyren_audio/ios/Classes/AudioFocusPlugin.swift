import AVFAudio
import Flutter

public final class AudioFocusPlugin: NSObject, FlutterPlugin {
  // AVAudioSession belongs to the process, including hosts with several engines.
  private static weak var owner: AudioFocusPlugin?
  private let channel: FlutterMethodChannel
  private var observers: [NSObjectProtocol] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "zyren/audio-session", binaryMessenger: registrar.messenger())
    let instance = AudioFocusPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.publish(instance)
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    observers.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let self = self, Self.owner === self,
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let kind = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      let options = AVAudioSession.InterruptionOptions(
        rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
      let state = kind == .began ? "transientLoss" : (options.contains(.shouldResume) ? "gain" : "loss")
      self.channel.invokeMethod("focus", arguments: state)
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let self = self, Self.owner === self,
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
      self.channel.invokeMethod("focus", arguments: "routeLost")
    })
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      let session = AVAudioSession.sharedInstance()
      switch call.method {
      case "acquire":
        guard Self.owner == nil || Self.owner === self else { result(false); return }
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        Self.owner = self
        result(true)
      case "release":
        if Self.owner === self {
          try session.setActive(false, options: [.notifyOthersOnDeactivation])
          Self.owner = nil
        }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "audioSession", message: error.localizedDescription, details: nil))
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    close()
  }

  private func close() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    channel.setMethodCallHandler(nil)
    if Self.owner === self {
      try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
      Self.owner = nil
    }
  }

  deinit { close() }
}
