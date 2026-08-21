//! 用真实落雪音源脚本验证 boa_engine 的可用性。
//!
//! 运行：`cargo run --example boa_real_script`
//!
//! 脚本置于 examples/fixtures/lx_sample.js（开发期取样，非运行时资源）。
//! 目标：确认脚本能完整解析、执行，并调用 lx.send('inited') 上报音源。

use boa_engine::{Context, Source};

fn main() {
    let script = include_str!("fixtures/lx_sample.js");
    println!("脚本长度: {} 字节\n", script.len());

    let mut ctx = Context::default();

    // 注入最小可用的 globalThis.lx，模拟宿主环境。
    // request 直接回调一个假响应，验证脚本的请求链路不会崩。
    let host = r#"
        globalThis.__log = [];
        globalThis.__inited = null;
        globalThis.__requestHandler = null;

        globalThis.console = {
            log: function() { globalThis.__log.push('log'); },
            warn: function() { globalThis.__log.push('warn'); },
            error: function() { globalThis.__log.push('error'); },
            group: function() {},
            groupEnd: function() {},
        };

        globalThis.lx = {
            EVENT_NAMES: { request: 'request', inited: 'inited', updateAlert: 'updateAlert' },
            request: function(url, options, callback) {
                globalThis.__log.push('http:' + url);
                // 模拟成功响应（脚本会检查 body.code）
                callback(null, { statusCode: 200, body: { code: 200, url: 'http://x/a.mp3' } });
                return function() {};
            },
            send: function(name, data) {
                if (name === 'inited') globalThis.__inited = JSON.stringify(data);
                return Promise.resolve();
            },
            on: function(name, handler) {
                if (name === 'request') globalThis.__requestHandler = handler;
                return Promise.resolve();
            },
            utils: {
                crypto: {
                    md5: function(s) { return 'deadbeef'; },
                    randomBytes: function(n) { return new Uint8Array(n); },
                    aesEncrypt: function(b) { return b; },
                    rsaEncrypt: function(b) { return b; },
                },
                buffer: {
                    from: function(x) { return x; },
                    bufToString: function(b, f) { return String(b); },
                },
                zlib: {
                    inflate: function(b) { return Promise.resolve(b); },
                    inflateSync: function(b) { return b; },
                    deflate: function(b) { return Promise.resolve(b); },
                },
            },
            currentScriptInfo: { name: 'ikun', version: 'v26', author: 'ikunshare' },
            version: '2.0.0',
            env: 'mobile',
        };
        globalThis.window = globalThis;
        globalThis.self = globalThis;
        globalThis.global = globalThis;
        globalThis.process = { versions: { node: '18.0.0' }, env: {} };
        globalThis.require = function() { return {}; };
        globalThis.setTimeout = function(fn) { return 0; };
        globalThis.clearTimeout = function() {};
    "#;

    if let Err(e) = ctx.eval(Source::from_bytes(host)) {
        println!("[FAIL] 宿主环境注入失败: {e}");
        return;
    }
    println!("[OK] 宿主环境注入成功");

    // 执行真实脚本
    match ctx.eval(Source::from_bytes(script)) {
        Ok(_) => println!("[OK] 脚本解析并执行完成"),
        Err(e) => {
            println!("[FAIL] 脚本执行失败: {e}");
            return;
        }
    }

    // 跑完挂起的 Promise
    ctx.run_jobs();

    // 检查是否上报了 inited
    match ctx.eval(Source::from_bytes("globalThis.__inited")) {
        Ok(v) if !v.is_null() => {
            let s = v
                .to_string(&mut ctx)
                .map(|s| s.to_std_string_escaped())
                .unwrap_or_default();
            println!("[OK] 脚本已上报 inited");
            println!("     {}", &s[..s.len().min(300)]);
        }
        _ => println!("[WARN] 脚本未调用 send('inited')"),
    }

    // 检查是否注册了 request 处理器
    match ctx.eval(Source::from_bytes(
        "typeof globalThis.__requestHandler === 'function' ? 'yes' : 'no'",
    )) {
        Ok(v) => {
            let s = v
                .to_string(&mut ctx)
                .map(|s| s.to_std_string_escaped())
                .unwrap_or_default();
            println!("[{}] request 处理器已注册: {s}", if s == "yes" { "OK" } else { "WARN" });
        }
        Err(e) => println!("[FAIL] 检查处理器失败: {e}"),
    }
}
