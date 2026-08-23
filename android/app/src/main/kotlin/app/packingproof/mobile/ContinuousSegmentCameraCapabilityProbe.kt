package app.packingproof.mobile

import android.media.MediaFormat
import android.os.SystemClock
import android.util.Size
import io.flutter.plugin.common.MethodChannel

internal fun ContinuousSegmentCamera.probeSequence(sequence: String, budgetMs: Int, result: MethodChannel.Result) {
    val normalized = sequence.trim().lowercase()
    if (disposed) {
        replyError(result, "disposed", "摄像头已经关闭")
        return
    }
    if (!initialized) {
        replyError(result, "camera_not_ready", "摄像头尚未准备完成")
        return
    }
    if (recordingRequested || recordingActive ||
        startResult != null || stopResult != null || splitResult != null
    ) {
        replyError(result, "camera_busy", "录像进行中不能检测摄像头能力")
        return
    }
    if (!CameraProbePlanPolicy.supportsCapabilitySequence(normalized)) {
        replyError(result, "invalid_sequence", "无法识别的摄像头能力探测序列")
        return
    }
    if (capabilityProbeActive) {
        replyError(result, "probe_pending", "摄像头能力检测正在进行")
        return
    }
    val mux = muxHandler
    val cam = cameraHandler
    if (mux == null || cam == null) {
        replyError(result, "camera_not_ready", "摄像头尚未准备完成")
        return
    }
    capabilityProbeActive = true
    probeInProgress = true
    probeGeneration++
    val generation = probeGeneration
    val deadline = SystemClock.uptimeMillis() + budgetMs.coerceIn(1_000, 30_000)
    mux.post {
        if (disposed || generation != probeGeneration) {
            finishCapabilityProbe(normalized, result, "error", "cancelled", emptyList())
            return@post
        }
        // 探针使用独立临时编码器：先释放长驻编码器，结束后确定性恢复，
        // 正式 preferredMime / selectedMime / fallbackReason
        // 均由同一确定性输入重建，与探测前一致。
        runCatching { captureSession?.close() }
        captureSession = null
        sessionHasPreview = false
        sessionHasEncoder = false
        sessionHasAnalysis = false
        runCatching { cameraDevice?.close() }
        cameraDevice = null
        releaseCameraGlCompositor()
        encodedWatermarkFrameTracker.reset()
        recordingVideoEncoder.release()
        cam.post {
            if (disposed || generation != probeGeneration) {
                finishCapabilityProbe(normalized, result, "error", "cancelled", emptyList())
                return@post
            }
            val environment = CameraCapabilityProbeEnvironment(
                handler = cam,
                cameraManager = cameraManager,
                streamConfigPolicy = streamConfigPolicy,
                videoCandidates = videoCandidates.map { StreamSize(it.width, it.height) },
                analysisCandidates = analysisCandidates.map {
                    StreamSize(it.width, it.height)
                },
                videoSize = StreamSize(videoSize.width, videoSize.height),
                analysisSize = StreamSize(analysisSize.width, analysisSize.height),
                selectedVideoMime = recordingVideoEncoder.selectedMime,
                surfacePipeline = cameraSurfacePipeline,
                cameraId = { selectedCameraId },
                cameraCharacteristics = { selectedCameraCharacteristics },
                surfaceTexture = { textureEntry?.surfaceTexture() },
                previewSurface = { previewSurface },
                updatePreviewSurface = { previewSurface = it },
                cameraDevice = { cameraDevice },
                updateCameraDevice = { cameraDevice = it },
                isDisposed = { disposed },
                createEncoderFormat = recordingVideoEncoder::createFormat,
                applyAutomaticCameraControls = ::applyAutomaticCameraControls,
            )
            CameraCapabilityProbeRunner(
                AndroidCameraCapabilityProbePhaseExecutor(environment),
            ).run(
                sequence = normalized,
                deadline = deadline,
                isCancelled = { disposed || generation != probeGeneration },
            ) { probeResult ->
                finishCapabilityProbe(
                    normalized,
                    result,
                    probeResult.status,
                    probeResult.reason,
                    probeResult.phases,
                )
            }
        }
    }
}

internal fun ContinuousSegmentCamera.finishCapabilityProbe(
    sequence: String,
    result: MethodChannel.Result,
    status: String,
    reason: String?,
    phases: List<Map<String, Any?>>,
) {
    capabilityProbeActive = false
    probeInProgress = false
    val payload = mapOf<String, Any?>(
        "sequence" to sequence,
        "status" to status,
        "probeErrorReason" to reason,
        "phases" to phases,
        "identity" to capabilityProbeIdentity(),
    )
    if (disposed) {
        replySuccess(result, payload)
        return
    }
    val mux = muxHandler
    val cam = cameraHandler
    if (mux == null || cam == null) {
        replySuccess(result, payload)
        return
    }
    mux.post {
        if (!disposed) {
            try {
                val output = cameraGlOutputGeometry(videoSize)
                recordingVideoEncoder.prepare(
                    output.width,
                    output.height,
                    muxHandler,
                )
                recordingVideoEncoder.setSuspended(true)
            } catch (error: Throwable) {
                // broad-catch: 编码器恢复错误统一上报，不中断能力探针收尾
                notifyNativeError("摄像头能力检测后编码器恢复失败", error)
            }
        }
        cam.post {
            if (disposed) {
                replySuccess(result, payload)
                return@post
            }
            val output = cameraGlOutputGeometry(videoSize)
            textureEntry?.surfaceTexture()?.setDefaultBufferSize(output.width, output.height)
            probeRestoreCallback = { restoreError ->
                replySuccess(
                    result,
                    if (restoreError == null) {
                        payload
                    } else {
                        payload + (
                            "restoreError" to (restoreError.message ?: "摄像头会话恢复失败")
                        )
                    },
                )
            }
            openCamera()
        }
    }
}

internal fun ContinuousSegmentCamera.capabilityProbeIdentity(): Map<String, Any?> =
    CameraDiagnosticsSnapshotMapper.capabilityProbeIdentity(
        CameraProbeIdentityDiagnostics(
            selectedCameraId, StreamSize(videoSize.width, videoSize.height),
            StreamSize(analysisSize.width, analysisSize.height),
            if (recordingVideoEncoder.selectedMime == MediaFormat.MIMETYPE_VIDEO_AVC) {
                "h264"
            } else {
                "hevc"
            },
            recordingSpecName, CONTINUOUS_CAMERA_CAPABILITY_PROBE_SCHEMA_VERSION,
            CONTINUOUS_CAMERA_PIPELINE_VERSION,
        ),
    )
