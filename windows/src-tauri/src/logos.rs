use futures_util::stream::{self, StreamExt};
use regex::Regex;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use url::Url;

use crate::storage::atomic_write_bytes;

const CUSTOM_LOGOS_DIR: &str = "CustomLogos";
const LOGO_CACHE_DIR: &str = "LogoCache";
const LEGACY_LOGOS_DIR: &str = "BrandLogos";
const FAILED_COOLDOWN_FILE: &str = "failed_cooldown.json";
const FAILED_COOLDOWN_SECS: f64 = 24.0 * 3600.0;
const MAX_LOGO_BYTES: u64 = 8 * 1024 * 1024;
const MAX_FETCHED_LOGO_BYTES: usize = 4 * 1024 * 1024;
const MAX_CONCURRENT_FETCHES: usize = 4;
const FETCH_REQUEST_TIMEOUT_SECS: u64 = 8;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomLogoResult {
    pub key: String,
    pub data_url: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrandLogoFetchResult {
    /// fetch_missing_brand_logos 返回本次新抓到的 key -> dataUrl；
    /// clear_and_refetch_brand_logos 返回清理并重抓后的完整可用图标表（含保留的 CustomLogos）
    pub logos: HashMap<String, String>,
    pub fetched_count: usize,
    pub failed_count: usize,
    pub skipped_count: usize,
    pub failed_keys: Vec<String>,
}

/// 严格禁止作为品牌 Logo 来源的平台域名黑名单（防止误抓 Etsy 橙色站标等第三方平台图标）
const BLACKLISTED_DOMAINS: &[&str] = &[
    "etsy.com",
    "etsystatic.com",
    "amazon.",
    "ebay.",
    "aliexpress.",
    "taobao.",
    "tmall.",
    "jd.com",
    "reddit.com",
    "instagram.com",
    "facebook.com",
    "youtube.com",
    "badgerandblade.com",
    "damnfineshave.com",
    "wikipedia.org",
    "pinterest.",
    "twitter.com",
    "x.com",
    "tiktok.com",
    "google.com",
    "gstatic.com",
    "bing.com",
    "duckduckgo.com",
    "shopify.com",
    "wixsite.com",
    "blogspot.",
    "wordpress.com",
];

/// 品牌中英文/简称/子线别名归一化表（与 Mac 版 BrandLogoCache.brandAliases 对齐）
const BRAND_ALIASES: &[(&str, &str)] = &[
    ("华研", "Terry's Soap"),
    ("华研手工皂", "Terry's Soap"),
    ("hwayeon", "Terry's Soap"),
    ("hwayeon soap", "Terry's Soap"),
    ("hwayeon soap co", "Terry's Soap"),
    ("terrys soap", "Terry's Soap"),
    ("terry soap", "Terry's Soap"),
    ("terry's soap", "Terry's Soap"),
    ("帝诗", "DSCosmetic"),
    ("dscosmetic", "DSCosmetic"),
    ("ds cosmetic", "DSCosmetic"),
    ("wolfman", "Wolfman"),
    ("wolfman razors", "Wolfman"),
    ("狼人", "Wolfman"),
    ("karve", "Karve"),
    ("karve shaving", "Karve"),
    ("karve shaving co", "Karve"),
    ("karve shaving co.", "Karve"),
    ("stirling", "Stirling Soap Co."),
    ("stirling soap", "Stirling Soap Co."),
    ("stirling soap co", "Stirling Soap Co."),
    ("stirling soap co.", "Stirling Soap Co."),
    ("斯特林", "Stirling Soap Co."),
    ("dg", "Declaration Grooming"),
    ("declaration", "Declaration Grooming"),
    ("declaration grooming", "Declaration Grooming"),
    ("hom", "House of Mammoth"),
    ("mammoth", "House of Mammoth"),
    ("house of mammoth", "House of Mammoth"),
    ("猛犸象", "House of Mammoth"),
    ("paa", "Phoenix Artisan Accoutrements"),
    ("phoenix", "Phoenix Artisan Accoutrements"),
    ("phoenix shaving", "Phoenix Artisan Accoutrements"),
    ("phoenix artisan", "Phoenix Artisan Accoutrements"),
    ("phoenix artisan accoutrements", "Phoenix Artisan Accoutrements"),
    ("moon", "Moon Soaps"),
    ("moon soaps", "Moon Soaps"),
    ("ae", "Ariana & Evans"),
    ("a&e", "Ariana & Evans"),
    ("ariana & evans", "Ariana & Evans"),
    ("ariana and evans", "Ariana & Evans"),
    ("the club", "Ariana & Evans"),
    ("c&h", "Chisel & Hound"),
    ("chisel & hound", "Chisel & Hound"),
    ("chisel and hound", "Chisel & Hound"),
    ("paladin", "Paladin"),
    ("paladin shaving", "Paladin"),
    ("tns", "Turn-N-Shave"),
    ("turn-n-shave", "Turn-N-Shave"),
    ("turn n shave", "Turn-N-Shave"),
    ("turnnshave", "Turn-N-Shave"),
    ("brad sears", "Brad Sears"),
    ("brad sears shave works", "Brad Sears"),
    ("yaqi", "Yaqi"),
    ("yaqi shaving", "Yaqi"),
    ("雅琪", "Yaqi"),
    ("aylsworth", "Aylsworth"),
    ("aylsworth razors", "Aylsworth"),
    ("alysworth", "Aylsworth"),
    ("rocnel", "Rocnel"),
    ("lambda", "Lambda"),
    ("lambda razors", "Lambda"),
    ("westman", "WestMan Shaving"),
    ("westman shaving", "WestMan Shaving"),
    ("semogue", "Semogue"),
    ("soc", "Semogue"),
    ("semogue owners club", "Semogue"),
    ("cayuen", "Cayuen"),
    ("cayuen workshop", "Cayuen"),
    ("att", "Above The Tie"),
    ("ad", "Atelier Durdan"),
    ("alpha shaving", "Alpha"),
    ("b&m", "Barrister and Mann"),
    ("barrister & mann", "Barrister and Mann"),
    ("blackland razors", "Blackland"),
    ("黑鸟", "Blackland"),
    ("colonial razors", "Colonial"),
    ("ethos", "Ethos Grooming"),
    ("fine", "Fine Accoutrements"),
    ("fs", "Frank Shaving"),
    ("羽毛", "Feather"),
    ("吉列", "Gillette"),
    ("henson shaving", "Henson"),
    ("homelike", "HLS"),
    ("homelike shaving", "HLS"),
    ("贝印", "Kai"),
    ("lpl", "Le Père Lucien"),
    ("le pere lucien", "Le Père Lucien"),
    ("macduff", "MacDuffs Soap Company"),
    ("macduffs", "MacDuffs Soap Company"),
    ("maggard razors", "Maggard"),
    ("mdc", "Martin de Candre"),
    ("muhle", "Mühle"),
    ("穆乐", "Mühle"),
    ("默克尔", "Merkur"),
    ("mwf", "Mitchell's Wool Fat"),
    ("水獭", "Noble Otter"),
    ("欧慕", "Oumo"),
    ("博蒂", "Boti"),
    ("博拉索", "Proraso"),
    ("rr", "RazoRock"),
    ("italian barber", "RazoRock"),
    ("rex", "Rex Supply Co."),
    ("rex supply", "Rex Supply Co."),
    ("sv", "Saponificio Varesino"),
    ("sv1945", "Saponificio Varesino"),
    ("舒适", "Schick"),
    ("辛普森", "Simpson"),
    ("tatara razors", "Tatara"),
    ("tobs", "Taylor of Old Bond Street"),
    ("tgs", "The Goodfellas' Smile"),
    ("trc", "The Razor Company"),
    ("津尔氏", "Thayers"),
    ("timeless razor", "Timeless"),
    ("wilkinson", "Wilkinson Sword"),
    ("zingari", "Zingari Man"),
    ("ej", "Edwin Jagger"),
    ("loccitane", "L'Occitane"),
    ("欧舒丹", "L'Occitane"),
    ("dr harris", "D.R. Harris"),
    ("carbon", "Carbon Shaving"),
];

/// 内置经核实的湿剃品牌官方独立域名白名单（严禁在白名单外瞎猜 <品牌>.com）
const BRAND_DOMAINS: &[(&str, &str)] = &[
    ("Above The Tie", "abovethetie.com"),
    ("Acqua di Parma", "acquadiparma.com"),
    ("Alpha", "alphashaving.com"),
    ("Amonatura", "amonatura.com"),
    ("AP Shave Co", "apshaveco.com"),
    ("Ariana & Evans", "aegrooming.com"),
    ("Arko", "arkomen.com"),
    ("Arno", "arnobrush.com"),
    ("Ascender", "ascenderrazors.com"),
    ("Atelier Durdan", "atelierdurdan.com"),
    ("Aylsworth", "aylsworthrazors.com"),
    ("Barrister and Mann", "barristerandmann.com"),
    ("BIC", "bic.com"),
    ("Blackland", "blacklandrazors.com"),
    ("Blutt", "bluttrasur.ch"),
    ("Boti", "botibrush.com"),
    ("Brad Sears", "bradsearsshaveworks.com"),
    ("Captain's Choice", "captainschoicestore.com"),
    ("Carbon Shaving", "carbonshavingco.com"),
    ("Castle Forbes", "castleforbes.com"),
    ("Catie's Bubbles", "catiesbubbles.com"),
    ("Cayuen", "cayuenworkshop.com"),
    ("Cella", "cellamilano.it"),
    ("CeraVe", "cerave.com"),
    ("Charcoal Goods", "charcoalgoods.com"),
    ("Chisel & Hound", "chiselandhound.com"),
    ("Chiseled Face", "chiseledface.com"),
    ("Clubman Pinaud", "clubmanonline.com"),
    ("Colonial", "colonialrazors.com"),
    ("D.R. Harris", "drharris.co.uk"),
    ("Declaration Grooming", "declarationgrooming.com"),
    ("Derby", "derbyrazorblades.com"),
    ("Dorco", "dorcousa.com"),
    ("DSCosmetic", "dscosmetic.com"),
    ("Edwin Jagger", "edwinjagger.com"),
    ("Elysian Soap Shop", "elysiansoapshop.com"),
    ("Ethos Grooming", "ethosgroomingessentials.com"),
    ("Fatip", "fatip.it"),
    ("Feather", "feather.co.jp"),
    ("Fine Accoutrements", "fineaccoutrements.com"),
    ("Frank Shaving", "frankshaving.com"),
    ("Geo. F. Trumper", "trumpers.com"),
    ("Gillette", "gillette.com"),
    ("Grooming Dept", "groomingdept.com"),
    ("HAGS", "haveagreatshave.com"),
    ("Haslinger", "haslingerseifen.at"),
    ("Henson", "hensonshaving.com"),
    ("HLS", "homelikeshaving.ru"),
    ("House of Mammoth", "houseofmammoth.com"),
    ("Kai", "kai-group.com"),
    ("Karve", "karveshaving.com"),
    ("L'Occitane", "loccitane.com"),
    ("Lambda", "lambdarazors.com"),
    ("Le Père Lucien", "leperelucien.com"),
    ("Leaf", "leafshave.com"),
    ("Longshaving", "longshaving.com"),
    ("MacDuffs Soap Company", "macduffssoapcompany.com"),
    ("Maggard", "maggardrazors.com"),
    ("Martin de Candre", "martin-de-candre.com"),
    ("Maxwell June", "maxwelljune.com"),
    ("Merkur", "merkur-razors.com"),
    ("Mitchell's Wool Fat", "mitchellswoolfatsoap.co.uk"),
    ("Moon Soaps", "moonsoaps.com"),
    ("Mühle", "muehle-shaving.com"),
    ("Murphy and McNeil", "murphyandmcneil.com"),
    ("Nivea", "nivea.com"),
    ("Noble Otter", "nobleotter.com"),
    ("Nomad Theory", "nomadtheory.co.uk"),
    ("Old Spice", "oldspice.com"),
    ("Omega", "omegabrush.com"),
    ("Osma", "osma-tradition.com"),
    ("Oumo", "oumoshavingbrush.com"),
    ("Paladin", "paladinshaving.com"),
    ("PantaRei", "pantareibrushes.it"),
    ("Parker", "parkershaving.com"),
    ("Personna", "personna.com"),
    ("Phoenix Artisan Accoutrements", "phoenixartisanaccoutrements.com"),
    ("Proraso", "proraso.com"),
    ("RazoRock", "italianbarber.com"),
    ("Rex Supply Co.", "rexsupplyco.com"),
    ("Rockwell", "getrockwell.com"),
    ("Rocnel", "rocnel.com"),
    ("Saponificio Varesino", "saponificiovaresino.com"),
    ("Schick", "schick.com"),
    ("Semogue", "portuguesefactory.com"),
    ("Shavemac", "shavemac.com"),
    ("Simpson", "simpsonshavingbrushes.com"),
    ("Southern Witchcrafts", "southernwitchcrafts.com"),
    ("Speick", "speick.de"),
    ("Stirling Soap Co.", "stirlingsoap.com"),
    ("Summer Break Soaps", "summerbreaksoaps.com"),
    ("Tabac", "tabac-original.com"),
    ("Tatara", "tatararazors.com"),
    ("Taylor of Old Bond Street", "tayloroldbondst.co.uk"),
    ("Terry's Soap", "hwayeon.co.kr"),
    ("Thayers", "thayers.com"),
    ("The Goodfellas' Smile", "rasoigoodfellas.com"),
    ("The Razor Company", "therazorcompany.com"),
    ("Timeless", "timelessrazor.com"),
    ("Treet", "treetonline.com"),
    ("Truefitt & Hill", "truefittandhill.co.uk"),
    ("Turn-N-Shave", "turnnshave.com"),
    ("Wald", "waldshaving.com"),
    ("WestMan Shaving", "westmanshaving.com"),
    ("Wholly Kaw", "whollykaw.com"),
    ("Wickham", "w-soap.co.uk"),
    ("Wilkinson Sword", "wilkinsonsword.com"),
    ("Wolfman", "wolfmanrazors.com"),
    ("Yaqi", "yaqishaving.com"),
    ("Yates", "yatesprecision.com"),
    ("Zenith", "pennellificiopandolfo.com"),
    ("Zingari Man", "zingariman.com"),
];

/// 与 Mac 版 BrandLogoCache.normalizedBrandKey(_:) 100% 一致的品牌文件名归一化
pub fn normalized_brand_key(brand: &str) -> String {
    brand
        .trim()
        .to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '_' })
        .collect()
}

fn compact_alnum_token(input: &str) -> String {
    input
        .trim()
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

fn should_skip_brand(brand: &str) -> bool {
    let trimmed = brand.trim();
    if trimmed.is_empty() {
        return true;
    }
    let lower = trimmed.to_lowercase();
    matches!(
        lower.as_str(),
        "仿刀" | "品牌未注明" | "无品牌" | "未知" | "unknown" | "none" | "n/a" | "无" | "-"
    )
}

fn is_blacklisted_host(host: &str) -> bool {
    let h = host.trim().to_lowercase();
    if h.is_empty() {
        return true;
    }
    for bad in BLACKLISTED_DOMAINS {
        if bad.ends_with('.') {
            if h.contains(bad) {
                return true;
            }
        } else if h == *bad || h.ends_with(&format!(".{}", bad)) {
            return true;
        }
    }
    false
}

fn lookup_direct_domain(candidate: &str) -> Option<(&'static str, &'static str)> {
    let trimmed = candidate.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lower = trimmed.to_lowercase();
    for (name, domain) in BRAND_DOMAINS {
        if name.eq_ignore_ascii_case(trimmed) || name.to_lowercase() == lower {
            return Some((*name, *domain));
        }
    }
    for (alias, canonical) in BRAND_ALIASES {
        if alias.eq_ignore_ascii_case(trimmed) || alias.to_lowercase() == lower {
            if let Some((name, domain)) = BRAND_DOMAINS
                .iter()
                .find(|(n, _)| n.eq_ignore_ascii_case(canonical))
            {
                return Some((*name, *domain));
            }
        }
    }
    let compact = compact_alnum_token(trimmed);
    if !compact.is_empty() {
        for (name, domain) in BRAND_DOMAINS {
            if compact_alnum_token(name) == compact {
                return Some((*name, *domain));
            }
        }
        for (alias, canonical) in BRAND_ALIASES {
            if compact_alnum_token(alias) == compact {
                if let Some((name, domain)) = BRAND_DOMAINS
                    .iter()
                    .find(|(n, _)| n.eq_ignore_ascii_case(canonical))
                {
                    return Some((*name, *domain));
                }
            }
        }
    }
    None
}

/// 别名归一化 + 混搭名 `A × B` 主品牌提取 → 仅命中经核实官网白名单
fn resolve_whitelisted_brand(brand: &str) -> Option<(&'static str, &'static str)> {
    let trimmed = brand.trim();
    if should_skip_brand(trimmed) {
        return None;
    }
    if let Some(hit) = lookup_direct_domain(trimmed) {
        return Some(hit);
    }
    for sep in ["×", " x ", " X ", " / ", "/"] {
        if trimmed.contains(sep) {
            for part in trimmed.split(sep).map(str::trim).filter(|p| !p.is_empty()) {
                if let Some(hit) = lookup_direct_domain(part) {
                    return Some(hit);
                }
            }
        }
    }
    None
}

fn encode_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(((input.len() + 2) / 3) * 4);
    for chunk in input.chunks(3) {
        match chunk.len() {
            3 => {
                let n = ((chunk[0] as u32) << 16) | ((chunk[1] as u32) << 8) | (chunk[2] as u32);
                out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
                out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
                out.push(TABLE[((n >> 6) & 0x3F) as usize] as char);
                out.push(TABLE[(n & 0x3F) as usize] as char);
            }
            2 => {
                let n = ((chunk[0] as u32) << 16) | ((chunk[1] as u32) << 8);
                out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
                out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
                out.push(TABLE[((n >> 6) & 0x3F) as usize] as char);
                out.push('=');
            }
            1 => {
                let n = (chunk[0] as u32) << 16;
                out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
                out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
                out.push('=');
                out.push('=');
            }
            _ => {}
        }
    }
    out
}

fn looks_like_html(bytes: &[u8]) -> bool {
    let sample_len = bytes.len().min(512);
    if let Ok(head) = std::str::from_utf8(&bytes[..sample_len]) {
        let lower = head.trim_start().to_lowercase();
        if lower.starts_with("<!doctype html")
            || lower.starts_with("<html")
            || lower.starts_with("<head")
            || lower.starts_with("<body")
            || lower.starts_with("<script")
            || lower.contains("<html")
        {
            return true;
        }
    }
    false
}

/// 严格按文件头魔数校验联网下载的图片（不信任 URL 扩展名，拦截 HTML 错误页与过小占位图标）
fn validate_fetched_image(bytes: &[u8], min_dimension: u32) -> Option<&'static str> {
    if bytes.is_empty() || bytes.len() > MAX_FETCHED_LOGO_BYTES {
        return None;
    }
    if looks_like_html(bytes) {
        return None;
    }

    // PNG：校验 IHDR 宽高（拦截 Google S2 16x16 默认灰地球等极小图标）
    if bytes.len() >= 24
        && bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        && &bytes[12..16] == b"IHDR"
    {
        let w = u32::from_be_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]);
        let h = u32::from_be_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]);
        if w >= min_dimension && h >= min_dimension && bytes.len() >= 200 {
            return Some("image/png");
        }
        return None;
    }

    // JPEG
    if bytes.len() >= 300 && bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some("image/jpeg");
    }

    // WebP
    if bytes.len() >= 250 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return Some("image/webp");
    }

    // GIF
    if bytes.len() >= 10 && (bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a")) {
        let w = u16::from_le_bytes([bytes[6], bytes[7]]) as u32;
        let h = u16::from_le_bytes([bytes[8], bytes[9]]) as u32;
        if w >= min_dimension && h >= min_dimension && bytes.len() >= 200 {
            return Some("image/gif");
        }
        return None;
    }

    // ICO：检查目录项是否包含有效尺寸
    if bytes.len() >= 22 && bytes.starts_with(&[0x00, 0x00, 0x01, 0x00]) {
        let count = u16::from_le_bytes([bytes[4], bytes[5]]) as usize;
        if count > 0 && count <= 32 {
            let mut max_dim: u32 = 0;
            for i in 0..count {
                let off = 6 + i * 16;
                if off + 2 > bytes.len() {
                    break;
                }
                let w = if bytes[off] == 0 {
                    256
                } else {
                    bytes[off] as u32
                };
                let h = if bytes[off + 1] == 0 {
                    256
                } else {
                    bytes[off + 1] as u32
                };
                max_dim = max_dim.max(w.min(h));
            }
            if max_dim >= min_dimension && bytes.len() >= 250 {
                return Some("image/x-icon");
            }
        }
        return None;
    }

    // SVG：校验完整 UTF-8 且包含 <svg 闭合标签
    if bytes.len() >= 64 {
        if let Ok(text) = std::str::from_utf8(bytes) {
            let lower = text.to_lowercase();
            let trimmed = lower.trim_start();
            if (trimmed.starts_with("<svg") || trimmed.starts_with("<?xml"))
                && lower.contains("<svg")
                && lower.contains("</svg>")
            {
                return Some("image/svg+xml");
            }
        }
    }

    None
}

fn detect_image_mime(bytes: &[u8], ext: Option<&str>) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
        return Some("image/png");
    }
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some("image/jpeg");
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    if bytes.starts_with(&[0x00, 0x00, 0x01, 0x00]) {
        return Some("image/x-icon");
    }
    if bytes.starts_with(b"BM") {
        return Some("image/bmp");
    }
    if let Ok(head) = std::str::from_utf8(&bytes[..bytes.len().min(256)]) {
        let trimmed = head.trim_start();
        if trimmed.starts_with("<svg") || trimmed.starts_with("<?xml") {
            return Some("image/svg+xml");
        }
    }

    match ext.map(|e| e.to_ascii_lowercase()).as_deref() {
        Some("png") => Some("image/png"),
        Some("jpg") | Some("jpeg") => Some("image/jpeg"),
        Some("webp") => Some("image/webp"),
        Some("gif") => Some("image/gif"),
        Some("ico") => Some("image/x-icon"),
        Some("bmp") => Some("image/bmp"),
        Some("svg") => Some("image/svg+xml"),
        _ => None,
    }
}

fn extension_for_mime(mime: &str) -> &'static str {
    match mime {
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "image/x-icon" => "ico",
        "image/bmp" => "bmp",
        "image/svg+xml" => "svg",
        _ => "png",
    }
}

fn collect_existing_keys_in_dir(dir: &Path, out: &mut HashSet<String>) {
    if !dir.is_dir() {
        return;
    }
    let Ok(read_dir) = fs::read_dir(dir) else {
        return;
    };
    for entry in read_dir.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Some(file_name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if file_name.starts_with('.') {
            continue;
        }
        let Ok(meta) = fs::metadata(&path) else {
            continue;
        };
        if meta.len() == 0 || meta.len() > MAX_LOGO_BYTES {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let key = stem.trim().to_lowercase();
        if key.is_empty() {
            continue;
        }
        let ext = path.extension().and_then(|e| e.to_str());
        let Ok(bytes) = fs::read(&path) else {
            continue;
        };
        if detect_image_mime(&bytes, ext).is_some() {
            out.insert(key);
        }
    }
}

fn scan_logo_dir(dir: &Path, out: &mut HashMap<String, String>) {
    if !dir.is_dir() {
        return;
    }
    let Ok(read_dir) = fs::read_dir(dir) else {
        return;
    };

    for entry in read_dir.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Some(file_name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if file_name.starts_with('.') {
            continue;
        }
        let Ok(meta) = fs::metadata(&path) else {
            continue;
        };
        if meta.len() == 0 || meta.len() > MAX_LOGO_BYTES {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let key = stem.trim().to_lowercase();
        if key.is_empty() {
            continue;
        }
        let ext = path.extension().and_then(|e| e.to_str());
        let Ok(bytes) = fs::read(&path) else {
            continue;
        };
        let Some(mime) = detect_image_mime(&bytes, ext) else {
            continue;
        };
        let data_url = format!("data:{};base64,{}", mime, encode_base64(&bytes));
        out.insert(key, data_url);
    }
}

/// 扫描当前数据目录下的品牌图标缓存（优先级：CustomLogos > LogoCache > BrandLogos）
pub fn load_brand_logos(data_dir: &Path) -> Result<HashMap<String, String>, String> {
    let mut map = HashMap::new();
    scan_logo_dir(&data_dir.join(LEGACY_LOGOS_DIR), &mut map);
    scan_logo_dir(&data_dir.join(LOGO_CACHE_DIR), &mut map);
    scan_logo_dir(&data_dir.join(CUSTOM_LOGOS_DIR), &mut map);
    Ok(map)
}

/// 将用户选择的本地图片保存至当前数据目录的 CustomLogos/，并返回可直接渲染的 data URL
pub fn set_custom_brand_logo(
    data_dir: &Path,
    brand: &str,
    source_path: &Path,
) -> Result<CustomLogoResult, String> {
    let key = normalized_brand_key(brand);
    if key.is_empty() {
        return Err("品牌名称为空，无法设置自定义图标".to_string());
    }

    let meta = fs::metadata(source_path)
        .map_err(|e| format!("无法读取所选图片文件 ({}): {}", source_path.display(), e))?;
    if meta.len() == 0 {
        return Err("所选图片文件为空".to_string());
    }
    if meta.len() > MAX_LOGO_BYTES {
        return Err("所选图片体积超过 8 MB，请选择更小的图标文件".to_string());
    }

    let bytes = fs::read(source_path)
        .map_err(|e| format!("读取所选图片失败 ({}): {}", source_path.display(), e))?;
    let ext = source_path.extension().and_then(|e| e.to_str());
    let mime = detect_image_mime(&bytes, ext)
        .ok_or_else(|| "不支持的图片格式，请选择 PNG / JPG / WebP / ICO / SVG 图片".to_string())?;

    let custom_dir = data_dir.join(CUSTOM_LOGOS_DIR);
    fs::create_dir_all(&custom_dir)
        .map_err(|e| format!("创建 CustomLogos 目录失败: {}", e))?;

    // 清理同品牌旧扩展名文件，避免同 key 多文件冲突
    if let Ok(read_dir) = fs::read_dir(&custom_dir) {
        for entry in read_dir.flatten() {
            let existing_path = entry.path();
            if existing_path.is_file() {
                if let Some(stem) = existing_path.file_stem().and_then(|s| s.to_str()) {
                    if stem.to_lowercase() == key {
                        let _ = fs::remove_file(&existing_path);
                    }
                }
            }
        }
    }

    let target_ext = extension_for_mime(mime);
    let target_path = custom_dir.join(format!("{}.{}", key, target_ext));
    atomic_write_bytes(&target_path, &bytes)?;

    let data_url = format!("data:{};base64,{}", mime, encode_base64(&bytes));
    Ok(CustomLogoResult { key, data_url })
}

// MARK: - 自动联网抓取品牌 Logo（并发限流 4、单请求 8s 超时、反 Etsy 黑名单、绝不覆盖 CustomLogos）

fn build_logo_http_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(FETCH_REQUEST_TIMEOUT_SECS))
        .redirect(reqwest::redirect::Policy::limited(5))
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
        .build()
        .map_err(|e| format!("初始化品牌图标抓取客户端失败: {}", e))
}

fn extract_attr_value(tag: &str, attr_name: &str) -> Option<String> {
    let pattern = format!(
        r#"(?i)\b{}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
        attr_name
    );
    let re = Regex::new(&pattern).ok()?;
    let caps = re.captures(tag)?;
    let raw = caps
        .get(1)
        .or_else(|| caps.get(2))
        .or_else(|| caps.get(3))?
        .as_str()
        .trim();
    if raw.is_empty() {
        None
    } else {
        Some(raw.replace("&amp;", "&"))
    }
}

fn extract_html_icon_urls(html: &str, base_url: &Url) -> Vec<String> {
    let mut apple_icons: Vec<String> = Vec::new();
    let mut std_icons: Vec<String> = Vec::new();
    let mut og_and_header: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    let push_candidate = |raw: &str, bucket: &mut Vec<String>, seen: &mut HashSet<String>| {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.starts_with("data:") || trimmed.starts_with("javascript:") {
            return;
        }
        let Ok(resolved) = base_url.join(trimmed) else {
            return;
        };
        if resolved.scheme() != "https" && resolved.scheme() != "http" {
            return;
        }
        let Some(host) = resolved.host_str() else {
            return;
        };
        if is_blacklisted_host(host) {
            return;
        }
        let abs = resolved.to_string();
        if seen.insert(abs.clone()) {
            bucket.push(abs);
        }
    };

    // 1) <link rel="apple-touch-icon"> 与 <link rel="icon">
    if let Ok(link_re) = Regex::new(r"(?is)<link\b[^>]*>") {
        for m in link_re.find_iter(html) {
            let tag = m.as_str();
            let Some(rel) = extract_attr_value(tag, "rel") else {
                continue;
            };
            let rel_lower = rel.to_lowercase();
            let is_apple = rel_lower.contains("apple-touch-icon");
            let is_icon = !is_apple
                && (rel_lower == "icon"
                    || rel_lower == "shortcut icon"
                    || rel_lower.split_whitespace().any(|tok| tok == "icon"));
            if !is_apple && !is_icon {
                continue;
            }
            let Some(href) = extract_attr_value(tag, "href") else {
                continue;
            };
            if is_apple {
                push_candidate(&href, &mut apple_icons, &mut seen);
            } else {
                push_candidate(&href, &mut std_icons, &mut seen);
            }
        }
    }

    // 2) <meta property="og:image">
    if let Ok(meta_re) = Regex::new(r"(?is)<meta\b[^>]*>") {
        for m in meta_re.find_iter(html) {
            let tag = m.as_str();
            let prop = extract_attr_value(tag, "property")
                .or_else(|| extract_attr_value(tag, "name"))
                .unwrap_or_default()
                .to_lowercase();
            if prop == "og:image" {
                if let Some(content) = extract_attr_value(tag, "content") {
                    push_candidate(&content, &mut og_and_header, &mut seen);
                }
            }
        }
    }

    // 3) 页面头部 Logo <img>（优先 <header> 区域或带 logo/brand 属性的 <img>）
    let mut header_regions: Vec<&str> = Vec::new();
    if let Ok(header_re) = Regex::new(r"(?is)<header\b[^>]*>.*?</header>") {
        for m in header_re.find_iter(html).take(2) {
            header_regions.push(m.as_str());
        }
    }
    let prefix_len = html.len().min(65_536);
    let mut safe_prefix = prefix_len;
    while safe_prefix > 0 && !html.is_char_boundary(safe_prefix) {
        safe_prefix -= 1;
    }
    header_regions.push(&html[..safe_prefix]);

    if let Ok(img_re) = Regex::new(r"(?is)<img\b[^>]*>") {
        for region in header_regions {
            for m in img_re.find_iter(region).take(20) {
                let tag = m.as_str();
                let lower = tag.to_lowercase();
                if !lower.contains("logo") && !lower.contains("brand") {
                    continue;
                }
                if let Some(src) = extract_attr_value(tag, "src") {
                    push_candidate(&src, &mut og_and_header, &mut seen);
                }
            }
        }
    }

    apple_icons.extend(std_icons);
    apple_icons.extend(og_and_header);
    apple_icons.truncate(10);
    apple_icons
}

async fn download_valid_image(
    client: &reqwest::Client,
    url_str: &str,
    check_host_blacklist: bool,
    min_dimension: u32,
) -> Option<(Vec<u8>, &'static str)> {
    let parsed = Url::parse(url_str).ok()?;
    if parsed.scheme() != "https" && parsed.scheme() != "http" {
        return None;
    }
    if check_host_blacklist {
        let host = parsed.host_str()?;
        if is_blacklisted_host(host) {
            return None;
        }
    }

    let resp = client.get(url_str).send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    if check_host_blacklist {
        let final_host = resp.url().host_str()?;
        if is_blacklisted_host(final_host) {
            return None;
        }
    }
    if let Some(ct) = resp.headers().get(reqwest::header::CONTENT_TYPE) {
        if let Ok(ct_str) = ct.to_str() {
            let ct_lower = ct_str.to_lowercase();
            if ct_lower.contains("text/html") || ct_lower.contains("application/xhtml") {
                return None;
            }
        }
    }

    let bytes = resp.bytes().await.ok()?;
    let slice = bytes.as_ref();
    let mime = validate_fetched_image(slice, min_dimension)?;
    Some((slice.to_vec(), mime))
}

enum HomepageFetchOutcome {
    Html(String, Url),
    CloudflareBlocked,
    Unavailable,
}

async fn fetch_site_homepage_html(
    client: &reqwest::Client,
    domain: &str,
) -> HomepageFetchOutcome {
    let mut cf_blocked = false;
    for home_str in [format!("https://{}", domain), format!("https://www.{}", domain)] {
        let Ok(resp) = client
            .get(&home_str)
            .header("Accept", "text/html,application/xhtml+xml")
            .send()
            .await
        else {
            continue;
        };
        let status = resp.status().as_u16();
        let has_cf_header = resp.headers().get("cf-mitigated").is_some();
        let final_url_str = resp.url().as_str().to_string();
        let body_bytes = resp.bytes().await.unwrap_or_default();
        let cap = body_bytes.len().min(256 * 1024);
        let html = String::from_utf8_lossy(&body_bytes[..cap]).to_string();
        let lower_html = html.to_lowercase();

        if has_cf_header
            || ((status == 403 || status == 503)
                && (lower_html.contains("cloudflare")
                    || lower_html.contains("just a moment")
                    || lower_html.contains("_cf_chl_opt")
                    || lower_html.contains("cf-browser-verification")))
        {
            cf_blocked = true;
            continue;
        }

        if !(200..=299).contains(&status) {
            continue;
        }
        let Ok(final_url) = Url::parse(&final_url_str) else {
            continue;
        };
        let Some(final_host) = final_url.host_str() else {
            continue;
        };
        if is_blacklisted_host(final_host) {
            continue;
        }
        return HomepageFetchOutcome::Html(html, final_url);
    }

    if cf_blocked {
        HomepageFetchOutcome::CloudflareBlocked
    } else {
        HomepageFetchOutcome::Unavailable
    }
}

async fn fetch_whitelisted_domain_logo(
    client: &reqwest::Client,
    domain: &str,
) -> Option<(Vec<u8>, &'static str)> {
    if is_blacklisted_host(domain) {
        return None;
    }

    let mut blocked_by_cloudflare = false;

    // 1) 白名单官网优先提取 apple-touch-icon / 高清 icon / og:image / 头部 Logo
    match fetch_site_homepage_html(client, domain).await {
        HomepageFetchOutcome::Html(html, final_url) => {
            let candidates = extract_html_icon_urls(&html, &final_url);
            for candidate in candidates {
                if let Some(img) = download_valid_image(client, &candidate, true, 24).await {
                    return Some(img);
                }
            }
        }
        HomepageFetchOutcome::CloudflareBlocked => {
            blocked_by_cloudflare = true;
        }
        HomepageFetchOutcome::Unavailable => {}
    }

    // 2) 未被 Cloudflare 拦截时，直接尝试 /apple-touch-icon.png 与 /favicon.ico
    if !blocked_by_cloudflare {
        let direct_candidates = [
            format!("https://{}/apple-touch-icon.png", domain),
            format!("https://www.{}/apple-touch-icon.png", domain),
            format!("https://{}/favicon.ico", domain),
            format!("https://www.{}/favicon.ico", domain),
        ];
        for url_str in direct_candidates {
            if let Some(img) = download_valid_image(client, &url_str, true, 24).await {
                return Some(img);
            }
        }
    }

    // 3) 被 Cloudflare 拦截或直连未命中：回退至 Google Favicon 代理（sz=128），严格过滤 16x16 默认灰地球占位图（要求 >= 32px）
    let s2_url = format!(
        "https://www.google.com/s2/favicons?domain={}&sz=128",
        domain
    );
    if let Some((bytes, mime)) = download_valid_image(client, &s2_url, false, 32).await {
        if bytes.len() >= 400 {
            return Some((bytes, mime));
        }
    }

    None
}

async fn resolve_brand_logo(
    client: &reqwest::Client,
    brand: &str,
) -> Option<(Vec<u8>, &'static str)> {
    // 禁用瞎猜 <品牌名>.com：仅抓取白名单内经核实的品牌官网，小众/国内手工/仿刀默认展示干净首字徽章
    let (_, known_domain) = resolve_whitelisted_brand(brand)?;
    fetch_whitelisted_domain_logo(client, known_domain).await
}

fn current_unix_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn load_failed_cooldowns(cache_dir: &Path) -> HashMap<String, f64> {
    let path = cache_dir.join(FAILED_COOLDOWN_FILE);
    let Ok(bytes) = fs::read(&path) else {
        return HashMap::new();
    };
    let Ok(map) = serde_json::from_slice::<HashMap<String, f64>>(&bytes) else {
        return HashMap::new();
    };
    let now = current_unix_secs();
    map.into_iter()
        .filter(|(_, ts)| now - *ts < FAILED_COOLDOWN_SECS)
        .collect()
}

fn save_failed_cooldowns(cache_dir: &Path, cooldowns: &HashMap<String, f64>) {
    let now = current_unix_secs();
    let active: HashMap<&String, &f64> = cooldowns
        .iter()
        .filter(|(_, ts)| now - **ts < FAILED_COOLDOWN_SECS)
        .collect();
    if let Ok(bytes) = serde_json::to_vec_pretty(&active) {
        let _ = fs::create_dir_all(cache_dir);
        let _ = atomic_write_bytes(&cache_dir.join(FAILED_COOLDOWN_FILE), &bytes);
    }
}

fn save_cached_logo(
    cache_dir: &Path,
    key: &str,
    bytes: &[u8],
    mime: &str,
) -> Result<String, String> {
    fs::create_dir_all(cache_dir).map_err(|e| format!("创建 LogoCache 目录失败: {}", e))?;

    // 清理同品牌旧扩展名缓存文件，防止重复残留
    if let Ok(read_dir) = fs::read_dir(cache_dir) {
        for entry in read_dir.flatten() {
            let existing = entry.path();
            if existing.is_file() {
                if let Some(stem) = existing.file_stem().and_then(|s| s.to_str()) {
                    if stem.to_lowercase() == key {
                        let _ = fs::remove_file(&existing);
                    }
                }
            }
        }
    }

    let ext = extension_for_mime(mime);
    let target = cache_dir.join(format!("{}.{}", key, ext));
    atomic_write_bytes(&target, bytes)?;
    Ok(format!("data:{};base64,{}", mime, encode_base64(bytes)))
}

async fn fetch_brands_concurrently(
    data_dir: &Path,
    brands: Vec<String>,
    skip_cached_in_logo_cache: bool,
) -> Result<BrandLogoFetchResult, String> {
    let custom_dir = data_dir.join(CUSTOM_LOGOS_DIR);
    let cache_dir = data_dir.join(LOGO_CACHE_DIR);
    let legacy_dir = data_dir.join(LEGACY_LOGOS_DIR);

    let mut protected_keys = HashSet::new();
    collect_existing_keys_in_dir(&custom_dir, &mut protected_keys);
    if skip_cached_in_logo_cache {
        collect_existing_keys_in_dir(&cache_dir, &mut protected_keys);
        collect_existing_keys_in_dir(&legacy_dir, &mut protected_keys);
    }

    let mut cooldowns = if skip_cached_in_logo_cache {
        load_failed_cooldowns(&cache_dir)
    } else {
        HashMap::new()
    };

    let mut seen_keys = HashSet::new();
    let mut pending_tasks: Vec<(String, String)> = Vec::new();
    let mut skipped_count: usize = 0;

    for raw_brand in brands {
        let trimmed = raw_brand.trim().to_string();
        if should_skip_brand(&trimmed) {
            skipped_count += 1;
            continue;
        }
        let key = normalized_brand_key(&trimmed);
        if key.is_empty() || !seen_keys.insert(key.clone()) {
            continue;
        }
        if protected_keys.contains(&key) {
            skipped_count += 1;
            continue;
        }
        // 非白名单品牌直接跳过网络请求（展示首字圆形徽章）
        let Some((_, domain)) = resolve_whitelisted_brand(&trimmed) else {
            skipped_count += 1;
            continue;
        };
        if skip_cached_in_logo_cache
            && (cooldowns.contains_key(&format!("brand:{}", key))
                || cooldowns.contains_key(&format!("domain:{}", domain)))
        {
            skipped_count += 1;
            continue;
        }
        pending_tasks.push((key, trimmed));
    }

    if pending_tasks.is_empty() {
        return Ok(BrandLogoFetchResult {
            logos: HashMap::new(),
            fetched_count: 0,
            failed_count: 0,
            skipped_count,
            failed_keys: Vec::new(),
        });
    }

    let client = build_logo_http_client()?;
    let cache_dir_arc = Arc::new(cache_dir.clone());

    let outcomes: Vec<(String, String, Option<String>)> = stream::iter(pending_tasks)
        .map(|(key, brand)| {
            let client = client.clone();
            let cache_dir = Arc::clone(&cache_dir_arc);
            async move {
                match resolve_brand_logo(&client, &brand).await {
                    Some((bytes, mime)) => {
                        match save_cached_logo(cache_dir.as_path(), &key, &bytes, mime) {
                            Ok(data_url) => (key, brand, Some(data_url)),
                            Err(_) => (key, brand, None),
                        }
                    }
                    None => (key, brand, None),
                }
            }
        })
        .buffer_unordered(MAX_CONCURRENT_FETCHES)
        .collect()
        .await;

    let mut fetched_logos = HashMap::new();
    let mut failed_keys = Vec::new();
    let now = current_unix_secs();

    for (key, brand, result) in outcomes {
        if let Some(data_url) = result {
            cooldowns.remove(&format!("brand:{}", key));
            fetched_logos.insert(key, data_url);
        } else {
            cooldowns.insert(format!("brand:{}", key), now);
            if let Some((_, domain)) = resolve_whitelisted_brand(&brand) {
                cooldowns.insert(format!("domain:{}", domain), now);
            }
            failed_keys.push(key);
        }
    }
    save_failed_cooldowns(&cache_dir, &cooldowns);

    let fetched_count = fetched_logos.len();
    let failed_count = failed_keys.len();

    Ok(BrandLogoFetchResult {
        logos: fetched_logos,
        fetched_count,
        failed_count,
        skipped_count,
        failed_keys,
    })
}

/// 仅自动抓取尚未缓存的品牌 Logo 到 LogoCache/（绝不覆盖 CustomLogos/）
pub async fn fetch_missing_brand_logos(
    data_dir: PathBuf,
    brands: Vec<String>,
) -> Result<BrandLogoFetchResult, String> {
    fetch_brands_concurrently(&data_dir, brands, true).await
}

/// 彻底清空旧 LogoCache/（含 failed_cooldown.json）与旧版 BrandLogos/（完整保留 CustomLogos/），再并发重抓全部白名单品牌 Logo
pub async fn clear_and_refetch_brand_logos(
    data_dir: PathBuf,
    brands: Vec<String>,
) -> Result<BrandLogoFetchResult, String> {
    let cache_dir = data_dir.join(LOGO_CACHE_DIR);
    let legacy_dir = data_dir.join(LEGACY_LOGOS_DIR);
    if cache_dir.exists() {
        fs::remove_dir_all(&cache_dir)
            .map_err(|e| format!("清理 LogoCache 目录失败: {}", e))?;
    }
    if legacy_dir.exists() {
        let _ = fs::remove_dir_all(&legacy_dir);
    }
    fs::create_dir_all(&cache_dir)
        .map_err(|e| format!("重建 LogoCache 目录失败: {}", e))?;

    let mut fetch_res = fetch_brands_concurrently(&data_dir, brands, false).await?;
    // 重新扫描完整目录（CustomLogos > LogoCache），保证前端直接拿到完整一致状态
    fetch_res.logos = load_brand_logos(&data_dir)?;
    Ok(fetch_res)
}
