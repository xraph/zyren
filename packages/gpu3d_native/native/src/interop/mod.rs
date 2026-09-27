pub mod abi;
pub mod apple;
mod leases;
#[cfg(target_vendor = "apple")]
pub mod metal;
mod session;
pub use leases::{LeaseId, LeaseLedger};
pub use session::{SurfaceConfig, SurfaceKey, SurfaceRegistry, SurfaceSession, SurfaceState};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum SurfaceError {
    InvalidArgument = 1,
    StaleKey = 2,
    StaleEpoch = 3,
    StaleLease = 4,
    DuplicateCompletion = 5,
    Backpressure = 6,
    Suspended = 7,
    Closed = 8,
    NotReady = 9,
    BudgetExceeded = 10,
    Exhausted = 11,
    Internal = 12,
    TimedOut = 13,
    FrameSuperseded = 14,
}
impl std::fmt::Display for SurfaceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}",
            match self {
                Self::InvalidArgument => "Invalid surface descriptor or ABI layout.",
                Self::StaleKey => "Surface key has expired.",
                Self::StaleEpoch => "Surface epoch has changed.",
                Self::StaleLease => "Frame lease has expired.",
                Self::DuplicateCompletion => "Frame ownership was already released.",
                Self::Backpressure => "Surface buffers are still in use.",
                Self::Suspended => "Surface is suspended.",
                Self::Closed => "Surface has closed.",
                Self::NotReady => "Surface registration is pending.",
                Self::BudgetExceeded => "Surface memory budget would be exceeded.",
                Self::Exhausted => "Surface generation or registry capacity exhausted.",
                Self::Internal => "Native surface operation failed.",
                Self::TimedOut => "GPU completion timed out; ownership is retained.",
                Self::FrameSuperseded =>
                    "Scene was applied, but its surface epoch changed before publication.",
            }
        )
    }
}
impl std::error::Error for SurfaceError {}
