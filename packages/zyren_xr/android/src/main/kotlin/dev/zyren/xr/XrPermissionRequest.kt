package dev.zyren.xr

// Activity callbacks and permission results run on the main thread. A grant may
// arrive before onResume, so keep it pending until the requesting activity resumes.
internal class XrPermissionRequest<T> {
    private var request: T? = null
    private var granted = false
    val pending: Boolean get() = request != null
    fun begin(value: T) {
        check(!pending)
        request = value; granted = false
    }
    fun resolve(authorized: Boolean, active: Boolean): T? {
        if (!pending) return null
        granted = authorized
        return if (!authorized || active) cancel() else null
    }
    fun resume(): T? = if (granted) cancel() else null
    fun cancel(): T? {
        val value = request
        request = null; granted = false
        return value
    }
}
