//! 音源插件管理：安装、启用停用、卸载、直链解析。
//!
//! 插件脚本保存在 `{data_dir}/plugins/{id}.js`，元信息索引保存在
//! `{data_dir}/plugins/index.json`，与桌面端的插件目录职责一致。
//!
//! # 脚本执行引擎
//!
//! 脚本试运行与直链解析统一走 [`crate::plugin_host`]（QuickJS，
//! 与桌面端同架构）。每次操作用唯一实例 id 装载、用完即卸载，
//! 避免并发解析同一插件时互相销毁实例。

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{OnceLock, RwLock};

use serde::{Deserialize, Serialize};

/// 脚本元信息（取自脚本头部注释）。
#[derive(Debug, Clone, Default, Serialize)]
pub struct ScriptMeta {
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    pub homepage: String,
}

/// 从脚本头部注释解析元信息。
///
/// 形如：
/// ```text
/// /*!
///  * @name ikun音源
///  * @version v26
///  * @author ikunshare
///  */
/// ```
pub fn parse_script_meta(script: &str) -> ScriptMeta {
    let mut meta = ScriptMeta::default();
    // 只扫描前若干行，避免在混淆正文里误匹配。
    for line in script.lines().take(40) {
        let line = line.trim().trim_start_matches('*').trim();
        let Some(rest) = line.strip_prefix('@') else {
            continue;
        };
        let mut parts = rest.splitn(2, char::is_whitespace);
        let key = parts.next().unwrap_or("").to_ascii_lowercase();
        let value = parts.next().unwrap_or("").trim().to_string();
        if value.is_empty() {
            continue;
        }
        match key.as_str() {
            "name" => meta.name = value,
            "version" => meta.version = value,
            "author" => meta.author = value,
            "description" => meta.description = value,
            "homepage" => meta.homepage = value,
            _ => {}
        }
    }
    meta
}

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

/// 生成一次性引擎实例 id：并发解析同一插件时互不干扰。
fn probe_instance_id() -> String {
    format!("lx-probe-{}", uuid::Uuid::new_v4().simple())
}

/// 在 QuickJS 引擎中试运行脚本，返回脚本上报的音源能力
/// `{ 音源标识 → 音质档位列表 }`。
async fn probe_sources(data_dir: &str, script: &str) -> Result<HashMap<String, Vec<String>>, String> {
    let engine = crate::plugin_host::global_engine(data_dir);
    let instance = probe_instance_id();

    let meta = parse_script_meta(script);
    let script_info = serde_json::json!({
        "name": meta.name,
        "version": meta.version,
        "author": meta.author,
        "description": meta.description,
        "homepage": meta.homepage,
    });

    let result = engine
        .load_lx(&instance, script, &script_info.to_string())
        .await;
    let sources = match result {
        r if r.ok => sources_from_init_info(r.metadata.as_ref()),
        r => Err(r.error.unwrap_or_else(|| "脚本初始化失败".to_string())),
    };
    engine.unload(&instance).await;
    sources
}

/// 从 `load_lx` 返回的 initInfo 提取音源能力。
fn sources_from_init_info(
    metadata: Option<&serde_json::Value>,
) -> Result<HashMap<String, Vec<String>>, String> {
    let Some(meta) = metadata else {
        return Err("脚本未上报音源信息".to_string());
    };
    let Some(sources) = meta.get("sources").and_then(|s| s.as_object()) else {
        return Err("脚本未上报任何可用音源".to_string());
    };

    let mut out = HashMap::new();
    for (key, val) in sources {
        let qualitys = val
            .get("qualitys")
            .and_then(|q| q.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        out.insert(key.clone(), qualitys);
    }
    if out.is_empty() {
        return Err("脚本未上报任何可用音源".to_string());
    }
    Ok(out)
}

/// 安装插件脚本。
///
/// 会先在引擎中试运行，确认脚本能正常上报音源，再落盘。
/// 这样可以在导入阶段就拦掉无效脚本，而不是等到播放时才失败。
pub async fn install_plugin(
    data_dir: &str,
    script: &str,
    origin: &str,
) -> Result<PluginInfo, String> {
    if script.trim().is_empty() {
        return Err("脚本内容为空".to_string());
    }

    // 试运行：验证脚本有效性并取得音源能力。
    let caps = probe_sources(data_dir, script).await?;
    let meta = parse_script_meta(script);
    let name = if meta.name.is_empty() {
        "未命名音源".to_string()
    } else {
        meta.name
    };

    let id = derive_id(&name, &meta.author);
    let mut sources: Vec<String> = caps.keys().cloned().collect();
    sources.sort();

    let info = PluginInfo {
        id: id.clone(),
        name,
        version: meta.version,
        author: meta.author,
        description: meta.description,
        enabled: true,
        sources,
        qualitys: caps,
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
    install_plugin(data_dir, &resp.body, url).await
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
/// 每个插件用一次性引擎实例执行，用完即卸载。
pub async fn resolve_url_with_plugins(
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

    let engine = crate::plugin_host::global_engine(data_dir);
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

        let instance = probe_instance_id();
        let meta = parse_script_meta(&script);
        let script_info = serde_json::json!({
            "name": meta.name,
            "version": meta.version,
            "author": meta.author,
            "description": meta.description,
            "homepage": meta.homepage,
        });

        let loaded = engine
            .load_lx(&instance, &script, &script_info.to_string())
            .await;
        if !loaded.ok {
            last_err = format!(
                "插件 {} 初始化失败: {}",
                plugin.name,
                loaded.error.unwrap_or_else(|| "未知错误".to_string())
            );
            engine.unload(&instance).await;
            continue;
        }

        let music_info: serde_json::Value =
            serde_json::from_str(song_info_json).unwrap_or(serde_json::Value::Null);

        for q in &qualities {
            let args = serde_json::json!([{
                "source": source,
                "action": "musicUrl",
                "info": { "musicInfo": music_info, "type": q },
            }]);
            let call = engine
                .call(&instance, "request", &args.to_string(), None, 30_000)
                .await;

            let url = match call {
                r if r.ok => r
                    .data
                    .and_then(|d| d.as_str().map(str::to_string))
                    .filter(|u| !u.is_empty()),
                r => {
                    last_err = r.error.unwrap_or_else(|| "插件调用失败".to_string());
                    None
                }
            };

            match url {
                Some(u) => {
                    engine.unload(&instance).await;
                    return Ok(u);
                }
                None => {
                    if last_err.is_empty() {
                        last_err = "插件未返回播放链接".to_string();
                    }
                }
            }
        }
        engine.unload(&instance).await;
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
    // 常见档位从高到低补齐，仅保留插件声明过的（对齐桌面端 12 档 rank 排序）。
    for q in [
        "master", "atmos_plus", "atmos", "dolby", "vinyl", "hires", "flac24bit", "flac",
        "320k", "192k", "128k", "mgg",
    ] {
        if q != preferred && declared.iter().any(|d| d == q) {
            out.push(q.to_string());
        }
    }
    if out.is_empty() {
        out.push(preferred.to_string());
    }
    out
}
