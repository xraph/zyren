use gpu3d_runtime::interop::{LeaseLedger, SurfaceConfig, SurfaceError, SurfaceRegistry};

fn config() -> SurfaceConfig {
    SurfaceConfig {
        width: 64,
        height: 64,
        buffer_limit: 3,
        max_in_flight: 2,
        memory_limit: 1024 * 1024,
    }
}

#[test]
fn reuse_waits_for_both_gpu_and_consumer_in_either_order() {
    for gpu_first in [true, false] {
        let mut ledger = LeaseLedger::new(1).unwrap();
        let lease = ledger.acquire(1).unwrap();
        ledger.retire(lease).unwrap();
        if gpu_first {
            ledger.gpu_completed(lease).unwrap();
        } else {
            ledger.consumer_released(lease).unwrap();
        }
        assert!(!ledger.is_reusable(lease).unwrap());
        assert_eq!(ledger.acquire(1), Err(SurfaceError::Backpressure));
        if gpu_first {
            ledger.consumer_released(lease).unwrap();
        } else {
            ledger.gpu_completed(lease).unwrap();
        }
        assert!(ledger.is_reusable(lease).unwrap());
        let next = ledger.acquire(2).unwrap();
        assert_ne!(next, lease);
        assert_eq!(
            ledger.consumer_released(lease),
            Err(SurfaceError::StaleLease)
        );
    }
}

#[test]
fn duplicate_completion_does_not_release_another_lease() {
    let mut ledger = LeaseLedger::new(2).unwrap();
    let first = ledger.acquire(1).unwrap();
    let second = ledger.acquire(1).unwrap();
    ledger.gpu_completed(first).unwrap();
    assert_eq!(
        ledger.gpu_completed(first),
        Err(SurfaceError::DuplicateCompletion)
    );
    ledger.consumer_released(first).unwrap();
    ledger.retire(first).unwrap();
    assert!(!ledger.is_reusable(second).unwrap());
}

#[test]
fn bounded_requests_coalesce_to_the_latest_frame() {
    let mut registry = SurfaceRegistry::default();
    let key = registry.reserve(config()).unwrap();
    let surface = registry.get_mut(key).unwrap();
    surface.activate().unwrap();
    let first = surface.begin_frame(1).unwrap();
    let second = surface.begin_frame(2).unwrap();
    for id in 3..10_003 {
        surface.queue_frame(id).unwrap();
    }
    assert_eq!(surface.pending_frame(), Some(10_002));
    assert_eq!(surface.coalesced_frames(), 9999);
    assert_eq!(surface.begin_pending(), Err(SurfaceError::Backpressure));
    assert!(surface.gpu_completed(first).unwrap());
    assert!(surface.gpu_completed(second).unwrap());
    surface.consumer_released(first).unwrap();
    let third = surface.begin_pending().unwrap().unwrap();
    assert_eq!(surface.frame_id(third).unwrap(), 10_002);
    assert!(surface.allocated_slots() <= 3);
}

#[test]
fn out_of_order_and_old_epoch_frames_never_replace_the_latest() {
    let mut registry = SurfaceRegistry::default();
    let key = registry.reserve(config()).unwrap();
    let surface = registry.get_mut(key).unwrap();
    surface.activate().unwrap();
    let first = surface.begin_frame(1).unwrap();
    let second = surface.begin_frame(2).unwrap();
    assert!(surface.gpu_completed(second).unwrap());
    assert!(!surface.gpu_completed(first).unwrap());
    let third = surface.begin_frame(3).unwrap();
    surface.resize(65, 47).unwrap();
    assert!(!surface.gpu_completed(third).unwrap());
    assert_eq!(surface.epoch(), 2);
    assert_eq!(surface.published(), None);
}

#[test]
fn resize_and_close_keep_consumer_held_buffers_until_release() {
    let mut registry = SurfaceRegistry::default();
    let key = registry.reserve(config()).unwrap();
    let surface = registry.get_mut(key).unwrap();
    surface.activate().unwrap();
    let mut held = vec![];
    for id in 1..=3 {
        let lease = surface.begin_frame(id).unwrap();
        surface.gpu_completed(lease).unwrap();
        held.push(lease);
    }
    surface.resize(128, 64).unwrap();
    assert_eq!(surface.begin_frame(4), Err(SurfaceError::Backpressure));
    surface.close().unwrap();
    assert!(!surface.is_drained());
    for lease in held {
        surface.consumer_released(lease).unwrap();
    }
    assert!(surface.is_drained());
    surface.close().unwrap();
    let replacement = registry.reserve(config()).unwrap();
    assert_eq!(replacement.slot, key.slot);
    assert_ne!(replacement.generation, key.generation);
    assert!(matches!(registry.get_mut(key), Err(SurfaceError::StaleKey)));
}

#[test]
fn cancelled_creation_and_suspension_reject_new_work() {
    let mut registry = SurfaceRegistry::default();
    let key = registry.reserve(config()).unwrap();
    let surface = registry.get_mut(key).unwrap();
    surface.close().unwrap();
    assert_eq!(surface.activate(), Err(SurfaceError::Closed));
    assert!(surface.is_drained());
    let replacement = registry.reserve(config()).unwrap();
    let surface = registry.get_mut(replacement).unwrap();
    surface.activate().unwrap();
    let lease = surface.begin_frame(1).unwrap();
    surface.suspend().unwrap();
    assert_eq!(surface.begin_frame(2), Err(SurfaceError::Suspended));
    assert!(!surface.gpu_completed(lease).unwrap());
    surface.resume().unwrap();
    assert!(surface.begin_frame(3).is_ok());
}

#[test]
fn extent_budget_includes_old_held_frames() {
    let mut registry = SurfaceRegistry::default();
    let mut limits = config();
    limits.width = 128;
    limits.height = 128;
    limits.memory_limit = 140000;
    let key = registry.reserve(limits).unwrap();
    let surface = registry.get_mut(key).unwrap();
    surface.activate().unwrap();
    let held = surface.begin_frame(1).unwrap();
    surface.gpu_completed(held).unwrap();
    let second = surface.begin_frame(2).unwrap();
    surface.gpu_completed(second).unwrap();
    assert_eq!(
        surface.resize(4096, 4096),
        Err(SurfaceError::BudgetExceeded)
    );
    assert_eq!(surface.epoch(), 1);
    surface.resize(100, 100).unwrap();
    assert_eq!(surface.begin_frame(3), Err(SurfaceError::Backpressure));
    surface.consumer_released(held).unwrap();
    assert!(surface.begin_frame(3).is_ok());
}

#[test]
fn timeout_stops_publication_but_keeps_in_flight_ownership() {
    let mut registry = SurfaceRegistry::default();
    let key = registry.reserve(config()).unwrap();
    let surface = registry.get_mut(key).unwrap();
    surface.activate().unwrap();
    let visible = surface.begin_frame(1).unwrap();
    surface.gpu_completed(visible).unwrap();
    let flight = surface.begin_frame(2).unwrap();
    surface.timeout().unwrap();
    assert_eq!(surface.terminal_error(), Some(SurfaceError::TimedOut));
    assert_eq!(surface.begin_frame(3), Err(SurfaceError::Closed));
    surface.consumer_released(visible).unwrap();
    assert!(!surface.is_drained());
    assert!(!surface.gpu_completed(flight).unwrap());
    assert!(surface.is_drained());
    assert_eq!(surface.published(), None);
}

#[test]
fn aligned_native_allocation_is_charged_before_acquiring_a_slot() {
    let mut limits = config();
    limits.memory_limit = 70000;
    let mut registry = SurfaceRegistry::default();
    let key = registry.reserve(limits).unwrap();
    let surface = registry.get_mut(key).unwrap();
    surface.activate().unwrap();
    let held = surface.begin_frame_with_bytes(1, 32768).unwrap();
    surface.gpu_completed(held).unwrap();
    let second = surface.begin_frame_with_bytes(2, 32768).unwrap();
    surface.gpu_completed(second).unwrap();
    assert_eq!(
        surface.begin_frame_with_bytes(3, 32768),
        Err(SurfaceError::Backpressure)
    );
    assert_eq!(
        surface.begin_frame_with_bytes(3, 4),
        Err(SurfaceError::InvalidArgument)
    );
    surface.resize(63, 47).unwrap();
    surface.consumer_released(held).unwrap();
    assert!(surface.begin_frame_with_bytes(3, 32768).is_ok());
}

#[test]
fn budget_must_allow_a_replacement_for_the_displayed_frame() {
    let mut registry = SurfaceRegistry::default();
    let mut limits = config();
    limits.memory_limit = 64 * 64 * 4;
    assert!(matches!(
        registry.reserve(limits),
        Err(SurfaceError::BudgetExceeded)
    ));
    limits.memory_limit *= 2;
    limits.buffer_limit = 1;
    limits.max_in_flight = 1;
    assert!(matches!(
        registry.reserve(limits),
        Err(SurfaceError::InvalidArgument)
    ));
    limits.buffer_limit = 2;
    let key = registry.reserve(limits).unwrap();
    let surface = registry.get_mut(key).unwrap();
    surface.activate().unwrap();
    assert_eq!(
        surface.begin_frame_with_bytes(1, 32768),
        Err(SurfaceError::BudgetExceeded)
    );
}
