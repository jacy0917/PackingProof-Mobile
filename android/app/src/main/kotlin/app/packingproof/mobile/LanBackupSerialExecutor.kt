package app.packingproof.mobile

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Owns the native backup store's single serial execution lane.
 *
 * Disposal stops admission first, then appends the close action behind every
 * operation that was already accepted. It deliberately does not block the UI
 * thread while that queue drains.
 */
internal class LanBackupSerialExecutor(
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "packing-proof-backup-host").apply { isDaemon = true }
    },
) {
    private val lifecycleLock = Any()
    private var acceptingOperations = true

    fun execute(action: () -> Unit): Boolean = synchronized(lifecycleLock) {
        if (!acceptingOperations) return@synchronized false
        try {
            executor.execute(action)
            true
        } catch (_: RejectedExecutionException) {
            false
        }
    }

    fun disposeAfterDraining(closeAction: () -> Unit): Boolean = synchronized(lifecycleLock) {
        if (!acceptingOperations) return@synchronized false
        acceptingOperations = false
        executor.execute(closeAction)
        executor.shutdown()
        true
    }
}
