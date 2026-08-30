/// 录制清晰度规格。默认保持高清档，4K 仅在当前镜头支持时提供。
enum RecordingSpecPreset { uhd4k30, hd1080p30, smooth720p30 }

extension RecordingSpecPresetDetails on RecordingSpecPreset {
  String get storageValue => switch (this) {
    RecordingSpecPreset.uhd4k30 => 'uhd4k30',
    RecordingSpecPreset.hd1080p30 => 'hd1080p30',
    RecordingSpecPreset.smooth720p30 => 'smooth720p30',
  };

  String get label => switch (this) {
    RecordingSpecPreset.uhd4k30 => '4K',
    RecordingSpecPreset.hd1080p30 => '1080p',
    RecordingSpecPreset.smooth720p30 => '720p',
  };

  String get description => switch (this) {
    RecordingSpecPreset.uhd4k30 => '3840 × 2160 · 30 帧 · 画质最高，占用最多',
    RecordingSpecPreset.hd1080p30 => '1920 × 1080 · 30 帧 · 日常推荐',
    RecordingSpecPreset.smooth720p30 => '1280 × 720 · 30 帧 · 更省空间、更流畅',
  };

  int get videoWidth => switch (this) {
    RecordingSpecPreset.uhd4k30 => 3840,
    RecordingSpecPreset.hd1080p30 => 1920,
    RecordingSpecPreset.smooth720p30 => 1280,
  };

  int get videoHeight => switch (this) {
    RecordingSpecPreset.uhd4k30 => 2160,
    RecordingSpecPreset.hd1080p30 => 1080,
    RecordingSpecPreset.smooth720p30 => 720,
  };

  int get fps => 30;

  int get avcBitRate => switch (this) {
    RecordingSpecPreset.uhd4k30 => 35_000_000,
    RecordingSpecPreset.hd1080p30 => 10_000_000,
    RecordingSpecPreset.smooth720p30 => 6_000_000,
  };

  int get hevcBitRate => switch (this) {
    RecordingSpecPreset.uhd4k30 => 24_000_000,
    RecordingSpecPreset.hd1080p30 => 7_000_000,
    RecordingSpecPreset.smooth720p30 => 4_500_000,
  };
}

RecordingSpecPreset recordingSpecFromStorage(Object? value) {
  return tryRecordingSpecFromStorage(value) ?? RecordingSpecPreset.hd1080p30;
}

RecordingSpecPreset? tryRecordingSpecFromStorage(Object? value) {
  final String normalized = '$value'.trim().toLowerCase();
  return switch (normalized) {
    'uhd4k30' || '4k' || '4k30' || '2160p30' => RecordingSpecPreset.uhd4k30,
    'hd1080p30' || '1080p30' || 'hd' => RecordingSpecPreset.hd1080p30,
    'smooth720p30' || '720p30' || 'smooth' => RecordingSpecPreset.smooth720p30,
    _ => null,
  };
}
