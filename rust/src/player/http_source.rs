//! HTTP Range 可 Seek 只读源（供 SymphoniaDecoder 消费流式 URL）。
//!
//! 移动端在线歌曲经本地回环代理（Dart `audio_proxy_server.dart`）转发上游 CDN：
//! 代理自动注入插件请求头（Referer/User-Agent/Cookie）并支持 Range 断点续传。
//! 本结构实现 `Read + Seek`（MediaSource），让共享 DSP 管线能像本地文件一样
//! 流式解码在线歌曲（EQ/混响/空间音效等全效果链生效）。
//!
//! 实现：专用单线程 tokio runtime 上跑 async reqwest 客户端（`read_timeout`
//! 提供逐块空闲超时），音频工作线程用 `block_on` 逐块拉取。Seek 惰性重开——
//! seek 只更新逻辑位置；下次 read 时若位置不在当前响应流范围内，再按
//! `Range: bytes=<pos>-` 重新请求。服务端忽略 Range（200 全量）时回退为
//! 顺序丢弃推进。

use std::io::{self, Read, Seek, SeekFrom};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use bytes::{Buf, Bytes};

/// 连接建立超时。
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// 逐块读取空闲超时（async 客户端语义：相邻两次 body 数据到达的最大间隔）。
/// 超时视为流中断，读取侧重开一次，仍失败则交由解码层报错
/// （Dart 侧轮询检测管线退出后自动回退 ExoPlayer）。
const READ_TIMEOUT: Duration = Duration::from_secs(30);

/// HTTP 源专用 runtime：单 worker 足够（同一时刻每首歌一个流）。
static HTTP_RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn http_runtime() -> &'static tokio::runtime::Runtime {
    HTTP_RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .expect("HTTP 源 tokio runtime 构建失败")
    })
}

fn io_err(e: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::Other, e.to_string())
}

struct Inner {
    /// 逻辑文件位置（下次 read 的目标偏移）。
    pos: u64,
    resp: Option<reqwest::Response>,
    /// 当前响应体起始字节对应的文件偏移（206 = Range 起点；200 = 0）。
    resp_start: u64,
    /// 当前响应体已消费到的绝对偏移。
    resp_pos: u64,
    /// chunk() 取出但尚未拷入调用方缓冲的剩余字节。
    pending: Bytes,
}

pub struct HttpSeekableReader {
    url: String,
    client: reqwest::Client,
    inner: Mutex<Inner>,
    /// 全文件大小（Content-Range 总长 / 200 响应 Content-Length）。
    total: Option<u64>,
}

/// 一次 Range 请求的元信息。
struct RangeResponse {
    resp: reqwest::Response,
    /// 全文件总长（未知为 None）。
    total: Option<u64>,
    /// 响应体首字节对应的文件偏移。
    start: u64,
}

impl HttpSeekableReader {
    /// 打开 URL：发首个 `Range: bytes=0-` 请求探测总长并保留该响应作为初始流。
    pub fn open(url: &str) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            // 仅访问本地回环代理，禁用系统代理避免干扰。
            .no_proxy()
            .connect_timeout(CONNECT_TIMEOUT)
            .read_timeout(READ_TIMEOUT)
            .build()
            .map_err(|e| format!("HTTP client 构建失败: {e}"))?;

        let rr = http_runtime().block_on(Self::request_range(&client, url, 0))?;
        Ok(Self {
            url: url.to_string(),
            client,
            inner: Mutex::new(Inner {
                pos: rr.start,
                resp: Some(rr.resp),
                resp_start: rr.start,
                resp_pos: rr.start,
                pending: Bytes::new(),
            }),
            total: rr.total,
        })
    }

    /// 发起 Range 请求（在 HTTP runtime 上阻塞完成）。
    /// 206 → start = 请求起点；200（忽略 Range）→ start = 0，由读取侧丢弃推进。
    async fn request_range(
        client: &reqwest::Client,
        url: &str,
        start: u64,
    ) -> Result<RangeResponse, String> {
        let resp = client
            .get(url)
            .header("Range", format!("bytes={start}-"))
            .send()
            .await
            .map_err(|e| format!("HTTP 请求失败: {e}"))?;

        let status = resp.status();
        if status == reqwest::StatusCode::PARTIAL_CONTENT {
            let total = resp
                .headers()
                .get(reqwest::header::CONTENT_RANGE)
                .and_then(|v| v.to_str().ok())
                .and_then(parse_content_range_total);
            Ok(RangeResponse {
                resp,
                total,
                start,
            })
        } else if status == reqwest::StatusCode::OK {
            // 服务端不支持 Range：全量响应（Content-Length 即文件总长）。
            // 起点固定 0，读取侧按逻辑位置丢弃推进到目标偏移。
            let total = resp.content_length().map(|n| n as u64);
            Ok(RangeResponse { resp, total, start: 0 })
        } else {
            Err(format!("HTTP 状态异常: {status}"))
        }
    }

    /// 取下一块数据（阻塞）。返回 None = 正常 EOF。
    fn next_chunk(inner: &mut Inner) -> io::Result<Option<Bytes>> {
        let resp = match inner.resp.as_mut() {
            Some(r) => r,
            None => return Ok(None),
        };
        let chunk = http_runtime()
            .block_on(resp.chunk())
            .map_err(io_err)?;
        Ok(chunk)
    }

    /// 确保存在起点 ≤ pos 的响应流；不存在则重开 Range 请求。
    fn ensure_stream(inner: &mut Inner, client: &reqwest::Client, url: &str, total_out: &mut Option<u64>) -> io::Result<()> {
        let need_reopen = match &inner.resp {
            None => true,
            Some(_) => inner.pos < inner.resp_start,
        };
        if !need_reopen {
            return Ok(());
        }
        inner.resp = None;
        inner.pending = Bytes::new();
        let rr = http_runtime()
            .block_on(Self::request_range(client, url, inner.pos))
            .map_err(io_err)?;
        if rr.total.is_some() {
            *total_out = rr.total;
        }
        inner.resp_start = rr.start;
        inner.resp_pos = rr.start;
        inner.resp = Some(rr.resp);
        Ok(())
    }
}

/// 解析 `Content-Range: bytes 0-12345/67890` 的总长（`*` 视为未知）。
fn parse_content_range_total(v: &str) -> Option<u64> {
    let idx = v.rfind('/')?;
    let total = v[idx + 1..].trim();
    if total == "*" {
        return None;
    }
    total.parse().ok()
}

impl Read for HttpSeekableReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let mut inner = self.inner.lock().map_err(|e| io_err(e))?;

        loop {
            // 1) 保证有起点 ≤ pos 的响应流。
            Self::ensure_stream(&mut inner, &self.client, &self.url, &mut self.total)?;

            // 2) 目标位置在当前流内部（200 全量或向前 seek）：丢弃推进。
            while inner.pos > inner.resp_pos {
                if inner.pending.is_empty() {
                    match Self::next_chunk(&mut inner)? {
                        Some(b) => inner.pending = b,
                        None => return Err(io_err("流在目标位置前提前结束")),
                    }
                }
                let skip = (inner.pos - inner.resp_pos) as usize;
                let n = skip.min(inner.pending.len());
                inner.pending.advance(n);
                inner.resp_pos += n as u64;
            }

            // 3) 正常读取（限长不越过总长）。
            let mut cap = buf.len();
            if let Some(total) = self.total {
                let remain = total.saturating_sub(inner.pos) as usize;
                cap = cap.min(remain);
                if cap == 0 {
                    return Ok(0);
                }
            }
            while inner.pending.is_empty() {
                match Self::next_chunk(&mut inner)? {
                    Some(b) => inner.pending = b,
                    // 正常 EOF（服务端响应体自然结束）。
                    None => return Ok(0),
                }
            }
            let n = cap.min(inner.pending.len());
            buf[..n].copy_from_slice(&inner.pending[..n]);
            inner.pending.advance(n);
            inner.pos += n as u64;
            inner.resp_pos += n as u64;
            return Ok(n);
        }
    }
}

impl Seek for HttpSeekableReader {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let mut inner = self.inner.lock().map_err(|e| io_err(e))?;
        let new_pos: i64 = match pos {
            SeekFrom::Start(o) => o as i64,
            SeekFrom::End(o) => self
                .total
                .ok_or_else(|| io_err("流式源未知总长，不支持 End 定位"))?
                as i64
                + o,
            SeekFrom::Current(o) => inner.pos as i64 + o,
        };
        if new_pos < 0 {
            return Err(io_err("seek 位置越界（负数）"));
        }
        inner.pos = new_pos as u64;
        Ok(inner.pos)
    }
}

impl symphonia::core::io::MediaSource for HttpSeekableReader {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        self.total
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_content_range_total_values() {
        assert_eq!(
            parse_content_range_total("bytes 0-1023/45678"),
            Some(45678)
        );
        assert_eq!(parse_content_range_total("bytes 100-199/*"), None);
        assert_eq!(parse_content_range_total("bytes 0-1/abc"), None);
        assert_eq!(parse_content_range_total("garbage"), None);
    }
}
