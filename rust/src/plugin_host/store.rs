//! 插件 Cookie / Storage 持久化存储
//!
//! 原实现在前端 localStorage（pluginCookieStore.ts），插件引擎迁至 Rust 后
//! 由本模块接管：Cookie 存储为扁平 name -> {value, domain} 映射，
//! Storage 为 key -> string 映射，整体持久化到 app_data_dir/plugin_host_store.json。
//! 语义与原 localStorage 实现逐一对齐（含双向子串域名匹配）。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct CookieEntry {
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub domain: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct PluginStoreData {
    #[serde(default)]
    pub cookies: HashMap<String, CookieEntry>,
    #[serde(default)]
    pub storage: HashMap<String, String>,
}

pub struct PluginStore {
    data: Mutex<PluginStoreData>,
    path: Option<std::path::PathBuf>,
}

fn url_hostname(url: &str) -> String {
    url::Url::parse(url)
        .map(|u| u.host_str().unwrap_or_default().to_lowercase())
        .unwrap_or_default()
}

impl PluginStore {
    pub fn load(path: Option<std::path::PathBuf>) -> Self {
        let data = path
            .as_deref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|raw| serde_json::from_str::<PluginStoreData>(&raw).ok())
            .unwrap_or_default();
        Self {
            data: Mutex::new(data),
            path,
        }
    }

    fn persist(&self, data: &PluginStoreData) {
        let Some(path) = &self.path else { return };
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                let _ = std::fs::create_dir_all(parent);
            }
        }
        if let Ok(json) = serde_json::to_string(data) {
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, json).is_ok() {
                let _ = std::fs::rename(&tmp, path);
            }
        }
    }

    /// 对应 setCookie(url, {name, value, domain?})
    pub fn set_cookie(&self, url: &str, name: &str, value: &str, domain: Option<&str>) -> bool {
        let host = url_hostname(url);
        if name.is_empty() {
            return false;
        }
        let mut data = self.data.lock().unwrap();
        let domain = domain
            .filter(|d| !d.is_empty())
            .map(|d| d.to_string())
            .unwrap_or(host);
        data.cookies.insert(
            name.to_string(),
            CookieEntry {
                value: value.to_string(),
                domain,
            },
        );
        self.persist(&data);
        true
    }

    /// 对应 getCookies(url)：双向子串域名匹配
    pub fn get_cookies_for_url(&self, url: &str) -> HashMap<String, CookieEntry> {
        let host = url_hostname(url);
        if host.is_empty() {
            return HashMap::new();
        }
        let data = self.data.lock().unwrap();
        data.cookies
            .iter()
            .filter(|(_, c)| {
                !c.domain.is_empty()
                    && (host.contains(&c.domain) || c.domain.contains(&host))
            })
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }

    /// 拼接 "name=value; ..." Cookie 请求头（对应 getCookiesForUrl）
    pub fn cookie_header_for_url(&self, url: &str) -> String {
        self.get_cookies_for_url(url)
            .iter()
            .map(|(name, c)| format!("{}={}", name, c.value))
            .collect::<Vec<_>>()
            .join("; ")
    }

    /// 域名包含指定关键字的 Cookie 头（对应 getPluginBilibiliCookies）
    pub fn cookie_header_for_domain(&self, domain_filter: &str) -> String {
        let filter = domain_filter.to_lowercase();
        let data = self.data.lock().unwrap();
        data.cookies
            .iter()
            .filter(|(_, c)| c.domain.to_lowercase().contains(&filter) && !c.value.is_empty())
            .map(|(name, c)| format!("{}={}", name, c.value))
            .collect::<Vec<_>>()
            .join("; ")
    }

    /// 对应 captureCookiesFromResponse：解析 Set-Cookie 行并存储
    pub fn capture_set_cookies(&self, url: &str, set_cookie_values: &[String]) {
        if set_cookie_values.is_empty() {
            return;
        }
        let host = url_hostname(url);
        if host.is_empty() {
            return;
        }
        let mut changed = false;
        let mut data = self.data.lock().unwrap();
        for raw in set_cookie_values {
            let first = raw.split(';').next().unwrap_or("");
            let mut parts = first.splitn(2, '=');
            let name = parts.next().unwrap_or("").trim();
            let value = parts.next().unwrap_or("").trim();
            if name.is_empty() || value.is_empty() {
                continue;
            }
            data.cookies.insert(
                name.to_string(),
                CookieEntry {
                    value: value.to_string(),
                    domain: host.clone(),
                },
            );
            changed = true;
        }
        if changed {
            self.persist(&data);
        }
    }

    pub fn storage_set(&self, key: &str, value: &str) {
        let mut data = self.data.lock().unwrap();
        data.storage.insert(key.to_string(), value.to_string());
        self.persist(&data);
    }

    pub fn storage_get(&self, key: &str) -> Option<String> {
        self.data.lock().unwrap().storage.get(key).cloned()
    }

    pub fn storage_remove(&self, key: &str) {
        let mut data = self.data.lock().unwrap();
        if data.storage.remove(key).is_some() {
            self.persist(&data);
        }
    }

    /// 一次性迁移 localStorage 旧数据：Rust 侧已有的条目优先（更新），仅补缺
    pub fn import_local(
        &self,
        cookies: HashMap<String, CookieEntry>,
        storage: HashMap<String, String>,
    ) {
        let mut changed = false;
        let mut data = self.data.lock().unwrap();
        for (name, entry) in cookies {
            if name.is_empty() || entry.value.is_empty() {
                continue;
            }
            data.cookies.entry(name).or_insert(entry);
            changed = true;
        }
        for (key, value) in storage {
            data.storage.entry(key).or_insert(value);
            changed = true;
        }
        if changed {
            self.persist(&data);
        }
    }

    pub fn cookie_snapshot(&self) -> HashMap<String, CookieEntry> {
        self.data.lock().unwrap().cookies.clone()
    }

    pub fn storage_snapshot(&self) -> HashMap<String, String> {
        self.data.lock().unwrap().storage.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cookie_roundtrip_and_domain_match() {
        let store = PluginStore::load(None);
        assert!(store.set_cookie(
            "https://www.bilibili.com/x",
            "SESSDATA",
            "abc123",
            None
        ));
        assert!(store.set_cookie(
            "https://api.kugou.com/v1",
            "kg_token",
            "xyz",
            None
        ));

        // 双向子串匹配（与原前端 getCookies 语义一致）：同 host 命中
        let header = store.cookie_header_for_url("https://www.bilibili.com/foo");
        assert!(header.contains("SESSDATA=abc123"));
        assert!(!header.contains("kg_token"));
        // api.bilibili.com 与 www.bilibili.com 互不包含，不命中
        // （原实现同样如此，跨子域靠 cookie_header_for_domain）
        let api = store.cookie_header_for_url("https://api.bilibili.com/foo");
        assert!(!api.contains("SESSDATA"));

        let bili = store.cookie_header_for_domain("bilibili");
        assert!(bili.contains("SESSDATA=abc123"));
        assert!(!bili.contains("kg_token"));
    }

    #[test]
    fn capture_set_cookies_parses_attributes() {
        let store = PluginStore::load(None);
        store.capture_set_cookies(
            "https://y.qq.com/api",
            &[
                "uin=12345; Path=/; Domain=.qq.com; HttpOnly".to_string(),
                "qqmusic_key=QK_; expires=Fri, 01-Jan-2027".to_string(),
                "invalid".to_string(),
            ],
        );
        // capture 使用响应 URL 的 host（y.qq.com）作为 domain
        let header = store.cookie_header_for_url("https://y.qq.com/");
        assert!(header.contains("uin=12345"));
        assert!(header.contains("qqmusic_key=QK"));
    }

    #[test]
    fn storage_ops() {
        let store = PluginStore::load(None);
        store.storage_set("plugin-a/state", "{\"v\":1}");
        assert_eq!(
            store.storage_get("plugin-a/state").as_deref(),
            Some("{\"v\":1}")
        );
        store.storage_remove("plugin-a/state");
        assert!(store.storage_get("plugin-a/state").is_none());
    }

    #[test]
    fn import_local_keeps_rust_entries() {
        let store = PluginStore::load(None);
        store.set_cookie("https://a.com/", "k", "rust", None);
        let mut cookies = HashMap::new();
        cookies.insert(
            "k".to_string(),
            CookieEntry {
                value: "local".to_string(),
                domain: "a.com".to_string(),
            },
        );
        cookies.insert(
            "new".to_string(),
            CookieEntry {
                value: "v".to_string(),
                domain: "b.com".to_string(),
            },
        );
        store.import_local(cookies, HashMap::new());
        // Rust 侧已有条目优先
        assert_eq!(store.cookie_header_for_url("https://a.com/"), "k=rust");
        // 仅补缺的新条目
        assert_eq!(store.cookie_header_for_url("https://b.com/"), "new=v");
    }
}
