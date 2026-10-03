use zyren_runtime::resources::{ResourceError, registry::ResourceRegistry};

#[test]
fn keys_validate_device_renderer_and_reused_slot() {
    let mut registry = ResourceRegistry::new(7, 3, 64);
    let key = registry.insert("first", 16).unwrap();
    assert_eq!(*registry.resolve(key).unwrap(), "first");
    for invalid in [
        zyren_runtime::resources::registry::ResourceKey { renderer: 8, ..key },
        zyren_runtime::resources::registry::ResourceKey {
            device_generation: 2,
            ..key
        },
    ] {
        assert_eq!(registry.resolve(invalid), Err(ResourceError::StaleKey));
    }
    registry.release(key).unwrap();
    registry.retire_completed(0);
    let next = registry.insert("next", 16).unwrap();
    assert_eq!(key.slot, next.slot);
    assert_ne!(key.slot_generation, next.slot_generation);
    assert_eq!(registry.resolve(key), Err(ResourceError::StaleKey));
}

#[test]
fn scope_references_and_submission_fences_both_protect_allocations() {
    let mut registry = ResourceRegistry::new(1, 1, 32);
    let key = registry.insert(42, 32).unwrap();
    registry.retain(key).unwrap();
    registry.mark_used(key, 9).unwrap();
    registry.release(key).unwrap();
    assert_eq!(*registry.resolve(key).unwrap(), 42);
    registry.release(key).unwrap();
    assert_eq!(registry.resolve(key), Err(ResourceError::StaleKey));
    registry.retire_completed(8);
    assert_eq!(registry.resident_bytes(), 32);
    assert_eq!(registry.insert(43, 1), Err(ResourceError::BudgetExceeded));
    registry.retire_completed(9);
    assert_eq!(registry.resident_bytes(), 0);
    assert!(registry.insert(43, 32).is_ok());
}

#[test]
fn allocation_batches_preflight_all_bytes_and_slots() {
    let registry = ResourceRegistry::<()>::new(1, 1, 128);
    assert_eq!(
        registry.check_batch(129, 2),
        Err(ResourceError::BudgetExceeded)
    );
    assert_eq!(
        registry.check_batch(4, 65537),
        Err(ResourceError::BudgetExceeded)
    );
    assert!(registry.check_batch(128, 65536).is_ok());
}

#[test]
fn inspection_includes_pending_retirement_and_does_not_retain_resources() {
    let mut registry = ResourceRegistry::new(1, 2, 128);
    let first = registry.insert("buffer", 16).unwrap();
    let second = registry.insert("texture", 32).unwrap();
    registry.mark_used(first, 9).unwrap();
    registry.release(first).unwrap();
    {
        let rows = registry.inspect(1);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0], (first, &"buffer", 16, 0, 9));
    }
    registry.retire_completed(8);
    assert_eq!(registry.inspect(256).len(), 2);
    registry.retire_completed(9);
    assert_eq!(registry.inspect(256)[0].0, second);
    registry.release(second).unwrap();
    registry.retire_completed(9);
    assert!(registry.inspect(256).is_empty());
}

#[test]
fn planned_release_credits_only_completed_final_owners_without_mutation() {
    let mut registry = ResourceRegistry::new(1, 1, 32);
    let key = registry.insert((), 24).unwrap();
    registry.mark_used(key, 9).unwrap();
    assert_eq!(
        registry.check_batch_after_release(16, 1, &[key], 8),
        Err(ResourceError::BudgetExceeded)
    );
    assert_eq!(registry.check_batch_after_release(16, 1, &[key], 9), Ok(()));
    registry.retain(key).unwrap();
    assert_eq!(
        registry.check_batch_after_release(16, 1, &[key], 9),
        Err(ResourceError::BudgetExceeded)
    );
    registry.release(key).unwrap();
    assert_eq!(
        registry.check_batch_after_release(40, 1, &[key, key], 9),
        Err(ResourceError::BudgetExceeded)
    );
    assert_eq!(
        registry.check_batch_after_release(1, 65536, &[key], 9),
        Ok(())
    );
    assert_eq!(
        registry.check_batch_after_release(1, 65537, &[key], 9),
        Err(ResourceError::BudgetExceeded)
    );
    assert_eq!(registry.resident_bytes(), 24);
    assert_eq!(registry.references(key), Ok(1));
    assert_eq!(registry.resolve(key), Ok(&()));
}
