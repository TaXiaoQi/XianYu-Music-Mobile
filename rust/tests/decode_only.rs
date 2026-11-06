//! 临时诊断：用 Symphonia 直接解码从设备拉回的失败缓存文件。

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

#[test]
fn decode_failed_cache_file() {
    let data = std::fs::read("/tmp/fail_cache.dat").unwrap();
    println!("file size = {}", data.len());
    let mss = MediaSourceStream::new(Box::new(std::io::Cursor::new(data)), Default::default());
    let mut hint = Hint::new();
    hint.with_extension("flac");
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .expect("probe failed");
    let track = probed.format.tracks().first().unwrap().clone();
    println!(
        "codec={:?} rate={:?} frames={:?} bits={:?}",
        track.codec_params.codec,
        track.codec_params.sample_rate,
        track.codec_params.n_frames,
        track.codec_params.bits_per_sample
    );
    let mut dec = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .expect("decoder");
    let mut fmt = probed.format;
    let mut total: u64 = 0;
    let mut packets = 0u64;
    let mut errs = 0u64;
    loop {
        match fmt.next_packet() {
            Ok(p) => match dec.decode(&p) {
                Ok(abuf) => {
                    let mut sb = SampleBuffer::<f32>::new(abuf.capacity() as u64, *abuf.spec());
                    sb.copy_interleaved_ref(abuf);
                    total += sb.samples().len() as u64;
                    packets += 1;
                }
                Err(e) => {
                    errs += 1;
                    if errs <= 5 {
                        eprintln!("decode err #{errs}: {e}");
                    }
                }
            },
            Err(symphonia::core::errors::Error::IoError(e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break
            }
            Err(e) => {
                eprintln!("next_packet err: {e}");
                break;
            }
        }
    }
    println!("packets={packets} samples={total} decode_errs={errs}");
}
