package app.packingproof.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraBarcodeDispatchTest {
    @Test
    fun pigeonListenerPreventsDuplicateLegacyEvent() {
        val events = mutableListOf<String>()

        dispatchCameraEvent(
            method = "barcodeFrame",
            arguments = emptyList<Any>(),
            eventListeners = listOf({ method, _ -> events += "pigeon:$method" }),
            legacyDispatch = { method, _ -> events += "legacy:$method" },
        )

        assertEquals(listOf("pigeon:barcodeFrame"), events)
    }

    @Test
    fun legacyEventRemainsAvailableWithoutPigeonListener() {
        val events = mutableListOf<String>()

        dispatchCameraEvent(
            method = "barcodeFrame",
            arguments = emptyList<Any>(),
            eventListeners = emptyList(),
            legacyDispatch = { method, _ -> events += "legacy:$method" },
        )

        assertEquals(listOf("legacy:barcodeFrame"), events)
    }

    @Test
    fun keepsOnlyLatestBatchWhileDartReplyIsPending() {
        val sent = mutableListOf<List<String>>()
        val replies = mutableListOf<(Result<Unit>) -> Unit>()
        val dispatcher = LatestBarcodeBatchDispatcher<String> { candidates, reply ->
            sent += candidates
            replies += reply
        }

        dispatcher.dispatch(listOf("A"))
        dispatcher.dispatch(listOf("B"))
        dispatcher.dispatch(listOf("C"))

        assertEquals(listOf(listOf("A")), sent)
        replies.removeAt(0)(Result.success(Unit))
        assertEquals(listOf(listOf("A"), listOf("C")), sent)
        replies.removeAt(0)(Result.success(Unit))
        assertEquals(2, sent.size)
    }

    @Test
    fun analyzesOnlyWhenScanningIsEnabledAndReady() {
        assertFalse(
            shouldAnalyzeBarcodeFrame(
                previewActive = true,
                pairingScanEnabled = false,
                workScanEnabled = false,
                scannerBusy = false,
                elapsedSinceLastAnalysisMs = 250,
                analysisIntervalMs = 250,
            ),
        )
        assertTrue(
            shouldAnalyzeBarcodeFrame(
                previewActive = true,
                pairingScanEnabled = false,
                workScanEnabled = true,
                scannerBusy = false,
                elapsedSinceLastAnalysisMs = 250,
                analysisIntervalMs = 250,
            ),
        )
        assertFalse(
            shouldAnalyzeBarcodeFrame(
                previewActive = true,
                pairingScanEnabled = true,
                workScanEnabled = false,
                scannerBusy = true,
                elapsedSinceLastAnalysisMs = 250,
                analysisIntervalMs = 250,
            ),
        )
        assertFalse(
            shouldAnalyzeBarcodeFrame(
                previewActive = true,
                pairingScanEnabled = true,
                workScanEnabled = false,
                scannerBusy = false,
                elapsedSinceLastAnalysisMs = 249,
                analysisIntervalMs = 250,
            ),
        )
    }
}
