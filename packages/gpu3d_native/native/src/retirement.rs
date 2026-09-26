use std::sync::{
    Arc, OnceLock,
    atomic::{AtomicUsize, Ordering},
};

const MAX_DEVICES: usize = 32;
static BUDGET: OnceLock<Arc<Budget>> = OnceLock::new();
static RETIRING: AtomicUsize = AtomicUsize::new(0);

struct Budget {
    limit: usize,
    reserved: AtomicUsize,
}
impl Budget {
    fn new(limit: usize) -> Arc<Self> {
        Arc::new(Self {
            limit,
            reserved: AtomicUsize::new(0),
        })
    }
    fn acquire(self: &Arc<Self>) -> Result<DevicePermit, String> {
        self.reserved.fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < self.limit).then_some(count + 1)
        }).map_err(|_| "native GPU session capacity is exhausted; wait for an active or retiring session to close")?;
        Ok(DevicePermit(self.clone()))
    }
}
pub(crate) struct DevicePermit(Arc<Budget>);
impl Drop for DevicePermit {
    fn drop(&mut self) {
        self.0.reserved.fetch_sub(1, Ordering::AcqRel);
    }
}
pub(crate) fn reserve_device() -> Result<DevicePermit, String> {
    BUDGET.get_or_init(|| Budget::new(MAX_DEVICES)).acquire()
}
pub fn retiring_count() -> usize {
    RETIRING.load(Ordering::Acquire)
}

/// Failed wgpu queues may wait indefinitely during Drop. Move their complete
/// ownership to a bounded retirement thread, keeping the device permit charged.
pub(crate) fn retire<T: Send + 'static>(state: Box<T>) {
    RETIRING.fetch_add(1, Ordering::AcqRel);
    let address = Box::into_raw(state) as usize;
    let result = std::thread::Builder::new()
        .name("gpu3d-retirement".into())
        .stack_size(256 * 1024)
        .spawn(move || {
            // SAFETY: this closure is the sole owner of the Box after transfer.
            // It runs only once, after a successful spawn.
            unsafe {
                drop(Box::from_raw(address as *mut T));
            }
            RETIRING.fetch_sub(1, Ordering::AcqRel);
        });
    if result.is_err() {
        // Retain permanently if the OS cannot create a retirement thread.
        // The charged device permit bounds this case and prevents unsafe Drop.
        eprintln!("GPU retirement could not start; native ownership remains quarantined.");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn capacity_stays_reserved_until_the_owner_releases_its_permit() {
        let budget = Budget::new(2);
        let first = budget.acquire().unwrap();
        let second = budget.acquire().unwrap();
        assert!(budget.acquire().is_err());
        drop(first);
        let replacement = budget.acquire().unwrap();
        assert!(budget.acquire().is_err());
        drop(second);
        drop(replacement);
        assert_eq!(budget.reserved.load(Ordering::Acquire), 0);
    }
}
