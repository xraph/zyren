//! Implementation details of the `cast_shapes` function.

// Zyren modification (2026-10-04): bounded capsule casts. See ZYREN_PATCH.md.

pub use self::shape_cast::{cast_shapes, ShapeCastHit, ShapeCastOptions, ShapeCastStatus};
pub use self::shape_cast_ball_ball::cast_shapes_ball_ball;
pub use self::shape_cast_halfspace_support_map::{
    cast_shapes_halfspace_support_map, cast_shapes_support_map_halfspace,
};
#[cfg(feature = "alloc")]
pub use self::{
    shape_cast_composite_shape_shape::{
        cast_shapes_composite_shape_shape, cast_shapes_shape_composite_shape,
    },
    shape_cast_heightfield_shape::{cast_shapes_heightfield_shape, cast_shapes_shape_heightfield},
    shape_cast_support_map_support_map::cast_shapes_support_map_support_map,
    shape_cast_voxels_shape::{cast_shapes_shape_voxels, cast_shapes_voxels_shape},
};

mod shape_cast;
mod shape_cast_ball_ball;
#[cfg(feature = "alloc")]
mod shape_cast_composite_shape_shape;
mod shape_cast_halfspace_support_map;
#[cfg(feature = "alloc")]
mod shape_cast_heightfield_shape;
#[cfg(feature = "alloc")]
mod shape_cast_support_map_support_map;
#[cfg(feature = "alloc")]
mod shape_cast_voxels_shape;

#[cfg(all(feature = "alloc", feature = "dim3"))]
mod shape_cast_cuboid_capsule;
#[cfg(all(feature = "alloc", feature = "dim3"))]
pub use shape_cast_cuboid_capsule::cast_shapes_cuboid_capsule;

#[cfg(all(feature = "alloc", feature = "dim3"))]
mod capsule_poly_distance;
#[cfg(all(feature = "alloc", feature = "dim3"))]
pub use shape_cast_cuboid_capsule::{cast_shapes_triangle_capsule,cast_shapes_convex_capsule};
