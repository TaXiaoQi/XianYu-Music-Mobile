//! 沙箱端到端验证：载入真实音源脚本并获取播放直链。
//!
//! 运行：`cargo run --example sandbox_smoke`
//!
//! 验证链路：解析元信息 → 执行脚本 → 上报音源 → 调用 musicUrl 拿直链。
//! 依赖真实网络与音源可用性，失败不一定是代码缺陷。

use xianyu_core::plugins::lx_sandbox::LxSandbox;

fn main() {
    let script = include_str!("fixtures/lx_sample.js");
    println!("脚本长度: {} 字节", script.len());

    let mut sandbox = match LxSandbox::load(script) {
        Ok(s) => s,
        Err(e) => {
            println!("[FAIL] 沙箱载入失败: {e}");
            return;
        }
    };

    let meta = sandbox.meta().clone();
    println!("[OK] 载入成功");
    println!("     名称: {}", meta.name);
    println!("     版本: {}", meta.version);
    println!("     作者: {}", meta.author);

    let mut sources: Vec<_> = sandbox.sources().keys().cloned().collect();
    sources.sort();
    println!("     音源: {}", sources.join(", "));
    for (id, cap) in sandbox.sources() {
        println!("       {id}: actions={:?} qualitys={:?}", cap.actions, cap.qualitys);
    }

    // 用一首真实歌曲验证直链解析（酷我「晴天」）。
    println!("\n=== 获取播放直链 ===");
    let song_info = r#"{"songmid":"228908","hash":null,"albumId":null,"albumMid":null,"copyrightId":null}"#;
    for (source, id) in [("kw", "228908"), ("wy", "5257138")] {
        let info = format!(
            r#"{{"songmid":"{id}","hash":null,"albumId":null,"albumMid":null,"copyrightId":null}}"#
        );
        match sandbox.get_music_url(source, &info, "320k") {
            Ok(url) => println!("  [OK]   {source} -> {}", &url[..url.len().min(70)]),
            Err(e) => println!("  [FAIL] {source} -> {e}"),
        }
    }
    let _ = song_info;

    let logs = sandbox.take_logs();
    if !logs.is_empty() {
        println!("\n=== 插件日志（前 10 条）===");
        for line in logs.iter().take(10) {
            println!("  {line}");
        }
    }
}
