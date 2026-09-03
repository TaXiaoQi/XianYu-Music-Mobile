//! 设备发现：抓取并解析设备描述 XML（双端同步一份代码，勿在本端私自改动）。

use super::soap::extract_tag;
use super::types::DlnaDevice;

/// 抓取设备描述 XML 并解析出 friendlyName / AVT / RCS 控制端点。
pub async fn describe_device(
    client: &reqwest::Client,
    location: &str,
) -> Result<DlnaDevice, String> {
    let text = client
        .get(location)
        .timeout(std::time::Duration::from_secs(6))
        .send()
        .await
        .map_err(|e| format!("拉取设备描述失败: {e}"))?
        .text()
        .await
        .map_err(|e| format!("读取设备描述失败: {e}"))?;

    let base_url = base_of(location);
    let udn = extract_tag(&text, "UDN").unwrap_or_default().trim().to_string();
    let friendly_name = extract_tag(&text, "friendlyName")
        .unwrap_or_else(|| "未知设备".into())
        .trim()
        .to_string();
    let model_name = extract_tag(&text, "modelName").unwrap_or_default().trim().to_string();

    // 扫描 service 块，定位 AVTransport / RenderingControl 的 controlURL。
    let (mut avt, mut rcs) = (None, None);
    for svc in split_service_blocks(&text) {
        let stype = extract_tag(&svc, "serviceType").unwrap_or_default();
        let curl = extract_tag(&svc, "controlURL").unwrap_or_default();
        if curl.is_empty() {
            continue;
        }
        if stype.contains("AVTransport") && avt.is_none() {
            avt = Some(resolve_url(&base_url, &curl));
        } else if stype.contains("RenderingControl") && rcs.is_none() {
            rcs = Some(resolve_url(&base_url, &curl));
        }
    }

    if avt.is_none() {
        return Err(format!("{friendly_name} 不支持 AVTransport（非 DLNA 渲染器）"));
    }

    Ok(DlnaDevice {
        udn: udn.trim_start_matches("uuid:").to_string(),
        friendly_name: if friendly_name.is_empty() {
            "未知设备".into()
        } else {
            friendly_name
        },
        model_name,
        location: location.to_string(),
        base_url,
        avt_control_url: avt,
        rcs_control_url: rcs,
    })
}

/// LOCATION URL 的 origin（scheme://host:port）。
fn base_of(location: &str) -> String {
    location
        .find("://")
        .and_then(|scheme_end| {
            let rest = &location[scheme_end + 3..];
            let path_start = rest.find('/').map(|i| scheme_end + 3 + i)?;
            Some(location[..path_start].to_string())
        })
        .unwrap_or_else(|| location.to_string())
}

/// 相对 controlURL → 绝对 URL（兼容 /开头 与 相对路径）。
pub fn resolve_url(base: &str, path: &str) -> String {
    let path = path.trim();
    if path.starts_with("http://") || path.starts_with("https://") {
        return path.to_string();
    }
    if path.starts_with('/') {
        return format!("{base}{path}");
    }
    format!("{base}/{path}")
}

/// 按 <service>...</service> 切块。
fn split_service_blocks(xml: &str) -> Vec<String> {
    let mut out = Vec::new();
    let lower = xml.to_ascii_lowercase();
    let mut cursor = 0usize;
    while let Some(s) = lower[cursor..].find("<service>") {
        let start = cursor + s;
        let Some(e) = lower[start..].find("</service>") else {
            break;
        };
        out.push(xml[start..start + e + "</service>".len()].to_string());
        cursor = start + e + "</service>".len();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
<URLBase>http://192.168.1.5:49152/</URLBase>
<device>
<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>客厅的小米电视</friendlyName>
<modelName>Xiaomi TV</modelName>
<UDN>uuid:abcd-1234</UDN>
<serviceList>
<service>
<serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
<controlURL>/rcs/control</controlURL>
</service>
<service>
<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
<controlURL>avt/control</controlURL>
</service>
</serviceList>
</device>
</root>"#;

    #[test]
    fn service_blocks_are_split() {
        assert_eq!(split_service_blocks(SAMPLE).len(), 2);
    }

    #[test]
    fn resolve_url_variants() {
        let base = "http://192.168.1.5:49152";
        assert_eq!(resolve_url(base, "/x/y"), "http://192.168.1.5:49152/x/y");
        assert_eq!(resolve_url(base, "x/y"), "http://192.168.1.5:49152/x/y");
        assert_eq!(resolve_url(base, "http://a/b"), "http://a/b");
    }

    #[tokio::test]
    async fn parse_is_pure_after_fetch() {
        // 不走网络，只测解析内联逻辑的可重入性：base_of / resolve_url。
        assert_eq!(
            base_of("http://192.168.1.5:49152/desc.xml"),
            "http://192.168.1.5:49152"
        );
    }
}
