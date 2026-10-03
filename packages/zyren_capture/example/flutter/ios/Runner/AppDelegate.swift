import AVFAudio
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var audioChannel: FlutterMethodChannel?
  private var audioObservers: [NSObjectProtocol] = []

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "zyren/smaller-lab/audio-session",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    audioChannel = channel
    channel.setMethodCallHandler { call, result in
      do {
        let session = AVAudioSession.sharedInstance()
        switch call.method {
        case "acquire":
          try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
          try session.setActive(true)
          result(true)
        case "release":
          try session.setActive(false, options: [.notifyOthersOnDeactivation])
          result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "audioSession", message: error.localizedDescription, details: nil))
      }
    }
    audioObservers.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let kind = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      let options = AVAudioSession.InterruptionOptions(
        rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
      let state = kind == .began ? "transientLoss" : (options.contains(.shouldResume) ? "gain" : "loss")
      self?.audioChannel?.invokeMethod("focus", arguments: state)
    })
    audioObservers.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
      self?.audioChannel?.invokeMethod("focus", arguments: "routeLost")
    })
  }
  deinit {
    for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
    audioChannel?.setMethodCallHandler(nil)
  }
}
