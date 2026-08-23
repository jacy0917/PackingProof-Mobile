package app.packingproof.mobile

import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraDevice
import android.media.ImageReader
import android.view.Surface

internal fun ContinuousSegmentCamera.runInitProbesIfNeeded() {
    if (disposed) return
    val stage = initFailureStage ?: return
    if (stage !in CONTINUOUS_CAMERA_PROBE_TRIGGER_STAGES) return
    if (ContinuousCameraInitProbeCache.results != null) return
    if (ContinuousCameraInitProbeCache.inProgress) {
        probeInProgress = true
        return
    }
    val handler = cameraHandler ?: return
    handler.post {
        if (disposed || ContinuousCameraInitProbeCache.results != null) return@post
        val configs = CameraProbePlanPolicy.initializationConfigs(
            videoCandidates.map { StreamSize(it.width, it.height) },
            analysisCandidates.map { StreamSize(it.width, it.height) },
        )
        if (configs.isEmpty()) return@post
        ContinuousCameraInitProbeCache.inProgress = true
        probeInProgress = true
        probeGeneration++
        val generation = probeGeneration
        runSingleProbe(generation, configs, 0, mutableListOf())
    }
}

internal fun ContinuousSegmentCamera.runSingleProbe(
    generation: Int,
    configs: List<ProbeConfig>,
    index: Int,
    results: MutableList<Map<String, Any?>>,
) {
    val handler = cameraHandler
    if (handler == null || disposed || generation != probeGeneration) {
        finishProbes(generation, results)
        return
    }
    if (index >= configs.size) {
        finishProbes(generation, results)
        return
    }
    val config = configs[index]
    runOneProbe(generation, config) { result ->
        results += result
        handler.post { runSingleProbe(generation, configs, index + 1, results) }
    }
}

internal fun ContinuousSegmentCamera.runOneProbe(
    generation: Int,
    config: ProbeConfig,
    onDone: (Map<String, Any?>) -> Unit,
) {
    val handler = cameraHandler
    val cameraId = selectedCameraId
    val entry = textureEntry
    val label = when {
        config.includeEncoder -> "preview+encoder+analysis"
        config.analysisSize != null -> "preview+analysis"
        else -> "preview"
    }
    if (handler == null || cameraId == null || entry == null) {
        onDone(mapOf("name" to config.name, "surfaces" to label, "result" to "preview_unavailable"))
        return
    }
    val surfaces = buildList {
        val texture = entry.surfaceTexture()
        texture.setDefaultBufferSize(config.videoSize.width, config.videoSize.height)
        val preview = previewSurface ?: Surface(texture).also { previewSurface = it }
        add(preview)
        config.analysisSize?.let { size ->
            ImageReader.newInstance(
                size.width,
                size.height,
                ImageFormat.YUV_420_888,
                2,
            ).also { reader ->
                probeReaders += reader
                add(reader.surface)
            }
        }
        if (config.includeEncoder) recordingVideoEncoder.inputSurface?.let(::add)
    }
    val expected = 1 +
        (if (config.analysisSize != null) 1 else 0) +
        (if (config.includeEncoder) 1 else 0)
    if (surfaces.size < expected) {
        closeProbeCameraAndReaders()
        onDone(mapOf("name" to config.name, "surfaces" to label, "result" to "surface_missing"))
        return
    }
    var finished = false
    val timeout = Runnable {
        if (!finished) {
            finished = true
            closeProbeCameraAndReaders()
            onDone(mapOf("name" to config.name, "surfaces" to label, "result" to "timeout"))
        }
    }
    fun finish(result: Map<String, Any?>) {
        if (finished) return
        finished = true
        handler.removeCallbacks(timeout)
        closeProbeCameraAndReaders()
        onDone(result)
    }
    handler.postDelayed(timeout, CONTINUOUS_CAMERA_PROBE_TIMEOUT_MS)
    try {
        cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                if (generation != probeGeneration || disposed) {
                    finish(mapOf("name" to config.name, "surfaces" to label, "result" to "cancelled"))
                    return
                }
                cameraDevice = camera
                try {
                    camera.createCaptureSession(
                        surfaces,
                        object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: CameraCaptureSession) {
                                try {
                                    session.close()
                                } catch (_: Throwable) {
                                    // broad-catch: 探针会继续返回原始配置失败结果
                                }
                                finish(
                                    mapOf(
                                        "name" to config.name,
                                        "surfaces" to label,
                                        "result" to "configured",
                                    ),
                                )
                            }

                            override fun onConfigureFailed(session: CameraCaptureSession) {
                                try {
                                    session.close()
                                } catch (_: Throwable) {
                                    // broad-catch: 探针会继续返回原始配置失败结果
                                }
                                finish(
                                    mapOf(
                                        "name" to config.name,
                                        "surfaces" to label,
                                        "result" to "configure_failed",
                                    ),
                                )
                            }
                        },
                        handler,
                    )
                } catch (error: Throwable) {
                    // broad-catch: 任意相机会话初始化异常都转换为探针失败结果
                    finish(
                        mapOf(
                            "name" to config.name,
                            "surfaces" to label,
                            "result" to "create_failed",
                            "detail" to (error.message ?: ""),
                        ),
                    )
                }
            }

            override fun onDisconnected(camera: CameraDevice) {
                closeCameraSafely(camera)
                finish(
                    mapOf(
                        "name" to config.name,
                        "surfaces" to label,
                        "result" to "open_disconnected",
                    ),
                )
            }

            override fun onError(camera: CameraDevice, error: Int) {
                closeCameraSafely(camera)
                finish(
                    mapOf(
                        "name" to config.name,
                        "surfaces" to label,
                        "result" to "open_failed",
                        "detail" to error.toString(),
                    ),
                )
            }
        }, handler)
    } catch (error: Throwable) {
        // broad-catch: 任意相机会话创建异常都转换为探针失败结果
        finish(
            mapOf(
                "name" to config.name,
                "surfaces" to label,
                "result" to "open_failed",
                "detail" to (error.message ?: ""),
            ),
        )
    }
}

internal fun ContinuousSegmentCamera.closeProbeCameraAndReaders() {
    try {
        cameraDevice?.close()
    } catch (_: Throwable) {
        // broad-catch: 探针资源清理不得遮蔽原始检测结果
    }
    cameraDevice = null
    probeReaders.forEach { reader ->
        try {
            reader.close()
        } catch (_: Throwable) {
            // broad-catch: 探针资源清理不得遮蔽原始检测结果
        }
    }
    probeReaders.clear()
}

internal fun ContinuousSegmentCamera.finishProbes(
    generation: Int,
    results: List<Map<String, Any?>>,
) {
    ContinuousCameraInitProbeCache.inProgress = false
    if (generation != probeGeneration) return
    probeInProgress = false
    if (results.isEmpty()) return
    val snapshot = results.toList()
    ContinuousCameraInitProbeCache.results = snapshot
    probeResults = snapshot
    emit(
        "probeFinished",
        mapOf(
            "results" to snapshot,
            "cameraId" to (selectedCameraId ?: ""),
            "hardwareLevel" to (hardwareLevel ?: -1),
        ),
    )
}
