//! 验证 boa_engine 能否承载 LX Music 音源脚本。
//!
//! 运行：`cargo run --example boa_probe`
//!
//! 关注三点（决定能否用 boa 替代 QuickJS）：
//! 1. 基础语法与 ES2020+ 特性（可选链、空值合并、解构）
//! 2. async/await 与 Promise（插件初始化和请求处理都依赖）
//! 3. 真实落雪脚本能否解析并执行到调用 lx.send('inited')

use boa_engine::{js_string, Context, JsValue, Source};

fn main() {
    println!("=== 1. 基础语法与 ES2020+ ===");
    check(
        "可选链 / 空值合并",
        r#"
        const o = { a: { b: 1 } };
        const x = o?.a?.b ?? 99;
        const y = o?.z?.w ?? 42;
        `${x},${y}`
        "#,
    );
    check(
        "解构 / 模板串 / 箭头函数",
        r#"
        const { EVENT_NAMES, request } = { EVENT_NAMES: 'ev', request: () => 'req' };
        `${EVENT_NAMES}-${request()}`
        "#,
    );
    check(
        "JSON.parse / Object.keys",
        r#"
        const q = JSON.parse('{"kg":["128k","320k"],"kw":["128k"]}');
        Object.keys(q).join(',')
        "#,
    );

    println!("\n=== 2. Promise / async-await ===");
    check(
        "async 函数与 await",
        r#"
        const f = async () => { const v = await Promise.resolve(7); return v * 2; };
        let out = 'pending';
        f().then(v => { out = String(v); });
        out
        "#,
    );

    println!("\n=== 3. 真实落雪脚本片段 ===");
    // 复刻脚本开头：注释元信息 + globalThis.lx 解构
    // 这是最容易失败的地方：脚本假定 globalThis.lx 已存在
    let lx_head = r#"
        globalThis.lx = {
            EVENT_NAMES: { request: 'request', inited: 'inited', updateAlert: 'updateAlert' },
            request: function(url, opts, cb) { return function() {}; },
            on: function(n, h) { return Promise.resolve(); },
            send: function(n, d) { globalThis.__inited = JSON.stringify(d); return Promise.resolve(); },
            utils: { crypto: { md5: function(s) { return 'md5:' + s.length; } }, buffer: {}, zlib: {} },
            currentScriptInfo: { name: 'test', version: 'v1' },
            version: '2.0.0',
            env: 'mobile',
        };
        const { EVENT_NAMES, request, on, send, utils, env, version } = globalThis.lx;

        const MUSIC_QUALITY = JSON.parse('{"kg":["128k","320k","flac"],"kw":["128k","320k"]}');
        const MUSIC_SOURCE = Object.keys(MUSIC_QUALITY);

        const httpFetch = (url, options = { method: 'GET' }) => new Promise((resolve, reject) => {
            request(url, options, (err, resp) => { if (err) return reject(err); resolve(resp); });
        });

        on(EVENT_NAMES.request, ({ source, action, info }) => {
            switch (action) {
                case 'musicUrl': return Promise.resolve('http://example.com/a.mp3');
                default: return Promise.reject(new Error('unsupported'));
            }
        });

        send(EVENT_NAMES.inited, {
            openDevTools: false,
            sources: MUSIC_SOURCE.reduce((acc, s) => {
                acc[s] = { name: s, type: 'music', actions: ['musicUrl'], qualitys: MUSIC_QUALITY[s] };
                return acc;
            }, {}),
        });

        globalThis.__inited ? 'inited-ok' : 'inited-missing'
        "#;
    check("脚本头部 + on/send 注册流程", lx_head);

    println!("\n=== 4. 混淆常见构造 ===");
    check(
        "unicode 转义标识符 / 字符串拼接调用",
        r#"
        var \u0053CRIPT = 'ok';
        const fn = { ['ge' + 't']: () => 'dyn' };
        `${\u0053CRIPT}-${fn.get()}`
        "#,
    );
    check(
        "立即执行 + 闭包 + arguments",
        r#"
        (function() {
            function f() { return Array.prototype.slice.call(arguments).join('|'); }
            return f(1, 2, 3);
        })()
        "#,
    );
}

/// 执行一段脚本并打印结果或错误。
fn check(label: &str, src: &str) {
    let mut ctx = Context::default();
    match ctx.eval(Source::from_bytes(src)) {
        Ok(v) => {
            // 执行挂起的 Promise 任务，让 async 结果落地
            ctx.run_jobs();
            println!("  [OK]   {label}: {}", to_display(&v, &mut ctx));
        }
        Err(e) => println!("  [FAIL] {label}: {e}"),
    }
}

fn to_display(v: &JsValue, ctx: &mut Context) -> String {
    v.to_string(ctx)
        .map(|s| s.to_std_string_escaped())
        .unwrap_or_else(|_| "<无法转换>".to_string())
}

// 保证 js_string 宏被使用，避免未使用告警影响阅读
#[allow(dead_code)]
fn _unused() {
    let _ = js_string!("x");
}
