use super::SurfaceError;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LeaseId {
    pub slot: u32,
    pub generation: u64,
}

#[derive(Default)]
pub(crate) struct Lease {
    pub generation: u64,
    pub epoch: u64,
    pub gpu_done: bool,
    pub consumer_done: bool,
    pub retired: bool,
}
impl Lease {
    fn reusable(&self) -> bool {
        self.generation == 0 || (self.retired && self.gpu_done && self.consumer_done)
    }
}

/// Each slot has two independent completion conditions. Neither a notification
/// nor a receipt from Dart can release the native consumer's ownership.
pub struct LeaseLedger {
    slots: Vec<Lease>,
}
impl LeaseLedger {
    pub fn new(buffer_limit: usize) -> Result<Self, SurfaceError> {
        if !(1..=3).contains(&buffer_limit) {
            return Err(SurfaceError::InvalidArgument);
        }
        Ok(Self {
            slots: (0..buffer_limit).map(|_| Lease::default()).collect(),
        })
    }
    pub fn acquire(&mut self, epoch: u64) -> Result<LeaseId, SurfaceError> {
        if epoch == 0 {
            return Err(SurfaceError::InvalidArgument);
        }
        let (index, slot) = self
            .slots
            .iter_mut()
            .enumerate()
            .find(|(_, slot)| slot.reusable())
            .ok_or(SurfaceError::Backpressure)?;
        let generation = slot
            .generation
            .checked_add(1)
            .ok_or(SurfaceError::Exhausted)?;
        *slot = Lease {
            generation,
            epoch,
            ..Default::default()
        };
        Ok(LeaseId {
            slot: index as u32,
            generation,
        })
    }
    pub(crate) fn get(&self, id: LeaseId) -> Result<&Lease, SurfaceError> {
        self.slots
            .get(id.slot as usize)
            .filter(|slot| slot.generation == id.generation && id.generation != 0)
            .ok_or(SurfaceError::StaleLease)
    }
    fn get_mut(&mut self, id: LeaseId) -> Result<&mut Lease, SurfaceError> {
        self.slots
            .get_mut(id.slot as usize)
            .filter(|slot| slot.generation == id.generation && id.generation != 0)
            .ok_or(SurfaceError::StaleLease)
    }
    pub fn gpu_completed(&mut self, id: LeaseId) -> Result<(), SurfaceError> {
        let slot = self.get_mut(id)?;
        if slot.gpu_done {
            return Err(SurfaceError::DuplicateCompletion);
        }
        slot.gpu_done = true;
        Ok(())
    }
    pub fn consumer_released(&mut self, id: LeaseId) -> Result<(), SurfaceError> {
        let slot = self.get_mut(id)?;
        if slot.consumer_done {
            return Err(SurfaceError::DuplicateCompletion);
        }
        slot.consumer_done = true;
        Ok(())
    }
    pub fn retire(&mut self, id: LeaseId) -> Result<(), SurfaceError> {
        self.get_mut(id)?.retired = true;
        Ok(())
    }
    pub fn is_reusable(&self, id: LeaseId) -> Result<bool, SurfaceError> {
        Ok(self.get(id)?.reusable())
    }
    pub(crate) fn active_ids(&self) -> impl Iterator<Item = LeaseId> + '_ {
        self.slots
            .iter()
            .enumerate()
            .filter(|(_, slot)| slot.generation != 0 && !slot.reusable())
            .map(|(index, slot)| LeaseId {
                slot: index as u32,
                generation: slot.generation,
            })
    }
    pub fn producer_count(&self) -> usize {
        self.slots
            .iter()
            .filter(|slot| slot.generation != 0 && !slot.gpu_done)
            .count()
    }
    pub fn allocated_slots(&self) -> usize {
        self.slots
            .iter()
            .filter(|slot| slot.generation != 0)
            .count()
    }
}
