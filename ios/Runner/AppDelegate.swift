import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // 注册 Pigeon 原生能力（相机录像/备份/媒体处理等）
    // 注意：本工程使用 UIScene 生命周期，didFinishLaunching 时 window 尚未创建，
    // 严禁在此处访问 window?.rootViewController（会因强制转换崩溃）。
    PigeonPlatform.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
