//! 插件管理端到端验证：安装 → 列表 → 解析直链 → 停用 → 卸载。
//!
//! 运行：`cargo run --example plugin_smoke`
//!
//! 在临时目录内操作，不影响真实应用数据。

use std::fs;

use xianyu_core::plugins::manager;

fn main() {
    let script = include_str!("fixtures/lx_sample.js");

    // 用系统临时目录，避免污染工作区。
    let data_dir = std::env::temp_dir().join("xianyu_plugin_smoke");
    let _ = fs::remove_dir_all(&data_dir);
    fs::create_dir_all(&data_dir).expect("创建临时目录失败");
    let dir = data_dir.to_string_lossy().to_string();

    println!("=== 1. 安装插件 ===");
    let info = match manager::install_plugin(&dir, script, "smoke-test") {
        Ok(i) => {
            println!("  [OK] id={} name={} version={}", i.id, i.name, i.version);
            println!("       音源: {:?}", i.sources);
            i
        }
        Err(e) => {
            println!("  [FAIL] {e}");
            return;
        }
    };

    println!("\n=== 2. 列出插件 ===");
    let list = manager::list_plugins(&dir);
    println!("  共 {} 个，enabled={}", list.len(), list[0].enabled);

    println!("\n=== 3. 音源可用性判定 ===");
    for source in ["kw", "wy", "tx", "kg", "mg"] {
        let ok = manager::has_enabled_plugin_for(&dir, source);
        println!("  {source}: {}", if ok { "有插件" } else { "无插件" });
    }

    println!("\n=== 4. 解析直链 ===");
    for (source, id) in [("kw", "228908"), ("wy", "5257138")] {
        let song = format!(
            r#"{{"songmid":"{id}","hash":null,"albumId":null,"albumMid":null,"copyrightId":null}}"#
        );
        match manager::resolve_url_with_plugins(&dir, source, &song, "320k") {
            Ok(url) => println!("  [OK]   {source} -> {}", &url[..url.len().min(64)]),
            Err(e) => println!("  [FAIL] {source} -> {e}"),
        }
    }

    println!("\n=== 5. 停用后不再参与解析 ===");
    manager::set_plugin_enabled(&dir, &info.id, false).expect("停用失败");
    println!("  kw 可用: {}", manager::has_enabled_plugin_for(&dir, "kw"));
    let song = r#"{"songmid":"228908","hash":null}"#;
    match manager::resolve_url_with_plugins(&dir, "kw", song, "320k") {
        Ok(_) => println!("  [FAIL] 停用后仍解析成功"),
        Err(e) => println!("  [OK] 已拒绝: {e}"),
    }

    println!("\n=== 6. 卸载 ===");
    manager::set_plugin_enabled(&dir, &info.id, true).expect("重新启用失败");
    match manager::remove_plugin(&dir, &info.id) {
        Ok(_) => println!("  [OK] 已卸载，剩余 {} 个", manager::list_plugins(&dir).len()),
        Err(e) => println!("  [FAIL] {e}"),
    }

    // 清理
    let _ = fs::remove_dir_all(&data_dir);
}
