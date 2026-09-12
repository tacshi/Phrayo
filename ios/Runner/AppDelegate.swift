import AppIntents
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = PhrayoHost.shared
    PhrayoShortcuts.updateAppShortcutParameters()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PhrayoNative")!
    PhrayoNativeSetup.setUp(binaryMessenger: registrar.messenger(), api: PhrayoHost.shared)
    PhrayoHost.shared.events = PhrayoEvents(binaryMessenger: registrar.messenger())
  }
}
