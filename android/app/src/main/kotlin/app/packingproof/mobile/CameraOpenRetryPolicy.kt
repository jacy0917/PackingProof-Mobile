package app.packingproof.mobile

/**
 * Camera2 初始化阶段瞬时故障的重试策略。
 *
 * 摄像头被其他应用占用、HAL 尚未就绪或 CameraService 短暂断开都属于瞬时故障，
 * 稍作延迟重试即可成功；这里只负责判定哪些错误值得重试以及重试次数。
 */
internal object CameraOpenRetryPolicy {
    // OnePlus/Android 16 may keep the camera client marked as busy for several
    // seconds during a cold start.  A short fixed budget makes the app fail
    // before CameraService has a chance to release the stale client.
    const val MAX_ATTEMPTS = 6
    const val RETRY_DELAY_MS = 750L
    private const val MAX_RETRY_DELAY_MS = 2_000L

    /** Delay before the next open attempt (attempt is zero-based). */
    fun retryDelayMs(attempt: Int): Long {
        if (attempt <= 0) return RETRY_DELAY_MS
        return (RETRY_DELAY_MS * (attempt + 1).toLong())
            .coerceAtMost(MAX_RETRY_DELAY_MS)
    }

    // 对应 CameraDevice.StateCallback 的瞬时错误码（值为编译期常量）。
    private const val ERROR_CAMERA_DISCONNECTED = 1
    private const val ERROR_CAMERA_IN_USE = 2
    private const val ERROR_MAX_CAMERAS_IN_USE = 3
    private const val ERROR_CAMERA_DISABLED = 4
    private const val ERROR_CAMERA_SERVICE_DISCONNECTED = 6

    fun isTransientStateError(errorCode: Int): Boolean = when (errorCode) {
        ERROR_CAMERA_DISCONNECTED,
        ERROR_CAMERA_IN_USE,
        ERROR_MAX_CAMERAS_IN_USE,
        ERROR_CAMERA_DISABLED,
        ERROR_CAMERA_SERVICE_DISCONNECTED -> true
        else -> false
    }
}
