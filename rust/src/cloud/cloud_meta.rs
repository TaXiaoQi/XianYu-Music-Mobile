// 云端曲目内嵌元数据头部预探（自桌面端 src-tauri/src/player/cloud_meta.rs 移植）。
//
// 网盘列表/播放接口不返回内嵌标签：按直链 Range 拉头 2MB，用 lofty 渐进解析
// 内嵌封面/歌词/时长，结果持久化到本地索引（data_dir/cloud_meta_index.json）
// 并回传 Dart 回填（封面已落盘，直接给绝对路径）。列表期与播放期共用本探针
// ——播放期拿到的是新鲜直链，无需等待流缓存，故不需要桌面版的缓存快照轮询。
//
// 部分文件解析约束：FLAC/ID3v2 元数据块都在文件头部，头 2MB 足够解出
// 标签与封面；FLAC 时长取 STREAMINFO（精确），MP3 时长按
// 总字节×8/码率估算（头部码率），总长未知则不回填时长。

use lofty::file::{AudioFile, FileType, TaggedFileExt};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use crate::music::covers;
use crate::music::tags::{extract_embedded_lyrics, find_embedded_picture, read_tagged_file_from_path};
use crate::security::ssrf;

/// 头部拉取上限：探针只读头部标签，拿不到就放弃（不打扰播放）。
const HEAD_RANGE_BYTES: u64 = 2 * 1024 * 1024;
/// 边下边试的首个解析门槛：FLAC/ID3 头部标签通常远小于此。
const HEAD_FIRST_TRY_BYTES: usize = 128 * 1024;

/// 探针结果（字段名冻结，Dart 按 camelCase 消费）。
/// 同时作为本地持久化索引的条目（cloud_meta_index.json，跨会话复用）。
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudTrackMetaPayload {
    pub cloud_path: String,
    pub url: String,
    pub lyrics_raw: Option<String>,
    pub cover_path: Option<String>,
    pub duration_secs: Option<u32>,
}

// ---------------------------------------------------------------------------
// 本地元数据索引（跨会话）：解析成功的封面/歌词/时长按 cloud_path 落盘，
// 下次列表装配/播放直接命中，不再走直链探针。
// ---------------------------------------------------------------------------

fn index_cache_slot() -> &'static Mutex<Option<HashMap<String, CloudTrackMetaPayload>>> {
    static CELL: OnceLock<Mutex<Option<HashMap<String, CloudTrackMetaPayload>>>> = OnceLock::new();
    CELL.get_or_init(|| Mutex::new(None))
}

/// 索引文件路径：data_dir/cloud_meta_index.json。
fn index_path(data_dir: &Path) -> PathBuf {
    data_dir.join("cloud_meta_index.json")
}

/// 从磁盘读索引；封面文件已丢失的条目降级（封面置空，歌词/时长保留）。
fn load_index_from_disk(data_dir: &Path) -> HashMap<String, CloudTrackMetaPayload> {
    let Ok(text) = std::fs::read_to_string(index_path(data_dir)) else {
        return HashMap::new();
    };
    let map: HashMap<String, CloudTrackMetaPayload> = match serde_json::from_str(&text) {
        Ok(map) => map,
        Err(_) => return HashMap::new(),
    };
    map.into_iter()
        .filter_map(|(key, mut payload)| {
            if let Some(p) = &payload.cover_path {
                if !Path::new(p).exists() {
                    payload.cover_path = None;
                }
            }
            let has_any = payload.cover_path.is_some()
                || payload.lyrics_raw.is_some()
                || payload.duration_secs.is_some();
            has_any.then_some((key, payload))
        })
        .collect()
}

/// 读取索引（进程内 memo，首次落盘读，之后走内存）。
pub fn load_index(data_dir: &Path) -> HashMap<String, CloudTrackMetaPayload> {
    if let Ok(guard) = index_cache_slot().lock() {
        if let Some(map) = guard.as_ref() {
            return map.clone();
        }
    }
    let map = load_index_from_disk(data_dir);
    if let Ok(mut guard) = index_cache_slot().lock() {
        *guard = Some(map.clone());
    }
    map
}

/// 解析成功后写索引（读-改-写 + 进程内 memo 同步更新；文件小，直接同步落盘）。
fn persist_entry(data_dir: &Path, payload: &CloudTrackMetaPayload) {
    let mut map = load_index(data_dir);
    map.insert(payload.cloud_path.clone(), payload.clone());
    if let Ok(mut guard) = index_cache_slot().lock() {
        *guard = Some(map.clone());
    }
    let path = index_path(data_dir);
    if let Ok(json) = serde_json::to_string(&map) {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&path, json);
    }
}

/// 索引命中读取：供调用方在发起网络前短路（零网络回填）。
pub fn index_lookup(data_dir: &Path, cloud_path: &str) -> Option<CloudTrackMetaPayload> {
    load_index(data_dir).get(cloud_path).cloned()
}

/// 探测诊断日志：落盘排查（超 1MB 重建），只记主机名等脱敏信息。
fn probe_log(data_dir: &Path, line: &str) {
    eprintln!("{line}");
    let path = data_dir.join("cloud_meta_probe.log");
    if let Ok(meta) = std::fs::metadata(&path) {
        if meta.len() > 1_000_000 {
            let _ = std::fs::remove_file(&path);
        }
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        use std::io::Write;
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = writeln!(f, "[{ts}] {line}");
    }
}

/// 直链 host（日志脱敏：只记主机名，不落签名参数）。
fn url_host(url: &str) -> &str {
    url.split("://")
        .nth(1)
        .and_then(|rest| rest.split(['/']).next())
        .unwrap_or("?")
}

/// 头部预探主入口：Range 拉头渐进解析，成功返回 payload（已写索引），
/// 失败 Err(简短原因)。任一步失败静默降级——列表期探测不打扰用户。
pub async fn probe_head(
    data_dir: &Path,
    covers_dir: &Path,
    url: &str,
    headers: Option<&HashMap<String, String>>,
    cloud_path: &str,
    duration_hint: u32,
) -> Result<CloudTrackMetaPayload, String> {
    // 索引命中：不碰网络直接返回
    if let Some(hit) = index_lookup(data_dir, cloud_path) {
        probe_log(
            data_dir,
            &format!("[cloud-head] 索引命中 host={} ({cloud_path})", url_host(url)),
        );
        return Ok(hit);
    }
    let hdr_note = headers
        .map(|h| format!("hdrs={}", h.len()))
        .unwrap_or_else(|| "hdrs=0".to_string());
    probe_log(
        data_dir,
        &format!("[cloud-head] 开始 host={host} {hdr_note}", host = url_host(url)),
    );
    ssrf::validate_url_ip_literal(url)?;

    let client = reqwest::Client::builder()
        // 移动网速下慢 CDN 拉 2MB 需要余量（超时表现为 chunk 阶段
        // "error decoding response body"，修复解析后渐进 break 通常远快于此）。
        // 实测阿里非会员无 cdn_url，手机到 dl1 断流级 <3KB/s：128KB 首个
        // 解析检查点要 ~45s，120s 保底熬到检查点后渐进 break。
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .map_err(|e| format!("client 构建失败: {e}"))?;
    let mut req = client
        .get(url)
        .header("Range", format!("bytes=0-{}", HEAD_RANGE_BYTES - 1));
    if let Some(hs) = headers {
        for (k, v) in hs {
            req = req.header(k.as_str(), v.as_str());
        }
    } else {
        req = req.header("User-Agent", "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36");
    }
    let mut resp = req.send().await.map_err(|e| {
        probe_log(
            data_dir,
            &format!("[cloud-head] 直链请求失败 host={}: {e}", url_host(url)),
        );
        "直链请求失败".to_string()
    })?;
    // content-range: "bytes 0-524287/92050432" → 总长（MP3 时长估算需要）
    let total_bytes = resp
        .headers()
        .get("content-range")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.rsplit('/').next())
        .and_then(|t| t.parse::<u64>().ok())
        .unwrap_or(0);
    let status = resp.status();
    // 非 2xx 直接落盘响应体片段（CDN 拒绝原因就在 body 里，如 OSS
    // AccessDenied XML），避免无效解析与猜测。
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        let snippet: String = body.chars().take(200).collect();
        probe_log(
            data_dir,
            &format!(
                "[cloud-head] 直链被拒 status={status} host={} body={snippet}",
                url_host(url)
            ),
        );
        return Err(format!("直链被拒 status={status}"));
    }

    // 流式下载 + 渐进解析：FLAC/ID3 标签在文件头，每到检查点就试解析，
    // 解出即中断下载（慢速节点不必等满 2MB）。
    let mut acc: Vec<u8> = Vec::with_capacity(HEAD_RANGE_BYTES as usize);
    let mut next_try = HEAD_FIRST_TRY_BYTES;
    let mut emitted: Option<CloudTrackMetaPayload> = None;
    while emitted.is_none() {
        let Some(chunk) = resp.chunk().await.map_err(|e| {
            probe_log(
                data_dir,
                &format!("[cloud-head] 直链读取失败 host={}: {e}", url_host(url)),
            );
            "直链读取失败".to_string()
        })?
        else {
            break; // 流结束
        };
        acc.extend_from_slice(&chunk);
        if acc.len() >= next_try {
            if let Some(payload) = extract_head_bytes(
                data_dir,
                covers_dir,
                &acc,
                total_bytes,
                url,
                cloud_path,
                duration_hint,
            ) {
                emitted = Some(payload);
                break;
            }
            next_try = (next_try * 2).min(HEAD_RANGE_BYTES as usize);
        }
        if acc.len() as u64 >= HEAD_RANGE_BYTES {
            break;
        }
    }
    if acc.is_empty() {
        probe_log(
            data_dir,
            &format!("[cloud-head] 响应为空 status={status} host={}", url_host(url)),
        );
        return Err("响应为空".to_string());
    }
    let payload = emitted.take().or_else(|| {
        extract_head_bytes(
            data_dir,
            covers_dir,
            &acc,
            total_bytes,
            url,
            cloud_path,
            duration_hint,
        )
    });
    match payload {
        Some(payload) => {
            probe_log(
                data_dir,
                &format!(
                    "[cloud-head] 就绪（{} bytes, status={status}）: cover={} lyrics={} dur={:?} ({cloud_path})",
                    acc.len(),
                    payload.cover_path.is_some(),
                    payload.lyrics_raw.is_some(),
                    payload.duration_secs
                ),
            );
            persist_entry(data_dir, &payload);
            Ok(payload)
        }
        None => {
            // 落盘响应头片段：200 OK 却拿到 HTML（WAF 挑战页/防盗链页）时
            // 直接可见内容，免二次猜。
            let head: String = String::from_utf8_lossy(
                &acc[..acc.len().min(6000)],
            )
            .chars()
            .map(|c| if c.is_control() { ' ' } else { c })
            .collect();
            probe_log(
                data_dir,
                &format!(
                    "[cloud-head] 解析无收获（status={status}, bytes={}, head={head}）: {cloud_path}",
                    acc.len()
                ),
            );
            Err("解析无收获".to_string())
        }
    }
}

/// 从缓冲的头部字节解析（临时文件供 lofty 按路径读，用完即删）。
/// tmp_dir 必须是应用可写目录（Android 上 std::env::temp_dir 回退
/// /data/local/tmp，应用进程无写权限，写入静默失败→一律「解析无收获」）。
fn extract_head_bytes(
    tmp_dir: &Path,
    covers_dir: &Path,
    bytes: &[u8],
    total_bytes: u64,
    url: &str,
    cloud_path: &str,
    duration_hint: u32,
) -> Option<CloudTrackMetaPayload> {
    let nonce = {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        url.hash(&mut h);
        h.finish()
    };
    // lofty 的 Probe::guess_file_type 按扩展名识别容器，固定 ".bin" 会直接
    // 解析失败（表现为 2MB 拉满却「解析无收获」），后缀必须还原真实类型
    let ext = probe_file_ext(url, bytes);
    let tmp = tmp_dir.join(format!("xym-cloud-head-{nonce:016x}{ext}"));
    std::fs::write(&tmp, bytes).ok()?;
    let payload = extract_meta(covers_dir, &tmp, total_bytes, url, cloud_path, duration_hint);
    let _ = std::fs::remove_file(&tmp);
    payload
}

/// 探针临时文件的扩展名：依次取 URL 路径扩展名 → 头部魔数嗅探，兜底 ".mp3"。
fn probe_file_ext(url: &str, bytes: &[u8]) -> String {
    if let Some(rest) = url.split("://").nth(1) {
        let path = rest.split('?').next().unwrap_or("");
        let last = path.rsplit('/').next().unwrap_or("");
        if let Some(dot) = last.rfind('.') {
            let ext = &last[dot + 1..];
            let ok = !ext.is_empty()
                && ext.len() <= 5
                && ext.chars().all(|c| c.is_ascii_alphanumeric());
            if ok {
                return format!(".{}", ext.to_ascii_lowercase());
            }
        }
    }
    if bytes.starts_with(b"fLaC") {
        return ".flac".into();
    }
    if bytes.starts_with(b"ID3") {
        return ".mp3".into();
    }
    if bytes.len() > 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 {
        return ".mp3".into();
    }
    if bytes.len() > 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE" {
        return ".wav".into();
    }
    if bytes.starts_with(b"OggS") {
        return ".ogg".into();
    }
    if bytes.len() > 12 && &bytes[4..8] == b"ftyp" {
        return ".m4a".into();
    }
    if bytes.starts_with(b"MAC ") {
        return ".ape".into();
    }
    ".mp3".into()
}

/// 从部分缓存文件提取内嵌元数据；无任何收获时返回 None。
fn extract_meta(
    covers_dir: &Path,
    partial_path: &Path,
    total_bytes: u64,
    url: &str,
    cloud_path: &str,
    duration_hint: u32,
) -> Option<CloudTrackMetaPayload> {
    let tagged = read_tagged_file_from_path(partial_path).ok()?;

    // 歌词：ID3v2 USLT / FLAC 通用 Lyrics 项
    let lyrics_raw = extract_embedded_lyrics(&tagged).filter(|s| !s.trim().is_empty());

    // 封面：内嵌图 → 按内容指纹落盘共享缓存
    let cover_path = find_embedded_picture(&tagged)
        .and_then(|pic| covers::save_embedded_cover_from_bytes(pic.data(), covers_dir));

    // 时长：FLAC 精确；MP3 按总长×8/码率估算；下载完成后直接信属性
    let props = tagged.properties();
    let duration_secs = {
        let from_props = props.duration().as_secs();
        let estimate_from_total = || {
            let bitrate = u64::from(props.audio_bitrate().unwrap_or(0));
            (total_bytes > 0 && bitrate > 0)
                .then(|| ((total_bytes * 8) / (bitrate * 1000)) as u32)
                .filter(|d| *d > 0)
        };
        if from_props > 0 && matches!(tagged.file_type(), FileType::Flac) {
            Some(from_props as u32) // STREAMINFO 与总长无关，部分文件也精确
        } else {
            estimate_from_total().or_else(|| {
                (duration_hint > 0).then_some(duration_hint) // 播放器实测值兜底
            })
        }
    };

    if lyrics_raw.is_none() && cover_path.is_none() && duration_secs.is_none() {
        return None;
    }

    Some(CloudTrackMetaPayload {
        cloud_path: cloud_path.to_string(),
        url: url.to_string(),
        lyrics_raw,
        cover_path,
        duration_secs,
    })
}

// ---------------------------------------------------------------------------
// api 层入参解析辅助（headers_json: "" 或字符串键值对 JSON object）
// ---------------------------------------------------------------------------

pub fn parse_headers_json(headers_json: &str) -> Result<Option<HashMap<String, String>>, String> {
    let s = headers_json.trim();
    if s.is_empty() {
        return Ok(None);
    }
    let v: Value =
        serde_json::from_str(s).map_err(|e| format!("headers 解析失败: {e}"))?;
    let Some(obj) = v.as_object() else {
        return Err("headers 必须是 JSON object".to_string());
    };
    let mut map = HashMap::new();
    for (k, val) in obj {
        let Some(sv) = val.as_str() else {
            continue; // 非字符串头忽略（调用方只传字符串头）
        };
        map.insert(k.clone(), sv.to_string());
    }
    Ok(Some(map))
}

/// 事件名与负载的单测锚点（防字段漂移，对齐桌面 payload 形态）。
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_serializes_camel_case() {
        let payload = CloudTrackMetaPayload {
            cloud_path: "cloud://a/_/x".into(),
            url: "https://example.com/f.mp3".into(),
            lyrics_raw: Some("[00:00.00]hi".into()),
            cover_path: Some("/data/covers/x.jpg".into()),
            duration_secs: Some(238),
        };
        let j = serde_json::to_value(&payload).unwrap();
        assert!(j.get("cloudPath").is_some());
        assert!(j.get("lyricsRaw").is_some());
        assert!(j.get("coverPath").is_some());
        assert!(j.get("durationSecs").is_some());
    }

    #[test]
    fn headers_json_parse() {
        assert!(parse_headers_json("").unwrap().is_none());
        let m = parse_headers_json(r#"{"User-Agent":"ua1","Referer":"r1"}"#)
            .unwrap()
            .unwrap();
        assert_eq!(m.get("User-Agent").map(String::as_str), Some("ua1"));
        assert!(parse_headers_json("[]").is_err());
    }
}
