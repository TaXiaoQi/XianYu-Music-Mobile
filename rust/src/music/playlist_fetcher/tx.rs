// 歌单导入 QQ 音乐平台实现：自前端 playlistImportTx.ts 移植（内置主链路）。

use serde_json::{json, Value};

use super::common::{
    decode_name, format_play_time, format_singer_name, http_fetch_json, PlaylistImportResult,
    PlaylistInfo, PlaylistSong,
};

/// 歌单 id 归一化：对齐前端 getTxListId（playlistImportBase.ts）。
/// 含 [?&:/] 视为链接，依次按 /playlist/(\d+)、id=(\d+)、/playsquare/(\d+)
/// 提取，均未命中返回 None；否则原样返回。
fn get_tx_list_id(raw_id: &str) -> Option<String> {
    // 对齐 TS 正则 /[?&:/]/ 的字符判断
    if raw_id.chars().any(|c| matches!(c, '?' | '&' | ':' | '/')) {
        if let Some(m) = regex::Regex::new(r"/playlist/(\d+)")
            .ok()?
            .captures(raw_id)
            .and_then(|c| c.get(1))
        {
            return Some(m.as_str().to_string());
        }
        if let Some(m) = regex::Regex::new(r"id=(\d+)")
            .ok()?
            .captures(raw_id)
            .and_then(|c| c.get(1))
        {
            return Some(m.as_str().to_string());
        }
        if let Some(m) = regex::Regex::new(r"/playsquare/(\d+)")
            .ok()?
            .captures(raw_id)
            .and_then(|c| c.get(1))
        {
            return Some(m.as_str().to_string());
        }
        return None;
    }
    Some(raw_id.to_string())
}

/// QQ 音乐歌单详情入口：对齐前端 getListDetailTx（playlistImportTx.ts）。
pub(super) async fn get_list_detail_tx(raw_id: &str) -> Result<PlaylistImportResult, String> {
    // TS 以 !id 判断空串，空串同样视为未解析
    let mut id = get_tx_list_id(raw_id).filter(|s| !s.is_empty());
    if id.is_none() && (raw_id.starts_with("http://") || raw_id.starts_with("https://")) {
        id = resolve_tx_share_url(raw_id).await;
    }
    let id = match id {
        Some(id) => id,
        None => return Ok(PlaylistImportResult::empty("tx")),
    };

    // 对齐 TS 的歌单详情 URL 拼接
    let url = format!(
        "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg\
            ?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid={id}\
            &loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8\
            &notice=0&platform=yqq.json&needNewCode=0"
    );
    let referer = format!("https://y.qq.com/n/yqq/playsquare/{id}.html");
    let headers = [("Origin", "https://y.qq.com"), ("Referer", referer.as_str())];
    let resp = http_fetch_json(&url, "GET", &headers, None, None).await?;

    let body = &resp.body;
    // TS：typeof body !== 'object' || body === null || body.code !== 0 → throw
    let code_ok = body.get("code").and_then(|v| v.as_f64()) == Some(0.0);
    if !matches!(body, Value::Object(_)) || !code_ok {
        // 对齐 TS `body?.code ?? 'unknown'`：仅 null/缺失记为 unknown
        let code_text = match body.get("code") {
            Some(Value::Null) | None => "unknown".to_string(),
            Some(Value::String(s)) => s.clone(),
            Some(other) => other.to_string(),
        };
        return Err(format!("QQ音乐歌单获取失败: code={}", code_text));
    }

    // cdlist 为空 → 空结果
    let Some(cd) = body
        .get("cdlist")
        .and_then(|v| v.as_array())
        .and_then(|list| list.first())
    else {
        return Ok(PlaylistImportResult::empty("tx"));
    };

    let mut songs: Vec<PlaylistSong> = Vec::new();
    for item in cd
        .get("songlist")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
    {
        if let Some(song) = parse_tx_song(item) {
            songs.push(song);
        }
    }

    let total = songs.len() as i64;
    let info = build_playlist_info(cd);
    Ok(PlaylistImportResult {
        source: "tx".to_string(),
        songs,
        total,
        info,
    })
}

/// 对齐 TS info 组装：dissname/desc 解码，desc 中 <br> 转换行；nickname 不解码；
/// playCount = String(cd.visitnum || 0)。
fn build_playlist_info(cd: &Value) -> PlaylistInfo {
    let desc = decode_name(cd.get("desc").and_then(|v| v.as_str()).unwrap_or(""))
        .replace("<br>", "\n");
    let play_count = match cd.get("visitnum") {
        Some(v @ Value::Number(_)) if v.as_f64().unwrap_or(0.0) != 0.0 => v.to_string(),
        _ => "0".to_string(),
    };
    PlaylistInfo {
        name: decode_name(cd.get("dissname").and_then(|v| v.as_str()).unwrap_or("")),
        img: cd
            .get("logo")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        desc,
        author: cd
            .get("nickname")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        play_count,
    }
}

/// 对齐前端 parseTxSong：字段映射 + 封面选择 + rawData 组装；duration 为毫秒。
fn parse_tx_song(item: &Value) -> Option<PlaylistSong> {
    let songmid = item.get("mid").and_then(|v| v.as_str()).unwrap_or("");
    // songId = String(item.id || '')：id 为 0/null/缺失时视为空
    let song_id = match item.get("id") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) if n.as_f64().unwrap_or(0.0) != 0.0 => n.to_string(),
        _ => String::new(),
    };
    if songmid.is_empty() && song_id.is_empty() {
        return None;
    }

    let empty_list = Value::Array(Vec::new());
    let singer = item.get("singer").unwrap_or(&empty_list);
    let singer_name = format_singer_name(singer);
    let name = decode_name(item.get("title").and_then(|v| v.as_str()).unwrap_or(""));

    let empty_obj = Value::Object(serde_json::Map::new());
    let album = item.get("album").unwrap_or(&empty_obj);
    let album_name = decode_name(album.get("name").and_then(|v| v.as_str()).unwrap_or(""));
    let album_mid = album
        .get("mid")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let interval = item.get("interval").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let str_media_mid = item
        .get("file")
        .and_then(|f| f.get("media_mid"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    // 封面：专辑名缺失或为「空」时退回歌手头像（无歌手则为空串）
    let img = if album_name.is_empty() || album_name == "空" {
        match singer.get(0) {
            Some(first) => format!(
                "https://y.gtimg.cn/music/photo_new/T001R500x500M000{}.jpg",
                first.get("mid").and_then(|v| v.as_str()).unwrap_or("")
            ),
            None => String::new(),
        }
    } else {
        format!(
            "https://y.gtimg.cn/music/photo_new/T002R500x500M000{}.jpg",
            album_mid
        )
    };

    let raw_data = json!({
        "songmid": songmid,
        "songId": song_id,
        "strMediaMid": str_media_mid,
        "albumMid": album_mid,
        "name": name,
        "singer": singer_name,
        "source": "tx",
        "interval": format_play_time(interval),
    });

    Some(PlaylistSong::new(
        if songmid.is_empty() { song_id.as_str() } else { songmid },
        &name,
        &singer_name,
        &album_name,
        &img,
        (interval * 1000.0) as i64,
        "QQ音乐",
        "tx",
        raw_data,
    ))
}

/// 对齐前端 resolveTxShareUrl：GET 分享链接，依次按多组正则提取歌单 id。
async fn resolve_tx_share_url(url: &str) -> Option<String> {
    let headers = [(
        "User-Agent",
        "Mozilla/5.0 (Linux; Android 10; HLK-AL00) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.5112.102 Mobile Safari/537.36 EdgA/104.0.1293.70",
    )];
    let resp = match http_fetch_json(url, "GET", &headers, None, None).await {
        Ok(resp) => resp,
        Err(e) => {
            eprintln!("[playlist_fetcher] resolveTxShareUrl failed: {}", e);
            return None;
        }
    };
    // TS：body 为字符串直接使用，否则 JSON.stringify
    let body_text = match &resp.body {
        Value::String(s) => s.clone(),
        other => serde_json::to_string(other).unwrap_or_default(),
    };

    let patterns = [
        r"id=(\d+)",
        r"/playlist/(\d+)",
        r"/playsquare/(\d+)",
        r#""disstid"\s*:\s*"?(\d+)"?"#,
        r#""dissid"\s*:\s*"?(\d+)"?"#,
    ];
    for pattern in patterns {
        let Ok(re) = regex::Regex::new(pattern) else {
            continue;
        };
        if let Some(m) = re.captures(&body_text).and_then(|c| c.get(1)) {
            return Some(m.as_str().to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_body() -> Value {
        serde_json::from_str(include_str!("../fixtures/playlist/tx.json"))
            .expect("tx fixture 应为合法 JSON")
    }

    fn fixture_song(index: usize) -> Value {
        fixture_body()["cdlist"][0]["songlist"][index].clone()
    }

    #[test]
    fn get_tx_list_id_accepts_plain_id() {
        assert_eq!(get_tx_list_id("8012590246"), Some("8012590246".to_string()));
    }

    #[test]
    fn get_tx_list_id_parses_urls() {
        assert_eq!(
            get_tx_list_id("https://y.qq.com/n/yqq/playlist/8012590246.html"),
            Some("8012590246".to_string())
        );
        assert_eq!(
            get_tx_list_id("https://i.y.qq.com/n2/m/share/details/taoge.html?id=8012590246&host=uin"),
            Some("8012590246".to_string())
        );
        assert_eq!(
            get_tx_list_id("https://y.qq.com/n/yqq/playsquare/8012590246.html"),
            Some("8012590246".to_string())
        );
    }

    #[test]
    fn get_tx_list_id_returns_none_when_no_match() {
        assert_eq!(get_tx_list_id("https://y.qq.com/n/yqq/album.html"), None);
    }

    #[test]
    fn parse_tx_song_maps_fields() {
        let song = parse_tx_song(&fixture_song(0)).expect("歌曲应解析成功");
        assert_eq!(song.id, "003MUv3q2XfUvE");
        assert_eq!(song.platform_id, "003MUv3q2XfUvE");
        assert_eq!(song.title, "晴天");
        assert_eq!(song.artist, "周杰伦、合唱团");
        assert_eq!(song.album, "叶惠美");
        assert_eq!(song.platform, "QQ音乐");
        assert_eq!(song.plugin_id, "tx");
    }

    #[test]
    fn parse_tx_song_cover_uses_album_mid() {
        let song = parse_tx_song(&fixture_song(0)).expect("歌曲应解析成功");
        assert_eq!(
            song.cover_url,
            "https://y.gtimg.cn/music/photo_new/T002R500x500M000001J5QJL1pRQYB.jpg"
        );
    }

    #[test]
    fn parse_tx_song_cover_falls_back_to_singer() {
        // 专辑名为「空」→ 歌手头像
        let song = parse_tx_song(&fixture_song(1)).expect("歌曲应解析成功");
        assert_eq!(
            song.cover_url,
            "https://y.gtimg.cn/music/photo_new/T001R500x500M000singerMid001.jpg"
        );

        // 专辑缺失 → 歌手头像
        let mut item = fixture_song(0);
        item["album"] = Value::Null;
        let song = parse_tx_song(&item).expect("歌曲应解析成功");
        assert_eq!(
            song.cover_url,
            "https://y.gtimg.cn/music/photo_new/T001R500x500M0000025NhlN2yWrP4.jpg"
        );

        // 无歌手 → 封面为空串
        item["singer"] = json!([]);
        let song = parse_tx_song(&item).expect("歌曲应解析成功");
        assert_eq!(song.cover_url, "");
    }

    #[test]
    fn parse_tx_song_raw_data_keys_and_values() {
        let song = parse_tx_song(&fixture_song(0)).expect("歌曲应解析成功");
        let raw = song.raw_data.as_object().expect("rawData 应为对象");
        // Object 键按字母序存储，只断言键存在性与取值
        for key in [
            "songmid", "songId", "strMediaMid", "albumMid", "name", "singer", "source", "interval",
        ] {
            assert!(raw.contains_key(key), "rawData 缺少键 {}", key);
        }
        assert_eq!(raw["songmid"], "003MUv3q2XfUvE");
        assert_eq!(raw["songId"], "483034299");
        assert_eq!(raw["strMediaMid"], "220770519");
        assert_eq!(raw["albumMid"], "001J5QJL1pRQYB");
        assert_eq!(raw["name"], "晴天");
        assert_eq!(raw["singer"], "周杰伦、合唱团");
        assert_eq!(raw["source"], "tx");
        // 269s → 04:29
        assert_eq!(raw["interval"], "04:29");
    }

    #[test]
    fn parse_tx_song_duration_is_milliseconds() {
        let first = parse_tx_song(&fixture_song(0)).expect("歌曲应解析成功");
        assert_eq!(first.duration, 269_000);
        let second = parse_tx_song(&fixture_song(1)).expect("歌曲应解析成功");
        assert_eq!(second.duration, 60_000);
    }

    #[test]
    fn parse_tx_song_skips_entry_without_ids() {
        assert!(parse_tx_song(&json!({ "title": "无ID歌曲" })).is_none());
    }

    #[test]
    fn playlist_info_decodes_and_converts_br() {
        let info = build_playlist_info(&fixture_body()["cdlist"][0]);
        assert_eq!(info.name, "测试歌单");
        assert_eq!(info.img, "https://y.gtimg.cn/logo.jpg");
        assert_eq!(info.desc, "第一行\n第二行");
        assert_eq!(info.author, "作者");
        assert_eq!(info.play_count, "456");

        // 多个 <br> 全部替换
        let mut cd = fixture_body()["cdlist"][0].clone();
        cd["desc"] = json!("A<br>B<br>C");
        assert_eq!(build_playlist_info(&cd).desc, "A\nB\nC");
    }
}