//! 音源插件管理：安装、启用停用、卸载、直链解析。
//!
//! 插件脚本保存在 `{data_dir}/plugins/{id}.js`，元信息索引保存在
//! `{data_dir}/plugins/index.json`，与桌面端的插件目录职责一致。
//!
//! # 沙箱生命周期
//!
//! [`super::lx_sandbox::LxSandbox`] 内含 boa 的 `Context`，不是 `Send`，
//! 无法跨 `await` 持有或放进全局缓存。因此这里只缓存脚本文本，
//! 解析直链时在阻塞线程内临时构建沙箱、用完即弃。
//! 单次直链解析的脚本初始化开销约在毫秒级，相对网络请求可忽略。

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{OnceLock, RwLock};

use serde::{Deserialize, Serialize};

use super::lx_sandbox::{parse_script_meta, LxSandbox};

/// 已安装插件的元信息。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginInfo {
    /// 插件唯一标识（由脚本名与作者推导）。
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    /// 是否启用。停用后不参与直链解析。
    pub enabled: bool,
    /// 脚本上报支持的音源标识（kw/kg/tx/wy 等）。
    pub sources: Vec<String>,
    /// 各音源支持的音质档位。
    pub qualitys: HashMap<String, Vec<String>>,
    /// 安装来源：本地文件路径或订阅 URL，便于后续更新。
    pub origin: String,
}

/// 插件索引文件结构。
#[derive(Debug, Default, Serialize, Deserialize)]
struct PluginIndex {
    plugins: Vec<PluginInfo>,
}

/// 进程内索引缓存，避免每次解析都读盘。
static INDEX_CACHE: OnceLock<RwLock<Option<PluginIndex>>> = OnceLock::new();

fn index_cache() -> &'static RwLock<Option<PluginIndex>> {
    INDEX_CACHE.get_or_init(|| RwLock::new(None))
}

fn plugins_dir(data_dir: &str) -> PathBuf {
    Path::new(data_dir).join("plugins")
}

fn index_path(data_dir: &str) -> PathBuf {
    plugins_dir(data_dir).join("index.json")
}

fn script_path(data_dir: &str, id: &str) -> PathBuf {
    plugins_dir(data_dir).join(format!("{id}.js"))
}

/// 读取索引（优先用缓存）。
fn load_index(data_dir: &str) -> PluginIndex {
    if let Ok(guard) = index_cache().read() {
        if let Some(idx) = guard.as_ref() {
            return PluginIndex {
                plugins: idx.plugins.clone(),
            };
        }
    }
    let path = index_path(data_dir);
    let idx = fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str::<PluginIndex>(&s).ok())
        .unwrap_or_default();
    if let Ok(mut guard) = index_cache().write() {
        *guard = Some(PluginIndex {
            plugins: idx.plugins.clone(),
        });
    }
    idx
}

/// 写回索引并刷新缓存。
fn save_index(data_dir: &str, index: &PluginIndex) -> Result<(), String> {
    let dir = plugins_dir(data_dir);
    fs::create_dir_all(&dir).map_err(|e| format!("创建插件目录失败: {e}"))?;
    let json = serde_json::to_string_pretty(index).map_err(|e| e.to_string())?;
    fs::write(index_path(data_dir), json).map_err(|e| format!("写入插件索引失败: {e}"))?;
    if let Ok(mut guard) = index_cache().write() {
        *guard = Some(PluginIndex {
            plugins: index.plugins.clone(),
        });
    }
    Ok(())
}

/// 由脚本元信息推导稳定的插件 id。
///
/// 同名同作者的脚本重复导入时会覆盖，避免堆积重复项。
fn derive_id(name: &str, author: &str) -> String {
    let raw = format!("{}-{}", name.trim(), author.trim());
    let digest = format!("{:x}", md5::compute(raw.as_bytes()));

    // id 会作为文件名使用，只保留 ASCII 字母数字做可读前缀，
    // 避免中文或特殊字符在不同文件系统上的兼容问题。
    let slug: String = name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(12)
        .collect::<String>()
        .to_lowercase();

    if slug.is_empty() {
        digest
    } else {
        // 摘要保证唯一性，前缀仅为便于辨认。
        format!("{slug}-{}", &digest[..16])
    }
}

/// 列出已安装插件。
pub fn list_plugins(data_dir: &str) -> Vec<PluginInfo> {
    load_index(data_dir).plugins
}

/// 安装插件脚本。
///
/// 会先在沙箱中试运行，确认脚本能正常上报音源，再落盘。
/// 这样可以在导入阶段就拦掉无效脚本，而不是等到播放时才失败。
pub fn install_plugin(data_dir: &str, script: &str, origin: &str) -> Result<PluginInfo, String> {
    if script.trim().is_empty() {
        return Err("脚本内容为空".to_string());
    }

    // 试运行：验证脚本有效性并取得音源能力。
    let sandbox = LxSandbox::load(script)?;
    let meta = sandbox.meta().clone();
    let caps = sandbox.sources().clone();

    let fallback_meta = parse_script_meta(script);
    let name = if meta.name.is_empty() {
        if fallback_meta.name.is_empty() {
            "未命名音源".to_string()
        } else {
            fallback_meta.name
        }
    } else {
        meta.name
    };

    let id = derive_id(&name, &meta.author);
    let mut sources: Vec<String> = caps.keys().cloned().collect();
    sources.sort();
    let qualitys: HashMap<String, Vec<String>> = caps
        .iter()
        .map(|(k, v)| (k.clone(), v.qualitys.clone()))
        .collect();

    let info = PluginInfo {
        id: id.clone(),
        name,
        version: meta.version,
        author: meta.author,
        description: meta.description,
        enabled: true,
        sources,
        qualitys,
        origin: origin.to_string(),
    };

    // 落盘脚本。
    let dir = plugins_dir(data_dir);
    fs::create_dir_all(&dir).map_err(|e| format!("创建插件目录失败: {e}"))?;
    fs::write(script_path(data_dir, &id), script)
        .map_err(|e| format!("保存插件脚本失败: {e}"))?;

    // 更新索引：同 id 覆盖。
    let mut index = load_index(data_dir);
    index.plugins.retain(|p| p.id != id);
    index.plugins.push(info.clone());
    save_index(data_dir, &index)?;

    Ok(info)
}

/// 从订阅 URL 安装插件。
pub async fn install_plugin_from_url(data_dir: &str, url: &str) -> Result<PluginInfo, String> {
    let resp = super::plugin_http_request(
        "GET".to_string(),
        url.to_string(),
        Some(HashMap::from([(
            "User-Agent".to_string(),
            "lx-music request".to_string(),
        )])),
        None,
        Some(30),
        Some(5),
    )
    .await?;

    if resp.status != 200 {
        return Err(format!("下载脚本失败: HTTP {}", resp.status));
    }
    install_plugin(data_dir, &resp.body, url)
}

/// 设置启用状态。
pub fn set_plugin_enabled(data_dir: &str, id: &str, enabled: bool) -> Result<(), String> {
    let mut index = load_index(data_dir);
    let target = index
        .plugins
        .iter_mut()
        .find(|p| p.id == id)
        .ok_or_else(|| "插件不存在".to_string())?;
    target.enabled = enabled;
    save_index(data_dir, &index)
}

/// 卸载插件（删除脚本与索引项）。
pub fn remove_plugin(data_dir: &str, id: &str) -> Result<(), String> {
    let mut index = load_index(data_dir);
    let before = index.plugins.len();
    index.plugins.retain(|p| p.id != id);
    if index.plugins.len() == before {
        return Err("插件不存在".to_string());
    }
    // 脚本文件删除失败不阻断索引更新，避免残留条目。
    let _ = fs::remove_file(script_path(data_dir, id));
    save_index(data_dir, &index)
}

/// 是否存在可用于该音源的已启用插件。
pub fn has_enabled_plugin_for(data_dir: &str, source: &str) -> bool {
    load_index(data_dir)
        .plugins
        .iter()
        .any(|p| p.enabled && p.sources.iter().any(|s| s == source))
}

/// 用已启用的插件解析播放直链。
///
/// 按索引顺序依次尝试支持该音源的插件，任一成功即返回。
/// 沙箱在阻塞线程内构建，避免 `Context` 跨线程/跨 await。
pub fn resolve_url_with_plugins(
    data_dir: &str,
    source: &str,
    song_info_json: &str,
    quality: &str,
) -> Result<String, String> {
    let candidates: Vec<PluginInfo> = load_index(data_dir)
        .plugins
        .into_iter()
        .filter(|p| p.enabled && p.sources.iter().any(|s| s == source))
        .collect();

    if candidates.is_empty() {
        return Err("没有可用于该音源的插件".to_string());
    }

    let mut last_err = String::new();
    for plugin in candidates {
        let path = script_path(data_dir, &plugin.id);
        let script = match fs::read_to_string(&path) {
            Ok(s) => s,
            Err(e) => {
                last_err = format!("读取脚本失败: {e}");
                continue;
            }
        };

        // 音质降级：插件声明的档位里挑一个可用的。
        let qualities = pick_qualities(&plugin, source, quality);
        let mut sandbox = match LxSandbox::load(&script) {
            Ok(s) => s,
            Err(e) => {
                last_err = format!("插件 {} 初始化失败: {e}", plugin.name);
                continue;
            }
        };

        for q in qualities {
            match sandbox.get_music_url(source, song_info_json, &q) {
                Ok(url) if !url.is_empty() => return Ok(url),
                Ok(_) => last_err = "插件返回空链接".to_string(),
                Err(e) => last_err = e,
            }
        }
    }

    Err(if last_err.is_empty() {
        "所有插件均未返回播放链接".to_string()
    } else {
        last_err
    })
}

/// 生成音质尝试顺序：首选请求音质，其余按插件声明降级。
fn pick_qualities(plugin: &PluginInfo, source: &str, preferred: &str) -> Vec<String> {
    let declared = plugin.qualitys.get(source).cloned().unwrap_or_default();
    let mut out = Vec::new();
    if declared.iter().any(|q| q == preferred) || declared.is_empty() {
        out.push(preferred.to_string());
    }
    // 常见档位从高到低补齐，仅保留插件声明过的。
    for q in ["320k", "128k"] {
        if q != preferred && declared.iter().any(|d| d == q) {
            out.push(q.to_string());
        }
    }
    if out.is_empty() {
        out.push(preferred.to_string());
    }
    out
}
