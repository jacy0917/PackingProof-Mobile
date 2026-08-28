import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    PigeonPlatform.onHostForeground()
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    PigeonPlatform.onHostBackground()
    super.sceneDidEnterBackground(scene)
  }

  override func sceneDidDisconnect(_ scene: UIScene) {
    PigeonPlatform.shutdownForTermination()
    super.sceneDidDisconnect(scene)
  }
}
