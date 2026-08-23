package app.packingproof.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IntegrationTestBridgePolicyTest {
    @Test
    fun `media probe is available only to isolated integration package`() {
        assertTrue(
            IntegrationTestBridgePolicy.isAllowed(
                "app.packingproof.mobile.integration_test",
            ),
        )
        assertFalse(IntegrationTestBridgePolicy.isAllowed("app.packingproof.mobile"))
        assertFalse(IntegrationTestBridgePolicy.isAllowed(""))
    }
}
