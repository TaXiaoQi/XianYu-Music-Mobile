//! AAudio FFI 绑定：libaaudio.so 动态加载函数表、格式常量与采样格式转换。

use super::*;

// =========================================================================
// AAudio FFI 常量
// =========================================================================

pub(crate) const AAUDIO_OK: i32 = 0;
pub(crate) const AAUDIO_ERROR_TIMEOUT: i32 = -13;
pub(crate) const AAUDIO_SHARING_MODE_EXCLUSIVE: i32 = 0;
pub(crate) const AAUDIO_SHARING_MODE_SHARED: i32 = 1;
pub(crate) const AAUDIO_FORMAT_INVALID: i32 = 0;
pub(crate) const AAUDIO_FORMAT_PCM_I16: i32 = 1;
pub(crate) const AAUDIO_FORMAT_PCM_FLOAT: i32 = 2;
pub(crate) const AAUDIO_FORMAT_PCM_I24_PACKED: i32 = 3;
pub(crate) const AAUDIO_PERFORMANCE_MODE_LOW_LATENCY: i32 = 4;
pub(crate) const AAUDIO_DIRECTION_OUTPUT: i32 = 0;

// =========================================================================
// AAudio FFI 类型
// =========================================================================

pub(crate) type AAudioStream = std::os::raw::c_void;
pub(crate) type AAudioStreamBuilder = std::os::raw::c_void;

// 函数指针类型
pub(crate) type FnCreateStreamBuilder = unsafe extern "C" fn(*mut *mut AAudioStreamBuilder) -> i32;
pub(crate) type FnBuilderDelete = unsafe extern "C" fn(*mut AAudioStreamBuilder) -> i32;
pub(crate) type FnBuilderSetDeviceId = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
pub(crate) type FnBuilderSetSampleRate = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
pub(crate) type FnBuilderSetChannelCount = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
pub(crate) type FnBuilderSetFormat = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
pub(crate) type FnBuilderSetSharingMode = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
pub(crate) type FnBuilderSetPerformanceMode = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
pub(crate) type FnBuilderSetBufferCapacity = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
pub(crate) type FnBuilderSetDirection = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
pub(crate) type FnBuilderOpenStream = unsafe extern "C" fn(*mut AAudioStreamBuilder, *mut *mut AAudioStream) -> i32;
pub(crate) type FnStreamRequestStart = unsafe extern "C" fn(*mut AAudioStream) -> i32;
pub(crate) type FnStreamRequestPause = unsafe extern "C" fn(*mut AAudioStream) -> i32;
pub(crate) type FnStreamRequestStop = unsafe extern "C" fn(*mut AAudioStream) -> i32;
pub(crate) type FnStreamClose = unsafe extern "C" fn(*mut AAudioStream) -> i32;
pub(crate) type FnStreamWrite = unsafe extern "C" fn(*mut AAudioStream, *const std::os::raw::c_void, i32, i64) -> i64;
pub(crate) type FnStreamGetFramesRead = unsafe extern "C" fn(*mut AAudioStream) -> i64;
pub(crate) type FnStreamGetFramesWritten = unsafe extern "C" fn(*mut AAudioStream) -> i64;
pub(crate) type FnStreamGetXRunCount = unsafe extern "C" fn(*mut AAudioStream) -> i32;
pub(crate) type FnStreamGetSampleRate = unsafe extern "C" fn(*mut AAudioStream) -> i32;
pub(crate) type FnStreamGetChannelCount = unsafe extern "C" fn(*mut AAudioStream) -> i32;
pub(crate) type FnStreamGetFormat = unsafe extern "C" fn(*mut AAudioStream) -> i32;
pub(crate) type FnStreamGetBufferSize = unsafe extern "C" fn(*mut AAudioStream) -> i32;
pub(crate) type FnStreamGetTimestamp = unsafe extern "C" fn(
    *mut AAudioStream,
    *mut std::os::raw::c_int,
    *mut i64,
    *mut i64,
) -> i32;
pub(crate) type FnConvertResultToText = unsafe extern "C" fn(i32) -> *const std::os::raw::c_char;

/// 动态加载的 AAudio 函数表。
pub(crate) struct AAudioLib {
    _handle: *mut std::os::raw::c_void,
    create_stream_builder: FnCreateStreamBuilder,
    builder_delete: FnBuilderDelete,
    builder_set_device_id: FnBuilderSetDeviceId,
    builder_set_sample_rate: FnBuilderSetSampleRate,
    builder_set_channel_count: FnBuilderSetChannelCount,
    builder_set_format: FnBuilderSetFormat,
    builder_set_sharing_mode: FnBuilderSetSharingMode,
    builder_set_performance_mode: FnBuilderSetPerformanceMode,
    builder_set_buffer_capacity: FnBuilderSetBufferCapacity,
    builder_set_direction: FnBuilderSetDirection,
    builder_open_stream: FnBuilderOpenStream,
    stream_request_start: FnStreamRequestStart,
    stream_request_pause: FnStreamRequestPause,
    stream_request_stop: FnStreamRequestStop,
    stream_close: FnStreamClose,
    stream_write: FnStreamWrite,
    stream_get_frames_read: FnStreamGetFramesRead,
    stream_get_frames_written: FnStreamGetFramesWritten,
    stream_get_xrun_count: FnStreamGetXRunCount,
    stream_get_sample_rate: FnStreamGetSampleRate,
    stream_get_channel_count: FnStreamGetChannelCount,
    stream_get_format: FnStreamGetFormat,
    stream_get_buffer_size: FnStreamGetBufferSize,
    stream_get_timestamp: FnStreamGetTimestamp,
    convert_result_to_text: FnConvertResultToText,
}

unsafe impl Send for AAudioLib {}

impl AAudioLib {
    /// 动态加载 libaaudio.so。失败时带出具体原因（dlerror / 缺失符号名），
    /// 避免上游只见「无法加载」而无法定位。
    fn load() -> Result<Self, String> {
        unsafe {
            let name = b"libaaudio.so\0".as_ptr();
            let handle = libc::dlopen(name as *const _, libc::RTLD_NOW);
            if handle.is_null() {
                let err = libc::dlerror();
                let detail = if err.is_null() {
                    "dlopen 返回空句柄".to_string()
                } else {
                    std::ffi::CStr::from_ptr(err).to_string_lossy().into_owned()
                };
                return Err(format!("dlopen libaaudio.so 失败: {detail}"));
            }

            macro_rules! sym {
                ($name:expr, $type:ty) => {
                    {
                        let sym_name = concat!($name, "\0").as_ptr();
                        let ptr = libc::dlsym(handle, sym_name as *const _);
                        if ptr.is_null() {
                            let err = libc::dlerror();
                            let detail = if err.is_null() {
                                "符号不存在".to_string()
                            } else {
                                std::ffi::CStr::from_ptr(err)
                                    .to_string_lossy()
                                    .into_owned()
                            };
                            libc::dlclose(handle);
                            return Err(format!("dlsym {} 失败: {}", $name, detail));
                        }
                        std::mem::transmute::<*mut std::os::raw::c_void, $type>(ptr)
                    }
                };
            }

            let lib = Self {
                _handle: handle,
                create_stream_builder: sym!("AAudio_createStreamBuilder", FnCreateStreamBuilder),
                builder_delete: sym!("AAudioStreamBuilder_delete", FnBuilderDelete),
                builder_set_device_id: sym!("AAudioStreamBuilder_setDeviceId", FnBuilderSetDeviceId),
                builder_set_sample_rate: sym!("AAudioStreamBuilder_setSampleRate", FnBuilderSetSampleRate),
                builder_set_channel_count: sym!("AAudioStreamBuilder_setChannelCount", FnBuilderSetChannelCount),
                builder_set_format: sym!("AAudioStreamBuilder_setFormat", FnBuilderSetFormat),
                builder_set_sharing_mode: sym!("AAudioStreamBuilder_setSharingMode", FnBuilderSetSharingMode),
                builder_set_performance_mode: sym!("AAudioStreamBuilder_setPerformanceMode", FnBuilderSetPerformanceMode),
                builder_set_buffer_capacity: sym!("AAudioStreamBuilder_setBufferCapacityInFrames", FnBuilderSetBufferCapacity),
                builder_set_direction: sym!("AAudioStreamBuilder_setDirection", FnBuilderSetDirection),
                builder_open_stream: sym!("AAudioStreamBuilder_openStream", FnBuilderOpenStream),
                stream_request_start: sym!("AAudioStream_requestStart", FnStreamRequestStart),
                stream_request_pause: sym!("AAudioStream_requestPause", FnStreamRequestPause),
                stream_request_stop: sym!("AAudioStream_requestStop", FnStreamRequestStop),
                stream_close: sym!("AAudioStream_close", FnStreamClose),
                stream_write: sym!("AAudioStream_write", FnStreamWrite),
                stream_get_frames_read: sym!("AAudioStream_getFramesRead", FnStreamGetFramesRead),
                stream_get_frames_written: sym!(
                    "AAudioStream_getFramesWritten",
                    FnStreamGetFramesWritten
                ),
                stream_get_xrun_count: sym!("AAudioStream_getXRunCount", FnStreamGetXRunCount),
                stream_get_sample_rate: sym!("AAudioStream_getSampleRate", FnStreamGetSampleRate),
                stream_get_channel_count: sym!("AAudioStream_getChannelCount", FnStreamGetChannelCount),
                stream_get_format: sym!("AAudioStream_getFormat", FnStreamGetFormat),
                stream_get_buffer_size: sym!("AAudioStream_getBufferSizeInFrames", FnStreamGetBufferSize),
                stream_get_timestamp: sym!("AAudioStream_getTimestamp", FnStreamGetTimestamp),
                convert_result_to_text: sym!("AAudio_convertResultToText", FnConvertResultToText),
            };
            Ok(lib)
        }
    }

    /// 当前可写帧数 = 缓冲大小 - (已写入 - 已读取)。
    ///
    /// 用公开 API（getFramesWritten/getFramesRead/getBufferSizeInFrames，API 26+）
    /// 组合计算，替代非公开符号 AAudioStream_getAvailableFrames（部分厂商 ROM
    /// 不导出该符号，dlsym 失败会导致整个 libaaudio 加载被判失败）。
    unsafe fn available_frames(&self, stream: *mut AAudioStream) -> i32 {
        let written = (self.stream_get_frames_written)(stream);
        let read = (self.stream_get_frames_read)(stream);
        let buf = (self.stream_get_buffer_size)(stream);
        buf - (written - read).clamp(0, buf as i64) as i32
    }

    unsafe fn result_text(&self, result: i32) -> String {
        let ptr = (self.convert_result_to_text)(result);
        if ptr.is_null() {
            return format!("AAudio error {}", result);
        }
        let cstr = std::ffi::CStr::from_ptr(ptr);
        cstr.to_string_lossy().into_owned()
    }
}

// =========================================================================
// 设备格式
// =========================================================================

#[derive(Clone, Copy, PartialEq)]
pub(crate) enum DeviceFormat {
    Float32,
    Int16,
    I24Packed,
}

impl DeviceFormat {
    fn aaudio_format(self) -> i32 {
        match self {
            Self::Float32 => AAUDIO_FORMAT_PCM_FLOAT,
            Self::Int16 => AAUDIO_FORMAT_PCM_I16,
            Self::I24Packed => AAUDIO_FORMAT_PCM_I24_PACKED,
        }
    }

    fn bytes_per_sample(self) -> usize {
        match self {
            Self::Float32 => 4,
            Self::Int16 => 2,
            Self::I24Packed => 3,
        }
    }
}

/// f32 → 设备格式字节（小端 LE）。
pub(crate) fn push_sample_bytes(buf: &mut Vec<u8>, sample: f32, fmt: DeviceFormat) {
    let clamped = sample.clamp(-1.0, 1.0);
    match fmt {
        DeviceFormat::Float32 => {
            buf.extend_from_slice(&clamped.to_le_bytes());
        }
        DeviceFormat::Int16 => {
            let val = (clamped * 32767.0) as i16;
            buf.extend_from_slice(&val.to_le_bytes());
        }
        DeviceFormat::I24Packed => {
            // 24 位定点（DoP / 24-bit PCM 直出）：f32 → i32 定点，取低 3 字节 LE。
            let val = (clamped * 8388607.0) as i32;
            let bytes = val.to_le_bytes();
            buf.extend_from_slice(&bytes[..3]);
        }
    }
}

// =========================================================================
// Symphonia 解码器（BlockProducer）
// =========================================================================

