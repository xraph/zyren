package dev.zyren.xr

import com.google.ar.core.*
import kotlin.math.*

internal object XrGeometry {
    fun pose(value: Any?): Pose {
        val v = (value as? List<*>)?.map { (it as? Number)?.toDouble() ?: Double.NaN } ?: emptyList()
        requireXr(v.size == 16 && v.all { it.isFinite() && it.toFloat().isFinite() }, "invalidArguments", "Expected a finite rigid transform.")
        requireXr(abs(v[3])+abs(v[7])+abs(v[11])+abs(v[15]-1) < .004, "invalidArguments", "Expected an affine transform.")
        for (a in 0..2) for (b in 0..2) requireXr(abs((0..2).sumOf { v[a*4+it]*v[b*4+it] } - if (a==b) 1.0 else 0.0) < .002, "invalidArguments", "Scale and shear are unavailable for anchors.")
        val determinant=v[0]*(v[5]*v[10]-v[9]*v[6])-v[4]*(v[1]*v[10]-v[9]*v[2])+v[8]*(v[1]*v[6]-v[5]*v[2])
        requireXr(abs(determinant-1)<.004, "invalidArguments", "Anchor transform must preserve handedness.")
        // Numerically stable matrix-to-quaternion conversion, column-major.
        val q = FloatArray(4)
        val trace=v[0]+v[5]+v[10]
        if (trace>0) { val s=sqrt(trace+1)*2; q[3]=(s/4).toFloat(); q[0]=((v[6]-v[9])/s).toFloat(); q[1]=((v[8]-v[2])/s).toFloat(); q[2]=((v[1]-v[4])/s).toFloat() }
        else {
            val i = (0..2).maxBy { v[it*5] }; val j=(i+1)%3; val k=(i+2)%3
            val s=sqrt(1+v[i*5]-v[j*5]-v[k*5])*2
            q[i]=(s/4).toFloat(); q[j]=((v[j*4+i]+v[i*4+j])/s).toFloat(); q[k]=((v[k*4+i]+v[i*4+k])/s).toFloat(); q[3]=((v[j*4+k]-v[k*4+j])/s).toFloat()
        }
        return Pose(floatArrayOf(v[12].toFloat(),v[13].toFloat(),v[14].toFloat()),q)
    }
    fun geometry(p: Plane, id: String, revision: Int, timestamp: Double): Map<String, Any?> {
        requireXr(p.trackingState == TrackingState.TRACKING && p.subsumedBy == null, "unknownPlane", "Plane is not tracking.")
        val polygon=p.polygon; requireXr(polygon.remaining()/2 <=1024,"geometryTooLarge","Plane boundary exceeds 1024 vertices.")
        val vertices=mutableListOf<Double>(); while(polygon.hasRemaining()) { vertices.add(polygon.get().toDouble()); vertices.add(0.0); vertices.add(polygon.get().toDouble()) }
        val count=vertices.size/3
        val indices=(1 until count-1).flatMap { listOf(0,it+1,it) }
        return mapOf("planeId" to id,"sessionRevision" to revision,"frameTimestamp" to timestamp,"transform" to p.centerPose.values(),"vertices" to vertices,"boundary" to vertices,"indices" to indices)
    }
    fun raycast(frame: Frame, presenter: XrVulkanPresenter, args: Map<String,Any?>, revision: Int, origin: Int, observedTimestamp: Double, id: (Plane)->String): Map<String,Any?> {
        val c=presenter.presentedCalibration ?: throw XrFailure("staleFrame","Render a camera view before raycasting.")
        val timestamp=c["timestamp"] as Double
        requireXr(args["frameId"]==c["frameId"] && args["epoch"]==c["epoch"] && c["revision"]==revision && observedTimestamp>=timestamp && observedTimestamp-timestamp<=.5,"staleFrame","The presented camera frame is stale.")
        val x=(args["x"] as? Number)?.toDouble() ?: Double.NaN; val y=(args["y"] as? Number)?.toDouble() ?: Double.NaN
        requireXr(x.isFinite() && y.isFinite() && x>=0 && y>=0 && x<c["logicalWidth"] as Double && y<c["logicalHeight"] as Double,"invalidArguments","Point lies outside the viewport.")
        // Use the presented pose/projection, not a later camera orientation.
        val projection=(c["projection"] as List<*>).map { (it as Number).toFloat() }.toFloatArray()
        val nx=(x/(c["logicalWidth"] as Double)*2-1).toFloat()
        val ny=(1-y/(c["logicalHeight"] as Double)*2).toFloat()
        val pose=pose(c["cameraTransform"])
        val ray=pose.rotateVector(floatArrayOf((nx+projection[8])/projection[0],(ny+projection[9])/projection[5],-1f))
        val norm=sqrt(ray.sumOf { (it*it).toDouble() }).toFloat()
        requireXr(norm.isFinite() && norm>0,"invalidCalibration","Camera ray is invalid.")
        for(i in 0..2) ray[i]/=norm
        val hits=frame.hitTest(pose.translation,0,ray,0).filter { val p=it.trackable; p is Plane && p.trackingState==TrackingState.TRACKING && p.isPoseInPolygon(it.hitPose) && p.subsumedBy==null }
        return mapOf("presenterId" to presenter.id,"frameId" to c["frameId"],"epoch" to c["epoch"],"frameTimestamp" to timestamp,"sensorTimestamp" to frame.timestamp/1e9,"queryTimestamp" to observedTimestamp,"sessionRevision" to revision,"originEpoch" to origin,"coverage" to "native-plane-geometry-estimate","omittedHits" to (hits.size-16).coerceAtLeast(0),"hits" to hits.take(16).map { mapOf("planeId" to id(it.trackable as Plane),"transform" to it.hitPose.values(),"distance" to it.distance.toDouble()) })
    }
}
