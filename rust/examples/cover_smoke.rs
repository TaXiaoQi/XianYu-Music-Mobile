//! 封面代理验证：确认各音源封面经 proxy_image 可取回。
//!
//! 运行：`cargo run --example cover_smoke`
//!
//! 各平台封面 CDN 有防盗链，需按域名补 Referer（见 plugins::proxy_image）。

use xianyu_core::music::lx_search::lx_search;
use xianyu_core::plugins::proxy_image;

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    for source in ["wy", "kw", "tx", "kg", "mg"] {
        let items = lx_search(source, "周杰伦", 3).await.unwrap_or_default();
        let Some(first) = items.first() else {
            println!("[{source}] 搜索无结果，跳过");
            continue;
        };
        let Some(img) = first.img.as_deref().filter(|s| !s.is_empty()) else {
            println!("[{source}] 无封面字段");
            continue;
        };

        println!("[{source}] {}", &img[..img.len().min(70)]);
        match proxy_image(img.to_string(), None).await {
            Ok(data_url) => {
                // 形如 data:image/jpeg;base64,xxxx
                let mime = data_url
                    .split(';')
                    .next()
                    .unwrap_or("")
                    .trim_start_matches("data:");
                let payload_len = data_url.split(',').nth(1).map(|s| s.len()).unwrap_or(0);
                // base64 长度 * 3/4 约等于原始字节数
                let approx_bytes = payload_len * 3 / 4;
                println!("    OK  mime={mime}  约 {approx_bytes} 字节");
            }
            Err(e) => println!("    FAIL  {e}"),
        }
    }
}
