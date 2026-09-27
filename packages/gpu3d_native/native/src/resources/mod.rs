pub mod image_decode;
pub mod registry;
mod runtime;
pub mod upload;
pub use runtime::ResourceStore;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum ResourceError {
    InvalidCommand = 1,
    StaleKey = 2,
    BudgetExceeded = 3,
    InvalidUsage = 4,
    InvalidRange = 5,
    DeviceFailed = 6,
}
impl std::fmt::Display for ResourceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::InvalidCommand => "invalid resource command or descriptor",
            Self::StaleKey => "resource belongs to another device or has retired",
            Self::BudgetExceeded => "resource allocation exceeds the device budget",
            Self::InvalidUsage => "resource usage does not permit this operation",
            Self::InvalidRange => "resource byte range or mip level is invalid",
            Self::DeviceFailed => "native device could not complete resource work",
        })
    }
}
impl std::error::Error for ResourceError {}
