use super::*;

#[derive(Debug)]
struct FloorTravel {
    minimum_height: f64,
    maximum_height: f64,
    distance_fraction: f64,
    grounded_ticks: usize,
}

fn floor_travel(scale: f64, floor_half_width: f64, direction: [f64; 2]) -> FloorTravel {
    floor_travel_with_geometry(scale, floor_half_width, direction, "box")
}

fn floor_travel_with_geometry(
    scale: f64,
    floor_half_width: f64,
    direction: [f64; 2],
    geometry: &str,
) -> FloorTravel {
    let mut world = World::new(&json!({"dt":0.02,"gravity":[0,-9.81*scale,0]})).unwrap();
    let floor = world
        .command(&json!({"op":"body","kind":"fixed",
        "position":[0,-0.5*scale,0]}))
        .unwrap();
    let w = floor_half_width * scale;
    let h = 0.5 * scale;
    let floor_shape = match geometry {
        "box" => json!({"type":"box","halfExtents":[w,h,w]}),
        "convex" => json!({"type":"convex","vertices":[
            [-w,-h,-w],[w,-h,-w],[w,-h,w],[-w,-h,w],
            [-w,h,-w],[w,h,-w],[w,h,w],[-w,h,w]]}),
        "mesh" => json!({"type":"mesh","vertices":[[-w,h,-w],[w,h,-w],[w,h,w],[-w,h,w]],
            "triangles":[[0,2,1],[0,3,2]]}),
        _ => panic!("unknown floor fixture"),
    };
    world
        .command(&json!({"op":"collider","body":floor,"shape":floor_shape}))
        .unwrap();
    let body = world
        .command(&json!({"op":"body","kind":"kinematicPosition",
        "position":[0,0.81*scale,0]}))
        .unwrap();
    let collider = world
        .command(&json!({"op":"collider","body":body,
        "shape":{"type":"capsule","halfHeight":0.5*scale,"radius":0.3*scale}}))
        .unwrap();
    let mut vertical_speed = 0.0;
    let mut grounded = false;
    let mut grounded_ticks = 0;
    let mut minimum_height = f64::INFINITY;
    let mut maximum_height = f64::NEG_INFINITY;
    let mut requested_distance = 0.0;
    let mut final_position = [0.0; 2];
    let yaw = direction[0].atan2(direction[1]);
    for tick in 0..160 {
        vertical_speed -= 9.81 * scale * 0.02;
        let horizontal = if tick < 10 {
            0.0
        } else if tick < 20 {
            ((tick - 10) as f64 * 0.001 + 0.0005) * scale
        } else {
            0.01 * scale
        };
        requested_distance += horizontal;
        let vertical = if tick < 10 && grounded {
            -0.004 * scale
        } else {
            vertical_speed * 0.02
        };
        let mut command = json!({"op":"characterMoveTarget","body":body,"collider":collider,
            "translation":[direction[0]*horizontal,vertical,direction[1]*horizontal],
            "offset":0.01*scale,"maxSlope":std::f64::consts::FRAC_PI_4,
            "slideSlope":std::f64::consts::FRAC_PI_4,"stepHeight":0.25*scale,
            "stepWidth":0.2*scale,"snapDistance":0.2*scale});
        if tick >= 10 {
            command["rotation"] = json!([0, (yaw / 2.0).sin(), 0, (yaw / 2.0).cos()]);
        }
        let result = world.command(&command).unwrap();
        grounded = result["grounded"].as_bool().unwrap();
        if grounded {
            grounded_ticks += 1;
            if vertical_speed < 0.0 {
                vertical_speed = 0.0;
            }
        }
        world.command(&json!({"op":"step"})).unwrap();
        let state = world
            .command(&json!({"op":"bodyState","body":body}))
            .unwrap();
        let height = state["position"][1].as_f64().unwrap() / scale;
        minimum_height = minimum_height.min(height);
        maximum_height = maximum_height.max(height);
        final_position = [
            state["position"][0].as_f64().unwrap(),
            state["position"][2].as_f64().unwrap(),
        ];
        assert!(world.physics.quarantine().is_empty());
    }
    let projected_distance = (final_position[0] * direction[0] + final_position[1] * direction[1])
        / (direction[0] * direction[0] + direction[1] * direction[1]);
    FloorTravel {
        minimum_height,
        maximum_height,
        distance_fraction: projected_distance / requested_distance,
        grounded_ticks,
    }
}

#[test]
fn small_diagonal_intent_keeps_capsule_clear_and_moving() {
    let travel = floor_travel(1.0, 20.0, [-1.0, -1.0]);
    assert!(travel.minimum_height >= 0.799, "{travel:?}");
    assert!(travel.maximum_height <= 0.821, "{travel:?}");
    assert!(travel.distance_fraction >= 0.95, "{travel:?}");
    assert!(travel.grounded_ticks >= 150, "{travel:?}");
}

#[test]
fn floor_travel_preserves_clearance_and_progress_across_scales_and_directions() {
    let mut failures = Vec::new();
    for scale in [0.25, 1.0, 4.0] {
        for floor in [8.0, 20.0, 64.0] {
            for direction in [
                [-1.0, -1.0],
                [-1.0, 0.0],
                [-1.0, 1.0],
                [0.0, -1.0],
                [0.0, 1.0],
                [1.0, -1.0],
                [1.0, 0.0],
                [1.0, 1.0],
            ] {
                let travel = floor_travel(scale, floor, direction);
                if travel.minimum_height < 0.799
                    || travel.maximum_height > 0.821
                    || travel.distance_fraction < 0.95
                    || travel.grounded_ticks < 150
                {
                    failures.push(format!(
                        "scale={scale} floor={floor} direction={direction:?}: {travel:?}"
                    ));
                }
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} of 72 floor cases failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn authored_convex_and_triangle_floors_keep_capsules_clear_and_moving() {
    let mut failures = Vec::new();
    for geometry in ["convex", "mesh"] {
        for scale in [0.25, 1.0, 4.0] {
            for floor in [8.0, 20.0, 64.0] {
                for direction in [
                    [-1.0, -1.0],
                    [-1.0, 0.0],
                    [-1.0, 1.0],
                    [0.0, -1.0],
                    [0.0, 1.0],
                    [1.0, -1.0],
                    [1.0, 0.0],
                    [1.0, 1.0],
                ] {
                    let travel = floor_travel_with_geometry(scale, floor, direction, geometry);
                    if travel.minimum_height < 0.799
                        || travel.maximum_height > 0.821
                        || travel.distance_fraction < 0.95
                        || travel.grounded_ticks < 150
                    {
                        failures.push(format!("{geometry} scale={scale} floor={floor} direction={direction:?}: {travel:?}"));
                    }
                }
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} of 144 authored floor cases failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}
