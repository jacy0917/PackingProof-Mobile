package app.packingproof.mobile

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LanBackupSerialExecutorTest {
    @Test
    fun `accepted operations run serially in submission order`() {
        val executor = LanBackupSerialExecutor()
        val firstStarted = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val completed = CountDownLatch(2)
        val order = Collections.synchronizedList(mutableListOf<String>())

        assertTrue(executor.execute {
            order += "first-start"
            firstStarted.countDown()
            releaseFirst.await(5, TimeUnit.SECONDS)
            order += "first-end"
            completed.countDown()
        })
        assertTrue(firstStarted.await(5, TimeUnit.SECONDS))
        assertTrue(executor.execute {
            order += "second"
            completed.countDown()
        })

        releaseFirst.countDown()
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        assertEquals(listOf("first-start", "first-end", "second"), order)
        executor.disposeAfterDraining {}
    }

    @Test
    fun `dispose rejects new work and closes after accepted operations`() {
        val executor = LanBackupSerialExecutor()
        val operationStarted = CountDownLatch(1)
        val releaseOperation = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val order = Collections.synchronizedList(mutableListOf<String>())

        assertTrue(executor.execute {
            order += "operation"
            operationStarted.countDown()
            releaseOperation.await(5, TimeUnit.SECONDS)
        })
        assertTrue(operationStarted.await(5, TimeUnit.SECONDS))
        assertTrue(executor.disposeAfterDraining {
            order += "close"
            closed.countDown()
        })
        assertFalse(executor.execute { order += "late" })
        assertFalse(executor.disposeAfterDraining { order += "second-close" })

        releaseOperation.countDown()
        assertTrue(closed.await(5, TimeUnit.SECONDS))
        assertEquals(listOf("operation", "close"), order)
    }
}
