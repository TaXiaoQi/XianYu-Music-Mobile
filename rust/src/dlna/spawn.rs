//! DLNA 长生命周期任务专用运行时（双端同步一份代码，勿在本端私自改动）。
//!
//! 宿主（FRB / Tauri）的 tokio runtime 生命周期不受我们控制，
//! httpd / SSDP 广播等常驻任务统一跑在自建 runtime 上，避免宿主关闭导致服务静默失效。

use std::sync::OnceLock;
use tokio::runtime::{Builder, Runtime};

static RT: OnceLock<Runtime> = OnceLock::new();

pub fn global_runtime() -> &'static Runtime {
    RT.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("dlna-rt")
            .enable_all()
            .build()
            .expect("failed to build dlna tokio runtime")
    })
}

/// 在专用 runtime 上启动常驻任务。
pub fn spawn_persistent<F>(fut: F)
where
    F: std::future::Future<Output = ()> + Send + 'static,
{
    global_runtime().spawn(fut);
}
