import '../../services/continuous_camera_service.dart';
import '../../models/recording_orientation.dart';
import '../contracts/camera_platform.dart';
// ⭐ 只导入 DTO 类，不导入 CameraHostApi
import '../generated/platform_api.g.dart' show
    CameraInitializeRequest,
    CameraInitializationDto,
    CameraRecordingStartDto,
    CameraRecordingSplitDto,
    CameraRecordingStopDto,
    CameraWatermarkDisposition,
    CameraLensDto,
    BarcodeCandidateDto,
    CameraEventApi,
    CameraSessionStartedDto,
    CameraSegmentStartedDto,
    CameraSegmentCompletedDto,
    CameraSegmentFailedDto,
    CameraSessionFailedDto;

// ⭐ 完整的 CameraHostApi stub（包含所有方法）
class CameraHostApi {
  Future<CameraInitializationDto> initialize(CameraInitializeRequest request) {
    throw UnsupportedError('Stub method');
  }
  Future<bool> ensurePermissions(bool recordAudio) {
    throw UnsupportedError('Stub method');
  }
  Future<CameraRecordingStartDto> startWork(
    String path,
    bool recordAudio,
    String trackingNumber,
  ) {
    throw UnsupportedError('Stub method');
  }
  Future<CameraRecordingSplitDto> split(
    String nextPath,
    String trackingNumber,
  ) {
    throw UnsupportedError('Stub method');
  }
  Future<CameraRecordingStopDto> stopWork() {
    throw UnsupportedError('Stub method');
  }
  Future<Map<String?, Object?>?> getDiagnostics() {
    throw UnsupportedError('Stub method');
  }
  Future<void> setPairingScanEnabled(bool enabled) {
    throw UnsupportedError('Stub method');
  }
  Future<void> setWorkScanEnabled(bool enabled) {
    throw UnsupportedError('Stub method');
  }
  Future<void> setPreviewActive(bool active) {
    throw UnsupportedError('Stub method');
  }
  Future<bool> setTorchEnabled(bool enabled) {
    throw UnsupportedError('Stub method');
  }
  Future<CameraInitializationDto> switchCamera() {
    throw UnsupportedError('Stub method');
  }
  Future<List<CameraLensDto>> listCameras() {
    throw UnsupportedError('Stub method');
  }
  Future<CameraInitializationDto> switchToCamera(String cameraId) {
    throw UnsupportedError('Stub method');
  }
  Future<Map<String?, Object?>?> probeSequence(
    String sequence,
    int budgetMs,
  ) {
    throw UnsupportedError('Stub method');
  }
  void setCapabilityMode(String mode) {
    throw UnsupportedError('Stub method');
  }
  Future<void> dispose() {
    throw UnsupportedError('Stub method');
  }
}

// ... 其余代码保持不变（PigeonCameraPlatform 类等）
