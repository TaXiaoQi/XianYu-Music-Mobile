use serde::{Serialize, Deserialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RemoteSource { // 实现
	pub id: String,
	pub name: String,
	pub provider: String,
	pub base_url: String,
	pub username: Option<String>,
	pub root_path: String,
	pub enabled: bool,
	pub last_sync_at: Option<i64>,
	pub last_sync_error: Option<String>,
	pub created_at: i64,
	pub updated_at: i64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RemoteSourceCredentials { // 实现
	#[serde(default)]
	pub id: String,
	#[serde(default)]
	pub name: String,
	#[serde(default)]
	pub provider: String,
	pub base_url: String,
	#[serde(default)]
	pub username: Option<String>,
	#[serde(default)]
	pub password: Option<String>,
	#[serde(default)]
	pub root_path: String,
	#[serde(default)]
	pub enabled: bool,
	#[serde(default)]
	pub last_sync_at: Option<i64>,
	#[serde(default)]
	pub last_sync_error: Option<String>,
	#[serde(default)]
	pub created_at: i64,
	#[serde(default)]
	pub updated_at: i64,
}

impl From<RemoteSourceCredentials> for RemoteSource {
	fn from(value: RemoteSourceCredentials) -> Self {
		Self {
			id: value.id,
			name: value.name,
			provider: value.provider,
			base_url: value.base_url,
			username: value.username,
			root_path: value.root_path,
			enabled: value.enabled,
			last_sync_at: value.last_sync_at,
			last_sync_error: value.last_sync_error,
			created_at: value.created_at,
			updated_at: value.updated_at,
		}
	}
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RemoteSourceInput { // 实现
	pub id: Option<String>,
	pub name: String,
	pub provider: String,
	pub base_url: String,
	pub username: Option<String>,
	pub password: Option<String>,
	pub root_path: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RemoteSyncResult { // 实现
	pub source_id: String,
	pub indexed_files: usize,
	pub audio_files: usize,
	pub parsed_songs: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RemoteFileEntry { // 实现
	pub remote_path: String,
	pub name: String,
	pub size: u64,
	pub etag: Option<String>,
	pub modified_at: Option<String>,
	pub is_dir: bool,
}

impl RemoteFileEntry { // RemoteFileEntry
	pub(crate) fn remote_uri(&self, source_id: &str) -> String {
		format!(
			"remote://{}/{}",
			source_id,
			self.remote_path.trim_start_matches('/')
		)
	}
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RemoteCacheUsage {
	pub bytes: u64,
	pub files: usize,
	pub limit_bytes: u64,
}
