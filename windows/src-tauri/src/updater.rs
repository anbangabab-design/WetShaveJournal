use futures_util::StreamExt;
use regex::Regex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};
use url::Url;

pub const GITHUB_REPO: &str = "anbangabab-design/WetShaveJournal";
pub const CURRENT_VERSION: &str = "1.4.1";

const CHECKSUMS_ASSET_NAME: &str = "SHA256SUMS.txt";
const MAX_CHECKSUMS_FILE_BYTES: usize = 1_048_576;

const ALLOWED_CDN_HOSTS: &[&str] = &[
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "github-releases.githubusercontent.com",
];

#[derive(Default)]
pub struct UpdaterState {
    pub cancel_flag: Arc<AtomicBool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseAssetInfo {
    pub name: String,
    pub browser_download_url: String,
    pub size: u64,
    pub digest: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseInfo {
    pub tag_name: String,
    pub version: String,
    pub title: String,
    pub body: String,
    pub html_url: String,
    pub matched_asset: Option<ReleaseAssetInfo>,
    pub is_from_web_fallback: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateCheckResult {
    pub current_version: String,
    pub has_update: bool,
    pub release: Option<ReleaseInfo>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadProgressEvent {
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
    pub progress: f64,
}

#[derive(Debug, Deserialize)]
struct ApiReleaseAsset {
    name: String,
    browser_download_url: String,
    #[serde(default)]
    size: u64,
    #[serde(default)]
    digest: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ApiReleasePayload {
    tag_name: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    body: Option<String>,
    #[serde(default)]
    html_url: Option<String>,
    #[serde(default)]
    prerelease: bool,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    assets: Vec<ApiReleaseAsset>,
}

// MARK: - 版本解析与比较

fn normalize_version(raw: &str) -> String {
    let trimmed = raw.trim();
    trimmed
        .strip_prefix('v')
        .or_else(|| trimmed.strip_prefix('V'))
        .unwrap_or(trimmed)
        .trim()
        .to_string()
}

fn is_prerelease_version(version: &str) -> bool {
    let lower = version.to_lowercase();
    lower.contains('-')
        || lower.contains("alpha")
        || lower.contains("beta")
        || lower.contains("rc")
        || lower.contains("preview")
}

fn numeric_version_parts(version: &str) -> Option<Vec<u64>> {
    let core = version.split(['-', '+']).next()?;
    let mut parts = Vec::new();
    for seg in core.split('.') {
        let n = seg.parse::<u64>().ok()?;
        parts.push(n);
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts)
    }
}

pub fn is_newer_version(candidate: &str, current: &str) -> bool {
    let norm_cand = normalize_version(candidate);
    let norm_curr = normalize_version(current);
    if norm_cand.is_empty() || norm_curr.is_empty() || is_prerelease_version(&norm_cand) {
        return false;
    }
    let (Some(a), Some(b)) = (
        numeric_version_parts(&norm_cand),
        numeric_version_parts(&norm_curr),
    ) else {
        return false;
    };
    let len = a.len().max(b.len());
    for i in 0..len {
        let va = a.get(i).copied().unwrap_or(0);
        let vb = b.get(i).copied().unwrap_or(0);
        if va != vb {
            return va > vb;
        }
    }
    false
}

// MARK: - URL 安全白名单与资产挑选（Windows 优先 .exe / .msi）

fn is_allowed_release_page_url(url: &Url) -> bool {
    if url.scheme() != "https" {
        return false;
    }
    let Some(host) = url.host_str() else {
        return false;
    };
    if !host.eq_ignore_ascii_case("github.com") {
        return false;
    }
    let path = url.path().to_lowercase();
    !path.contains("..") && path.starts_with(&format!("/{}/releases/", GITHUB_REPO.to_lowercase()))
}

fn is_allowed_release_asset_url(url: &Url) -> bool {
    if url.scheme() != "https" {
        return false;
    }
    let Some(host) = url.host_str() else {
        return false;
    };
    if !host.eq_ignore_ascii_case("github.com") {
        return false;
    }
    let path = url.path().to_lowercase();
    !path.contains("..")
        && path.starts_with(&format!(
            "/{}/releases/download/",
            GITHUB_REPO.to_lowercase()
        ))
}

fn is_allowed_download_redirect_url(url: &Url) -> bool {
    if url.scheme() != "https" {
        return false;
    }
    let Some(host) = url.host_str() else {
        return false;
    };
    let lower_host = host.to_lowercase();
    if lower_host == "github.com" {
        return is_allowed_release_asset_url(url);
    }
    ALLOWED_CDN_HOSTS.contains(&lower_host.as_str())
}

fn is_allowed_windows_asset_name(name: &str) -> bool {
    let trimmed = name.trim();
    if trimmed.is_empty()
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains("..")
    {
        return false;
    }
    let lower = trimmed.to_lowercase();
    lower.ends_with(".exe") || lower.ends_with(".msi")
}

fn select_preferred_windows_asset(assets: &[ReleaseAssetInfo]) -> Option<ReleaseAssetInfo> {
    let valid: Vec<&ReleaseAssetInfo> = assets
        .iter()
        .filter(|a| {
            is_allowed_windows_asset_name(&a.name)
                && Url::parse(&a.browser_download_url)
                    .map(|u| is_allowed_release_asset_url(&u))
                    .unwrap_or(false)
        })
        .collect();

    if valid.is_empty() {
        return None;
    }

    let is_arm64 = cfg!(target_arch = "aarch64");
    let arch_matches = |name: &str| -> bool {
        let lower = name.to_lowercase();
        if is_arm64 {
            lower.contains("arm64") || lower.contains("aarch64")
        } else {
            lower.contains("x64") || lower.contains("x86_64") || lower.contains("amd64")
        }
    };

    // 优先 NSIS .exe 安装包（匹配当前架构优先），其次 .msi
    if let Some(a) = valid
        .iter()
        .find(|a| a.name.to_lowercase().ends_with(".exe") && arch_matches(&a.name))
    {
        return Some((*a).clone());
    }
    if let Some(a) = valid
        .iter()
        .find(|a| a.name.to_lowercase().ends_with(".exe"))
    {
        return Some((*a).clone());
    }
    if let Some(a) = valid
        .iter()
        .find(|a| a.name.to_lowercase().ends_with(".msi") && arch_matches(&a.name))
    {
        return Some((*a).clone());
    }
    valid.first().map(|a| (*a).clone())
}

// MARK: - SHA-256 摘要解析与同 Release SHA256SUMS.txt 校验清单支持

fn encode_path_segment(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for b in input.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

fn is_valid_sha256_hex(raw: &str) -> bool {
    raw.len() == 64 && raw.bytes().all(|b| b.is_ascii_hexdigit())
}

fn parse_expected_sha256_hex(raw: Option<&str>) -> Option<String> {
    let trimmed = raw?.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lower = trimmed.to_ascii_lowercase();
    let hex = lower.strip_prefix("sha256:")?;
    if is_valid_sha256_hex(hex) {
        Some(hex.to_string())
    } else {
        None
    }
}

fn normalized_file_basename(raw: &str) -> String {
    let mut trimmed = raw.trim();
    if trimmed.len() >= 2 && trimmed.starts_with('"') && trimmed.ends_with('"') {
        trimmed = &trimmed[1..trimmed.len() - 1];
    }
    let unified = trimmed.replace('\\', "/");
    unified
        .rsplit('/')
        .find(|seg| !seg.is_empty())
        .unwrap_or("")
        .trim()
        .to_string()
}

fn parse_sha256_sums_line(line: &str) -> Option<(String, String)> {
    let trimmed = line.trim().trim_start_matches('\u{feff}').trim();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }

    // BSD / OpenSSL 格式: SHA256 (<path>) = <64-hex>
    if let Some(prefix) = trimmed.get(..6) {
        if prefix.eq_ignore_ascii_case("sha256") {
            let rest = trimmed[6..].trim_start();
            if let Some(after_open) = rest.strip_prefix('(') {
                if let Some(close_idx) = after_open.rfind(')') {
                    let path_part = &after_open[..close_idx];
                    let after_paren = after_open[close_idx + 1..].trim_start();
                    if let Some(hash_raw) = after_paren.strip_prefix('=') {
                        let hash = hash_raw.trim();
                        let base = normalized_file_basename(path_part);
                        if is_valid_sha256_hex(hash) && !base.is_empty() {
                            return Some((hash.to_ascii_lowercase(), base));
                        }
                    }
                }
            }
        }
    }

    // GNU sha256sum / shasum 格式: [\]<64-hex><spaces/tabs>[*]<path>
    let gnu_line = trimmed.strip_prefix('\\').unwrap_or(trimmed);
    let ws_idx = gnu_line.find(|c: char| c.is_ascii_whitespace())?;
    let hash_raw = &gnu_line[..ws_idx];
    if !is_valid_sha256_hex(hash_raw) {
        return None;
    }
    let mut path_part = gnu_line[ws_idx..].trim_start_matches([' ', '\t']);
    if let Some(stripped) = path_part.strip_prefix('*') {
        path_part = stripped;
    }
    let base = normalized_file_basename(path_part);
    if base.is_empty() {
        return None;
    }
    Some((hash_raw.to_ascii_lowercase(), base))
}

fn parse_sha256_sums(content: &str, target_file_name: &str) -> Option<String> {
    let target_base = normalized_file_basename(target_file_name);
    if target_base.is_empty() {
        return None;
    }
    let target_lower = target_base.to_ascii_lowercase();
    let mut exact_matches: HashSet<String> = HashSet::new();
    let mut ci_matches: HashSet<String> = HashSet::new();

    for line in content.lines() {
        let Some((hash, entry_base)) = parse_sha256_sums_line(line) else {
            continue;
        };
        if entry_base == target_base {
            exact_matches.insert(hash);
        } else if entry_base.to_ascii_lowercase() == target_lower {
            ci_matches.insert(hash);
        }
    }

    if !exact_matches.is_empty() {
        if exact_matches.len() == 1 {
            exact_matches.into_iter().next()
        } else {
            None
        }
    } else if ci_matches.len() == 1 {
        ci_matches.into_iter().next()
    } else {
        None
    }
}

fn extract_tag_from_asset_url(url: &Url) -> Option<String> {
    if !is_allowed_release_asset_url(url) {
        return None;
    }
    let path = url.path();
    let marker = format!("/{}/releases/download/", GITHUB_REPO);
    let prefix = path.get(..marker.len())?;
    if !prefix.eq_ignore_ascii_case(&marker) {
        return None;
    }
    let remainder = &path[marker.len()..];
    let seg = remainder.split('/').next()?;
    let decoded = decode_percent_basic(seg).trim().to_string();
    if decoded.is_empty()
        || decoded.contains('/')
        || decoded.contains('\\')
        || decoded.contains("..")
    {
        None
    } else {
        Some(decoded)
    }
}

fn build_release_checksums_url(tag_name: &str) -> Option<Url> {
    let trimmed = tag_name.trim();
    if trimmed.is_empty()
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains("..")
    {
        return None;
    }
    let encoded_tag = encode_path_segment(trimmed);
    let raw = format!(
        "https://github.com/{}/releases/download/{}/{}",
        GITHUB_REPO, encoded_tag, CHECKSUMS_ASSET_NAME
    );
    let url = Url::parse(&raw).ok()?;
    if is_allowed_release_asset_url(&url) {
        Some(url)
    } else {
        None
    }
}

fn is_same_release_checksums_url(url: &Url, tag_name: &str) -> bool {
    if !is_allowed_release_asset_url(url) {
        return false;
    }
    let path = url.path();
    let marker = format!("/{}/releases/download/", GITHUB_REPO);
    let Some(prefix) = path.get(..marker.len()) else {
        return false;
    };
    if !prefix.eq_ignore_ascii_case(&marker) {
        return false;
    }
    let parts: Vec<&str> = path[marker.len()..].split('/').collect();
    if parts.len() != 2 {
        return false;
    }
    let url_tag = decode_percent_basic(parts[0]).trim().to_string();
    let url_file = decode_percent_basic(parts[1]).trim().to_string();
    url_tag == tag_name.trim() && url_file.eq_ignore_ascii_case(CHECKSUMS_ASSET_NAME)
}

fn build_asset_download_client(timeout_secs: Option<u64>) -> Result<reqwest::Client, String> {
    let redirect_policy = reqwest::redirect::Policy::custom(|attempt| {
        if attempt.previous().len() > 10 {
            attempt.error("重定向次数过多")
        } else if is_allowed_download_redirect_url(attempt.url()) {
            attempt.follow()
        } else {
            attempt.error("重定向目标域名不在 GitHub 官方白名单内")
        }
    });

    let mut builder = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(20))
        .redirect(redirect_policy);
    if let Some(secs) = timeout_secs {
        builder = builder.timeout(Duration::from_secs(secs));
    }
    builder
        .build()
        .map_err(|e| format!("初始化下载客户端失败: {}", e))
}

async fn fetch_sha256_from_release_checksums(
    tag_name: &str,
    asset_name: &str,
    candidate_assets: &[ReleaseAssetInfo],
) -> Option<String> {
    let candidate_url = candidate_assets.iter().find_map(|a| {
        if !a.name.trim().eq_ignore_ascii_case(CHECKSUMS_ASSET_NAME) {
            return None;
        }
        let parsed = Url::parse(&a.browser_download_url).ok()?;
        if is_same_release_checksums_url(&parsed, tag_name) {
            Some(parsed)
        } else {
            None
        }
    });

    let checksums_url = candidate_url.or_else(|| build_release_checksums_url(tag_name))?;
    let client = build_asset_download_client(Some(18)).ok()?;

    let resp = client
        .get(checksums_url)
        .header("Accept", "text/plain, */*")
        .header(
            "User-Agent",
            format!("WetShaveJournal-Windows/{}", CURRENT_VERSION),
        )
        .send()
        .await
        .ok()?;

    if !resp.status().is_success() || !is_allowed_download_redirect_url(resp.url()) {
        return None;
    }
    if let Some(len) = resp.content_length() {
        if len == 0 || len > MAX_CHECKSUMS_FILE_BYTES as u64 {
            return None;
        }
    }

    let mut buf = Vec::new();
    let mut stream = resp.bytes_stream();
    while let Some(chunk_res) = stream.next().await {
        let chunk = chunk_res.ok()?;
        if buf.len().saturating_add(chunk.len()) > MAX_CHECKSUMS_FILE_BYTES {
            return None;
        }
        buf.extend_from_slice(&chunk);
    }
    if buf.is_empty() {
        return None;
    }
    let text = String::from_utf8(buf).ok()?;
    parse_sha256_sums(&text, asset_name)
}

async fn fetch_release_by_tag_via_api(
    client: &reqwest::Client,
    tag_name: &str,
) -> Option<ReleaseInfo> {
    let encoded_tag = encode_path_segment(tag_name.trim());
    if encoded_tag.is_empty() {
        return None;
    }
    let api_url = format!(
        "https://api.github.com/repos/{}/releases/tags/{}",
        GITHUB_REPO, encoded_tag
    );
    let resp = client
        .get(&api_url)
        .header("Accept", "application/vnd.github+json")
        .header(
            "User-Agent",
            format!("WetShaveJournal-Windows/{}", CURRENT_VERSION),
        )
        .send()
        .await
        .ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    let text = resp.text().await.ok()?;
    let payload: ApiReleasePayload = serde_json::from_str(&text).ok()?;
    let version = normalize_version(&payload.tag_name);
    if payload.draft || payload.prerelease || is_prerelease_version(&version) {
        return None;
    }
    let assets: Vec<ReleaseAssetInfo> = payload
        .assets
        .into_iter()
        .map(|a| ReleaseAssetInfo {
            name: a.name,
            browser_download_url: a.browser_download_url,
            size: a.size,
            digest: a.digest,
        })
        .collect();
    let matched_asset = select_preferred_windows_asset(&assets);
    let html_url = payload
        .html_url
        .filter(|u| {
            Url::parse(u)
                .map(|parsed| is_allowed_release_page_url(&parsed))
                .unwrap_or(false)
        })
        .unwrap_or_else(|| {
            format!(
                "https://github.com/{}/releases/tag/{}",
                GITHUB_REPO, payload.tag_name
            )
        });
    Some(ReleaseInfo {
        tag_name: payload.tag_name.clone(),
        version,
        title: payload
            .name
            .filter(|n| !n.trim().is_empty())
            .unwrap_or(payload.tag_name),
        body: payload.body.unwrap_or_default(),
        html_url,
        matched_asset,
        is_from_web_fallback: false,
    })
}

// MARK: - 网页降级 HTML 解析（HTTP 403/429 免限流通道）

fn decode_percent_basic(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex_str) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(val) = u8::from_str_radix(hex_str, 16) {
                    out.push(val);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| input.to_string())
}

fn decode_html_entities(raw: &str) -> String {
    let mut s = raw
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'");

    if let Ok(re) = Regex::new(r"&#(?:x([0-9a-fA-F]+)|(\d+));") {
        s = re
            .replace_all(&s, |caps: &regex::Captures| {
                let code = if let Some(hex) = caps.get(1) {
                    u32::from_str_radix(hex.as_str(), 16).ok()
                } else if let Some(dec) = caps.get(2) {
                    dec.as_str().parse::<u32>().ok()
                } else {
                    None
                };
                code.and_then(char::from_u32)
                    .map(|c| c.to_string())
                    .unwrap_or_else(|| caps[0].to_string())
            })
            .to_string();
    }
    s
}

fn extract_tag_from_release_url(url: &Url) -> Option<String> {
    if !is_allowed_release_page_url(url) {
        return None;
    }
    let path = url.path();
    let lower = path.to_lowercase();
    let marker = "/releases/tag/";
    let idx = lower.find(marker)?;
    let remainder = &path[idx + marker.len()..];
    let seg = remainder.split('/').next()?;
    let decoded = decode_percent_basic(seg).trim().to_string();
    if decoded.is_empty() {
        None
    } else {
        Some(decoded)
    }
}

fn extract_release_notes_from_html(html: &str) -> String {
    let Ok(start_re) = Regex::new(r#"(?i)<div\b[^>]*\bclass="[^"]*\bmarkdown-body\b[^"]*"[^>]*>"#)
    else {
        return String::new();
    };
    let Some(first) = start_re.find(html) else {
        return String::new();
    };
    let tail = &html[first.end()..];
    let Ok(div_re) = Regex::new(r"(?i)</?div\b[^>]*>") else {
        return String::new();
    };

    let mut depth: i32 = 1;
    let mut end_offset: Option<usize> = None;
    for m in div_re.find_iter(tail) {
        if m.as_str().to_lowercase().starts_with("</div") {
            depth -= 1;
            if depth == 0 {
                end_offset = Some(m.start());
                break;
            }
        } else {
            depth += 1;
        }
    }
    let Some(end_idx) = end_offset else {
        return String::new();
    };

    let mut text = tail[..end_idx].to_string();
    let rules: &[(&str, &str)] = &[
        (r"(?is)<svg\b[^>]*>.*?</svg>", ""),
        (r"(?is)<script\b[^>]*>.*?</script>", ""),
        (r"(?is)<style\b[^>]*>.*?</style>", ""),
        (r"(?is)<h2\b[^>]*>(.*?)</h2>", "\n\n## $1\n"),
        (r"(?is)<h3\b[^>]*>(.*?)</h3>", "\n### $1\n"),
        (r"(?is)<li\b[^>]*>", "\n• "),
        (r"(?is)</li>", ""),
        (r"(?is)<br\s*/?>", "\n"),
        (r"(?is)</p>", "\n\n"),
        (r"<[^>]+>", ""),
    ];
    for (pat, rep) in rules {
        if let Ok(re) = Regex::new(pat) {
            text = re.replace_all(&text, *rep).to_string();
        }
    }

    text = decode_html_entities(&text)
        .replace("\r\n", "\n")
        .replace('\r', "\n");

    let cleaned: Vec<&str> = text.lines().map(str::trim).collect();
    let joined = cleaned.join("\n");
    if let Ok(multi_nl) = Regex::new(r"\n{3,}") {
        multi_nl.replace_all(&joined, "\n\n").trim().to_string()
    } else {
        joined.trim().to_string()
    }
}

fn extract_assets_from_expanded_html(html: &str) -> Vec<ReleaseAssetInfo> {
    let escaped_repo = regex::escape(GITHUB_REPO);
    let pattern = format!(
        r#"(?i)href="?(/{}/releases/download/[^"'\s<>]+)"?"#,
        escaped_repo
    );
    let Ok(re) = Regex::new(&pattern) else {
        return Vec::new();
    };

    let mut seen = HashSet::new();
    let mut results = Vec::new();
    for caps in re.captures_iter(html) {
        let Some(rel_match) = caps.get(1) else {
            continue;
        };
        let rel = rel_match.as_str();
        let full_url = format!("https://github.com{}", rel);
        if !seen.insert(full_url.clone()) {
            continue;
        }
        let raw_name = rel.rsplit('/').next().unwrap_or("");
        let decoded_name = decode_percent_basic(raw_name).trim().to_string();
        if decoded_name.is_empty() {
            continue;
        }
        results.push(ReleaseAssetInfo {
            name: decoded_name,
            browser_download_url: full_url,
            size: 0,
            digest: None,
        });
    }
    results
}

// MARK: - 检查更新主流程（API 优先 + 403/429 网页免限流降级）

async fn fetch_latest_via_web_fallback(client: &reqwest::Client) -> Result<ReleaseInfo, String> {
    let latest_url = format!("https://github.com/{}/releases/latest", GITHUB_REPO);
    let resp = client
        .get(&latest_url)
        .header("Accept", "text/html,application/xhtml+xml")
        .header(
            "User-Agent",
            format!("WetShaveJournal-Windows/{}", CURRENT_VERSION),
        )
        .send()
        .await
        .map_err(|e| format!("网页更新通道连接失败: {}", e))?;

    let status = resp.status().as_u16();
    if status == 404 {
        return Err("尚未发布任何正式版本".to_string());
    }
    if !(200..=299).contains(&status) {
        return Err(format!("网页更新通道返回 HTTP {}", status));
    }

    let final_url = resp.url().clone();
    let raw_tag = extract_tag_from_release_url(&final_url)
        .ok_or_else(|| "尚未发布任何正式版本（未识别到版本标签）".to_string())?;
    let normalized_version = normalize_version(&raw_tag);
    if normalized_version.is_empty() {
        return Err("未能解析最新版本号".to_string());
    }

    let page_html = resp
        .text()
        .await
        .map_err(|e| format!("读取发布页内容失败: {}", e))?;
    let notes = extract_release_notes_from_html(&page_html);

    let expanded_url = format!(
        "https://github.com/{}/releases/expanded_assets/{}",
        GITHUB_REPO,
        encode_path_segment(&raw_tag)
    );
    let mut assets = Vec::new();
    if let Ok(assets_resp) = client
        .get(&expanded_url)
        .header("Accept", "text/html,application/xhtml+xml")
        .header(
            "User-Agent",
            format!("WetShaveJournal-Windows/{}", CURRENT_VERSION),
        )
        .send()
        .await
    {
        if assets_resp.status().is_success() {
            if let Ok(assets_html) = assets_resp.text().await {
                assets = extract_assets_from_expanded_html(&assets_html);
            }
        }
    }

    let mut matched_asset = select_preferred_windows_asset(&assets);
    if let Some(ref mut asset) = matched_asset {
        if parse_expected_sha256_hex(asset.digest.as_deref()).is_none() {
            if let Some(sha_hex) =
                fetch_sha256_from_release_checksums(&raw_tag, &asset.name, &assets).await
            {
                asset.digest = Some(format!("sha256:{}", sha_hex));
            }
        }
    }
    Ok(ReleaseInfo {
        tag_name: raw_tag.clone(),
        version: normalized_version,
        title: raw_tag,
        body: notes,
        html_url: final_url.to_string(),
        matched_asset,
        is_from_web_fallback: true,
    })
}

pub async fn check_for_updates() -> Result<UpdateCheckResult, String> {
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(12))
        .timeout(Duration::from_secs(18))
        .build()
        .map_err(|e| format!("初始化更新客户端失败: {}", e))?;

    let api_url = format!("https://api.github.com/repos/{}/releases/latest", GITHUB_REPO);
    let api_res = client
        .get(&api_url)
        .header("Accept", "application/vnd.github+json")
        .header(
            "User-Agent",
            format!("WetShaveJournal-Windows/{}", CURRENT_VERSION),
        )
        .send()
        .await;

    let release: Option<ReleaseInfo> = match api_res {
        Ok(resp) => {
            let status = resp.status().as_u16();
            if status == 200 {
                let text = resp
                    .text()
                    .await
                    .map_err(|e| format!("读取 GitHub API 响应失败: {}", e))?;
                match serde_json::from_str::<ApiReleasePayload>(&text) {
                    Ok(payload) => {
                        let version = normalize_version(&payload.tag_name);
                        if payload.draft || payload.prerelease || is_prerelease_version(&version) {
                            None
                        } else {
                            let assets: Vec<ReleaseAssetInfo> = payload
                                .assets
                                .into_iter()
                                .map(|a| ReleaseAssetInfo {
                                    name: a.name,
                                    browser_download_url: a.browser_download_url,
                                    size: a.size,
                                    digest: a.digest,
                                })
                                .collect();
                            let mut matched_asset = select_preferred_windows_asset(&assets);
                            if let Some(ref mut asset) = matched_asset {
                                if parse_expected_sha256_hex(asset.digest.as_deref()).is_none() {
                                    if let Some(sha_hex) = fetch_sha256_from_release_checksums(
                                        &payload.tag_name,
                                        &asset.name,
                                        &assets,
                                    )
                                    .await
                                    {
                                        asset.digest = Some(format!("sha256:{}", sha_hex));
                                    }
                                }
                            }
                            let html_url = payload
                                .html_url
                                .filter(|u| {
                                    Url::parse(u)
                                        .map(|parsed| is_allowed_release_page_url(&parsed))
                                        .unwrap_or(false)
                                })
                                .unwrap_or_else(|| {
                                    format!(
                                        "https://github.com/{}/releases/tag/{}",
                                        GITHUB_REPO, payload.tag_name
                                    )
                                });
                            Some(ReleaseInfo {
                                tag_name: payload.tag_name.clone(),
                                version,
                                title: payload
                                    .name
                                    .filter(|n| !n.trim().is_empty())
                                    .unwrap_or(payload.tag_name),
                                body: payload.body.unwrap_or_default(),
                                html_url,
                                matched_asset,
                                is_from_web_fallback: false,
                            })
                        }
                    }
                    Err(_) => Some(fetch_latest_via_web_fallback(&client).await?),
                }
            } else if status == 403 || status == 429 || status >= 500 {
                // GitHub API 频率受限或异常：自动降级走网页免限流通道
                let fallback = fetch_latest_via_web_fallback(&client).await?;
                if is_prerelease_version(&fallback.version) {
                    None
                } else {
                    Some(fallback)
                }
            } else if status == 404 {
                None
            } else {
                let fallback = fetch_latest_via_web_fallback(&client).await?;
                if is_prerelease_version(&fallback.version) {
                    None
                } else {
                    Some(fallback)
                }
            }
        }
        Err(_) => {
            // 网络层异常时尝试一次网页通道
            let fallback = fetch_latest_via_web_fallback(&client).await?;
            if is_prerelease_version(&fallback.version) {
                None
            } else {
                Some(fallback)
            }
        }
    };

    if let Some(rel) = release {
        let has_update = is_newer_version(&rel.version, CURRENT_VERSION);
        Ok(UpdateCheckResult {
            current_version: CURRENT_VERSION.to_string(),
            has_update,
            release: if has_update { Some(rel) } else { None },
        })
    } else {
        Ok(UpdateCheckResult {
            current_version: CURRENT_VERSION.to_string(),
            has_update: false,
            release: None,
        })
    }
}

// MARK: - 流式下载安装包到 Downloads 并自动打开

fn resolve_downloads_dir() -> Result<PathBuf, String> {
    if let Some(dl) = dirs::download_dir() {
        return Ok(dl);
    }
    if let Some(home) = dirs::home_dir() {
        return Ok(home.join("Downloads"));
    }
    Err("无法定位用户 Downloads 目录".to_string())
}

pub async fn download_and_open_update(
    app: AppHandle,
    cancel_flag: Arc<AtomicBool>,
    download_url: String,
    file_name: String,
    expected_size: u64,
    tag_name: Option<String>,
    expected_digest: Option<String>,
) -> Result<String, String> {
    let parsed_url = Url::parse(download_url.trim())
        .map_err(|_| "无效的安装包下载地址".to_string())?;
    if !is_allowed_release_asset_url(&parsed_url) {
        return Err("已阻止下载：地址不在官方 GitHub Releases 白名单内".to_string());
    }
    if !is_allowed_windows_asset_name(&file_name) {
        return Err("已阻止下载：目标文件不是受支持的 Windows 安装包（.exe / .msi）".to_string());
    }

    cancel_flag.store(false, Ordering::SeqCst);

    let resolved_tag = tag_name
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToString::to_string)
        .or_else(|| extract_tag_from_asset_url(&parsed_url));

    let mut resolved_sha256 = parse_expected_sha256_hex(expected_digest.as_deref());
    let mut resolved_expected_size = expected_size;

    if resolved_sha256.is_none() {
        if let Some(ref tag) = resolved_tag {
            // 1. 优先尝试通过 GitHub API 按 tag 恢复官方 digest 与文件大小
            if let Ok(api_client) = reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(12))
                .timeout(Duration::from_secs(18))
                .build()
            {
                if let Some(api_release) = fetch_release_by_tag_via_api(&api_client, tag).await {
                    if let Some(api_asset) = api_release.matched_asset {
                        if api_asset.name.eq_ignore_ascii_case(file_name.trim()) {
                            if resolved_expected_size == 0 && api_asset.size > 0 {
                                resolved_expected_size = api_asset.size;
                            }
                            if let Some(api_sha) =
                                parse_expected_sha256_hex(api_asset.digest.as_deref())
                            {
                                resolved_sha256 = Some(api_sha);
                            }
                        }
                    }
                }
            }

            if cancel_flag.load(Ordering::SeqCst) {
                return Err("CANCELLED".to_string());
            }

            // 2. API 未返回 digest 或受限时，自动从同一 Release 下载 SHA256SUMS.txt 解析目标文件摘要
            if resolved_sha256.is_none() {
                resolved_sha256 =
                    fetch_sha256_from_release_checksums(tag, &file_name, &[]).await;
            }
        }
    }

    if cancel_flag.load(Ordering::SeqCst) {
        return Err("CANCELLED".to_string());
    }

    let Some(expected_sha256) = resolved_sha256 else {
        return Err(
            "未能从 GitHub Releases API 或 SHA256SUMS.txt 获取可信 SHA-256 摘要，出于安全考虑已禁止自动打开安装包，请前往官方 Release 页面手动核验下载"
                .to_string(),
        );
    };

    let client = build_asset_download_client(None)?;

    let resp = client
        .get(parsed_url)
        .header(
            "User-Agent",
            format!("WetShaveJournal-Windows/{}", CURRENT_VERSION),
        )
        .send()
        .await
        .map_err(|e| format!("连接下载服务器失败: {}", e))?;

    let status = resp.status().as_u16();
    if !(200..=299).contains(&status) {
        return Err(format!("下载失败（HTTP {}）", status));
    }
    if !is_allowed_download_redirect_url(resp.url()) {
        return Err("已阻止下载：重定向目标域名不在 GitHub 官方白名单内".to_string());
    }

    let total_bytes = resp.content_length().unwrap_or(resolved_expected_size);
    let downloads_dir = resolve_downloads_dir()?;
    fs::create_dir_all(&downloads_dir)
        .map_err(|e| format!("创建下载目录失败: {}", e))?;

    let safe_name = Path::new(&file_name)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("WetShaveJournal-Setup.exe");
    let final_path = downloads_dir.join(safe_name);
    let part_path = downloads_dir.join(format!("{}.part", safe_name));

    let mut file = File::create(&part_path)
        .map_err(|e| format!("创建下载临时文件失败: {}", e))?;

    let mut stream = resp.bytes_stream();
    let mut hasher = Sha256::new();
    let mut downloaded_bytes: u64 = 0;
    let mut last_emit = Instant::now();

    let _ = app.emit(
        "update-download-progress",
        DownloadProgressEvent {
            downloaded_bytes: 0,
            total_bytes,
            progress: 0.0,
        },
    );

    while let Some(chunk_res) = stream.next().await {
        if cancel_flag.load(Ordering::SeqCst) {
            drop(file);
            let _ = fs::remove_file(&part_path);
            return Err("CANCELLED".to_string());
        }

        let chunk = match chunk_res {
            Ok(c) => c,
            Err(e) => {
                drop(file);
                let _ = fs::remove_file(&part_path);
                return Err(format!("下载中断: {}", e));
            }
        };

        if let Err(e) = file.write_all(&chunk) {
            drop(file);
            let _ = fs::remove_file(&part_path);
            return Err(format!("写入下载文件失败: {}", e));
        }

        hasher.update(&chunk);
        downloaded_bytes = downloaded_bytes.saturating_add(chunk.len() as u64);

        if last_emit.elapsed() >= Duration::from_millis(80) {
            last_emit = Instant::now();
            let progress = if total_bytes > 0 {
                (downloaded_bytes as f64 / total_bytes as f64).clamp(0.0, 1.0)
            } else {
                0.0
            };
            let _ = app.emit(
                "update-download-progress",
                DownloadProgressEvent {
                    downloaded_bytes,
                    total_bytes,
                    progress,
                },
            );
        }
    }

    if cancel_flag.load(Ordering::SeqCst) {
        drop(file);
        let _ = fs::remove_file(&part_path);
        return Err("CANCELLED".to_string());
    }

    if downloaded_bytes == 0 {
        drop(file);
        let _ = fs::remove_file(&part_path);
        return Err("校验失败：下载的安装包为空文件，已删除".to_string());
    }

    if resolved_expected_size > 0 && downloaded_bytes != resolved_expected_size {
        drop(file);
        let _ = fs::remove_file(&part_path);
        return Err(format!(
            "校验失败：文件大小与 Release 元数据不一致（预期 {} 字节，实际 {} 字节），已删除",
            resolved_expected_size, downloaded_bytes
        ));
    }

    let digest = hasher.finalize();
    let actual_sha256: String = digest.iter().map(|b| format!("{:02x}", b)).collect();
    if actual_sha256 != expected_sha256 {
        drop(file);
        let _ = fs::remove_file(&part_path);
        return Err(
            "校验失败：安装包 SHA-256 与 Release 摘要不匹配，已自动删除并阻止打开".to_string(),
        );
    }

    let sync_res = file.flush().and_then(|()| file.sync_all());
    drop(file);
    sync_res.map_err(|e| {
        let _ = fs::remove_file(&part_path);
        format!("落盘安装包失败: {}", e)
    })?;

    if final_path.exists() {
        let _ = fs::remove_file(&final_path);
    }
    fs::rename(&part_path, &final_path).map_err(|e| {
        let _ = fs::remove_file(&part_path);
        format!("重命名安装包失败: {}", e)
    })?;

    let _ = app.emit(
        "update-download-progress",
        DownloadProgressEvent {
            downloaded_bytes,
            total_bytes: total_bytes.max(downloaded_bytes),
            progress: 1.0,
        },
    );

    open_path_with_system(&final_path)?;
    Ok(final_path.to_string_lossy().to_string())
}

// MARK: - 系统打开 URL / 安装包 / 在文件夹中定位

pub fn open_external_url(raw_url: &str) -> Result<(), String> {
    let parsed = Url::parse(raw_url.trim()).map_err(|_| "无效的 URL".to_string())?;
    if parsed.scheme() != "https" && parsed.scheme() != "http" {
        return Err("仅允许打开 http/https 链接".to_string());
    }
    let target = parsed.as_str();

    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        std::process::Command::new("cmd")
            .args(["/C", "start", "", target])
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .map_err(|e| format!("打开外部链接失败: {}", e))?;
    }

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(target)
            .spawn()
            .map_err(|e| format!("打开外部链接失败: {}", e))?;
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        std::process::Command::new("xdg-open")
            .arg(target)
            .spawn()
            .map_err(|e| format!("打开外部链接失败: {}", e))?;
    }

    Ok(())
}

fn open_path_with_system(path: &Path) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let path_str = path.to_string_lossy().to_string();
        std::process::Command::new("cmd")
            .args(["/C", "start", "", &path_str])
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .map_err(|e| format!("启动安装程序失败: {}", e))?;
    }

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(path)
            .spawn()
            .map_err(|e| format!("打开安装包失败: {}", e))?;
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        std::process::Command::new("xdg-open")
            .arg(path)
            .spawn()
            .map_err(|e| format!("打开安装包失败: {}", e))?;
    }

    Ok(())
}

pub fn reveal_file_in_folder(path: &Path) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(format!("/select,{}", path.display()))
            .spawn()
            .map_err(|e| format!("定位文件失败: {}", e))?;
    }

    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .args(["-R", &path.to_string_lossy()])
            .spawn()
            .map_err(|e| format!("定位文件失败: {}", e))?;
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Some(parent) = path.parent() {
            std::process::Command::new("xdg-open")
                .arg(parent)
                .spawn()
                .map_err(|e| format!("打开所在目录失败: {}", e))?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_sha256_sums_supports_gnu_binary_bsd_and_rejects_conflicts() {
        let exe_sha = "a".repeat(64);
        let msi_sha = "b".repeat(64);
        let pkg_sha = "C".repeat(64);
        let manifest = format!(
            "# SHA256SUMS\n{}  artifacts/WetShaveJournal_1.4.1_x64-setup.exe\n{} *artifacts/WetShaveJournal_1.4.1_x64_en-US.msi\nSHA256 (./artifacts/WetShaveJournal-1.4.1-arm64.pkg) = {}\n",
            exe_sha, msi_sha, pkg_sha
        );

        assert_eq!(
            parse_sha256_sums(&manifest, "WetShaveJournal_1.4.1_x64-setup.exe"),
            Some(exe_sha.clone())
        );
        assert_eq!(
            parse_sha256_sums(&manifest, "WetShaveJournal_1.4.1_x64_en-US.msi"),
            Some(msi_sha.clone())
        );
        assert_eq!(
            parse_sha256_sums(&manifest, "WetShaveJournal-1.4.1-arm64.pkg"),
            Some(pkg_sha.to_ascii_lowercase())
        );
        assert_eq!(parse_sha256_sums(&manifest, "missing.exe"), None);

        let conflicted = format!(
            "{}  artifacts/WetShaveJournal_1.4.1_x64-setup.exe\n{}  WetShaveJournal_1.4.1_x64-setup.exe\n",
            exe_sha, msi_sha
        );
        assert_eq!(
            parse_sha256_sums(&conflicted, "WetShaveJournal_1.4.1_x64-setup.exe"),
            None
        );
    }

    #[test]
    fn checksums_url_validation_requires_same_repo_and_tag() {
        let ok_url = Url::parse(
            "https://github.com/anbangabab-design/WetShaveJournal/releases/download/v1.4.1/SHA256SUMS.txt",
        )
        .unwrap();
        assert!(is_same_release_checksums_url(&ok_url, "v1.4.1"));
        assert!(!is_same_release_checksums_url(&ok_url, "v1.4.0"));

        let evil_url = Url::parse("https://evil.example.com/SHA256SUMS.txt").unwrap();
        assert!(!is_same_release_checksums_url(&evil_url, "v1.4.1"));

        let exe_url = Url::parse(
            "https://github.com/anbangabab-design/WetShaveJournal/releases/download/v1.4.1/WetShaveJournal_1.4.1_x64-setup.exe",
        )
        .unwrap();
        assert_eq!(
            extract_tag_from_asset_url(&exe_url),
            Some("v1.4.1".to_string())
        );
    }
}
