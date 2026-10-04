use super::*;

fn ray(world: &mut World) -> Value {
    world
        .command(&json!({"op":"query", "kind":"ray", "origin":[0,0,5],
        "direction":[0,0,-1], "maxDistance":10}))
        .unwrap()
}

fn sphere(world: &mut World, x: f32) -> (u64, u64) {
    let body = world
        .command(&json!({"op":"body", "position":[x,0,0]}))
        .unwrap()
        .as_u64()
        .unwrap();
    let collider = world
        .command(&json!({"op":"collider", "body":body,
        "shape":{"type":"sphere", "radius":0.5}}))
        .unwrap()
        .as_u64()
        .unwrap();
    (body, collider)
}

#[test]
fn clean_queries_reuse_step_geometry_until_native_mutation() {
    let mut world = World::new(&json!({"gravity":[0,0,0]})).unwrap();
    let (body, collider) = sphere(&mut world, 0.0);
    world.command(&json!({"op":"step"})).unwrap();
    for _ in 0..100 {
        assert_eq!(ray(&mut world)["collider"], collider);
    }
    assert_eq!(world.collision_refreshes, 0);
    world
        .command(&json!({"op":"bodyUpdate", "body":body, "action":"teleport", "position":[5,0,0]}))
        .unwrap();
    assert!(ray(&mut world).is_null());
    assert_eq!(world.collision_refreshes, 1);
    assert!(ray(&mut world).is_null());
    assert_eq!(world.collision_refreshes, 1);
    assert!(
        world
            .command(&json!({"op":"bodyUpdate", "body":body, "action":"damping", "linear":-1}))
            .is_err()
    );
    assert!(ray(&mut world).is_null());
    assert_eq!(world.collision_refreshes, 2);
    let (_, other) = sphere(&mut world, 0.0);
    assert_eq!(ray(&mut world)["collider"], other);
    world
        .command(&json!({"op":"removeCollider", "collider":other}))
        .unwrap();
    assert!(ray(&mut world).is_null());
}

#[test]
fn collider_edits_refresh_mass_and_contact_events_once() {
    let mut world = World::new(&json!({"gravity":[0,0,0]})).unwrap();
    let (body, collider) = sphere(&mut world, 0.0);
    let (other, _) = sphere(&mut world, 0.5);
    ray(&mut world);
    let start = world.command(&json!({"op":"drainEvents"})).unwrap();
    assert!(
        start
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["kind"] == "collision" && v["started"] == true)
    );
    let old_mass = world
        .command(&json!({"op":"bodyState", "body":body}))
        .unwrap()["mass"]
        .as_f64()
        .unwrap();
    world
        .command(&json!({"op":"colliderUpdate", "collider":collider,
        "density":3, "membership":4294967295u64, "filter":4294967295u64}))
        .unwrap();
    ray(&mut world);
    let new_mass = world
        .command(&json!({"op":"bodyState", "body":body}))
        .unwrap()["mass"]
        .as_f64()
        .unwrap();
    assert!(new_mass > old_mass * 2.9);
    world.command(&json!({"op":"drainEvents"})).unwrap();
    for _ in 0..10 {
        ray(&mut world);
    }
    assert_eq!(
        world.command(&json!({"op":"drainEvents"})).unwrap(),
        json!([])
    );
    world
        .command(&json!({"op":"removeBody", "body":other}))
        .unwrap();
    ray(&mut world);
    let stop = world.command(&json!({"op":"drainEvents"})).unwrap();
    assert!(
        stop.as_array()
            .unwrap()
            .iter()
            .any(|v| v["kind"] == "collision" && v["started"] == false)
    );
    ray(&mut world);
    assert_eq!(
        world.command(&json!({"op":"drainEvents"})).unwrap(),
        json!([])
    );
}

#[test]
fn snapshot_wire_bytes_exclude_query_cache_and_restore_refreshes() {
    let mut world = World::new(&json!({"gravity":[0,0,0]})).unwrap();
    let (_, collider) = sphere(&mut world, 0.0);
    world.command(&json!({"op":"step"})).unwrap();
    let bytes = bincode::serialize(&world).unwrap();
    world.queries_dirty = true;
    world.collision_refreshes = 123;
    assert_eq!(bincode::serialize(&world).unwrap(), bytes);
    let mut restored: World = bincode::deserialize(&bytes).unwrap();
    assert!(restored.queries_dirty);
    assert_eq!(ray(&mut restored)["collider"], collider);
    assert_eq!(restored.collision_refreshes, 1);
    assert_eq!(ray(&mut restored)["collider"], collider);
    assert_eq!(restored.collision_refreshes, 1);
}

#[test]
fn kinematic_targets_and_new_dynamic_bodies_still_advance_after_queries() {
    let mut world = World::new(&json!({"gravity":[0,0,0]})).unwrap();
    let body = world
        .command(&json!({"op":"body", "kind":"kinematicPosition"}))
        .unwrap()
        .as_u64()
        .unwrap();
    let collider = world
        .command(&json!({"op":"collider", "body":body,
        "shape":{"type":"sphere", "radius":0.5}}))
        .unwrap()
        .as_u64()
        .unwrap();
    world.command(&json!({"op":"step"})).unwrap();
    world
        .command(&json!({"op":"bodyUpdate", "body":body, "action":"target", "position":[5,0,0]}))
        .unwrap();
    // A target does not teleport current collision geometry before its step.
    assert_eq!(ray(&mut world)["collider"], collider);
    world.command(&json!({"op":"step"})).unwrap();
    assert!(ray(&mut world).is_null());
    let (moving, _) = sphere(&mut world, 0.0);
    world
        .command(&json!({"op":"bodyUpdate", "body":moving, "action":"velocity", "value":[1,0,0]}))
        .unwrap();
    for _ in 0..20 {
        ray(&mut world);
    }
    world.command(&json!({"op":"step"})).unwrap();
    let state = world
        .command(&json!({"op":"bodyState", "body":moving}))
        .unwrap();
    assert!(state["position"][0].as_f64().unwrap() > 0.01);
}
