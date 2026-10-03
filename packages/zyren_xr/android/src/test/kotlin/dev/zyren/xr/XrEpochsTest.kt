package dev.zyren.xr

import org.junit.Assert.*
import org.junit.Test

class XrEpochsTest {
    @Test fun pauseResumeCannotRestoreAnOldLease() {
        val epochs = XrEpochs()
        val lease = epochs.lifecycle()
        epochs.invalidate()
        assertFalse(epochs.current(lease))
        var published = false
        try { epochs.guarded(lease) { published = true }; fail("Stale lease accepted") }
        catch (failure: XrFailure) { assertEquals("frameDeferred", failure.code) }
        assertFalse(published)
    }
    @Test fun disposedViewCannotInvalidateReplacement() {
        val epochs = XrEpochs()
        epochs.register("old")
        epochs.register("current")
        val current = epochs.changeSurface("current")
        assertNull(epochs.changeSurface("old"))
        assertEquals(current, epochs.surface())
        assertTrue(epochs.changeSurface("current")!! > current!!)
    }
    @Test fun invalidationAfterRenderDiscardsWithoutLosingAppliedPacket() {
        val epochs = XrEpochs()
        val renderedEpoch = epochs.lifecycle()
        var submitted = false
        var discarded = false
        val presented = publishRenderedFrame({ true }, {
            epochs.invalidate()
            epochs.guarded(renderedEpoch) { submitted = true }
        }, { discarded = true })
        assertFalse(presented)
        assertFalse(submitted)
        assertTrue(discarded)
    }
    @Test fun queuedPortraitCallbackCannotReplaceNewerLandscape() {
        val epochs = XrEpochs()
        epochs.register("presenter")
        val portrait = epochs.changeSurface("presenter")!!
        val landscape = epochs.changeSurface("presenter")!!
        assertFalse(epochs.currentSurface("presenter", portrait))
        assertTrue(epochs.currentSurface("presenter", landscape))
        epochs.register("replacement")
        assertFalse(epochs.currentSurface("presenter", landscape))
    }
    @Test fun repeatedSensorFrameKeepsOriginalObservationTime() {
        val clock = XrFrameClock()
        assertEquals(1000L, clock.observe(900000000000L, 1000L))
        assertEquals(1000L, clock.observe(900000000000L, 999999L))
        assertEquals(1000000L, clock.observe(900000000001L, 1000000L))
    }
}
