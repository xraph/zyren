use super::{LeaseId, LeaseLedger, SurfaceError};

const MAX_SURFACES: usize = 1024;
const MAX_MEMORY: u64 = 256 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SurfaceKey {
    pub slot: u64,
    pub generation: u64,
}
#[derive(Clone, Copy, Debug)]
pub struct SurfaceConfig {
    pub width: u32,
    pub height: u32,
    pub buffer_limit: usize,
    pub max_in_flight: usize,
    pub memory_limit: u64,
}
impl SurfaceConfig {
    fn validate(&self) -> Result<(), SurfaceError> {
        if !(2..=3).contains(&self.buffer_limit)
            || !(1..=2).contains(&self.max_in_flight)
            || self.max_in_flight > self.buffer_limit
            || self.memory_limit > MAX_MEMORY
        {
            return Err(SurfaceError::InvalidArgument);
        }
        self.frame_bytes(self.width, self.height).map(|_| ())
    }
    fn frame_bytes(&self, width: u32, height: u32) -> Result<u64, SurfaceError> {
        if width == 0 || height == 0 || width > 4096 || height > 4096 {
            return Err(SurfaceError::InvalidArgument);
        }
        let bytes = u64::from(width) * u64::from(height) * 4;
        // Keep room for a replacement while Flutter holds the displayed frame.
        if bytes > self.memory_limit / 2 {
            return Err(SurfaceError::BudgetExceeded);
        }
        Ok(bytes)
    }
}
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SurfaceState {
    Creating,
    Ready,
    Suspended,
    Closing,
    Closed,
}
#[derive(Clone, Copy, Default)]
struct FrameSlot {
    id: u64,
    bytes: u64,
    published: bool,
}

pub struct SurfaceSession {
    config: SurfaceConfig,
    state: SurfaceState,
    epoch: u64,
    ledger: LeaseLedger,
    frames: Vec<FrameSlot>,
    published: Option<LeaseId>,
    last_frame: u64,
    last_published: u64,
    pending: Option<u64>,
    coalesced: u64,
    terminal_error: Option<SurfaceError>,
}
impl SurfaceSession {
    fn new(config: SurfaceConfig) -> Result<Self, SurfaceError> {
        config.validate()?;
        Ok(Self {
            config,
            state: SurfaceState::Creating,
            epoch: 1,
            ledger: LeaseLedger::new(config.buffer_limit)?,
            frames: vec![FrameSlot::default(); config.buffer_limit],
            published: None,
            last_frame: 0,
            last_published: 0,
            pending: None,
            coalesced: 0,
            terminal_error: None,
        })
    }
    pub fn state(&self) -> SurfaceState {
        self.state
    }
    pub fn epoch(&self) -> u64 {
        self.epoch
    }
    pub fn size(&self) -> (u32, u32) {
        (self.config.width, self.config.height)
    }
    pub fn activate(&mut self) -> Result<(), SurfaceError> {
        if self.state != SurfaceState::Creating {
            return Err(SurfaceError::Closed);
        }
        self.state = SurfaceState::Ready;
        Ok(())
    }
    fn ready(&self) -> Result<(), SurfaceError> {
        match self.state {
            SurfaceState::Ready => Ok(()),
            SurfaceState::Creating => Err(SurfaceError::NotReady),
            SurfaceState::Suspended => Err(SurfaceError::Suspended),
            _ => Err(SurfaceError::Closed),
        }
    }
    fn advance_epoch(&mut self) -> Result<(), SurfaceError> {
        let epoch = self.epoch.checked_add(1).ok_or(SurfaceError::Exhausted)?;
        if let Some(old) = self.published.take() {
            self.ledger.retire(old)?;
        }
        self.epoch = epoch;
        self.pending = None;
        Ok(())
    }
    pub fn resize(&mut self, width: u32, height: u32) -> Result<(), SurfaceError> {
        if matches!(self.state, SurfaceState::Closing | SurfaceState::Closed) {
            return Err(SurfaceError::Closed);
        }
        self.config.frame_bytes(width, height)?;
        if self.size() == (width, height) {
            return Ok(());
        }
        self.advance_epoch()?;
        self.config.width = width;
        self.config.height = height;
        Ok(())
    }
    pub fn suspend(&mut self) -> Result<(), SurfaceError> {
        if self.state == SurfaceState::Suspended {
            return Ok(());
        }
        self.ready()?;
        self.advance_epoch()?;
        self.state = SurfaceState::Suspended;
        Ok(())
    }
    pub fn resume(&mut self) -> Result<(), SurfaceError> {
        if self.state == SurfaceState::Ready {
            return Ok(());
        }
        if self.state != SurfaceState::Suspended {
            return Err(SurfaceError::Closed);
        }
        self.state = SurfaceState::Ready;
        Ok(())
    }
    pub fn queue_frame(&mut self, id: u64) -> Result<(), SurfaceError> {
        self.ready()?;
        if id == 0 || id <= self.last_frame || self.pending.is_some_and(|last| id <= last) {
            return Err(SurfaceError::InvalidArgument);
        }
        if self.pending.replace(id).is_some() {
            self.coalesced += 1;
        }
        Ok(())
    }
    pub fn pending_frame(&self) -> Option<u64> {
        self.pending
    }
    pub fn coalesced_frames(&self) -> u64 {
        self.coalesced
    }
    pub fn begin_pending(&mut self) -> Result<Option<LeaseId>, SurfaceError> {
        let Some(id) = self.pending else {
            return Ok(None);
        };
        let lease = self.begin_frame(id)?;
        self.pending = None;
        Ok(Some(lease))
    }
    pub fn begin_frame(&mut self, id: u64) -> Result<LeaseId, SurfaceError> {
        let bytes = self
            .config
            .frame_bytes(self.config.width, self.config.height)?;
        self.begin_frame_with_bytes(id, bytes)
    }
    /// Charge the platform's actual allocation, including row/page alignment.
    /// Adapters must release retired storage before its slot becomes reusable.
    pub fn begin_frame_with_bytes(&mut self, id: u64, bytes: u64) -> Result<LeaseId, SurfaceError> {
        self.ready()?;
        if id == 0 || id <= self.last_frame {
            return Err(SurfaceError::InvalidArgument);
        }
        if self.ledger.producer_count() >= self.config.max_in_flight {
            return Err(SurfaceError::Backpressure);
        }
        let minimum_bytes = self
            .config
            .frame_bytes(self.config.width, self.config.height)?;
        if bytes < minimum_bytes {
            return Err(SurfaceError::InvalidArgument);
        }
        if bytes > self.config.memory_limit / 2 {
            return Err(SurfaceError::BudgetExceeded);
        }
        let active_bytes: u64 = self
            .ledger
            .active_ids()
            .map(|lease| self.frames[lease.slot as usize].bytes)
            .sum();
        if active_bytes + bytes > self.config.memory_limit {
            return Err(SurfaceError::Backpressure);
        }
        let lease = self.ledger.acquire(self.epoch)?;
        self.frames[lease.slot as usize] = FrameSlot {
            id,
            bytes,
            published: false,
        };
        self.last_frame = id;
        Ok(lease)
    }
    pub fn frame_id(&self, lease: LeaseId) -> Result<u64, SurfaceError> {
        self.ledger.get(lease)?;
        Ok(self.frames[lease.slot as usize].id)
    }
    /// Returns true only when this completion may replace the displayed frame.
    pub fn gpu_completed(&mut self, lease: LeaseId) -> Result<bool, SurfaceError> {
        self.ledger.gpu_completed(lease)?;
        let entry = self.ledger.get(lease)?;
        let frame = self.frames[lease.slot as usize];
        if self.state != SurfaceState::Ready
            || entry.epoch != self.epoch
            || frame.id <= self.last_published
        {
            self.ledger.retire(lease)?;
            if !self.ledger.get(lease)?.consumer_done {
                self.ledger.consumer_released(lease)?;
            }
            self.check_drained();
            return Ok(false);
        }
        if let Some(old) = self.published.replace(lease) {
            self.ledger.retire(old)?;
        }
        self.frames[lease.slot as usize].published = true;
        self.last_published = frame.id;
        Ok(true)
    }
    pub fn consumer_released(&mut self, lease: LeaseId) -> Result<(), SurfaceError> {
        self.ledger.consumer_released(lease)?;
        self.check_drained();
        Ok(())
    }
    pub fn published(&self) -> Option<LeaseId> {
        self.published
    }
    pub fn allocated_slots(&self) -> usize {
        self.ledger.allocated_slots()
    }
    pub fn close(&mut self) -> Result<(), SurfaceError> {
        if matches!(self.state, SurfaceState::Closing | SurfaceState::Closed) {
            return Ok(());
        }
        self.advance_epoch()?;
        self.state = SurfaceState::Closing;
        for id in self.ledger.active_ids().collect::<Vec<_>>() {
            self.ledger.retire(id)?;
            if !self.frames[id.slot as usize].published && !self.ledger.get(id)?.consumer_done {
                self.ledger.consumer_released(id)?;
            }
        }
        self.check_drained();
        Ok(())
    }
    /// A timeout cancels publication. It never substitutes for GPU completion.
    pub fn timeout(&mut self) -> Result<(), SurfaceError> {
        self.terminal_error.get_or_insert(SurfaceError::TimedOut);
        self.close()
    }
    pub fn terminal_error(&self) -> Option<SurfaceError> {
        self.terminal_error
    }
    fn check_drained(&mut self) {
        if self.state == SurfaceState::Closing && self.ledger.active_ids().next().is_none() {
            self.state = SurfaceState::Closed;
        }
    }
    pub fn is_drained(&self) -> bool {
        self.state == SurfaceState::Closed
    }
}
struct Entry {
    generation: u64,
    session: SurfaceSession,
}
#[derive(Default)]
pub struct SurfaceRegistry {
    entries: Vec<Entry>,
}
impl SurfaceRegistry {
    pub fn reserve(&mut self, config: SurfaceConfig) -> Result<SurfaceKey, SurfaceError> {
        let session = SurfaceSession::new(config)?;
        if let Some((slot, entry)) = self
            .entries
            .iter_mut()
            .enumerate()
            .find(|(_, entry)| entry.session.is_drained())
        {
            let generation = entry
                .generation
                .checked_add(1)
                .ok_or(SurfaceError::Exhausted)?;
            *entry = Entry {
                generation,
                session,
            };
            return Ok(SurfaceKey {
                slot: slot as u64 + 1,
                generation,
            });
        }
        if self.entries.len() >= MAX_SURFACES {
            return Err(SurfaceError::Exhausted);
        }
        self.entries.push(Entry {
            generation: 1,
            session,
        });
        Ok(SurfaceKey {
            slot: self.entries.len() as u64,
            generation: 1,
        })
    }
    pub fn get_mut(&mut self, key: SurfaceKey) -> Result<&mut SurfaceSession, SurfaceError> {
        let index = key
            .slot
            .checked_sub(1)
            .and_then(|slot| usize::try_from(slot).ok())
            .ok_or(SurfaceError::StaleKey)?;
        self.entries
            .get_mut(index)
            .filter(|entry| entry.generation == key.generation)
            .map(|entry| &mut entry.session)
            .ok_or(SurfaceError::StaleKey)
    }
}
