//! axum HTTP 服务组装：媒体代理 + DMR 控制端点共端口（双端同步一份代码，勿在本端私自改动）。

use super::dmr;
use super::media_server::{serve_cover, serve_media, MediaRegistry};
use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;
use axum::routing::{any, get, post};
use axum::Router;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use tokio::sync::watch;

/// 端口扫描范围（9958 被占则向上找，最多 21 个）。
const PORT_RANGE: std::ops::RangeInclusive<u16> = 9958..=9978;

pub struct HttpServer {
    pub port: u16,
    /// 优雅停机句柄（测试用；生产端随进程退出销毁）。
    #[allow(dead_code)]
    shutdown_tx: watch::Sender<bool>,
}

impl HttpServer {
    /// 停机（仅测试调用，避免测试残留监听）。
    #[allow(dead_code)]
    pub async fn stop(self) {
        let _ = self.shutdown_tx.send(true);
    }
}

#[derive(Clone)]
pub struct AppState {
    pub registry: Arc<MediaRegistry>,
    pub dmr: Arc<dmr::DmrShared>,
}

fn not_found() -> Response {
    Response::builder()
        .status(StatusCode::NOT_FOUND)
        .body(Body::empty())
        .unwrap()
}

async fn dmr_desc(State(st): State<AppState>) -> Response {
    if st.dmr.enabled.load(Ordering::SeqCst) == 0 {
        return not_found();
    }
    let udn = st.dmr.udn.lock().unwrap().clone();
    let name = st.dmr.friendly_name.lock().unwrap().clone();
    let port = st.dmr.port.load(Ordering::SeqCst);
    Response::builder()
        .status(StatusCode::OK)
        .header("CONTENT-TYPE", "text/xml; charset=\"utf-8\"")
        .body(Body::from(dmr::device_description(&udn, &name, port)))
        .unwrap()
}

async fn dmr_scpd(Path(id): Path<String>) -> Response {
    match dmr::scpd(&id) {
        Some(xml) => Response::builder()
            .status(StatusCode::OK)
            .header("CONTENT-TYPE", "text/xml; charset=\"utf-8\"")
            .body(Body::from(xml))
            .unwrap(),
        None => not_found(),
    }
}

async fn dmr_control(
    State(st): State<AppState>,
    Path(service): Path<String>,
    headers: HeaderMap,
    body: String,
) -> Response {
    dmr::handle_control(&st.dmr, &service, &headers, &body).await
}

async fn dmr_event(State(st): State<AppState>, Path(_service): Path<String>) -> Response {
    // 渲染器关闭时订阅也拒绝。
    if st.dmr.enabled.load(Ordering::SeqCst) == 0 {
        return not_found();
    }
    // GENA 订阅桩：SUBSCRIBE 以自定义 method 发出，axum 0.8 允许任意 method 匹配 any()；
    // 统一应答 200 + SID，避免部分控制点报错。
    dmr::handle_event("SUBSCRIBE")
}

async fn not_found_handler() -> Response {
    not_found()
}

/// 启动单端口 axum 服务（媒体 + DMR）。
///
/// TCP 监听与 serve 常驻任务均在专用 runtime 上（IO 资源与创建它的
/// runtime 绑定），绑定结果经 oneshot 回传调用方。
pub async fn start(state: AppState) -> Result<HttpServer, String> {
    // 媒体路由单独挂 registry 状态（serve_media/serve_cover 只依赖 MediaRegistry），
    // DMR 路由用完整 AppState，合并后统一以 AppState 提供外层状态。
    let media_routes = Router::new()
        .route("/media/cover/{token}", get(serve_cover))
        .route("/media/{token}", get(serve_media).head(serve_media))
        .with_state(state.registry.clone());
    let app = Router::new()
        .merge(media_routes)
        .route("/dlna/desc.xml", get(dmr_desc))
        .route("/dlna/scpd/{id}", get(dmr_scpd))
        .route("/dlna/control/{service}", post(dmr_control))
        .route("/dlna/event/{service}", any(dmr_event))
        .fallback(not_found_handler)
        .with_state(state);

    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel::<Result<(u16, watch::Sender<bool>), String>>();
    super::spawn::spawn_persistent(async move {
        let result = bind_and_serve(app).await;
        let _ = ready_tx.send(result);
    });
    let (port, shutdown_tx) = ready_rx
        .await
        .map_err(|_| "httpd 任务启动失败".to_string())??;
    Ok(HttpServer { port, shutdown_tx })
}

async fn bind_and_serve(
    app: Router,
) -> Result<(u16, watch::Sender<bool>), String> {
    let mut bound = None;
    for port in PORT_RANGE {
        match tokio::net::TcpListener::bind(("0.0.0.0", port)).await {
            Ok(l) => {
                bound = Some(l);
                break;
            }
            Err(_) => continue,
        }
    }
    let listener = bound.ok_or_else(|| "9958-9978 端口均被占用".to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();

    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    tokio::spawn(async move {
        let server = axum::serve(listener, app).with_graceful_shutdown(async move {
            let mut rx = shutdown_rx;
            while !*rx.borrow_and_update() {
                if rx.changed().await.is_err() {
                    break;
                }
            }
        });
        if let Err(e) = server.await {
            eprintln!("[dlna] http server exited: {e}");
        }
    });

    Ok((port, shutdown_tx))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn server_binds_and_serves_404_for_disabled_dmr() {
        let (tx, _rx) = tokio::sync::mpsc::channel(4);
        let state = AppState {
            registry: Arc::new(MediaRegistry::new(reqwest::Client::new())),
            dmr: Arc::new(dmr::DmrShared::new(tx)),
        };
        let server = start(state).await.expect("server should bind");
        assert!((9958..=9978).contains(&server.port));
        let body = reqwest::get(format!("http://127.0.0.1:{}/dlna/desc.xml", server.port))
            .await
            .unwrap();
        assert_eq!(body.status(), reqwest::StatusCode::NOT_FOUND);
        server.stop().await;
    }

    #[tokio::test]
    async fn media_unknown_token_404() {
        let (tx, _rx) = tokio::sync::mpsc::channel(4);
        let state = AppState {
            registry: Arc::new(MediaRegistry::new(reqwest::Client::new())),
            dmr: Arc::new(dmr::DmrShared::new(tx)),
        };
        let server = start(state).await.expect("server should bind");
        let resp = reqwest::get(format!("http://127.0.0.1:{}/media/unknown", server.port))
            .await
            .unwrap();
        assert_eq!(resp.status(), reqwest::StatusCode::NOT_FOUND);
        server.stop().await;
    }
}
