package app.packingproof.mobile

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build

internal class BackCameraCatalog(
    private val cameraManager: CameraManager,
) {
    fun build(mainCameraId: String? = null): List<BackLensInfo> = runCatching {
        val logicalBack = cameraManager.cameraIdList.filter(::isBackCamera)
        val entries = ArrayList<BackLensEntry>()
        for (id in logicalBack) addEntry(entries, id)
        for (id in logicalBack) {
            for (physicalId in cameraManager.getCameraCharacteristics(id).physicalCameraIds) {
                if (isBackCamera(physicalId)) addEntry(entries, physicalId)
            }
        }
        val wideZoomRatio = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            logicalBack.firstNotNullOfOrNull { id ->
                cameraManager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
                    ?.takeIf { it.lower < 1f }
                    ?.lower
                    ?.toDouble()
            }
        } else {
            null
        }
        BackLensCatalog.build(
            entries,
            mainCameraId = mainCameraId ?: logicalBack.firstOrNull(),
            wideZoomRatio = wideZoomRatio,
        )
    }.getOrDefault(emptyList())

    fun allIds(): Set<String> = runCatching {
        val logicalBack = cameraManager.cameraIdList.filter(::isBackCamera)
        val ids = logicalBack.toMutableSet()
        for (id in logicalBack) {
            for (physicalId in cameraManager.getCameraCharacteristics(id).physicalCameraIds) {
                if (isBackCamera(physicalId)) ids.add(physicalId)
            }
        }
        ids
    }.getOrDefault(emptySet())

    fun defaultId(): String? = runCatching {
        cameraManager.cameraIdList.firstOrNull(::isBackCamera)
    }.getOrDefault(null)

    private fun addEntry(entries: MutableList<BackLensEntry>, cameraId: String) {
        val characteristics = cameraManager.getCameraCharacteristics(cameraId)
        val focalLength = characteristics
            .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            ?.firstOrNull() ?: return
        val sensorWidth = characteristics
            .get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
            ?.width ?: return
        entries.add(BackLensEntry(cameraId, focalLength, sensorWidth))
    }

    private fun isBackCamera(cameraId: String): Boolean = runCatching {
        cameraManager.getCameraCharacteristics(cameraId)
            .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
    }.getOrDefault(false)
}
