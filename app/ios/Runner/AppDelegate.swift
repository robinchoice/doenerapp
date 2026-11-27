import CryptoKit
import Flutter
import GoogleMaps
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Set via GOOGLE_MAPS_IOS_KEY in ios/Flutter/Secrets.xcconfig (written by CI).
    if let key = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String, !key.isEmpty {
      GMSServices.provideAPIKey(key)
    }
    // Lets flutter_local_notifications show the check-in reminder and report taps.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // AES-GCM through CryptoKit, so the app ships no encryption of its own: opens a contact directory box, nil when the key does not fit
    let crypto = FlutterMethodChannel(name: "com.robinchoice.doener/crypto", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    crypto.setMethodCallHandler { call, result in
      guard call.method == "openAesGcm",
            let arguments = call.arguments as? [String: Any],
            let key = (arguments["key"] as? FlutterStandardTypedData)?.data,
            let nonce = (arguments["nonce"] as? FlutterStandardTypedData)?.data,
            let sealed = (arguments["sealed"] as? FlutterStandardTypedData)?.data,
            sealed.count >= 16 else { result(FlutterMethodNotImplemented); return }
      guard let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16)),
            let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { result(nil); return }
      result(FlutterStandardTypedData(bytes: plain))
    }
  }
}
