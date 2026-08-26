package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraOpenRetryPolicyTest {
    @Test
    fun `camera in use and service disconnects are transient`() {
        assertTrue(CameraOpenRetryPolicy.isTransientStateError(1))
        assertTrue(CameraOpenRetryPolicy.isTransientStateError(2))
        assertTrue(CameraOpenRetryPolicy.isTransientStateError(3))
        assertTrue(CameraOpenRetryPolicy.isTransientStateError(4))
        assertTrue(CameraOpenRetryPolicy.isTransientStateError(6))
    }

    @Test
    fun `fatal device errors are not retried`() {
        assertFalse(CameraOpenRetryPolicy.isTransientStateError(5))
        assertFalse(CameraOpenRetryPolicy.isTransientStateError(0))
        assertFalse(CameraOpenRetryPolicy.isTransientStateError(-1))
    }

    @Test
    fun `retry budget is bounded`() {
        assertEquals(6, CameraOpenRetryPolicy.MAX_ATTEMPTS)
        assertTrue(CameraOpenRetryPolicy.RETRY_DELAY_MS > 0)
    }

    @Test
    fun `retry delay backs off but remains bounded`() {
        assertEquals(750L, CameraOpenRetryPolicy.retryDelayMs(0))
        assertEquals(1_500L, CameraOpenRetryPolicy.retryDelayMs(1))
        assertEquals(2_000L, CameraOpenRetryPolicy.retryDelayMs(2))
        assertEquals(2_000L, CameraOpenRetryPolicy.retryDelayMs(99))
    }
}
