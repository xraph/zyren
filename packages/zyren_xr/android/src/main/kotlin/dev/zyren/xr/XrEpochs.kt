package dev.zyren.xr

// Main-thread invalidation and worker mutation share this short critical section.
// GPU rendering never holds it, so pause/resume cannot hide an invalidation.
internal class XrEpochs {
    private var lifecycle = 0L
    private var presenterId: String? = null
    private var surface = 0L
    @Synchronized fun lifecycle(): Long = lifecycle
    @Synchronized fun invalidate() { lifecycle++ }
    @Synchronized fun register(id: String?) { presenterId = id; surface++ }
    @Synchronized fun changeSurface(id: String): Long? {
        if (id != presenterId) return null
        return ++surface
    }
    @Synchronized fun currentSurface(id: String, generation: Long): Boolean = presenterId == id && surface == generation
    @Synchronized fun surface(): Long = surface
    @Synchronized fun current(epoch: Long): Boolean = lifecycle == epoch
    @Synchronized fun <T> guarded(epoch: Long, action: () -> T): T {
        requireXr(lifecycle == epoch, "frameDeferred", "The activity lifecycle changed.")
        return action()
    }
}

internal class XrFrameClock {
    private var sensor = 0L
    var observed = 0L; private set
    fun observe(sensorTimestamp: Long, now: Long): Long {
        if (sensor != sensorTimestamp) { sensor = sensorTimestamp; observed = now }
        return observed
    }
}

// Rendering has already applied the scene packet when this gate runs.
internal fun publishRenderedFrame(active: () -> Boolean, publish: () -> Unit, discard: () -> Unit): Boolean {
    if (!active()) { discard(); return false }
    try { publish() }
    catch (failure: XrFailure) {
        if (failure.code != "frameDeferred") throw failure
        discard(); return false
    }
    return true
}
