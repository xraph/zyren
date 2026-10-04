use super::*;

fn fixture() -> (World, Vec<(u64, u64)>) {
    let mut world = World::new(&json!({"dt":0.02})).unwrap();
    for (position, size) in [
        ([0.0, -0.5, 0.0], [8.0, 0.5, 8.0]),
        ([2.0, 1.0, 0.0], [0.1, 1.0, 4.0]),
    ] {
        let body = world
            .command(&json!({"op":"body","kind":"fixed","position":position}))
            .unwrap();
        world
            .command(
                &json!({"op":"collider","body":body,"shape":{"type":"box","halfExtents":size}}),
            )
            .unwrap();
    }
    let mut characters = Vec::new();
    for x in [-0.5, 0.5] {
        let body = world
            .command(&json!({"op":"body","kind":"kinematicPosition","position":[x,0.81,0]}))
            .unwrap()
            .as_u64()
            .unwrap();
        let collider = world
            .command(&json!({"op":"collider","body":body,"position":[0.1,0,0],
            "shape":{"type":"capsule","halfHeight":0.5,"radius":0.3}}))
            .unwrap()
            .as_u64()
            .unwrap();
        characters.push((body, collider));
    }
    let dynamic = world
        .command(&json!({"op":"body","position":[0,1,2],"velocity":[0,0,-0.1]}))
        .unwrap();
    world
        .command(&json!({"op":"collider","body":dynamic,"shape":{"type":"sphere","radius":0.35}}))
        .unwrap();
    (world, characters)
}

fn sweep(body: u64, collider: u64, tick: usize) -> Value {
    let angle = tick as f64 * 0.04;
    json!({"op":"characterMoveTarget","body":body,"collider":collider,
        "translation":[angle.sin()*0.03,-0.01,angle.cos()*0.03],
        "rotation":[0,(angle/2.0).sin(),0,(angle/2.0).cos()],
        "offset":0.01,"maxSlope":0.7,"slideSlope":0.7,"stepHeight":0.25,"stepWidth":0.2,"snapDistance":0.2})
}

#[test]
fn target_queries_preserve_current_geometry_and_failure_invalidation() {
    let (mut world, actors) = fixture();
    world.command(&json!({"op":"step"})).unwrap();
    let ray = json!({"op":"query","kind":"ray","origin":[-0.4,0.81,-3],"direction":[0,0,1],"maxDistance":6});
    let before = world.command(&ray).unwrap();
    assert_eq!(before["collider"], actors[0].1);
    for &(body, collider) in &actors {
        world.command(&sweep(body, collider, 1)).unwrap();
    }
    assert_eq!(world.command(&ray).unwrap(), before);
    assert_eq!(world.collision_refreshes, 2);
    let mut invalid = sweep(actors[0].0, actors[0].1, 1);
    invalid["translation"] = json!([10000, 0, 0]);
    assert!(world.command(&invalid).is_err());
    assert!(world.queries_dirty);
    world.command(&ray).unwrap();
    assert_eq!(world.collision_refreshes, 3);
    world.command(&json!({"op":"bodyUpdate","body":actors[0].0,"action":"teleport","position":[-5,0.81,0]})).unwrap();
    assert_ne!(world.command(&ray).unwrap()["collider"], actors[0].1);
    assert_eq!(world.collision_refreshes, 4);
}

#[test]
fn interleaved_character_queries_keep_contacts_linked_through_600_steps() {
    let (mut world, actors) = fixture();
    for tick in 0..600 {
        for &(body, collider) in &actors {
            world.command(&sweep(body, collider, tick)).unwrap();
        }
        let result = world.command(&json!({"op":"step"})).unwrap();
        assert_eq!(result["poses"].as_array().unwrap().len(), 5);
        assert!(world.physics.quarantine().is_empty());
    }
    assert_eq!(world.collision_refreshes, 601);
}

#[test]
fn sleeping_target_and_collision_changes_survive_save_before_step() {
    let (mut world, actors) = fixture();
    for _ in 0..50 {
        world.command(&json!({"op":"step"})).unwrap();
    }
    for &(body, _) in &actors {
        world
            .command(&json!({"op":"bodyUpdate","body":body,"action":"sleep"}))
            .unwrap();
    }
    for &(body, collider) in &actors {
        world.command(&sweep(body, collider, 1)).unwrap();
    }
    let mut restored: World = bincode::deserialize(&bincode::serialize(&world).unwrap()).unwrap();
    restored.mass_revision = world.mass_revision;
    for tick in 0..150 {
        if tick == 30 || tick == 60 {
            let edit = json!({"op":"colliderUpdate","collider":4,"sensor":tick==30,"membership":0xffffffffu32,"filter":0xffffffffu32});
            world.command(&edit).unwrap();
            restored.command(&edit).unwrap();
        }
        if tick == 90 {
            let remove = json!({"op":"removeCollider","collider":4});
            world.command(&remove).unwrap();
            restored.command(&remove).unwrap();
        }
        if tick > 0 {
            for &(body, collider) in &actors {
                let movement = sweep(body, collider, tick);
                assert_eq!(
                    world.command(&movement).unwrap(),
                    restored.command(&movement).unwrap()
                );
            }
        }
        assert_eq!(
            world.command(&json!({"op":"step"})).unwrap(),
            restored.command(&json!({"op":"step"})).unwrap(),
            "restored tick {tick}"
        );
    }
}

#[test]
fn query_refresh_preserves_joint_collision_filtering_and_anchor_wake() {
    let mut world = World::new(&json!({"gravity":[0,0,0],"dt":0.02})).unwrap();
    let anchor = world.command(&json!({"op":"body","kind":"fixed"})).unwrap();
    let body = world.command(&json!({"op":"body"})).unwrap();
    let mut colliders = Vec::new();
    for owner in [&anchor, &body] {
        colliders.push(
            world
                .command(&json!({"op":"collider","body":owner,
            "shape":{"type":"sphere","radius":0.5}}))
                .unwrap(),
        );
    }
    world
        .command(&json!({"op":"joint","kind":"fixed","body1":anchor,"body2":body,"contacts":false}))
        .unwrap();
    world.command(&json!({"op":"step"})).unwrap();
    world
        .command(&json!({"op":"colliderUpdate","collider":colliders[0],"friction":0.6,"membership":0xffffffffu32,"filter":0xffffffffu32}))
        .unwrap();
    let query =
        json!({"op":"query","kind":"ray","origin":[0,0,5],"direction":[0,0,-1],"maxDistance":10});
    world.command(&query).unwrap();
    assert_eq!(
        world.command(&json!({"op":"drainEvents"})).unwrap(),
        json!([]),
        "connected bodies exclude contacts during queries too"
    );
    world
        .command(&json!({"op":"bodyUpdate","body":body,"action":"sleep"}))
        .unwrap();
    world.command(&json!({"op":"step"})).unwrap();
    assert_eq!(
        world
            .command(&json!({"op":"bodyState","body":body}))
            .unwrap()["sleeping"],
        true
    );
    world
        .command(&json!({"op":"bodyUpdate","body":anchor,"action":"teleport","position":[2,0,0]}))
        .unwrap();
    world.command(&query).unwrap();
    assert_eq!(
        world
            .command(&json!({"op":"bodyState","body":body}))
            .unwrap()["sleeping"],
        false,
        "moving a fixed joint anchor must wake its actual partner"
    );
    world.command(&json!({"op":"step"})).unwrap();
    assert!(
        world
            .command(&json!({"op":"bodyState","body":body}))
            .unwrap()["position"][0]
            .as_f64()
            .unwrap()
            > 0.0
    );
}
