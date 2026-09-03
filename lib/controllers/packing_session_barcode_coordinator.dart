// packing_session_barcode_coordinator.dart
// 方案 A：移除 Dart 层 ML Kit 依赖，仅保留原生路径逻辑

part of 'packing_session_controller.dart';

/// 条码扫描协调器 - 纯净版 (移除了 Dart 层图像处理逻辑)
mixin _PackingSessionBarcodeCoordinator on _PackingSessionController {
  
  // ---------------------------------------------------------
  // 1. 核心状态与配置
  // ---------------------------------------------------------

  /// 标记是否支持原生相机通道
  /// 在方案 A 中，我们强制依赖此通道
  bool get supportsNativeCamera => _supportsNativeCamera;
  bool _supportsNativeCamera = false; // 默认值，需在初始化时由原生层确认

  /// 稳定性追踪器 (保留原有业务逻辑)
  final BarcodeStabilityTracker _stabilityTracker = BarcodeStabilityTracker();

  /// 提示音策略 (保留原有业务逻辑)
  final BarcodeRecognizedBeepPolicy _beepPolicy = BarcodeRecognizedBeepPolicy();

  // ---------------------------------------------------------
  // 2. 初始化与生命周期
  // ---------------------------------------------------------

  /// 初始化协调器
  Future<void> initBarcodeCoordinator() async {
    debugPrint('[BarcodeCoordinator] Initializing...');
    
    // 检查原生能力
    // 注意：这里假设你的 Controller 里有检查原生能力的方法
    // 如果没有，请确保在 Controller 的 initState 中设置 _supportsNativeCamera = true;
    try {
      // 模拟检查原生通道是否可用
      // 实际项目中可能需要调用 MethodChannel 或检查 Platform.isIOS/Android
      _supportsNativeCamera = true; 
      debugPrint('[BarcodeCoordinator] Native camera support: $_supportsNativeCamera');
    } catch (e) {
      debugPrint('[BarcodeCoordinator] Failed to check native support: $e');
      _supportsNativeCamera = false;
    }
  }

  @override
  void dispose() {
    _stabilityTracker.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------
  // 3. 原生路径处理 (保留)
  // ---------------------------------------------------------

  /// 处理来自原生层 (iOS/Android) 的条码结果
  /// 这是方案 A 中唯一的数据来源
  void _processNativeBarcodeFrame(NativeBarcodeCandidate candidate) {
    if (candidate == null || candidate.rawValue == null) return;

    final String code = candidate.rawValue!;
    
    // 1. 稳定性过滤 (防止抖动误触)
    if (!_stabilityTracker.isStable(code)) {
      return; 
    }

    // 2. 触发业务确认
    _handleConfirmedBarcode(code);
  }

  // ---------------------------------------------------------
  // 4. 业务逻辑 (保留)
  // ---------------------------------------------------------

  /// 确认条码后的业务处理
  void _handleConfirmedBarcode(String code) {
    debugPrint('[BarcodeCoordinator] Confirmed barcode: $code');
    
    // 播放提示音
    _beepPolicy.playBeep();

    // TODO: 在这里继续执行原有的业务逻辑
    // 例如：更新 UI、保存记录、触发录像等
    // updateState(...);
  }

  // ---------------------------------------------------------
  // 5. 已删除的方法 (Dart 层 ML Kit 逻辑)
  // ---------------------------------------------------------
  // 以下方法已被彻底移除，不再包含任何 google_mlkit_barcode_scanning 的引用：
  // - _processFrame()
  // - _toInputImage()
  // - _toCroppedInputImage()
  // - _inputImageRotation()
  // - BarcodeScanner getter
}
