use super::*;

const FIELDS: [&str; 13] = [
    "body",
    "kind",
    "position",
    "rotation",
    "velocity",
    "angularVelocity",
    "sleeping",
    "ccd",
    "mass",
    "centerOfMass",
    "localCenterOfMass",
    "inverseInertia",
    "massPropertiesRevision",
];

fn assert_states(dense: &Value, legacy: &Value) {
    assert_eq!(dense["stateEncoding"], 1);
    let rows = dense["poses"].as_array().unwrap();
    let old = legacy.as_array().unwrap();
    assert_eq!(rows.len(), old.len());
    for (row, state) in rows.iter().zip(old) {
        assert_eq!(row.as_array().unwrap().len(), FIELDS.len());
        for (index, field) in FIELDS.iter().enumerate() {
            assert_eq!(row[index], state[*field], "field {field}");
        }
    }
}

#[test]
fn dense_states_preserve_all_fields_and_native_snapshot_bytes() {
    let mut world = World::new(&json!({"gravity":[0,-9.81,0]})).unwrap();
    for (i, kind) in ["fixed", "dynamic", "kinematicPosition", "kinematicVelocity"]
        .iter()
        .enumerate()
    {
        let id = world
            .command(&json!({"op":"body", "kind":kind,
            "position":[i * 3,3,0], "rotation":[0.1,0.2,0.3,0.9],
            "velocity":[0.2,0.1,0.3], "angularVelocity":[0.1,0.2,0.3],
            "mass":2, "inertia":[1,2,3], "centerOfMass":[0.1,0.2,0.3],
            "ccd":true}))
            .unwrap();
        world
            .command(&json!({"op":"collider", "body":id,
            "position":[0.1,0.2,0.3], "shape":{"type":"box","halfExtents":[0.5,0.4,0.3]}}))
            .unwrap();
    }
    let before = bincode::serialize(&world).unwrap();
    let dense = world.command(&json!({"op":"posesDense"})).unwrap();
    assert_states(&dense, &world.poses());
    assert_eq!(bincode::serialize(&world).unwrap(), before);
    assert!(dense.to_string().len() < world.poses().to_string().len());

    let mut legacy: World = bincode::deserialize(&before).unwrap();
    // Revision is transient metadata, reset by snapshot restoration. Both
    // encodings here represent the same live world generation.
    legacy.mass_revision = world.mass_revision;
    for _ in 0..120 {
        let next = world.command(&json!({"op":"stepDense"})).unwrap();
        let old = legacy.command(&json!({"op":"step"})).unwrap();
        assert_states(&next, &old["poses"]);
        assert_eq!(next["events"], old["events"]);
        assert_eq!(
            bincode::serialize(&world).unwrap(),
            bincode::serialize(&legacy).unwrap()
        );
        assert!(!world.queries_dirty);
    }
}

#[test]
fn dense_step_integrates_transient_forces_once_and_preserves_query_cache() {
    let mut world = World::new(&json!({"gravity":[0,0,0],"dt":0.02})).unwrap();
    let body = world
        .command(&json!({"op":"body","mass":2,"inertia":[1,1,1]}))
        .unwrap();
    world
        .command(&json!({"op":"queueForces","commands":[{
        "body":body,"linear":[10,0,0],"angular":[0,0,0],"wake":true}]}))
        .unwrap();
    let dense = world.command(&json!({"op":"posesDense"})).unwrap();
    assert_states(&dense, &world.poses());
    world.command(&json!({"op":"stepDense"})).unwrap();
    let first = world
        .command(&json!({"op":"bodyState","body":body}))
        .unwrap();
    assert!(first["velocity"][0].as_f64().unwrap() > 0.09);
    assert!(world.transient_forces.is_empty());
    world
        .command(&json!({"op":"query","kind":"ray","origin":[0,0,5],
        "direction":[0,0,-1],"maxDistance":10}))
        .unwrap();
    assert_eq!(world.collision_refreshes, 0);
    world.command(&json!({"op":"stepDense"})).unwrap();
    assert_eq!(
        world
            .command(&json!({"op":"bodyState","body":body}))
            .unwrap()["velocity"],
        first["velocity"]
    );
}
