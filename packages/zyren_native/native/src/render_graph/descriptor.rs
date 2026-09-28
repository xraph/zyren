use serde::Deserialize;

pub type Key = [u64; 4];
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Description {
    pub label: String,
    pub inputs: Vec<Key>,
    pub resources: Vec<Resource>,
    pub passes: Vec<Pass>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Resource {
    pub key: Key,
    pub label: String,
}
#[derive(Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Compute,
    Render,
    Material,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Pass {
    pub kind: Kind,
    pub name: String,
    pub program: Key,
    pub bindings: Vec<Binding>,
    pub reads: Vec<Key>,
    pub writes: Vec<Key>,
    pub after: Vec<String>,
    pub entry_point: Option<String>,
    pub workgroups: Option<[u32; 3]>,
    pub vertex_entry_point: Option<String>,
    pub fragment_entry_point: Option<String>,
    pub vertex_count: Option<u32>,
    pub instance_count: Option<u32>,
    pub sample_count: Option<u32>,
    pub blend: Option<Blend>,
    pub color: Option<Color>,
    pub requires_uv: Option<bool>,
    pub screen_space: Option<bool>,
}
#[derive(Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub enum BindingKind {
    Uniform,
    StorageRead,
    StorageReadWrite,
    Sampled,
    StorageTexture,
    Sampler,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Binding {
    pub group: u32,
    pub binding: u32,
    pub kind: BindingKind,
    pub stages: Vec<u32>,
    pub key: Option<Key>,
    pub offset: Option<u64>,
    pub size: Option<u64>,
    pub mip_level: Option<u32>,
    pub mip_levels: Option<u32>,
    pub sampler: Option<[u32; 5]>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Color {
    pub key: Key,
    pub mip_level: u32,
    pub load: Load,
    pub store: Store,
    pub clear: [f64; 4],
}
#[derive(Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Load {
    Clear,
    Load,
}
#[derive(Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Store {
    Store,
    Discard,
}

#[derive(Deserialize, Clone, Copy, Default, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
pub enum Blend {
    #[default]
    Replace,
    PremultipliedAlpha,
    Additive,
}
impl Blend {
    pub fn state(self) -> Option<wgpu::BlendState> {
        match self {
            Self::Replace => None,
            Self::PremultipliedAlpha => Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
            Self::Additive => {
                let component = wgpu::BlendComponent {
                    src_factor: wgpu::BlendFactor::One,
                    dst_factor: wgpu::BlendFactor::One,
                    operation: wgpu::BlendOperation::Add,
                };
                Some(wgpu::BlendState {
                    color: component,
                    alpha: component,
                })
            }
        }
    }
}
