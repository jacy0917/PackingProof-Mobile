import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    
    // 1. 注册 Pigeon 原生相机接口
    let cameraApi = NativeCameraApiImpl()
    NativeCameraApiSetup.setUp(binaryMessenger: controller.binaryMessenger, api: cameraApi)
    
    // 2. 注册 MethodChannel
    let barcodeChannel = FlutterMethodChannel(name: "app.packingproof.mobile/barcode",
                                              binaryMessenger: controller.binaryMessenger)
    
    barcodeChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      if call.method == "useVisionScanner" {
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    })
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
