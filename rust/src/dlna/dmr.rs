//! DMR 渲染器：设备描述 / SCPD / AVTransport SOAP 分发（双端同步一份代码，勿在本端私自改动）。

use super::soap::{arg, extract_tag, format_upnp_time, parse_upnp_time, xml_escape, xml_unescape};
use super::types::{DmrCommand, DmrHost};
use axum::body::Body;
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;
use tokio::sync::mpsc::Sender;

pub const AVT_SERVICE: &str = "urn:schemas-upnp-org:service:AVTransport:1";
pub const RCS_SERVICE: &str = "urn:schemas-upnp-org:service:RenderingControl:1";
pub const CM_SERVICE: &str = "urn:schemas-upnp-org:service:ConnectionManager:1";
const UPNP_ERR_INVALID_ACTION: u16 = 401;
const UPNP_ERR_TRANSITION: u16 = 701;

/// DMR 共享状态：SOAP 端点写入 / HTTP 应答读取。
pub struct DmrShared {
    /// 0=disabled 1=enabled（desc.xml 与 control 端点未启用时返回 404/503）。
    pub enabled: AtomicU8,
    pub udn: std::sync::Mutex<String>,
    pub friendly_name: std::sync::Mutex<String>,
    pub port: std::sync::atomic::AtomicU16,
    /// 当前投递的 URI / 元数据（GetPositionInfo 应答用）。
    pub current_uri: std::sync::Mutex<String>,
    pub current_meta: std::sync::Mutex<String>,
    /// 宿主播放器状态读取。
    pub host: std::sync::Mutex<Option<Arc<dyn DmrHost>>>,
    /// 控制点指令出口（宿主消费）。
    pub commands: Sender<DmrCommand>,
}

impl DmrShared {
    pub fn new(commands: Sender<DmrCommand>) -> Self {
        Self {
            enabled: AtomicU8::new(0),
            udn: std::sync::Mutex::new(String::new()),
            friendly_name: std::sync::Mutex::new(String::new()),
            port: std::sync::atomic::AtomicU16::new(0),
            current_uri: std::sync::Mutex::new(String::new()),
            current_meta: std::sync::Mutex::new(String::new()),
            host: std::sync::Mutex::new(None),
            commands,
        }
    }

    fn host(&self) -> Option<Arc<dyn DmrHost>> {
        self.host.lock().unwrap().clone()
    }
}

// ---------- 设备描述 / SCPD ----------

pub fn device_description(udn: &str, friendly_name: &str, port: u16) -> String {
    let esc_name = xml_escape(friendly_name);
    format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion>
<device>
<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>{esc_name}</friendlyName>
<manufacturer>弦予音乐</manufacturer>
<manufacturerURL>https://xianyumusic.cn</manufacturerURL>
<modelDescription>弦予音乐 DLNA 渲染器</modelDescription>
<modelName>XianYu Music</modelName>
<modelNumber>1.0</modelNumber>
<UDN>uuid:{udn}</UDN>
<serviceList>
<service>
<serviceType>{AVT_SERVICE}</serviceType>
<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
<SCPDURL>/dlna/scpd/avt.xml</SCPDURL>
<controlURL>/dlna/control/avt</controlURL>
<eventSubURL>/dlna/event/avt</eventSubURL>
</service>
<service>
<serviceType>{RCS_SERVICE}</serviceType>
<serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
<SCPDURL>/dlna/scpd/rcs.xml</SCPDURL>
<controlURL>/dlna/control/rcs</controlURL>
<eventSubURL>/dlna/event/rcs</eventSubURL>
</service>
<service>
<serviceType>{CM_SERVICE}</serviceType>
<serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
<SCPDURL>/dlna/scpd/cm.xml</SCPDURL>
<controlURL>/dlna/control/cm</controlURL>
<eventSubURL>/dlna/event/cm</eventSubURL>
</service>
</serviceList>
<dlna:X_DLNADOC xmlns:dlna="urn:schemas-dlna-org:device-1-0">DMR-1.50</dlna:X_DLNADOC>
</device>
<URLBase>http://0.0.0.0:{port}</URLBase>
</root>"#
    )
}

const SCPD_AVT: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion>
<actionList>
<action><name>SetAVTransportURI</name><argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>CurrentURI</name><direction>in</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
<argument><name>CurrentURIMetaData</name><direction>in</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
</argumentList></action>
<action><name>Play</name><argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Speed</name><direction>in</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
</argumentList></action>
<action><name>Pause</name><argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
</argumentList></action>
<action><name>Stop</name><argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
</argumentList></action>
<action><name>Seek</name><argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Unit</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekMode</relatedStateVariable></argument>
<argument><name>Target</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekTarget</relatedStateVariable></argument>
</argumentList></action>
<action><name>GetPositionInfo</name><argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Track</name><direction>out</direction><relatedStateVariable>CurrentTrack</relatedStateVariable></argument>
<argument><name>TrackDuration</name><direction>out</direction><relatedStateVariable>CurrentTrackDuration</relatedStateVariable></argument>
<argument><name>TrackMetaData</name><direction>out</direction><relatedStateVariable>CurrentTrackMetaData</relatedStateVariable></argument>
<argument><name>TrackURI</name><direction>out</direction><relatedStateVariable>CurrentTrackURI</relatedStateVariable></argument>
<argument><name>RelTime</name><direction>out</direction><relatedStateVariable>RelativeTimePosition</relatedStateVariable></argument>
<argument><name>AbsTime</name><direction>out</direction><relatedStateVariable>AbsoluteTimePosition</relatedStateVariable></argument>
<argument><name>RelCount</name><direction>out</direction><relatedStateVariable>RelativeCounterPosition</relatedStateVariable></argument>
<argument><name>AbsCount</name><direction>out</direction><relatedStateVariable>AbsoluteCounterPosition</relatedStateVariable></argument>
</argumentList></action>
<action><name>GetTransportInfo</name><argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>CurrentTransportState</name><direction>out</direction><relatedStateVariable>TransportState</relatedStateVariable></argument>
<argument><name>CurrentTransportStatus</name><direction>out</direction><relatedStateVariable>TransportStatus</relatedStateVariable></argument>
<argument><name>CurrentSpeed</name><direction>out</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
</argumentList></action>
</actionList>
<serviceStateTable>
<stateVariable sendEvents="yes"><name>LastChange</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>TransportState</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>TransportStatus</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>TransportPlaySpeed</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>AVTransportURI</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>AVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>CurrentTrackDuration</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>CurrentTrackURI</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>CurrentTrackMetaData</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekMode</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekTarget</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>RelativeTimePosition</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>AbsoluteTimePosition</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>RelativeCounterPosition</name><dataType>i4</dataType></stateVariable>
<stateVariable sendEvents="no"><name>AbsoluteCounterPosition</name><dataType>i4</dataType></stateVariable>
<stateVariable sendEvents="no"><name>CurrentTrack</name><dataType>ui4</dataType></stateVariable>
</serviceStateTable>
</scpd>"#;

const SCPD_RCS: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion>
<actionList>
<action><name>GetVolume</name><argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
<argument><name>CurrentVolume</name><direction>out</direction><relatedStateVariable>Volume</relatedStateVariable></argument>
</argumentList></action>
<action><name>SetVolume</name><argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
<argument><name>DesiredVolume</name><direction>in</direction><relatedStateVariable>Volume</relatedStateVariable></argument>
</argumentList></action>
<action><name>GetMute</name><argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
<argument><name>CurrentMute</name><direction>out</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
</argumentList></action>
<action><name>SetMute</name><argumentList>
<argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
<argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
<argument><name>DesiredMute</name><direction>in</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
</argumentList></action>
</actionList>
<serviceStateTable>
<stateVariable sendEvents="yes"><name>LastChange</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="no"><name>Volume</name><dataType>ui2</dataType></stateVariable>
<stateVariable sendEvents="no"><name>Mute</name><dataType>boolean</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
<stateVariable sendEvents="no"><name>A_ARG_TYPE_Channel</name><dataType>string</dataType></stateVariable>
</serviceStateTable>
</scpd>"#;

const SCPD_CM: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion>
<actionList>
<action><name>GetProtocolInfo</name><argumentList>
<argument><name>Source</name><direction>out</direction><relatedStateVariable>SourceProtocolInfo</relatedStateVariable></argument>
<argument><name>Sink</name><direction>out</direction><relatedStateVariable>SinkProtocolInfo</relatedStateVariable></argument>
</argumentList></action>
</actionList>
<serviceStateTable>
<stateVariable sendEvents="yes"><name>SourceProtocolInfo</name><dataType>string</dataType></stateVariable>
<stateVariable sendEvents="yes"><name>SinkProtocolInfo</name><dataType>string</dataType></stateVariable>
</serviceStateTable>
</scpd>"#;

pub fn scpd(id: &str) -> Option<&'static str> {
    match id {
        "avt" | "avt.xml" => Some(SCPD_AVT),
        "rcs" | "rcs.xml" => Some(SCPD_RCS),
        "cm" | "cm.xml" => Some(SCPD_CM),
        _ => None,
    }
}

// ---------- SOAP 服务端处理 ----------

fn soap_ok(service: &str, action: &str, inner: &str) -> Response {
    let body = format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:{action}Response xmlns:u="{service}">{inner}</u:{action}Response></s:Body></s:Envelope>"#
    );
    Response::builder()
        .status(StatusCode::OK)
        .header("CONTENT-TYPE", "text/xml; charset=\"utf-8\"")
        .header("EXT", "")
        .body(Body::from(body))
        .unwrap()
}

fn soap_fault(code: u16, desc: &str) -> Response {
    let body = format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>{code}</errorCode><errorDescription>{desc}</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>"#
    );
    Response::builder()
        .status(StatusCode::INTERNAL_SERVER_ERROR)
        .header("CONTENT-TYPE", "text/xml; charset=\"utf-8\"")
        .body(Body::from(body))
        .unwrap()
}

/// 处理 POST /dlna/control/{service}。
pub async fn handle_control(
    shared: &Arc<DmrShared>,
    service_id: &str,
    headers: &HeaderMap,
    body: &str,
) -> Response {
    if shared.enabled.load(Ordering::SeqCst) == 0 {
        return soap_fault(UPNP_ERR_INVALID_ACTION, "renderer disabled");
    }
    let action = super::soap::parse_action_header(
        headers.get("soapaction").and_then(|v| v.to_str().ok()),
    );
    let Some(action) = action else {
        return soap_fault(UPNP_ERR_INVALID_ACTION, "missing SOAPACTION");
    };
    let service = match service_id {
        "avt" => AVT_SERVICE,
        "rcs" => RCS_SERVICE,
        "cm" => CM_SERVICE,
        _ => return soap_fault(UPNP_ERR_INVALID_ACTION, "unknown service"),
    };
    if !body.contains(&action) {
        return soap_fault(UPNP_ERR_INVALID_ACTION, "action mismatch");
    }

    match (service_id, action.as_str()) {
        ("avt", "SetAVTransportURI") => {
            let uri = arg(body, "CurrentURI");
            let meta = xml_unescape(&arg(body, "CurrentURIMetaData"));
            if uri.is_empty() {
                return soap_fault(UPNP_ERR_TRANSITION, "empty URI");
            }
            *shared.current_uri.lock().unwrap() = uri.clone();
            *shared.current_meta.lock().unwrap() = meta.clone();
            let title = extract_tag(&meta, "dc:title").unwrap_or_default();
            let artist = extract_tag(&meta, "dc:creator")
                .or_else(|| extract_tag(&meta, "upnp:artist"))
                .unwrap_or_default();
            let album = extract_tag(&meta, "upnp:album").unwrap_or_default();
            let duration_ms = extract_attr(&meta, "res", "duration")
                .and_then(|d| parse_upnp_time(&d))
                .map(|s| (s * 1000.0) as u64)
                .unwrap_or(0);
            let _ = shared
                .commands
                .send(DmrCommand::LoadUri {
                    uri,
                    title,
                    artist,
                    album,
                    duration_ms,
                    metadata_xml: meta,
                })
                .await;
            soap_ok(service, "SetAVTransportURI", "")
        }
        ("avt", "Play") => {
            let _ = shared.commands.send(DmrCommand::Play).await;
            soap_ok(service, "Play", "")
        }
        ("avt", "Pause") => {
            let _ = shared.commands.send(DmrCommand::Pause).await;
            soap_ok(service, "Pause", "")
        }
        ("avt", "Stop") => {
            let _ = shared.commands.send(DmrCommand::Stop).await;
            soap_ok(service, "Stop", "")
        }
        ("avt", "Seek") => {
            let unit = arg(body, "Unit");
            let target = arg(body, "Target");
            if !unit.eq_ignore_ascii_case("REL_TIME") && !unit.eq_ignore_ascii_case("ABS_TIME") {
                return soap_fault(UPNP_ERR_TRANSITION, "unsupported seek unit");
            }
            match parse_upnp_time(&target) {
                Some(secs) => {
                    let _ = shared.commands.send(DmrCommand::Seek { secs }).await;
                    soap_ok(service, "Seek", "")
                }
                None => soap_fault(UPNP_ERR_TRANSITION, "bad target"),
            }
        }
        ("avt", "GetPositionInfo") => {
            let Some(host) = shared.host() else {
                return soap_fault(UPNP_ERR_TRANSITION, "no host");
            };
            let snap = host.playback_snapshot();
            let uri = shared.current_uri.lock().unwrap().clone();
            let meta = shared.current_meta.lock().unwrap().clone();
            let inner = format!(
                "<Track>1</Track>\
                 <TrackDuration>{}</TrackDuration>\
                 <TrackMetaData>{}</TrackMetaData>\
                 <TrackURI>{}</TrackURI>\
                 <RelTime>{}</RelTime>\
                 <AbsTime>{}</AbsTime>\
                 <RelCount>2147483647</RelCount>\
                 <AbsCount>2147483647</AbsCount>",
                format_upnp_time(snap.duration_secs),
                xml_escape(&meta),
                xml_escape(&uri),
                format_upnp_time(snap.position_secs),
                format_upnp_time(snap.position_secs),
            );
            soap_ok(service, "GetPositionInfo", &inner)
        }
        ("avt", "GetTransportInfo") => {
            let Some(host) = shared.host() else {
                return soap_fault(UPNP_ERR_TRANSITION, "no host");
            };
            let snap = host.playback_snapshot();
            let inner = format!(
                "<CurrentTransportState>{}</CurrentTransportState>\
                 <CurrentTransportStatus>OK</CurrentTransportStatus>\
                 <CurrentSpeed>1</CurrentSpeed>",
                snap.state.as_str()
            );
            soap_ok(service, "GetTransportInfo", &inner)
        }
        ("rcs", "GetVolume") => {
            let Some(host) = shared.host() else {
                return soap_fault(UPNP_ERR_TRANSITION, "no host");
            };
            let (vol, _) = host.volume_snapshot();
            soap_ok(service, "GetVolume", &format!("<CurrentVolume>{vol}</CurrentVolume>"))
        }
        ("rcs", "SetVolume") => {
            let vol: u8 = arg(body, "DesiredVolume").trim().parse().unwrap_or(0);
            let _ = shared.commands.send(DmrCommand::SetVolume { percent: vol }).await;
            soap_ok(service, "SetVolume", "")
        }
        ("rcs", "GetMute") => {
            let Some(host) = shared.host() else {
                return soap_fault(UPNP_ERR_TRANSITION, "no host");
            };
            let (_, mute) = host.volume_snapshot();
            soap_ok(service, "GetMute", &format!("<CurrentMute>{}</CurrentMute>", if mute { 1 } else { 0 }))
        }
        ("rcs", "SetMute") => {
            let want = arg(body, "DesiredMute").trim().to_string();
            let on = want == "1" || want.eq_ignore_ascii_case("true") || want.eq_ignore_ascii_case("yes");
            let _ = shared.commands.send(DmrCommand::SetMute { on }).await;
            soap_ok(service, "SetMute", "")
        }
        ("cm", "GetProtocolInfo") => {
            let sink = "http-get:*:audio/mpeg:*,http-get:*:audio/flac:*,http-get:*:audio/mp4:*,http-get:*:audio/aac:*,http-get:*:audio/ogg:*,http-get:*:audio/wav:*,http-get:*:audio/x-flac:*,http-get:*:audio/x-wav:*";
            soap_ok(
                service,
                "GetProtocolInfo",
                &format!(
                    "<Source></Source><Sink>{}</Sink>",
                    xml_escape(sink)
                ),
            )
        }
        _ => soap_fault(UPNP_ERR_INVALID_ACTION, "unsupported action"),
    }
}

/// 提取 `<tag attr="...">` 的属性值（首个匹配，大小写不敏感）。
fn extract_attr(xml: &str, tag: &str, attr: &str) -> Option<String> {
    let lower = xml.to_ascii_lowercase();
    let open = format!("<{}", tag.to_ascii_lowercase());
    let start = lower.find(&open)?;
    let tag_end = lower[start..].find('>')? + start;
    let seg = &xml[start..tag_end];
    // 在标签内找 attr="value" / attr='value'。
    let pat = format!("{}=", attr.to_ascii_lowercase());
    let seg_lower = seg.to_ascii_lowercase();
    let pos = seg_lower.find(&pat)? + pat.len();
    let rest = seg[pos..].trim_start();
    let quote = rest.chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    let end = rest[1..].find(quote)? + 1;
    Some(rest[1..end].to_string())
}

/// 处理 SUBSCRIBE / UNSUBSCRIBE / GET /dlna/event/*（GENA 订阅桩）。
pub fn handle_event(method: &str) -> Response {
    if method.eq_ignore_ascii_case("SUBSCRIBE") {
        Response::builder()
            .status(StatusCode::OK)
            .header("SID", "uuid:xianyu-dlna-stub")
            .header("TIMEOUT", "Second-1800")
            .body(Body::empty())
            .unwrap()
    } else {
        Response::builder().status(StatusCode::OK).body(Body::empty()).unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shared() -> Arc<DmrShared> {
        let (tx, _rx) = tokio::sync::mpsc::channel(16);
        Arc::new(DmrShared::new(tx))
    }

    fn headers_with_action(action: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert(
            "soapaction",
            format!("\"{AVT_SERVICE}#{action}\"").parse().unwrap(),
        );
        h
    }

    #[tokio::test]
    async fn set_uri_emits_load_command() {
        let (tx, mut rx) = tokio::sync::mpsc::channel(4);
        let s = Arc::new(DmrShared::new(tx));
        s.enabled.store(1, Ordering::SeqCst);
        let body = r#"<u:SetAVTransportURI xmlns:u="x"><InstanceID>0</InstanceID><CurrentURI>http://1.2.3.4/a.mp3</CurrentURI><CurrentURIMetaData>&lt;DIDL-Lite&gt;&lt;dc:title&gt;歌&lt;/dc:title&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData></u:SetAVTransportURI>"#;
        let resp = handle_control(&s, "avt", &headers_with_action("SetAVTransportURI"), body).await;
        assert_eq!(resp.status(), StatusCode::OK);
        match rx.recv().await.unwrap() {
            DmrCommand::LoadUri { uri, title, .. } => {
                assert_eq!(uri, "http://1.2.3.4/a.mp3");
                assert_eq!(title, "歌");
            }
            _ => panic!("expected LoadUri"),
        }
    }

    #[tokio::test]
    async fn disabled_renderer_faults() {
        let s = shared();
        let resp = handle_control(
            &s,
            "avt",
            &headers_with_action("Play"),
            "<u:Play xmlns:u=\"x\"></u:Play>",
        )
        .await;
        assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    }

    #[tokio::test]
    async fn unknown_action_faults() {
        let s = shared();
        s.enabled.store(1, Ordering::SeqCst);
        let resp = handle_control(
            &s,
            "avt",
            &headers_with_action("Next"),
            "<u:Next xmlns:u=\"x\"></u:Next>",
        )
        .await;
        assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    }

    #[test]
    fn scpd_templates_exist() {
        assert!(scpd("avt").unwrap().contains("SetAVTransportURI"));
        assert!(scpd("rcs").unwrap().contains("SetVolume"));
        assert!(scpd("cm").unwrap().contains("GetProtocolInfo"));
        assert!(scpd("bad").is_none());
    }

    #[test]
    fn device_desc_contains_services() {
        let d = device_description("udn-9", "测试设备", 9958);
        assert!(d.contains("uuid:udn-9"));
        assert!(d.contains("测试设备"));
        assert!(d.contains("/dlna/scpd/avt.xml"));
    }
}
