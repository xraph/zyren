package dev.zyren.xr

import org.junit.Assert.*
import org.junit.Test

class XrGeometryTest {
    private fun identity() = mutableListOf(1.0,0.0,0.0,0.0, 0.0,1.0,0.0,0.0, 0.0,0.0,1.0,0.0, 0.0,0.0,0.0,1.0)

    @Test fun preservesTranslatedHalfTurnsOnEveryAxis() {
        for (axis in 0..2) {
            val transform = identity()
            for (a in 0..2) transform[a*5] = if (a == axis) 1.0 else -1.0
            transform[12] = 1.25; transform[13] = -2.5; transform[14] = 3.75
            val native = XrGeometry.pose(transform).values()
            for (i in 0..15) assertEquals(transform[i], native[i], 0.00001)
        }
    }

    @Test fun preservesQuarterTurnHandedness() {
        val transform = identity()
        transform[0] = 0.0; transform[1] = 1.0
        transform[4] = -1.0; transform[5] = 0.0
        val pose = XrGeometry.pose(transform)
        val rotated = pose.rotateVector(floatArrayOf(1f,0f,0f))
        assertArrayEquals(floatArrayOf(0f,1f,0f), rotated, 0.00001f)
    }

    @Test fun rejectsReflectionsScaleShearAndInvalidNumbers() {
        val cases = listOf(
            identity().apply { this[0] = -1.0 },
            identity().apply { this[0] = 2.0 },
            identity().apply { this[4] = .5 },
            identity().apply { this[12] = Double.NaN },
            identity().apply { this[12] = Double.MAX_VALUE },
            identity().apply { this[3] = .1 },
            identity().dropLast(1),
        )
        for (matrix in cases) {
            try { XrGeometry.pose(matrix); fail("Invalid anchor matrix was accepted: $matrix") }
            catch (e: XrFailure) { assertEquals("invalidArguments", e.code) }
        }
    }
}
