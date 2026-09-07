import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PackingProofApp());
}

class PackingProofApp extends StatelessWidget {
  const PackingProofApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PackingProof Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.blueAccent,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const PackingView(),
    );
  }
}

/// 打包验货主界面
class PackingView extends StatefulWidget {
  const PackingView({Key? key}) : super(key: key);

  @override
  State<PackingView> createState() => _PackingViewState();
}

class _PackingViewState extends State<PackingView> {
  static const MethodChannel _cameraChannel = MethodChannel('app.packingproof.mobile/camera');
  static const MethodChannel _audioChannel = MethodChannel('app.packingproof.mobile/audio');

  final TextEditingController _orderInputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();

  bool _isRecording = false;
  bool _isCameraReady = false;
  String _currentOrderNo = '';
  String _currentMode = 'SHIPPING'; // SHIPPING (出货) 或 RETURN (退货)
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  /// 初始化相机
  Future<void> _initializeCamera() async {
    try {
      final int? textureId = await _cameraChannel.invokeMethod('initializeCamera', {
        'resolution': '1080p',
        'enableWatermark': true,
      });
      
      if (textureId != null) {
        setState(() {
          _textureId = textureId;
          _isCameraReady = true;
        });
        _playAudioPrompt('recording_started.mp3');
      }
    } on PlatformException catch (e) {
      _showErrorSnackBar('相机初始化失败: ${e.message}');
      _playAudioPrompt('camera_not_found.mp3');
    }
  }

  /// 处理扫码/输入单号
  void _handleOrderScanned(String orderNo) async {
    if (orderNo.trim().isEmpty) return;

    if (_isRecording && _currentOrderNo == orderNo) {
      _playAudioPrompt('duplicate_order_warning.mp3');
      _showErrorSnackBar('警告：重复扫描相同订单！');
      return;
    }

    if (_isRecording) {
      await _stopRecording();
    }

    setState(() {
      _currentOrderNo = orderNo.trim();
    });

    _startRecording();
    _orderInputController.clear();
    _inputFocusNode.requestFocus();
  }

  /// 开始录像
  Future<void> _startRecording() async {
    try {
      await _cameraChannel.invokeMethod('startSegment', {
        'orderNo': _currentOrderNo,
        'mode': _currentMode,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      setState(() {
        _isRecording = true;
      });

      _playAudioPrompt('recording_started.mp3');
    } catch (e) {
      _playAudioPrompt('recording_failed.mp3');
      _showErrorSnackBar('启动录像失败: $e');
    }
  }

  /// 结束录像
  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    try {
      final String? videoPath = await _cameraChannel.invokeMethod('stopSegment');
      
      setState(() {
        _isRecording = false;
        _currentOrderNo = '';
      });

      _playAudioPrompt('recording_stopped.mp3');

      if (videoPath != null) {
        _triggerLanBackup(videoPath);
      }
    } catch (e) {
      _playAudioPrompt('segment_save_failed.mp3');
      _showErrorSnackBar('视频保存失败: $e');
    }
  }

  /// 后台局域网备份
  Future<void> _triggerLanBackup(String filePath) async {
    const MethodChannel backupChannel = MethodChannel('app.packingproof.mobile/backup');
    await backupChannel.invokeMethod('enqueueJob', {'filePath': filePath});
  }

  /// 播放提示音
  Future<void> _playAudioPrompt(String filename) async {
    try {
      await _audioChannel.invokeMethod('playAsset', {'path': 'assets/audio/tts/$filename'});
    } catch (_) {}
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  @override
  void dispose() {
    _orderInputController.dispose();
    _inputFocusNode.dispose();
    _cameraChannel.invokeMethod('dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('PackingProof 打包打包验货'),
        backgroundColor: Colors.grey[900],
        actions: [
          ChoiceChip(
            label: Text(_currentMode == 'SHIPPING' ? '出货模式' : '退货模式'),
            selected: true,
            onSelected: (_) {
              setState(() {
                _currentMode = _currentMode == 'SHIPPING' ? 'RETURN' : 'SHIPPING';
              });
              _playAudioPrompt(_currentMode == 'SHIPPING' ? 'shipping_mode.mp3' : 'return_mode.mp3');
            },
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                _isCameraReady && _textureId != null
                    ? Texture(textureId: _textureId!)
                    : const Center(child: CircularProgressIndicator()),
                Positioned(
                  top: 16,
                  left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start, // 此处已修正为 CrossAxisAlignment.start
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.fiber_manual_record,
                              color: _isRecording ? Colors.red : Colors.grey,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _isRecording ? '正在录制' : '待机中',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        if (_currentOrderNo.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text('单号: $_currentOrderNo', style: const TextStyle(color: Colors.yellow)),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey[900],
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _orderInputController,
                    focusNode: _inputFocusNode,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '扫描快递单号/订单条形码...',
                      hintStyle: const TextStyle(color: Colors.grey),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.qr_code_scanner, color: Colors.blueAccent),
                        onPressed: () => _handleOrderScanned(_orderInputController.text),
                      ),
                    ),
                    onSubmitted: _handleOrderScanned,
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isRecording ? Colors.red : Colors.green,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  ),
                  onPressed: () {
                    if (_isRecording) {
                      _stopRecording();
                    } else {
                      if (_orderInputController.text.isNotEmpty) {
                        _handleOrderScanned(_orderInputController.text);
                      } else {
                        _showErrorSnackBar('请先扫描或输入单号！');
                      }
                    }
                  },
                  child: Text(_isRecording ? '结束打包' : '开始打包'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
