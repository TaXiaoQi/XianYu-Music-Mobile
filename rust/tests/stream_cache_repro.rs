//! 临时诊断测试：复现「流缓存整档下载完成但解码 0 样本」。
//! 用本地 HTTP 服务喂一个真实 FLAC，走 start_streaming_download +
//! new_reader_with_decryption，比对字节一致性并用 Symphonia 解码计数。

use std::io::{Read, Seek, SeekFrom};
use std::net::TcpListener;

fn serve_file(path: &'static str) -> (String, std::thread::JoinHandle<()>) {
    let data = std::fs::read(path).expect("read flac");
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let handle = std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut s = match stream {
                Ok(s) => s,
                Err(_) => break,
            };
            let mut buf = [0u8; 4096];
            let _ = s.read(&mut buf); // 读掉请求头（简化）
            let hdr = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: audio/flac\r\nConnection: close\r\n\r\n",
                data.len()
            );
            let _ = s.write_all(hdr.as_bytes());
            let _ = s.write_all(&data);
        }
    });
    (format!("http://{addr}/test.flac"), handle)
}

use std::io::Write as _;

#[test]
fn stream_cache_reader_roundtrip_and_decode() {
    let (url, server) = serve_file("/tmp/test.flac");
    let original = std::fs::read("/tmp/test.flac").unwrap();

    let state = xianyu_core::player::stream_cache::start_streaming_download(
        &url, None, None, None, None,
    )
    .expect("start download");

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    while !xianyu_core::player::stream_cache::is_buffer_ready(&state) {
        assert!(std::time::Instant::now() < deadline, "buffer not ready in time");
        if let Some(e) = state.download_error() {
            panic!("download error: {e}");
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }

    let mut reader = state.new_reader_with_decryption().expect("new reader");
    reader.seek(SeekFrom::Start(0)).unwrap();
    let mut got = Vec::new();
    reader.read_to_end(&mut got).expect("read to end");

    assert_eq!(
        got.len(),
        original.len(),
        "reader 长度不一致: got={} want={}",
        got.len(),
        original.len()
    );
    assert!(
        got == original,
        "reader 字节与源文件不一致！前 32 字节 got={:?} want={:?}",
        &got[..32.min(got.len())],
        &original[..32]
    );

    // Symphonia 解码计数
    use symphonia::core::audio::SampleBuffer;
    use symphonia::core::codecs::DecoderOptions;
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    let cursor = std::io::Cursor::new(got);
    let mss = MediaSourceStream::new(Box::new(cursor), Default::default());
    let mut hint = Hint::new();
    hint.with_extension("flac");
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .expect("probe");
    let track = probed.format.tracks().first().unwrap().clone();
    let mut dec = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .expect("decoder");
    let mut fmt = probed.format;
    let mut total: u64 = 0;
    let mut packets = 0u64;
    loop {
        match fmt.next_packet() {
            Ok(p) => match dec.decode(&p) {
                Ok(abuf) => {
                    let mut sb = SampleBuffer::<f32>::new(abuf.capacity() as u64, *abuf.spec());
                    sb.copy_interleaved_ref(abuf);
                    total += sb.samples().len() as u64;
                    packets += 1;
                }
                Err(e) => eprintln!("decode err: {e}"),
            },
            Err(symphonia::core::errors::Error::IoError(e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break
            }
            Err(e) => eprintln!("next_packet err: {e}"),
        }
    }
    println!("packets={packets} samples={total}");
    assert!(packets > 0 && total > 0, "Symphonia 未解出任何样本!");
    let _ = server.join();
}
