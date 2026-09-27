use super::ResourceError;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ResourceKey {
    pub renderer: u64,
    pub device_generation: u64,
    pub slot: u64,
    pub slot_generation: u64,
}
struct Entry<T> {
    value: T,
    bytes: u64,
    references: u32,
    last_submission: u64,
}
struct Slot<T> {
    generation: u64,
    entry: Option<Entry<T>>,
}
pub struct ResourceRegistry<T> {
    renderer: u64,
    device_generation: u64,
    slots: Vec<Slot<T>>,
    limit: u64,
    resident: u64,
}
impl<T> ResourceRegistry<T> {
    pub fn new(renderer: u64, device_generation: u64, limit: u64) -> Self {
        Self {
            renderer,
            device_generation,
            slots: Vec::new(),
            limit,
            resident: 0,
        }
    }
    pub fn check_capacity(&self, bytes: u64) -> Result<(), ResourceError> {
        if bytes == 0 {
            return Err(ResourceError::BudgetExceeded);
        }
        self.check_batch(bytes, 1)
    }
    pub fn check_batch(&self, bytes: u64, count: usize) -> Result<(), ResourceError> {
        let available = 65536 - self.slots.len()
            + self
                .slots
                .iter()
                .filter(|s| s.entry.is_none() && s.generation < u64::MAX)
                .count();
        if bytes > self.limit.saturating_sub(self.resident) || count > available {
            return Err(ResourceError::BudgetExceeded);
        }
        Ok(())
    }
    pub fn insert(&mut self, value: T, bytes: u64) -> Result<ResourceKey, ResourceError> {
        self.check_capacity(bytes)?;
        let index = self
            .slots
            .iter()
            .position(|s| s.entry.is_none() && s.generation < u64::MAX)
            .unwrap_or(self.slots.len());
        if index == self.slots.len() {
            self.slots.push(Slot {
                generation: 0,
                entry: None,
            });
        }
        let slot = &mut self.slots[index];
        slot.generation += 1;
        slot.entry = Some(Entry {
            value,
            bytes,
            references: 1,
            last_submission: 0,
        });
        self.resident += bytes;
        Ok(ResourceKey {
            renderer: self.renderer,
            device_generation: self.device_generation,
            slot: index as u64,
            slot_generation: slot.generation,
        })
    }
    fn entry(&self, key: ResourceKey) -> Result<&Entry<T>, ResourceError> {
        if key.renderer != self.renderer || key.device_generation != self.device_generation {
            return Err(ResourceError::StaleKey);
        }
        let slot = self
            .slots
            .get(usize::try_from(key.slot).map_err(|_| ResourceError::StaleKey)?)
            .ok_or(ResourceError::StaleKey)?;
        if key.slot_generation != slot.generation {
            return Err(ResourceError::StaleKey);
        }
        slot.entry
            .as_ref()
            .filter(|e| e.references > 0)
            .ok_or(ResourceError::StaleKey)
    }
    pub fn resolve(&self, key: ResourceKey) -> Result<&T, ResourceError> {
        Ok(&self.entry(key)?.value)
    }
    pub fn retain(&mut self, key: ResourceKey) -> Result<(), ResourceError> {
        let references = self
            .entry(key)?
            .references
            .checked_add(1)
            .ok_or(ResourceError::BudgetExceeded)?;
        self.slots[key.slot as usize]
            .entry
            .as_mut()
            .unwrap()
            .references = references;
        Ok(())
    }
    pub fn release(&mut self, key: ResourceKey) -> Result<(), ResourceError> {
        self.entry(key)?;
        self.slots[key.slot as usize]
            .entry
            .as_mut()
            .unwrap()
            .references -= 1;
        Ok(())
    }
    pub fn mark_used(&mut self, key: ResourceKey, submission: u64) -> Result<(), ResourceError> {
        self.entry(key)?;
        let entry = self.slots[key.slot as usize].entry.as_mut().unwrap();
        entry.last_submission = entry.last_submission.max(submission);
        Ok(())
    }
    pub fn retire_completed(&mut self, submission: u64) {
        for slot in &mut self.slots {
            if slot
                .entry
                .as_ref()
                .is_some_and(|e| e.references == 0 && e.last_submission <= submission)
            {
                self.resident -= slot.entry.take().unwrap().bytes;
            }
        }
    }
    pub fn resident_bytes(&self) -> u64 {
        self.resident
    }
    pub fn live_allocations(&self) -> u64 {
        self.slots.iter().filter(|s| s.entry.is_some()).count() as u64
    }
}
