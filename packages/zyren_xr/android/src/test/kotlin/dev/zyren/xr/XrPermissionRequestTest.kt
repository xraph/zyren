package dev.zyren.xr

import org.junit.Assert.*
import org.junit.Test

class XrPermissionRequestTest {
    @Test fun grantBeforeResumeWaitsForActivity() {
        val request = XrPermissionRequest<String>()
        request.begin("start")
        assertNull(request.resolve(authorized = true, active = false))
        assertTrue(request.pending)
        assertEquals("start", request.resume())
        assertNull(request.resume())
    }
    @Test fun resumeBeforeGrantWaitsForPermission() {
        val request = XrPermissionRequest<String>()
        request.begin("start")
        assertNull(request.resume())
        assertEquals("start", request.resolve(authorized = true, active = true))
        assertFalse(request.pending)
    }
    @Test fun denialCompletesWithoutWaitingForResume() {
        val request = XrPermissionRequest<String>()
        request.begin("denied")
        assertEquals("denied", request.resolve(authorized = false, active = false))
        assertNull(request.resume())
    }
    @Test fun backgroundOrExplicitCancellationPreventsLaterStart() {
        for (alreadyGranted in listOf(false, true)) {
            val request = XrPermissionRequest<String>()
            request.begin("cancelled")
            if (alreadyGranted) assertNull(request.resolve(authorized = true, active = false))
            assertEquals("cancelled", request.cancel())
            assertNull(request.resolve(authorized = true, active = true))
            assertNull(request.resume())
        }
    }
}
