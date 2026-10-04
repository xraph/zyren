use rapier3d::control::{CharacterAutostep, CharacterLength, KinematicCharacterController};
use rapier3d::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    ffi::{CStr, CString, c_char},
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
};

type Result<T> = std::result::Result<T, String>;
const MAX_ITEMS: usize = 16384;
const MAX_BYTES: usize = 16 * 1024 * 1024;
fn number(v: &Value, key: &str, default: f32) -> Result<f32> {
    let n = v
        .get(key)
        .map(|x| x.as_f64().ok_or_else(|| format!("{key} must be numeric")))
        .transpose()?
        .unwrap_or(default as f64);
    if !n.is_finite() || n.abs() > 1e12 {
        return Err(format!("{key} is out of range"));
    }
    Ok(n as f32)
}
fn positive(v: &Value, key: &str, default: f32) -> Result<f32> {
    let n = number(v, key, default)?;
    if n <= 0.0 {
        Err(format!("{key} must be positive"))
    } else {
        Ok(n)
    }
}
fn nonnegative(v: &Value, key: &str, default: f32) -> Result<f32> {
    let n = number(v, key, default)?;
    if n < 0.0 {
        Err(format!("{key} must be nonnegative"))
    } else {
        Ok(n)
    }
}
fn vector(v: &Value, key: &str, default: Vector) -> Result<Vector> {
    let Some(a) = v.get(key) else {
        return Ok(default);
    };
    let a = a.as_array().ok_or("vector must be an array")?;
    if a.len() != 3 {
        return Err(format!("{key} needs three components"));
    }
    let mut out = [0.0; 3];
    for i in 0..3 {
        out[i] = number(&json!({"n":a[i]}), "n", 0.0)?;
    }
    Ok(Vector::from_array(out))
}
fn pose(v: &Value) -> Result<Pose> {
    let p = vector(v, "position", Vector::ZERO)?;
    let a = v.get("rotation").cloned().unwrap_or(json!([0, 0, 0, 1]));
    let a = a.as_array().ok_or("rotation must be an array")?;
    if a.len() != 4 {
        return Err("rotation needs four components".into());
    }
    let mut q = [0.0; 4];
    for i in 0..4 {
        q[i] = number(&json!({"n":a[i]}), "n", 0.0)?;
    }
    let q = Rotation::from_xyzw(q[0], q[1], q[2], q[3]);
    if q.length_squared() < 1e-20 {
        return Err("rotation must be nonzero".into());
    }
    Ok(Pose::from_parts(p, q.normalize()))
}
fn id(v: &Value, key: &str) -> Result<u64> {
    v[key]
        .as_u64()
        .ok_or_else(|| format!("{key} must be an integer"))
}
fn ray_request(v: &Value) -> Result<(Ray, f32, bool)> {
    let dir = vector(v, "direction", Vector::ZERO)?;
    if dir.length_squared() < 1e-20 {
        return Err("ray direction must be nonzero".into());
    }
    Ok((
        Ray::new(vector(v, "origin", Vector::ZERO)?, dir.normalize()),
        positive(v, "maxDistance", 1000.0)?,
        v["solid"].as_bool().unwrap_or(true),
    ))
}
fn shape(v: &Value, depth: usize) -> Result<SharedShape> {
    if depth > 8 {
        return Err("compound nesting exceeds eight".into());
    }
    match v["type"].as_str().ok_or("shape type missing")? {
        "box" => {
            let h = vector(v, "halfExtents", Vector::ZERO)?;
            if h.min_element() <= 0.0 {
                return Err("box extents must be positive".into());
            }
            Ok(SharedShape::cuboid(h.x, h.y, h.z))
        }
        "sphere" => Ok(SharedShape::ball(positive(v, "radius", 0.0)?)),
        "capsule" => Ok(SharedShape::capsule_y(
            nonnegative(v, "halfHeight", 0.0)?,
            positive(v, "radius", 0.0)?,
        )),
        "convex" | "mesh" => {
            let points = v["vertices"].as_array().ok_or("vertices missing")?;
            let minimum = if v["type"] == "mesh" { 3 } else { 4 };
            if points.len() < minimum || points.len() > MAX_ITEMS {
                return Err(format!("vertex count outside {minimum}..16384"));
            }
            let points = points
                .iter()
                .map(|p| vector(&json!({"p":p}), "p", Vector::ZERO))
                .collect::<Result<Vec<_>>>()?;
            if v["type"] == "convex" {
                SharedShape::convex_hull(&points).ok_or("convex points are degenerate".into())
            } else {
                let tris = v["triangles"].as_array().ok_or("triangles missing")?;
                if tris.is_empty() || tris.len() > MAX_ITEMS {
                    return Err("triangle count outside 1..16384".into());
                }
                let tris = tris
                    .iter()
                    .map(|t| {
                        let a = t.as_array().ok_or("triangle needs indices")?;
                        if a.len() != 3 {
                            return Err("triangle needs three indices".into());
                        }
                        let mut out = [0; 3];
                        for i in 0..3 {
                            let n = a[i].as_u64().ok_or("invalid index")?;
                            if n >= points.len() as u64 {
                                return Err("index outside vertices".into());
                            }
                            out[i] = n as u32;
                        }
                        if out[0] == out[1] || out[1] == out[2] || out[0] == out[2] {
                            return Err("degenerate triangle".into());
                        }
                        let ab = points[out[1] as usize] - points[out[0] as usize];
                        let ac = points[out[2] as usize] - points[out[0] as usize];
                        let area = ab.cross(ac).length_squared();
                        if !area.is_finite() || area == 0.0 {
                            return Err("degenerate triangle".into());
                        }
                        Ok(out)
                    })
                    .collect::<Result<Vec<_>>>()?;
                SharedShape::trimesh(points, tris).map_err(|e| e.to_string())
            }
        }
        "compound" => {
            let children = v["children"].as_array().ok_or("children missing")?;
            if children.is_empty() || children.len() > 256 {
                return Err("compound count outside 1..256".into());
            }
            Ok(SharedShape::compound(
                children
                    .iter()
                    .map(|c| Ok((pose(c)?, shape(&c["shape"], depth + 1)?)))
                    .collect::<Result<Vec<_>>>()?,
            ))
        }
        _ => Err("unsupported shape".into()),
    }
}
fn contains_mesh(v: &Value) -> bool {
    v["type"] == "mesh"
        || v["children"]
            .as_array()
            .is_some_and(|a| a.iter().any(|c| contains_mesh(&c["shape"])))
}
#[derive(Serialize, Deserialize)]
struct World {
    physics: PhysicsWorld,
    next: u64,
    bodies: BTreeMap<u64, RigidBodyHandle>,
    colliders: BTreeMap<u64, ColliderHandle>,
    joints: BTreeMap<u64, ImpulseJointHandle>,
    removed_colliders: HashMap<ColliderHandle, u64>,
    pending_events: Vec<String>,
    #[serde(skip, default = "dirty_queries")]
    queries_dirty: bool,
    #[serde(skip)]
    mass_revision: u64,
    #[cfg(test)]
    #[serde(skip)]
    collision_refreshes: usize,
}
fn dirty_queries() -> bool {
    true
}
impl World {
    fn new(v: &Value) -> Result<Self> {
        let mut physics = PhysicsWorld {
            gravity: vector(v, "gravity", Vector::new(0.0, -9.81, 0.0))?,
            ..Default::default()
        };
        physics.integration_parameters.dt = positive(v, "dt", 1.0 / 60.0)?;
        if !(1e-6..=0.1).contains(&physics.integration_parameters.dt) {
            return Err("dt must be within 0.000001..0.1 seconds".into());
        }
        Ok(Self {
            physics,
            next: 1,
            bodies: BTreeMap::new(),
            colliders: BTreeMap::new(),
            joints: BTreeMap::new(),
            removed_colliders: HashMap::new(),
            pending_events: Vec::new(),
            queries_dirty: true,
            mass_revision: 0,
            #[cfg(test)]
            collision_refreshes: 0,
        })
    }
    fn alloc(&mut self) -> Result<u64> {
        let n = self.next;
        if n > i64::MAX as u64 {
            return Err("handle space exhausted".into());
        }
        self.next = self.next.checked_add(1).ok_or("handle space exhausted")?;
        Ok(n)
    }
    fn body(&self, v: &Value, key: &str) -> Result<RigidBodyHandle> {
        self.bodies
            .get(&id(v, key)?)
            .copied()
            .ok_or("body does not belong to this world".into())
    }
    fn command(&mut self, v: &Value) -> Result<Value> {
        let op = v["op"].as_str().ok_or("operation missing")?;
        let mutates = !matches!(
            op,
            "worldInfo"
                | "poses"
                | "bodyState"
                | "snapshot"
                | "debug"
                | "drainEvents"
                | "query"
                | "characterMove"
        );
        if mutates {
            self.queries_dirty = true;
        }
        let changes_mass = matches!(
            op,
            "body" | "collider" | "colliderUpdate" | "removeCollider"
        ) || (op == "bodyUpdate" && v["action"] == "mass");
        if changes_mass {
            self.mass_revision = self
                .mass_revision
                .checked_add(1)
                .ok_or("mass revision exhausted")?;
        }
        let result = self.command_inner(v);
        if changes_mass {
            for handle in self.bodies.values() {
                self.physics.bodies[*handle]
                    .recompute_mass_properties_from_colliders(&self.physics.colliders);
            }
        }
        // Removal may refresh contacts before changing topology. Keep those
        // later writes dirty, including any partially completed failed command.
        if mutates && op != "step" {
            self.queries_dirty = true;
        }
        result
    }
    fn command_inner(&mut self, v: &Value) -> Result<Value> {
        let p = &mut self.physics;
        match v["op"].as_str().ok_or("operation missing")? {
            "body" => {
                if self.bodies.len() >= MAX_ITEMS {
                    return Err("body budget exceeded".into());
                }
                let kind = v["kind"].as_str().unwrap_or("dynamic");
                let mut b = match kind {
                    "dynamic" => RigidBodyBuilder::dynamic(),
                    "fixed" => RigidBodyBuilder::fixed(),
                    "kinematicPosition" => RigidBodyBuilder::kinematic_position_based(),
                    "kinematicVelocity" => RigidBodyBuilder::kinematic_velocity_based(),
                    _ => return Err("unsupported body kind".into()),
                };
                b = b
                    .pose(pose(v)?)
                    .linvel(vector(v, "velocity", Vector::ZERO)?)
                    .angvel(vector(v, "angularVelocity", Vector::ZERO)?)
                    .linear_damping(nonnegative(v, "linearDamping", 0.0)?)
                    .angular_damping(nonnegative(v, "angularDamping", 0.0)?)
                    .ccd_enabled(v["ccd"].as_bool().unwrap_or(false))
                    .can_sleep(v["canSleep"].as_bool().unwrap_or(true));
                if let Some(mass) = v.get("mass") {
                    let m = positive(&json!({"mass":mass}), "mass", 1.0)?;
                    let inertia = vector(v, "inertia", Vector::splat(m))?;
                    if inertia.min_element() <= 0.0 {
                        return Err("inertia must be positive".into());
                    }
                    b = b.additional_mass_properties(MassProperties::new(
                        vector(v, "centerOfMass", Vector::ZERO)?,
                        m,
                        inertia,
                    ));
                }
                let n = self.alloc()?;
                b = b.user_data(n as u128);
                let h = self.physics.insert_body(b);
                self.bodies.insert(n, h);
                Ok(json!(n))
            }
            "collider" => {
                if self.colliders.len() >= MAX_ITEMS {
                    return Err("collider budget exceeded".into());
                }
                let h = self.body(v, "body")?;
                if self.physics.bodies[h].is_dynamic() && contains_mesh(&v["shape"]) {
                    return Err("triangle mesh requires fixed or kinematic body".into());
                }
                let sh = shape(&v["shape"], 0)?;
                let group = |key: &str| -> Result<Group> {
                    let n = v
                        .get(key)
                        .map(|n| n.as_u64().ok_or("group must be integer"))
                        .transpose()?
                        .unwrap_or(u32::MAX as u64);
                    if n > u32::MAX as u64 {
                        return Err("group exceeds 32 bits".into());
                    }
                    Ok(Group::from_bits_retain(n as u32))
                };
                let restitution = nonnegative(v, "restitution", 0.0)?;
                if restitution > 1.0 {
                    return Err("restitution exceeds one".into());
                }
                let c = ColliderBuilder::new(sh)
                    .position(pose(v)?)
                    .density(nonnegative(v, "density", 1.0)?)
                    .friction(nonnegative(v, "friction", 0.5)?)
                    .restitution(restitution)
                    .sensor(v["sensor"].as_bool().unwrap_or(false))
                    .collision_groups(InteractionGroups::new(
                        group("membership")?,
                        group("filter")?,
                        InteractionTestMode::And,
                    ))
                    .active_events(
                        ActiveEvents::COLLISION_EVENTS | ActiveEvents::CONTACT_FORCE_EVENTS,
                    )
                    .contact_force_event_threshold(0.0);
                let n = self.alloc()?;
                let c = c.user_data(n as u128);
                let handle = self.physics.insert_collider(c, Some(h));
                self.colliders.insert(n, handle);
                Ok(json!(n))
            }
            "step" => {
                let events = self.update_collisions(true)?;
                Ok(json!({"poses":self.poses(),"events":events}))
            }
            "drainEvents" => {
                let events = self
                    .pending_events
                    .iter()
                    .map(|e| serde_json::from_str(e).map_err(|e| e.to_string()))
                    .collect::<Result<Vec<Value>>>()?;
                self.pending_events.clear();
                Ok(json!(events))
            }
            "worldInfo" => Ok(json!({"gravity": p.gravity.to_array()})),
            "impulses" => self.apply_impulses(v),
            "rebase" => self.rebase(v),
            "poses" => Ok(self.poses()),
            "bodyState" => {
                let body_id = id(v, "body")?;
                let handle = self.body(v, "body")?;
                Ok(self.body_state(body_id, handle))
            }
            "gravity" => {
                p.gravity = vector(v, "value", Vector::ZERO)?;
                Ok(Value::Null)
            }
            "bodyUpdate" => {
                let h = self.body(v, "body")?;
                let b = &mut self.physics.bodies[h];
                let action = v["action"].as_str().ok_or("action missing")?;
                if matches!(
                    action,
                    "force"
                        | "forceAt"
                        | "impulse"
                        | "impulseAt"
                        | "torque"
                        | "torqueImpulse"
                        | "mass"
                ) && !b.is_dynamic()
                {
                    return Err("forces and mass require a dynamic body".into());
                }
                if matches!(action, "velocity" | "angularVelocity") && b.is_fixed() {
                    return Err("fixed body cannot have velocity".into());
                }
                match v["action"].as_str().ok_or("action missing")? {
                    "restoreMotion" => {
                        let restored_pose = pose(v)?;
                        let linear = vector(v, "velocity", Vector::ZERO)?;
                        let angular = vector(v, "angularVelocity", Vector::ZERO)?;
                        let sleeping = v["sleeping"].as_bool().ok_or("sleeping missing")?;
                        let kind = b.body_type();
                        if b.is_fixed() && (linear != Vector::ZERO || angular != Vector::ZERO) {
                            return Err("fixed body cannot have velocity".into());
                        }
                        if sleeping && (linear != Vector::ZERO || angular != Vector::ZERO) {
                            return Err("sleeping checkpoint cannot have velocity".into());
                        }
                        b.set_position(restored_pose, false);
                        b.reset_forces(false);
                        b.reset_torques(false);
                        // Rapier ignores setters on position-driven kinematics. Seed
                        // their derived velocity without changing their public kind.
                        if kind == RigidBodyType::KinematicPositionBased {
                            b.set_body_type(RigidBodyType::KinematicVelocityBased, false);
                        }
                        b.set_linvel(linear, false);
                        b.set_angvel(angular, false);
                        if kind == RigidBodyType::KinematicPositionBased {
                            b.set_body_type(kind, false);
                        }
                        if sleeping {
                            b.sleep();
                        } else {
                            b.wake_up(true);
                        }
                    }
                    "teleport" => {
                        b.set_position(pose(v)?, true);
                        if v["resetVelocity"].as_bool().unwrap_or(true) {
                            b.set_linvel(Vector::ZERO, true);
                            b.set_angvel(Vector::ZERO, true);
                            b.reset_forces(true);
                            b.reset_torques(true);
                        }
                    }
                    "target" => {
                        if !b.is_kinematic()
                            || b.body_type() != RigidBodyType::KinematicPositionBased
                        {
                            return Err("target requires position kinematic body".into());
                        }
                        b.set_next_kinematic_position(pose(v)?);
                    }
                    "velocity" => {
                        b.set_linvel(vector(v, "value", Vector::ZERO)?, true);
                    }
                    "angularVelocity" => {
                        b.set_angvel(vector(v, "value", Vector::ZERO)?, true);
                    }
                    "force" => b.add_force(vector(v, "value", Vector::ZERO)?, true),
                    "impulse" => b.apply_impulse(vector(v, "value", Vector::ZERO)?, true),
                    "torque" => b.add_torque(vector(v, "value", Vector::ZERO)?, true),
                    "torqueImpulse" => {
                        b.apply_torque_impulse(vector(v, "value", Vector::ZERO)?, true)
                    }
                    "forceAt" => b.add_force_at_point(
                        vector(v, "value", Vector::ZERO)?,
                        vector(v, "point", Vector::ZERO)?,
                        true,
                    ),
                    "impulseAt" => b.apply_impulse_at_point(
                        vector(v, "value", Vector::ZERO)?,
                        vector(v, "point", Vector::ZERO)?,
                        true,
                    ),
                    "mass" => {
                        let mass = positive(v, "mass", 1.0)?;
                        let inertia = vector(v, "inertia", Vector::splat(mass))?;
                        if inertia.min_element() <= 0.0 {
                            return Err("inertia must be positive".into());
                        }
                        let center = vector(v, "centerOfMass", Vector::ZERO)?;
                        b.set_additional_mass_properties(
                            MassProperties::new(center, mass, inertia),
                            true,
                        );
                    }
                    "clearForces" => {
                        b.reset_forces(true);
                        b.reset_torques(true);
                    }
                    "sleep" => b.sleep(),
                    "wake" => b.wake_up(true),
                    "damping" => {
                        let linear = nonnegative(v, "linear", 0.0)?;
                        let angular = nonnegative(v, "angular", 0.0)?;
                        b.set_linear_damping(linear);
                        b.set_angular_damping(angular);
                    }
                    _ => return Err("unsupported body action".into()),
                }
                Ok(Value::Null)
            }
            "jointUpdate" => {
                let handle = *self.joints.get(&id(v, "joint")?).ok_or("invalid joint")?;
                let axis = match v["axis"].as_str().unwrap_or("angularX") {
                    "linearX" => JointAxis::LinX,
                    "angularX" => JointAxis::AngX,
                    "angularY" => JointAxis::AngY,
                    "angularZ" => JointAxis::AngZ,
                    _ => return Err("unsupported motor axis".into()),
                };
                let position = number(v, "position", 0.0)?;
                let velocity = number(v, "velocity", 0.0)?;
                let stiffness = nonnegative(v, "stiffness", 0.0)?;
                let damping = nonnegative(v, "damping", 1.0)?;
                let max_force = nonnegative(v, "maxForce", 1000.0)?;
                let joint = p
                    .impulse_joints
                    .get_mut(handle, true)
                    .ok_or("removed joint")?;
                if joint.data.locked_axes.contains(axis.into()) {
                    return Err("motor axis is locked by the joint".into());
                }
                joint
                    .data
                    .set_motor(axis, position, velocity, stiffness, damping);
                joint.data.set_motor_max_force(axis, max_force);
                Ok(Value::Null)
            }
            "colliderUpdate" => {
                let handle = *self
                    .colliders
                    .get(&id(v, "collider")?)
                    .ok_or("invalid collider")?;
                let friction = nonnegative(v, "friction", 0.5)?;
                let restitution = nonnegative(v, "restitution", 0.0)?;
                if restitution > 1.0 {
                    return Err("restitution exceeds one".into());
                }
                let density = nonnegative(v, "density", 1.0)?;
                let membership = id(v, "membership")?;
                let filter = id(v, "filter")?;
                if membership > u32::MAX as u64 || filter > u32::MAX as u64 {
                    return Err("groups exceed 32 bits".into());
                }
                let c = p.colliders.get_mut(handle).ok_or("removed collider")?;
                c.set_friction(friction);
                c.set_restitution(restitution);
                c.set_density(density);
                c.set_sensor(v["sensor"].as_bool().unwrap_or(false));
                c.set_collision_groups(InteractionGroups::new(
                    Group::from_bits_retain(membership as u32),
                    Group::from_bits_retain(filter as u32),
                    InteractionTestMode::And,
                ));
                Ok(Value::Null)
            }
            "removeBody" => {
                let n = id(v, "body")?;
                let h = self.body(v, "body")?;
                if self.removed_colliders.len() + self.physics.bodies[h].colliders().len()
                    > MAX_ITEMS
                {
                    self.update_collisions(false)?;
                }
                for (id, collider) in &self.colliders {
                    if self.physics.colliders[*collider].parent() == Some(h) {
                        self.removed_colliders.insert(*collider, *id);
                    }
                }
                self.physics.remove_body(h);
                self.bodies.remove(&n);
                self.colliders
                    .retain(|_, h| self.physics.colliders.contains(*h));
                self.joints
                    .retain(|_, h| self.physics.impulse_joints.get(*h).is_some());
                Ok(Value::Null)
            }
            "removeCollider" => {
                let n = id(v, "collider")?;
                if self.removed_colliders.len() >= MAX_ITEMS {
                    self.update_collisions(false)?;
                }
                let h = self.colliders.remove(&n).ok_or("invalid collider")?;
                self.removed_colliders.insert(h, n);
                self.physics.remove_collider(h);
                Ok(Value::Null)
            }
            "joint" => self.add_joint(v),
            "removeJoint" => {
                let n = id(v, "joint")?;
                let h = self.joints.remove(&n).ok_or("invalid joint")?;
                p.impulse_joints.remove(h, true);
                Ok(Value::Null)
            }
            "query" => self.query(v),
            "characterMove" => self.character_move(v),
            "debug" => {
                let mut lines = Lines(Vec::new(), false);
                p.debug_render(
                    &mut DebugRenderPipeline::new(
                        DebugRenderStyle::default(),
                        DebugRenderMode::COLLIDER_SHAPES
                            | DebugRenderMode::JOINTS
                            | DebugRenderMode::CONTACTS
                            | DebugRenderMode::SOLVER_CONTACTS,
                    ),
                    &mut lines,
                );
                if lines.1 {
                    return Err("debug line budget exceeded".into());
                }
                Ok(json!(lines.0))
            }
            "snapshot" => {
                let bytes = bincode::serialize(self).map_err(|e| e.to_string())?;
                if bytes.len() > MAX_BYTES / 4 {
                    return Err("snapshot budget exceeded".into());
                }
                Ok(json!({"version":1,"rapier":"0.36.0","bytes":bytes}))
            }
            _ => Err("unsupported operation".into()),
        }
    }
    fn update_collisions(&mut self, simulate: bool) -> Result<Vec<Value>> {
        if !simulate && !self.queries_dirty {
            return Ok(Vec::new());
        }
        #[cfg(test)]
        if !simulate {
            self.collision_refreshes += 1;
        }
        let mut collector = Collector::default();
        collector.ids.extend(self.removed_colliders.drain());
        collector
            .ids
            .extend(self.colliders.iter().map(|(id, h)| (*h, *id)));
        let pending = self
            .pending_events
            .iter()
            .map(|event| serde_json::from_str(event).map_err(|e| e.to_string()))
            .collect::<Result<Vec<Value>>>()?;
        *collector
            .events
            .get_mut()
            .map_err(|_| "event lock poisoned")? = pending;
        self.pending_events.clear();
        if simulate {
            self.physics.step_with_events(&(), &collector);
        } else {
            self.physics.detect_collisions(&(), &collector);
            // Collision-only refresh clears Rapier's modified-body queue before
            // PhysicsPipeline can register newly inserted moving bodies.
            for handle in self.bodies.values() {
                let _ = self.physics.bodies.get_mut(*handle);
            }
        }
        let events = collector
            .events
            .into_inner()
            .map_err(|_| "event lock poisoned")?;
        if collector.overflow.load(Ordering::Relaxed) {
            self.pending_events = events.iter().map(Value::to_string).collect();
            return Err("physics event budget exceeded or unsupported event; restore a snapshot or drain events".into());
        }
        if simulate {
            if !self.physics.quarantine().is_empty() {
                return Err(
                    "nonfinite simulation state quarantined; restore a valid snapshot".into(),
                );
            }
            self.queries_dirty = false;
            Ok(events)
        } else {
            self.pending_events = events.iter().map(Value::to_string).collect();
            self.queries_dirty = false;
            Ok(Vec::new())
        }
    }
    fn rebase(&mut self, v: &Value) -> Result<Value> {
        let transform = pose(v)?;
        let rotation = transform.rotation;
        let mut changes = Vec::with_capacity(self.bodies.len());
        for handle in self.bodies.values() {
            let body = &self.physics.bodies[*handle];
            let position = transform * *body.position();
            let next = transform * *body.next_position();
            let linear = rotation * body.linvel();
            let angular = rotation * body.angvel();
            let force = rotation * body.user_force();
            let torque = rotation * body.user_torque();
            if !position.translation.is_finite()
                || !next.translation.is_finite()
                || !linear.is_finite()
                || !angular.is_finite()
                || !force.is_finite()
                || !torque.is_finite()
            {
                return Err("rebase would exceed finite state".into());
            }
            changes.push((
                *handle,
                position,
                next,
                linear,
                angular,
                force,
                torque,
                body.is_sleeping(),
                body.body_type(),
            ));
        }
        for (handle, position, next, linear, angular, force, torque, sleeping, kind) in changes {
            let body = &mut self.physics.bodies[handle];
            body.set_position(position, false);
            body.set_next_kinematic_position(next);
            if kind == RigidBodyType::KinematicPositionBased {
                body.set_body_type(RigidBodyType::KinematicVelocityBased, false);
            }
            body.set_linvel(linear, false);
            body.set_angvel(angular, false);
            if kind == RigidBodyType::KinematicPositionBased {
                body.set_body_type(kind, false);
            }
            body.reset_forces(false);
            body.reset_torques(false);
            body.add_force(force, false);
            body.add_torque(torque, false);
            if sleeping {
                body.sleep();
            }
        }
        self.physics.gravity = rotation * self.physics.gravity;
        Ok(Value::Null)
    }
    fn apply_impulses(&mut self, v: &Value) -> Result<Value> {
        let commands = v["commands"].as_array().ok_or("impulse commands missing")?;
        if commands.len() > MAX_ITEMS {
            return Err("impulse command budget exceeded".into());
        }
        let mut totals = BTreeMap::<u64, (RigidBodyHandle, Vector, Vector, bool)>::new();
        for command in commands {
            let id = id(command, "body")?;
            let handle = self.body(command, "body")?;
            let body = &self.physics.bodies[handle];
            if !body.is_dynamic() {
                return Err("impulses require a dynamic body".into());
            }
            let linear = vector(command, "linear", Vector::ZERO)?;
            let mut angular = vector(command, "angular", Vector::ZERO)?;
            if command.get("point").is_some() {
                let point = vector(command, "point", Vector::ZERO)?;
                angular += (point - body.mass_properties().world_com).cross(linear);
            }
            let total = totals
                .entry(id)
                .or_insert((handle, Vector::ZERO, Vector::ZERO, false));
            total.1 += linear;
            total.2 += angular;
            total.3 |= command["wake"].as_bool().unwrap_or(true);
        }
        for (handle, linear, angular, _) in totals.values() {
            let body = &self.physics.bodies[*handle];
            let props = body.mass_properties();
            if !linear.is_finite()
                || !angular.is_finite()
                || !(body.linvel() + props.effective_inv_mass * *linear).is_finite()
                || !(body.angvel() + props.effective_world_inv_inertia * *angular).is_finite()
            {
                return Err("impulse batch would exceed finite state".into());
            }
        }
        for (handle, linear, angular, wake) in totals.into_values() {
            let body = &mut self.physics.bodies[handle];
            body.apply_impulse(linear, wake);
            body.apply_torque_impulse(angular, wake);
        }
        Ok(Value::Null)
    }
    fn body_state(&self, id: u64, handle: RigidBodyHandle) -> Value {
        let body = &self.physics.bodies[handle];
        let props = body.mass_properties();
        let inverse = props.effective_world_inv_inertia;
        json!({
            "body": id,
            "kind": match body.body_type() {
                RigidBodyType::Dynamic => "dynamic",
                RigidBodyType::Fixed => "fixed",
                RigidBodyType::KinematicPositionBased => "kinematicPosition",
                RigidBodyType::KinematicVelocityBased => "kinematicVelocity",
                RigidBodyType::SoftFrame => "unsupportedSoftFrame",
            },
            "position": body.translation().to_array(),
            "rotation": body.rotation().to_array(),
            "velocity": body.linvel().to_array(),
            "angularVelocity": body.angvel().to_array(),
            "sleeping": body.is_sleeping(),
            "ccd": body.is_ccd_enabled(),
            "mass": body.mass(),
            "centerOfMass": props.world_com.to_array(),
            "localCenterOfMass": props.local_mprops.local_com.to_array(),
            "inverseInertia": [inverse.m11,inverse.m22,inverse.m33,inverse.m12,inverse.m13,inverse.m23],
            "massPropertiesRevision": self.mass_revision,
        })
    }
    fn poses(&self) -> Value {
        json!(
            self.bodies
                .iter()
                .map(|(id, handle)| self.body_state(*id, *handle))
                .collect::<Vec<_>>()
        )
    }
    fn add_joint(&mut self, v: &Value) -> Result<Value> {
        if self.joints.len() >= MAX_ITEMS {
            return Err("joint budget exceeded".into());
        }
        let a = self.body(v, "body1")?;
        let b = self.body(v, "body2")?;
        if a == b {
            return Err("joint needs distinct bodies".into());
        }
        let axis = vector(v, "axis", Vector::Y)?;
        if axis.length_squared() < 1e-20 {
            return Err("joint axis must be nonzero".into());
        }
        let axis = axis.normalize();
        let kind = v["kind"].as_str().ok_or("joint kind missing")?;
        let mut joint: GenericJoint = match kind {
            "hinge" => RevoluteJointBuilder::new(axis).build().into(),
            "slider" => PrismaticJointBuilder::new(axis).build().into(),
            "fixed" => FixedJointBuilder::new()
                .local_frame1(pose(&v["frame1"])?)
                .local_frame2(pose(&v["frame2"])?)
                .build()
                .into(),
            "spherical" => SphericalJointBuilder::new().build().into(),
            "spring" => SpringJoint::new(
                positive(v, "length", 1.0)?,
                nonnegative(v, "stiffness", 10.0)?,
                nonnegative(v, "damping", 1.0)?,
            )
            .into(),
            "distance" => RopeJoint::new(positive(v, "length", 1.0)?).into(),
            _ => return Err("unsupported joint kind".into()),
        };
        if kind != "fixed" {
            joint.set_local_anchor1(vector(v, "anchor1", Vector::ZERO)?);
            joint.set_local_anchor2(vector(v, "anchor2", Vector::ZERO)?);
        }
        joint.set_contacts_enabled(v["contacts"].as_bool().unwrap_or(false));
        let motor_axis = match v["motorAxis"].as_str().unwrap_or(if kind == "slider" {
            "linearX"
        } else {
            "angularX"
        }) {
            "linearX" => JointAxis::LinX,
            "angularX" => JointAxis::AngX,
            "angularY" => JointAxis::AngY,
            "angularZ" => JointAxis::AngZ,
            _ => return Err("unsupported motor axis".into()),
        };
        if v.get("limits").is_some()
            || v.get("motorVelocity").is_some()
            || v.get("motorPosition").is_some()
        {
            if !matches!(kind, "hinge" | "slider" | "spherical") {
                return Err("joint does not support configured limits/motor".into());
            }
            if joint.locked_axes.contains(motor_axis.into()) {
                return Err("motor or limit axis is locked by the joint".into());
            }
            if kind != "spherical"
                && motor_axis
                    != if kind == "slider" {
                        JointAxis::LinX
                    } else {
                        JointAxis::AngX
                    }
            {
                return Err("motor axis incompatible with joint".into());
            }
        }
        if let Some(l) = v.get("limits") {
            let l = l.as_array().ok_or("limits needs array")?;
            if l.len() != 2 {
                return Err("limits needs two values".into());
            }
            let min = number(&json!({"n":l[0]}), "n", 0.0)?;
            let max = number(&json!({"n":l[1]}), "n", 0.0)?;
            if min > max {
                return Err("limits inverted".into());
            }
            joint.set_limits(motor_axis, [min, max]);
        }
        if v.get("motorVelocity").is_some() {
            joint.set_motor_velocity(
                motor_axis,
                number(v, "motorVelocity", 0.0)?,
                nonnegative(v, "motorFactor", 1.0)?,
            );
        }
        if v.get("motorPosition").is_some() {
            joint.set_motor_position(
                motor_axis,
                number(v, "motorPosition", 0.0)?,
                nonnegative(v, "stiffness", 10.0)?,
                nonnegative(v, "damping", 1.0)?,
            );
        }
        joint.set_motor_max_force(motor_axis, nonnegative(v, "maxForce", 1000.0)?);
        let n = self.alloc()?;
        let h = self.physics.impulse_joints.insert(a, b, joint, true);
        self.joints.insert(n, h);
        Ok(json!(n))
    }
    fn character_move(&mut self, v: &Value) -> Result<Value> {
        self.update_collisions(false)?;
        let body = self.body(v, "body")?;
        if !self.physics.bodies[body].is_kinematic() {
            return Err("character body must be kinematic".into());
        }
        let handle = *self
            .colliders
            .get(&id(v, "collider")?)
            .ok_or("invalid collider")?;
        let collider = &self.physics.colliders[handle];
        if collider.parent() != Some(body)
            || collider.is_sensor()
            || collider.shape().as_capsule().is_none()
        {
            return Err("character needs its own solid capsule collider".into());
        }
        let up = collider.position().rotation * Vector::Y;
        if up.dot(Vector::Y) < 0.99999 {
            return Err("character capsule must be upright".into());
        }
        let climb = nonnegative(v, "maxSlope", 0.7853982)?;
        let slide = nonnegative(v, "slideSlope", 0.7853982)?;
        if climb >= std::f32::consts::FRAC_PI_2
            || slide >= std::f32::consts::FRAC_PI_2
            || slide < climb
        {
            return Err("slope angles must satisfy 0 <= climb <= slide < pi/2".into());
        }
        let step = nonnegative(v, "stepHeight", 0.0)?;
        let snap = nonnegative(v, "snapDistance", 0.2)?;
        let controller = KinematicCharacterController {
            offset: CharacterLength::Absolute(positive(v, "offset", 0.01)?),
            max_slope_climb_angle: climb,
            min_slope_slide_angle: slide,
            autostep: if step > 0.0 {
                Some(CharacterAutostep {
                    max_height: CharacterLength::Absolute(step),
                    min_width: CharacterLength::Absolute(positive(v, "stepWidth", 0.2)?),
                    include_dynamic_bodies: false,
                })
            } else {
                None
            },
            snap_to_ground: if snap > 0.0 {
                Some(CharacterLength::Absolute(snap))
            } else {
                None
            },
            ..Default::default()
        };
        let filter = QueryFilter::default()
            .exclude_sensors()
            .exclude_rigid_body(body)
            .groups(collider.collision_groups());
        let queries = self.physics.query_pipeline_with_filter(filter);
        let mut hits = Vec::new();
        let mut overflow = false;
        let desired = vector(v, "translation", Vector::ZERO)?;
        let radius = collider.shape().as_capsule().unwrap().radius;
        let steps = (desired.length() / (radius * 0.5).max(0.01))
            .ceil()
            .max(1.0) as usize;
        if steps > 256 {
            return Err("character movement exceeds sweep budget".into());
        }
        let mut position = *collider.position();
        let mut grounded = false;
        let mut sliding = false;
        for _ in 0..steps {
            let movement = controller.move_shape(
                self.physics.integration_parameters.dt / steps as f32,
                &queries,
                collider.shape(),
                &position,
                desired / steps as f32,
                |hit| {
                    let c = &self.physics.colliders[hit.handle];
                    let n = c.user_data as u64;
                    if hits.iter().any(|h: &Value| h["collider"] == n) {
                        return;
                    }
                    if hits.len() >= 128 {
                        overflow = true;
                        return;
                    }
                    hits.push(json!({"collider":n,
                        "body":c.parent().map(|b| self.physics.bodies[b].user_data as u64),
                        "normal":hit.hit.normal1.to_array(),
                        "point":(hit.character_pos * hit.hit.witness2).to_array()}));
                },
            );
            position.translation += movement.translation;
            grounded = movement.grounded;
            sliding |= movement.is_sliding_down_slope;
        }
        if overflow {
            return Err("character collision budget exceeded".into());
        }
        Ok(
            json!({"translation":(position.translation - collider.position().translation).to_array(), "grounded":grounded,
            "sliding":sliding, "collisions":hits}),
        )
    }
    fn query(&mut self, v: &Value) -> Result<Value> {
        self.update_collisions(false)?;
        let mut filter = QueryFilter::default();
        if v["excludeSensors"].as_bool().unwrap_or(false) {
            filter.flags |= QueryFilterFlags::EXCLUDE_SENSORS;
        }
        if v.get("excludeBody").is_some() {
            filter.exclude_rigid_body = Some(self.body(v, "excludeBody")?);
        }
        if v.get("membership").is_some() {
            let m = id(v, "membership")?;
            let f = id(v, "filter")?;
            if m > u32::MAX as u64 || f > u32::MAX as u64 {
                return Err("query groups exceed 32 bits".into());
            }
            filter.groups = Some(InteractionGroups::new(
                Group::from_bits_retain(m as u32),
                Group::from_bits_retain(f as u32),
                InteractionTestMode::And,
            ));
        }
        let q = self.physics.query_pipeline_with_filter(filter);
        let output = |h: ColliderHandle, toi: f32, normal: Vector| {
            // A solid cast at a sphere's centre has no surface normal. Rapier
            // can return NaN there; preserve the hit with an explicit zero.
            let normal = if toi == 0.0 && !normal.is_finite() {
                Vector::ZERO
            } else {
                normal
            };
            json!({"collider":self.physics.colliders[h].user_data as u64,"body":self.physics.colliders[h].parent().map(|b|self.physics.bodies[b].user_data as u64),"time":toi,"normal":normal.to_array()})
        };
        match v["kind"].as_str().ok_or("query kind missing")? {
            "ray" => {
                let (ray, distance, solid) = ray_request(v)?;
                Ok(q.cast_ray_and_get_normal(&ray, distance, solid)
                    .map(|(h, hit)| output(h, hit.time_of_impact, hit.normal))
                    .unwrap_or(Value::Null))
            }
            "rays" => {
                let rays = v["rays"].as_array().ok_or("ray batch missing")?;
                if rays.len() > 256 {
                    return Err("ray batch exceeds 256 queries".into());
                }
                let rays = rays.iter().map(ray_request).collect::<Result<Vec<_>>>()?;
                Ok(Value::Array(
                    rays.iter()
                        .map(|(ray, distance, solid)| {
                            q.cast_ray_and_get_normal(ray, *distance, *solid)
                                .map(|(h, hit)| output(h, hit.time_of_impact, hit.normal))
                                .unwrap_or(Value::Null)
                        })
                        .collect(),
                ))
            }
            "shape" => {
                let sh = shape(&v["shape"], 0)?;
                let opts = rapier3d::parry::query::ShapeCastOptions {
                    max_time_of_impact: positive(v, "maxTime", 1.0)?,
                    ..Default::default()
                };
                Ok(q.cast_shape(
                    &pose(v)?,
                    vector(v, "velocity", Vector::ZERO)?,
                    sh.as_ref(),
                    opts,
                )
                .map(|(h, hit)| output(h, hit.time_of_impact, hit.normal1))
                .unwrap_or(Value::Null))
            }
            "overlap" => {
                let sh = shape(&v["shape"], 0)?;
                let pos = pose(v)?;
                Ok(json!(
                    q.intersect_shape(pos, sh.as_ref())
                        .map(|(h, _)| self.physics.colliders[h].user_data as u64)
                        .collect::<Vec<_>>()
                ))
            }
            _ => Err("unsupported query".into()),
        }
    }
}
#[derive(Default)]
struct Collector {
    events: Mutex<Vec<Value>>,
    ids: HashMap<ColliderHandle, u64>,
    overflow: AtomicBool,
}
impl Collector {
    fn push(&self, value: Value) {
        let mut events = self.events.lock().unwrap();
        if events.len() < MAX_ITEMS {
            events.push(value);
        } else {
            self.overflow.store(true, Ordering::Relaxed);
        }
    }
}
impl EventHandler for Collector {
    fn handle_soft_body_tear_event(&self, _: &SoftBodySet, _: &SoftBodyTearEvent) {
        self.overflow.store(true, Ordering::Relaxed);
    }
    fn handle_collision_event(
        &self,
        _: &RigidBodySet,
        c: &ColliderSet,
        e: CollisionEvent,
        _: Option<&ContactPair>,
    ) {
        let (a, b, started, flags) = match e {
            CollisionEvent::Started(a, b, f) => (a, b, true, f),
            CollisionEvent::Stopped(a, b, f) => (a, b, false, f),
        };
        self.push(json!({"kind":"collision","collider1":c.get(a).map(|c|c.user_data as u64).or_else(||self.ids.get(&a).copied()),"collider2":c.get(b).map(|c|c.user_data as u64).or_else(||self.ids.get(&b).copied()),"started":started,"sensor":flags.contains(CollisionEventFlags::SENSOR)}));
    }

    fn handle_contact_force_event(
        &self,
        dt: f32,
        _: &RigidBodySet,
        c: &ColliderSet,
        pair: &ContactPair,
        total: f32,
    ) {
        let event = ContactForceEvent::from_contact_pair(dt, pair, total);
        self.push(json!({"kind":"contact","collider1":c[pair.collider1].user_data as u64,"collider2":c[pair.collider2].user_data as u64,"force":event.total_force.to_array(),"magnitude":event.total_force_magnitude}));
    }
}
struct Lines(Vec<Value>, bool);
impl DebugRenderBackend for Lines {
    fn draw_line(&mut self, object: DebugRenderObject, a: Vector, b: Vector, color: DebugColor) {
        if self.0.len() < MAX_ITEMS {
            self.0
                .push(json!({"a":a.to_array(),"b":b.to_array(),"color":color,"kind":match object {DebugRenderObject::Collider(..)|DebugRenderObject::ColliderAabb(..)=>"collider",DebugRenderObject::ImpulseJoint(..)|DebugRenderObject::MultibodyJoint(..)=>"joint",DebugRenderObject::ContactPair(..)=>"contact",DebugRenderObject::RigidBody(..)=>"body",DebugRenderObject::SoftBody(..)=>"softBody"}}));
        } else {
            self.1 = true;
        }
    }
}
struct Registry {
    next: u64,
    worlds: BTreeMap<u64, World>,
}
static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
fn dispatch(v: Value) -> Result<Value> {
    let mut r = REGISTRY
        .get_or_init(|| {
            Mutex::new(Registry {
                next: 1,
                worlds: BTreeMap::new(),
            })
        })
        .lock()
        .map_err(|_| "physics registry poisoned")?;
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<Value> {
        match v["op"].as_str().ok_or("operation missing")? {
            "create" => {
                if r.worlds.len() >= 256 {
                    return Err("world budget exceeded".into());
                }
                let w = World::new(&v)?;
                let n = r.next;
                if n > (usize::MAX as u64).min(i64::MAX as u64) {
                    return Err("world handle space exhausted".into());
                }
                r.next = r
                    .next
                    .checked_add(1)
                    .ok_or("world handle space exhausted")?;
                r.worlds.insert(n, w);
                Ok(json!(n))
            }
            "close" => {
                r.worlds.remove(&id(&v, "world")?);
                Ok(Value::Null)
            }
            "restore" => {
                let n = id(&v, "world")?;
                if !r.worlds.contains_key(&n) {
                    return Err("invalid world".into());
                }
                let snapshot = &v["snapshot"];
                if snapshot["version"] != 1 || snapshot["rapier"] != "0.36.0" {
                    return Err("incompatible snapshot".into());
                }
                let bytes: Vec<u8> =
                    serde_json::from_value(snapshot["bytes"].clone()).map_err(|e| e.to_string())?;
                if bytes.len() > MAX_BYTES {
                    return Err("snapshot budget exceeded".into());
                }
                use bincode::Options;
                let world: World = bincode::DefaultOptions::new()
                    .with_fixint_encoding()
                    .with_limit(MAX_BYTES as u64)
                    .reject_trailing_bytes()
                    .deserialize(&bytes)
                    .map_err(|e| e.to_string())?;
                if world.physics.integration_parameters.dt
                    != r.worlds[&n].physics.integration_parameters.dt
                {
                    return Err("snapshot timestep differs from world".into());
                }
                if world.bodies.len() > MAX_ITEMS
                    || world.colliders.len() > MAX_ITEMS
                    || world.joints.len() > MAX_ITEMS
                    || world.pending_events.len() > MAX_ITEMS
                    || world.removed_colliders.len() > MAX_ITEMS
                {
                    return Err("snapshot resource budget exceeded".into());
                }
                r.worlds.insert(n, world);
                Ok(Value::Null)
            }
            "counts" => Ok(
                json!({"worlds":r.worlds.len(),"bodies":r.worlds.values().map(|w|w.bodies.len()).sum::<usize>()}),
            ),
            _ => r
                .worlds
                .get_mut(&id(&v, "world")?)
                .ok_or("invalid or closed world")?
                .command(&v),
        }
    }));
    match result {
        Ok(result) => result,
        Err(_) => {
            if let Some(id) = v["world"].as_u64() {
                r.worlds.remove(&id);
            }
            Err("native physics panic; affected world released".into())
        }
    }
}
/// Input is a NUL terminated UTF-8 request. The returned string must be freed once.
///
/// # Safety
/// You must pass null or a valid NUL terminated string for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zyren_physics_call(input: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if input.is_null() {
            return Err("null request".into());
        }
        let bytes = unsafe { CStr::from_ptr(input) }.to_bytes();
        if bytes.len() > MAX_BYTES {
            return Err("request budget exceeded".into());
        }
        let v = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        dispatch(v)
    });
    let output = match result {
        Ok(Ok(v)) => json!({"protocol":1,"value":v}),
        Ok(Err(e)) => json!({"protocol":1,"error":e}),
        Err(_) => json!({"protocol":1,"error":"native physics panic"}),
    };
    CString::new(output.to_string()).unwrap().into_raw()
}
/// # Safety
/// Pass null or an unfreed pointer returned by `zyren_physics_call`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zyren_physics_free(output: *mut c_char) {
    if !output.is_null() {
        drop(unsafe { CString::from_raw(output) });
    }
}

/// GC fallback. Tokens encode registry IDs and are never dereferenced.
#[unsafe(no_mangle)]
pub extern "C" fn zyren_physics_finalize(token: *mut std::ffi::c_void) {
    if let Some(registry) = REGISTRY.get()
        && let Ok(mut registry) = registry.lock()
    {
        registry.worlds.remove(&(token as usize as u64));
    }
}

#[cfg(test)]
mod query_cache_tests;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validation_is_transactional_and_handles_do_not_recycle() {
        let mut world = World::new(&json!({})).unwrap();
        assert!(
            world
                .command(&json!({"op":"body","kind":"invalid"}))
                .is_err()
        );
        assert!(world.bodies.is_empty());
        let a = world
            .command(&json!({"op":"body"}))
            .unwrap()
            .as_u64()
            .unwrap();
        assert!(
            world
                .command(&json!({"op":"collider","body":a,"shape":{"type":"sphere","radius":-1}}))
                .is_err()
        );
        assert!(world.colliders.is_empty());
        world.command(&json!({"op":"removeBody","body":a})).unwrap();
        let b = world
            .command(&json!({"op":"body"}))
            .unwrap()
            .as_u64()
            .unwrap();
        assert!(b > a);
        assert!(
            world
                .command(&json!({"op":"bodyUpdate","body":a,"action":"wake"}))
                .is_err()
        );
    }
    #[test]
    fn malformed_and_nonfinite_inputs_are_rejected() {
        for v in [json!({"dt":0}), json!({"dt":1}), json!({"gravity":[0,0]})] {
            assert!(World::new(&v).is_err());
        }
        assert!(pose(&json!({"rotation":[0,0,0,0]})).is_err());
        assert!(
            shape(
                &json!({"type":"convex","vertices":[[0,0,0],[0,0,0],[0,0,0],[0,0,0]]}),
                0
            )
            .is_err()
        );
        assert!(shape(&json!({"type":"compound","children":[]}), 0).is_err());
    }
    #[test]
    fn ffi_errors_are_owned_and_freeable() {
        let text = CString::new("{").unwrap();
        let output = unsafe { zyren_physics_call(text.as_ptr()) };
        let response: Value =
            serde_json::from_slice(unsafe { CStr::from_ptr(output) }.to_bytes()).unwrap();
        assert!(response["error"].is_string());
        unsafe {
            zyren_physics_free(output);
            zyren_physics_free(std::ptr::null_mut());
        }
    }
}
