use chrono::{DateTime, SecondsFormat, Utc};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use crate::storage::{
    atomic_write_bytes, create_verified_backup, current_apple_reference_timestamp,
    default_journal_value, validate_journal_root,
};

const JOURNAL_FILE_NAME: &str = "journal.json";
const CUSTOM_LOGOS_DIR_NAME: &str = "CustomLogos";
const DEFAULT_MAX_BACKUPS: usize = 30;
const MAX_HISTORY_DEPTH: usize = 30;
const MAX_LOGO_BYTES: u64 = 8 * 1024 * 1024;

const LOGO_EXTENSIONS: &[&str] = &[
    "png", "jpg", "jpeg", "webp", "gif", "ico", "bmp", "svg", "heic", "tiff",
];

const CORE_TOP_LEVEL_KEYS: &[&str] = &[
    "schemaVersion",
    "entries",
    "duplicates",
    "skipped",
    "lastSync",
    "overrides",
    "pending",
    "history",
    "deletedSourceIDs",
    "deletedEntryIds",
];

const KNOWN_OVERRIDE_KEYS: &[&str] = &[
    "brand",
    "name",
    "model",
    "razorType",
    "isAdjustable",
    "isSlant",
    "material",
    "plateType",
    "gapOrSpec",
    "bladeType",
    "handleBrand",
    "knotBrand",
    "brushMaterial",
    "badgerTreatment",
    "badgerBand",
    "knotSize",
    "knotShape",
    "isSample",
    "status",
    "notes",
    "recognizedSource",
    "isManuallyConfirmed",
    "updatedAt",
];

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudSyncResult {
    pub status: String,
    pub synced_at: String,
    pub entries_added: usize,
    pub entries_updated: usize,
    pub entries_deleted: usize,
    pub entries_pushed: usize,
    pub rules_added: usize,
    pub rules_updated: usize,
    pub rules_pushed: usize,
    pub logos_pulled: usize,
    pub logos_pushed: usize,
    pub local_did_change: bool,
    pub remote_did_change: bool,
    pub error_message: Option<String>,
}

impl CloudSyncResult {
    fn simple(status: &str, synced_at: String, error_message: Option<String>) -> Self {
        Self {
            status: status.to_string(),
            synced_at,
            entries_added: 0,
            entries_updated: 0,
            entries_deleted: 0,
            entries_pushed: 0,
            rules_added: 0,
            rules_updated: 0,
            rules_pushed: 0,
            logos_pulled: 0,
            logos_pushed: 0,
            local_did_change: false,
            remote_did_change: false,
            error_message,
        }
    }
}

struct CloudMergeOutput {
    merged_object: Map<String, Value>,
    entries_added: usize,
    entries_updated: usize,
    entries_deleted: usize,
    entries_pushed: usize,
    rules_added: usize,
    rules_updated: usize,
    rules_pushed: usize,
    local_did_change: bool,
    remote_did_change: bool,
}

fn now_iso8601_utc() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn parse_iso8601_millis(raw: Option<&str>) -> Option<i64> {
    let trimmed = raw?.trim();
    if trimmed.is_empty() {
        return None;
    }
    DateTime::parse_from_rfc3339(trimmed)
        .ok()
        .map(|dt| dt.timestamp_millis())
}

fn file_mtime_millis(path: &Path) -> Option<i64> {
    let modified = fs::metadata(path).ok()?.modified().ok()?;
    let dur = modified.duration_since(UNIX_EPOCH).ok()?;
    Some(dur.as_millis() as i64)
}

fn default_database_map() -> Map<String, Value> {
    match default_journal_value() {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}

fn fnv1a_64_hex(input: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in input.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{:016x}", hash)
}

fn canonical_json_string(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_default()
}

fn json_maps_equal(a: &Map<String, Value>, b: &Map<String, Value>) -> bool {
    canonical_json_string(&Value::Object(a.clone()))
        == canonical_json_string(&Value::Object(b.clone()))
}

fn databases_semantically_equal(a: &Map<String, Value>, b: &Map<String, Value>) -> bool {
    let mut lhs = a.clone();
    let mut rhs = b.clone();
    lhs.remove("lastSync");
    rhs.remove("lastSync");
    if lhs
        .get("deletedSourceIDs")
        .and_then(|v| v.as_array())
        .map(|arr| arr.is_empty())
        .unwrap_or(false)
    {
        lhs.remove("deletedSourceIDs");
    }
    if rhs
        .get("deletedSourceIDs")
        .and_then(|v| v.as_array())
        .map(|arr| arr.is_empty())
        .unwrap_or(false)
    {
        rhs.remove("deletedSourceIDs");
    }
    if lhs
        .get("deletedEntryIds")
        .and_then(|v| v.as_object())
        .map(|obj| obj.is_empty())
        .unwrap_or(false)
    {
        lhs.remove("deletedEntryIds");
    }
    if rhs
        .get("deletedEntryIds")
        .and_then(|v| v.as_object())
        .map(|obj| obj.is_empty())
        .unwrap_or(false)
    {
        rhs.remove("deletedEntryIds");
    }
    json_maps_equal(&lhs, &rhs)
}

fn paths_refer_to_same_dir(a: &Path, b: &Path) -> bool {
    if a == b {
        return true;
    }
    if let (Ok(ca), Ok(cb)) = (fs::canonicalize(a), fs::canonicalize(b)) {
        return ca == cb;
    }
    false
}

// MARK: - 顶层入口：执行一次完整的云盘双向同步（与 macOS CloudSyncService 100% 对齐）

pub fn perform_bidirectional_sync(
    local_data_dir: &Path,
    cloud_sync_dir: &Path,
) -> CloudSyncResult {
    let now_iso = now_iso8601_utc();

    // 1. 校验云盘同步目录是否可访问（绝不静默创建未挂载云盘路径）
    if !cloud_sync_dir.is_dir() {
        return CloudSyncResult::simple(
            "unavailable",
            now_iso,
            Some("云盘同步目录当前不可访问（云盘可能未挂载）".to_string()),
        );
    }

    // 2. 防止同步目录与当前本地数据目录指向同一目录
    if paths_refer_to_same_dir(local_data_dir, cloud_sync_dir) {
        return CloudSyncResult::simple("sameDirectory", now_iso, None);
    }

    let local_journal_path = local_data_dir.join(JOURNAL_FILE_NAME);
    let remote_journal_path = cloud_sync_dir.join(JOURNAL_FILE_NAME);
    let local_exists = local_journal_path.is_file();
    let remote_exists = remote_journal_path.is_file();

    // 3. 读取本地与云端原始 JSON 对象（完整保留未知扩展字段）
    let (local_map, local_mtime_ms) = if local_exists {
        let bytes = match fs::read(&local_journal_path) {
            Ok(b) => b,
            Err(e) => {
                return CloudSyncResult::simple(
                    "error",
                    now_iso,
                    Some(format!("读取本地 journal.json 失败: {}", e)),
                );
            }
        };
        let parsed: Value = match serde_json::from_slice(&bytes) {
            Ok(v) => v,
            Err(e) => {
                return CloudSyncResult::simple(
                    "error",
                    now_iso,
                    Some(format!("解析本地 journal.json 失败: {}", e)),
                );
            }
        };
        if let Err(e) = validate_journal_root(&parsed) {
            return CloudSyncResult::simple("error", now_iso, Some(e));
        }
        match parsed {
            Value::Object(m) => (m, file_mtime_millis(&local_journal_path)),
            _ => {
                return CloudSyncResult::simple(
                    "error",
                    now_iso,
                    Some("本地 journal.json 根节点不是有效的 JSON 对象".to_string()),
                );
            }
        }
    } else {
        (default_database_map(), None)
    };

    let (remote_map, remote_mtime_ms) = if remote_exists {
        let bytes = match fs::read(&remote_journal_path) {
            Ok(b) => b,
            Err(e) => {
                return CloudSyncResult::simple(
                    "error",
                    now_iso,
                    Some(format!("读取云端 journal.json 失败: {}", e)),
                );
            }
        };
        let parsed: Value = match serde_json::from_slice(&bytes) {
            Ok(v) => v,
            Err(e) => {
                return CloudSyncResult::simple(
                    "error",
                    now_iso,
                    Some(format!("解析云端 journal.json 失败: {}", e)),
                );
            }
        };
        if let Err(e) = validate_journal_root(&parsed) {
            return CloudSyncResult::simple("error", now_iso, Some(e));
        }
        match parsed {
            Value::Object(m) => (m, file_mtime_millis(&remote_journal_path)),
            _ => {
                return CloudSyncResult::simple(
                    "error",
                    now_iso,
                    Some("云端 journal.json 根节点不是有效的 JSON 对象".to_string()),
                );
            }
        }
    } else {
        (default_database_map(), None)
    };

    // 4. 智能双向合并
    let mut merge = merge_databases(
        &local_map,
        local_mtime_ms,
        &remote_map,
        remote_mtime_ms,
        local_exists,
        remote_exists,
    );

    let need_write_local = merge.local_did_change || (!local_exists && remote_exists);
    let need_write_remote = merge.remote_did_change || !remote_exists;

    // 5. 写入前先保留本地校验备份，再以临时文件 + 原子替换写入本地与云端
    if need_write_local || need_write_remote {
        merge.merged_object.insert(
            "lastSync".to_string(),
            json!(current_apple_reference_timestamp()),
        );
        let merged_value = Value::Object(merge.merged_object);
        if let Err(e) = validate_journal_root(&merged_value) {
            return CloudSyncResult::simple(
                "error",
                now_iso,
                Some(format!("合并结果校验失败: {}", e)),
            );
        }

        let serialized = match serde_json::to_vec_pretty(&merged_value) {
            Ok(b) => b,
            Err(e) => {
                return CloudSyncResult::simple(
                    "error",
                    now_iso,
                    Some(format!("序列化合并数据失败: {}", e)),
                );
            }
        };

        if need_write_local {
            if local_exists {
                if let Err(e) = create_verified_backup(local_data_dir, None, DEFAULT_MAX_BACKUPS) {
                    return CloudSyncResult::simple(
                        "error",
                        now_iso,
                        Some(format!("同步写入前创建本地备份失败: {}", e)),
                    );
                }
            }
            if let Err(e) = atomic_write_bytes(&local_journal_path, &serialized) {
                return CloudSyncResult::simple(
                    "error",
                    now_iso,
                    Some(format!("写入本地 journal.json 失败: {}", e)),
                );
            }
        }

        if need_write_remote {
            if let Err(e) = atomic_write_bytes(&remote_journal_path, &serialized) {
                return CloudSyncResult {
                    status: "unavailable".to_string(),
                    synced_at: now_iso,
                    entries_added: merge.entries_added,
                    entries_updated: merge.entries_updated,
                    entries_deleted: merge.entries_deleted,
                    entries_pushed: 0,
                    rules_added: merge.rules_added,
                    rules_updated: merge.rules_updated,
                    rules_pushed: 0,
                    logos_pulled: 0,
                    logos_pushed: 0,
                    local_did_change: need_write_local,
                    remote_did_change: false,
                    error_message: Some(format!("写入云盘 journal.json 失败: {}", e)),
                };
            }
        }
    }

    // 6. 双向增量同步 CustomLogos/
    let (logos_pulled, logos_pushed) = sync_custom_logos(local_data_dir, cloud_sync_dir);

    let any_change =
        need_write_local || need_write_remote || logos_pulled > 0 || logos_pushed > 0;

    CloudSyncResult {
        status: if any_change {
            "synced".to_string()
        } else {
            "upToDate".to_string()
        },
        synced_at: now_iso,
        entries_added: merge.entries_added,
        entries_updated: merge.entries_updated,
        entries_deleted: merge.entries_deleted,
        entries_pushed: merge.entries_pushed,
        rules_added: merge.rules_added,
        rules_updated: merge.rules_updated,
        rules_pushed: merge.rules_pushed,
        logos_pulled,
        logos_pushed,
        local_did_change: need_write_local,
        remote_did_change: need_write_remote,
        error_message: None,
    }
}

// MARK: - 纯函数双向 JSON 合并算法（与 macOS Swift 版逐条对齐）

fn merge_databases(
    local: &Map<String, Value>,
    local_mtime_ms: Option<i64>,
    remote: &Map<String, Value>,
    remote_mtime_ms: Option<i64>,
    local_exists: bool,
    remote_exists: bool,
) -> CloudMergeOutput {
    let mut entries_added: usize = 0;
    let mut entries_updated: usize = 0;
    let mut entries_deleted: usize = 0;
    let mut entries_pushed: usize = 0;
    let mut rules_added: usize = 0;
    let mut rules_updated: usize = 0;
    let mut rules_pushed: usize = 0;

    // 1. 合并 deletedEntryIds（取各 id 较新的删除时间戳）
    let mut merged_deleted_entries = merge_deleted_entry_map(
        extract_string_map(local.get("deletedEntryIds")),
        extract_string_map(remote.get("deletedEntryIds")),
    );

    // 2. 合并 deletedSourceIDs（去重排序并集）
    let mut deleted_sources_set: HashSet<String> = HashSet::new();
    for s in extract_string_array(local.get("deletedSourceIDs")) {
        deleted_sources_set.insert(s);
    }
    for s in extract_string_array(remote.get("deletedSourceIDs")) {
        deleted_sources_set.insert(s);
    }
    let mut merged_deleted_sources: Vec<String> = deleted_sources_set.into_iter().collect();
    merged_deleted_sources.sort();

    // 3. 合并 entries
    let local_entries_raw = extract_object_array(local.get("entries"));
    let remote_entries_raw = extract_object_array(remote.get("entries"));

    let local_map = index_entries_by_id(local_entries_raw, local_mtime_ms);
    let remote_map = index_entries_by_id(remote_entries_raw, remote_mtime_ms);

    // 墓碑过滤：仅当条目有显式 updatedAt 且严格晚于 deletedAt 时允许复活（并移除墓碑）
    let mut surviving_local: HashMap<String, Map<String, Value>> = HashMap::new();
    for (id, entry) in local_map {
        if let Some(del_iso) = merged_deleted_entries.get(&id).cloned() {
            if should_entry_revive_over_tombstone(&entry, &del_iso) {
                merged_deleted_entries.remove(&id);
                surviving_local.insert(id, entry);
            } else {
                entries_deleted += 1;
            }
        } else {
            surviving_local.insert(id, entry);
        }
    }

    let mut surviving_remote: HashMap<String, Map<String, Value>> = HashMap::new();
    for (id, entry) in remote_map {
        if let Some(del_iso) = merged_deleted_entries.get(&id).cloned() {
            if should_entry_revive_over_tombstone(&entry, &del_iso) {
                merged_deleted_entries.remove(&id);
                surviving_remote.insert(id, entry);
            }
        } else {
            surviving_remote.insert(id, entry);
        }
    }

    // 先处理所有本地条目（含双方共有 id）并建立「日期 + 核心器材指纹」索引
    let mut merged_entries_by_id: HashMap<String, Map<String, Value>> = HashMap::new();
    let mut fingerprint_to_local_id: HashMap<String, String> = HashMap::new();

    for (id, local_entry) in &surviving_local {
        if let Some(remote_entry) = surviving_remote.get(id) {
            let (chosen, remote_won) = resolve_entry_conflict(
                local_entry,
                local_mtime_ms,
                remote_entry,
                remote_mtime_ms,
            );
            if remote_won && !json_maps_equal(local_entry, &chosen) {
                entries_updated += 1;
            } else if !remote_won && !json_maps_equal(remote_entry, &chosen) {
                entries_pushed += 1;
            }
            if let Some(fp) = core_gear_fingerprint(&chosen) {
                fingerprint_to_local_id
                    .entry(fp)
                    .or_insert_with(|| id.clone());
            }
            merged_entries_by_id.insert(id.clone(), chosen);
        } else {
            if remote_exists {
                entries_pushed += 1;
            }
            if let Some(fp) = core_gear_fingerprint(local_entry) {
                fingerprint_to_local_id
                    .entry(fp)
                    .or_insert_with(|| id.clone());
            }
            merged_entries_by_id.insert(id.clone(), local_entry.clone());
        }
    }

    // 处理仅存在于云端的条目：按「日期 + 核心器材指纹」防重，并用确定性主 ID 确保双端收敛
    for (remote_id, remote_entry) in &surviving_remote {
        if surviving_local.contains_key(remote_id) {
            continue;
        }
        if let Some(fp) = core_gear_fingerprint(remote_entry) {
            if let Some(matched_local_id) = fingerprint_to_local_id.get(&fp).cloned() {
                if !surviving_remote.contains_key(&matched_local_id) {
                    if let Some(existing_local) = merged_entries_by_id.get(&matched_local_id).cloned()
                    {
                        if are_process_texts_compatible(&existing_local, remote_entry) {
                            let (mut chosen, remote_won) = resolve_entry_conflict(
                                &existing_local,
                                local_mtime_ms,
                                remote_entry,
                                remote_mtime_ms,
                            );
                            let canonical_id =
                                pick_canonical_duplicate_id(&matched_local_id, remote_id);
                            chosen.insert("id".to_string(), Value::String(canonical_id.clone()));
                            if canonical_id != matched_local_id {
                                merged_entries_by_id.remove(&matched_local_id);
                                fingerprint_to_local_id.insert(fp, canonical_id.clone());
                            }
                            if (remote_won || canonical_id != matched_local_id)
                                && !json_maps_equal(&existing_local, &chosen)
                            {
                                entries_updated += 1;
                            }
                            merged_entries_by_id.insert(canonical_id, chosen);
                            continue;
                        }
                    }
                }
            }
        }
        merged_entries_by_id.insert(remote_id.clone(), remote_entry.clone());
        entries_added += 1;
    }

    let mut sorted_entries: Vec<Map<String, Value>> = merged_entries_by_id.into_values().collect();
    sorted_entries.sort_by(|a, b| {
        let da = a.get("date").and_then(|v| v.as_str()).unwrap_or("");
        let db = b.get("date").and_then(|v| v.as_str()).unwrap_or("");
        db.cmp(da).then_with(|| {
            let ia = a.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let ib = b.get("id").and_then(|v| v.as_str()).unwrap_or("");
            ia.cmp(ib)
        })
    });
    let sorted_entries_val: Vec<Value> = sorted_entries.into_iter().map(Value::Object).collect();

    // 4. 合并 overrides（按 key 双向合并 + updatedAt/人工确认优先 + 保留未知扩展字段）
    let local_overrides = extract_object_map(local.get("overrides"));
    let remote_overrides = extract_object_map(remote.get("overrides"));
    let mut merged_overrides: Map<String, Value> = Map::new();
    let mut remote_won_override_keys: HashSet<String> = HashSet::new();
    let mut local_won_override_keys: HashSet<String> = HashSet::new();

    let mut all_override_keys: HashSet<String> = HashSet::new();
    for k in local_overrides.keys() {
        all_override_keys.insert(k.clone());
    }
    for k in remote_overrides.keys() {
        all_override_keys.insert(k.clone());
    }

    for key in all_override_keys {
        match (local_overrides.get(&key), remote_overrides.get(&key)) {
            (Some(l), None) => {
                merged_overrides.insert(key.clone(), Value::Object(l.clone()));
                local_won_override_keys.insert(key);
                if remote_exists {
                    rules_pushed += 1;
                }
            }
            (None, Some(r)) => {
                merged_overrides.insert(key.clone(), Value::Object(r.clone()));
                remote_won_override_keys.insert(key);
                rules_added += 1;
            }
            (Some(l), Some(r)) => {
                let (chosen, remote_won) =
                    resolve_override_conflict(l, local_mtime_ms, r, remote_mtime_ms);
                if remote_won {
                    remote_won_override_keys.insert(key.clone());
                    if !json_maps_equal(l, &chosen) {
                        rules_updated += 1;
                    }
                } else {
                    local_won_override_keys.insert(key.clone());
                    if !json_maps_equal(r, &chosen) {
                        rules_pushed += 1;
                    }
                }
                merged_overrides.insert(key, Value::Object(chosen));
            }
            (None, None) => {}
        }
    }

    // 5. 合并 pending（双向并集，剔除已被另一端人工确认或较新修改解除待确认的 key）
    let local_pending = extract_string_array(local.get("pending"));
    let remote_pending = extract_string_array(remote.get("pending"));
    let local_pending_set: HashSet<String> = local_pending.iter().cloned().collect();
    let remote_pending_set: HashSet<String> = remote_pending.iter().cloned().collect();
    let mut merged_pending: Vec<Value> = Vec::new();
    let mut seen_pending: HashSet<String> = HashSet::new();

    for key in local_pending.into_iter().chain(remote_pending.into_iter()) {
        if !seen_pending.insert(key.clone()) {
            continue;
        }
        let in_local = local_pending_set.contains(&key);
        let in_remote = remote_pending_set.contains(&key);
        if in_local && in_remote {
            merged_pending.push(Value::String(key));
        } else if in_local {
            let remote_resolved = remote_overrides
                .get(&key)
                .map(|ov| {
                    ov.get("isManuallyConfirmed")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false)
                        || remote_won_override_keys.contains(&key)
                })
                .unwrap_or(false);
            if !remote_resolved {
                merged_pending.push(Value::String(key));
            }
        } else {
            let local_resolved = local_overrides
                .get(&key)
                .map(|ov| {
                    ov.get("isManuallyConfirmed")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false)
                        || local_won_override_keys.contains(&key)
                })
                .unwrap_or(false);
            if !local_resolved {
                merged_pending.push(Value::String(key));
            }
        }
    }

    // 6. 合并 history（去重合并，保留本地最近撤销栈在末尾，上限 30）
    let local_history = local
        .get("history")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let remote_history = remote
        .get("history")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let merged_history = merge_history_arrays(local_history, remote_history);

    // 7. 标量与未知顶层扩展字段无损合并
    let local_schema = local
        .get("schemaVersion")
        .and_then(|v| v.as_i64())
        .unwrap_or(2);
    let remote_schema = remote
        .get("schemaVersion")
        .and_then(|v| v.as_i64())
        .unwrap_or(2);
    let schema_version = local_schema.max(remote_schema).max(2);

    let local_dup = local.get("duplicates").and_then(|v| v.as_i64()).unwrap_or(0);
    let remote_dup = remote
        .get("duplicates")
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let local_skip = local.get("skipped").and_then(|v| v.as_i64()).unwrap_or(0);
    let remote_skip = remote.get("skipped").and_then(|v| v.as_i64()).unwrap_or(0);
    let local_last_sync = local
        .get("lastSync")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let remote_last_sync = remote
        .get("lastSync")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);

    let mut merged_root: Map<String, Value> = Map::new();
    merged_root.insert("schemaVersion".to_string(), json!(schema_version));
    merged_root.insert("entries".to_string(), Value::Array(sorted_entries_val));
    merged_root.insert("duplicates".to_string(), json!(local_dup.max(remote_dup)));
    merged_root.insert("skipped".to_string(), json!(local_skip.max(remote_skip)));
    merged_root.insert(
        "lastSync".to_string(),
        json!(local_last_sync.max(remote_last_sync)),
    );
    merged_root.insert("overrides".to_string(), Value::Object(merged_overrides));
    merged_root.insert("pending".to_string(), Value::Array(merged_pending));
    merged_root.insert("history".to_string(), Value::Array(merged_history));

    if !merged_deleted_sources.is_empty() {
        merged_root.insert(
            "deletedSourceIDs".to_string(),
            Value::Array(
                merged_deleted_sources
                    .into_iter()
                    .map(Value::String)
                    .collect(),
            ),
        );
    }

    if !merged_deleted_entries.is_empty() {
        let mut del_map = Map::new();
        for (k, v) in merged_deleted_entries {
            del_map.insert(k, Value::String(v));
        }
        merged_root.insert("deletedEntryIds".to_string(), Value::Object(del_map));
    }

    // 保留并双向合并所有未知顶层扩展字段
    let mut unknown_keys: HashSet<String> = HashSet::new();
    for k in local.keys() {
        if !CORE_TOP_LEVEL_KEYS.contains(&k.as_str()) {
            unknown_keys.insert(k.clone());
        }
    }
    for k in remote.keys() {
        if !CORE_TOP_LEVEL_KEYS.contains(&k.as_str()) {
            unknown_keys.insert(k.clone());
        }
    }
    let remote_is_newer_file = remote_mtime_ms.unwrap_or(0) > local_mtime_ms.unwrap_or(0);
    for key in unknown_keys {
        match (local.get(&key), remote.get(&key)) {
            (Some(lv), None) => {
                merged_root.insert(key, lv.clone());
            }
            (None, Some(rv)) => {
                merged_root.insert(key, rv.clone());
            }
            (Some(lv), Some(rv)) => {
                if let (Some(l_obj), Some(r_obj)) = (lv.as_object(), rv.as_object()) {
                    merged_root.insert(
                        key,
                        Value::Object(merge_unknown_objects(l_obj, r_obj, remote_is_newer_file)),
                    );
                } else {
                    merged_root.insert(
                        key,
                        if remote_is_newer_file {
                            rv.clone()
                        } else {
                            lv.clone()
                        },
                    );
                }
            }
            (None, None) => {}
        }
    }

    let local_did_change = !local_exists || !databases_semantically_equal(local, &merged_root);
    let remote_did_change = !remote_exists || !databases_semantically_equal(remote, &merged_root);

    if !remote_exists && local_exists {
        entries_pushed = merged_root
            .get("entries")
            .and_then(|v| v.as_array())
            .map(|a| a.len())
            .unwrap_or(0);
        rules_pushed = merged_root
            .get("overrides")
            .and_then(|v| v.as_object())
            .map(|o| o.len())
            .unwrap_or(0);
    }

    CloudMergeOutput {
        merged_object: merged_root,
        entries_added,
        entries_updated,
        entries_deleted,
        entries_pushed,
        rules_added,
        rules_updated,
        rules_pushed,
        local_did_change,
        remote_did_change,
    }
}

// MARK: - CustomLogos/ 双向增量同步

struct LogoFileRecord {
    path: PathBuf,
    mtime_ms: i64,
}

fn sync_custom_logos(local_data_dir: &Path, cloud_sync_dir: &Path) -> (usize, usize) {
    let local_logos_dir = local_data_dir.join(CUSTOM_LOGOS_DIR_NAME);
    let remote_logos_dir = cloud_sync_dir.join(CUSTOM_LOGOS_DIR_NAME);

    let local_files = scan_logo_files_by_stem(&local_logos_dir);
    let remote_files = scan_logo_files_by_stem(&remote_logos_dir);

    if local_files.is_empty() && remote_files.is_empty() {
        return (0, 0);
    }

    let mut pulled: usize = 0;
    let mut pushed: usize = 0;

    let mut all_stems: HashSet<String> = HashSet::new();
    for s in local_files.keys() {
        all_stems.insert(s.clone());
    }
    for s in remote_files.keys() {
        all_stems.insert(s.clone());
    }

    for stem in all_stems {
        match (local_files.get(&stem), remote_files.get(&stem)) {
            (Some(lf), None) => {
                if copy_logo_atomically(&lf.path, &remote_logos_dir, &stem) {
                    pushed += 1;
                }
            }
            (None, Some(rf)) => {
                if copy_logo_atomically(&rf.path, &local_logos_dir, &stem) {
                    pulled += 1;
                }
            }
            (Some(lf), Some(rf)) => {
                let (Ok(local_bytes), Ok(remote_bytes)) =
                    (fs::read(&lf.path), fs::read(&rf.path))
                else {
                    continue;
                };
                if local_bytes == remote_bytes {
                    continue;
                }
                if rf.mtime_ms > lf.mtime_ms + 1000 {
                    if copy_logo_atomically(&rf.path, &local_logos_dir, &stem) {
                        pulled += 1;
                    }
                } else if lf.mtime_ms > rf.mtime_ms + 1000 {
                    if copy_logo_atomically(&lf.path, &remote_logos_dir, &stem) {
                        pushed += 1;
                    }
                }
            }
            (None, None) => {}
        }
    }

    (pulled, pushed)
}

fn scan_logo_files_by_stem(dir: &Path) -> HashMap<String, LogoFileRecord> {
    let mut map: HashMap<String, LogoFileRecord> = HashMap::new();
    if !dir.is_dir() {
        return map;
    }
    let Ok(read_dir) = fs::read_dir(dir) else {
        return map;
    };

    for entry in read_dir.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Some(file_name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if file_name.starts_with('.') || file_name.ends_with(".tmp") {
            continue;
        }
        let Some(ext) = path.extension().and_then(|e| e.to_str()) else {
            continue;
        };
        let ext_lower = ext.to_ascii_lowercase();
        if !LOGO_EXTENSIONS.contains(&ext_lower.as_str()) {
            continue;
        }
        let Ok(meta) = fs::metadata(&path) else {
            continue;
        };
        if meta.len() == 0 || meta.len() > MAX_LOGO_BYTES {
            continue;
        }
        let Some(stem_raw) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let stem = stem_raw.trim().to_lowercase();
        if stem.is_empty() {
            continue;
        }
        let mtime_ms = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        if let Some(existing) = map.get(&stem) {
            if existing.mtime_ms >= mtime_ms {
                continue;
            }
        }
        map.insert(stem, LogoFileRecord { path, mtime_ms });
    }
    map
}

fn copy_logo_atomically(source_path: &Path, target_dir: &Path, stem: &str) -> bool {
    let Ok(bytes) = fs::read(source_path) else {
        return false;
    };
    if bytes.is_empty() {
        return false;
    }
    let Some(file_name) = source_path.file_name() else {
        return false;
    };
    let target_path = target_dir.join(file_name);
    if atomic_write_bytes(&target_path, &bytes).is_err() {
        return false;
    }

    // 清理目标目录下同 stem 的不同扩展名旧图标
    if let Ok(read_dir) = fs::read_dir(target_dir) {
        for entry in read_dir.flatten() {
            let p = entry.path();
            if !p.is_file() || p == target_path {
                continue;
            }
            if let Some(s) = p.file_stem().and_then(|x| x.to_str()) {
                if s.trim().to_lowercase() == stem {
                    let _ = fs::remove_file(&p);
                }
            }
        }
    }
    true
}

// MARK: - 合并算法辅助函数

fn extract_string_map(raw: Option<&Value>) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let Some(obj) = raw.and_then(|v| v.as_object()) else {
        return out;
    };
    for (k, v) in obj {
        if let Some(s) = v.as_str() {
            let trimmed = s.trim();
            if !trimmed.is_empty() {
                out.insert(k.clone(), trimmed.to_string());
            }
        }
    }
    out
}

fn extract_string_array(raw: Option<&Value>) -> Vec<String> {
    let Some(arr) = raw.and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| v.as_str().map(ToString::to_string))
        .collect()
}

fn extract_object_array(raw: Option<&Value>) -> Vec<Map<String, Value>> {
    let Some(arr) = raw.and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| v.as_object().cloned())
        .collect()
}

fn extract_object_map(raw: Option<&Value>) -> HashMap<String, Map<String, Value>> {
    let mut out = HashMap::new();
    let Some(obj) = raw.and_then(|v| v.as_object()) else {
        return out;
    };
    for (k, v) in obj {
        if let Some(inner) = v.as_object() {
            out.insert(k.clone(), inner.clone());
        }
    }
    out
}

fn merge_deleted_entry_map(
    mut local: BTreeMap<String, String>,
    remote: BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    for (id, remote_ts) in remote {
        let should_insert = match local.get(&id) {
            Some(local_ts) => {
                let l_ms = parse_iso8601_millis(Some(local_ts)).unwrap_or(0);
                let r_ms = parse_iso8601_millis(Some(&remote_ts)).unwrap_or(0);
                r_ms > l_ms || (r_ms == l_ms && remote_ts.as_str() > local_ts.as_str())
            }
            None => true,
        };
        if should_insert {
            local.insert(id, remote_ts);
        }
    }
    local
}

fn should_entry_revive_over_tombstone(entry: &Map<String, Value>, deleted_iso: &str) -> bool {
    let Some(updated_ms) =
        parse_iso8601_millis(entry.get("updatedAt").and_then(|v| v.as_str()))
    else {
        return false;
    };
    let Some(deleted_ms) = parse_iso8601_millis(Some(deleted_iso)) else {
        return false;
    };
    updated_ms > deleted_ms
}

fn index_entries_by_id(
    entries: Vec<Map<String, Value>>,
    fallback_mtime_ms: Option<i64>,
) -> HashMap<String, Map<String, Value>> {
    let mut map: HashMap<String, Map<String, Value>> = HashMap::new();
    for entry in entries {
        let Some(id) = entry
            .get("id")
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToString::to_string)
        else {
            continue;
        };
        let next_entry = if let Some(existing) = map.get(&id) {
            let (chosen, _) =
                resolve_entry_conflict(existing, fallback_mtime_ms, &entry, fallback_mtime_ms);
            chosen
        } else {
            entry
        };
        map.insert(id, next_entry);
    }
    map
}

fn resolve_entry_conflict(
    local: &Map<String, Value>,
    local_mtime_ms: Option<i64>,
    remote: &Map<String, Value>,
    remote_mtime_ms: Option<i64>,
) -> (Map<String, Value>, bool) {
    let l_explicit = parse_iso8601_millis(local.get("updatedAt").and_then(|v| v.as_str()));
    let r_explicit = parse_iso8601_millis(remote.get("updatedAt").and_then(|v| v.as_str()));

    let remote_wins = match (l_explicit, r_explicit) {
        (Some(l), Some(r)) => {
            if l != r {
                r > l
            } else {
                entry_non_empty_score(remote) > entry_non_empty_score(local)
            }
        }
        (None, Some(_)) => true,
        (Some(_), None) => false,
        (None, None) => {
            let l_m = local_mtime_ms.unwrap_or(0);
            let r_m = remote_mtime_ms.unwrap_or(0);
            if (r_m - l_m).abs() > 1000 {
                r_m > l_m
            } else {
                entry_non_empty_score(remote) > entry_non_empty_score(local)
            }
        }
    };

    let (mut winner, loser) = if remote_wins {
        (remote.clone(), local)
    } else {
        (local.clone(), remote)
    };

    for (k, v) in loser {
        if k == "updatedAt" {
            continue;
        }
        if !winner.contains_key(k) {
            winner.insert(k.clone(), v.clone());
        }
    }
    if !winner.contains_key("updatedAt") {
        if let Some(loser_updated) = loser.get("updatedAt") {
            winner.insert("updatedAt".to_string(), loser_updated.clone());
        }
    }

    (winner, remote_wins)
}

fn resolve_override_conflict(
    local: &Map<String, Value>,
    local_mtime_ms: Option<i64>,
    remote: &Map<String, Value>,
    remote_mtime_ms: Option<i64>,
) -> (Map<String, Value>, bool) {
    let l_explicit = parse_iso8601_millis(local.get("updatedAt").and_then(|v| v.as_str()));
    let r_explicit = parse_iso8601_millis(remote.get("updatedAt").and_then(|v| v.as_str()));
    let l_manual = local
        .get("isManuallyConfirmed")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let r_manual = remote
        .get("isManuallyConfirmed")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    let remote_wins = match (l_explicit, r_explicit) {
        (Some(l), Some(r)) => {
            if l != r {
                r > l
            } else if l_manual != r_manual {
                r_manual
            } else {
                override_non_empty_score(remote) > override_non_empty_score(local)
            }
        }
        (None, Some(_)) => true,
        (Some(_), None) => false,
        (None, None) => {
            if l_manual != r_manual {
                r_manual
            } else {
                let l_m = local_mtime_ms.unwrap_or(0);
                let r_m = remote_mtime_ms.unwrap_or(0);
                if (r_m - l_m).abs() > 1000 {
                    r_m > l_m
                } else {
                    override_non_empty_score(remote) > override_non_empty_score(local)
                }
            }
        }
    };

    let (mut winner, loser) = if remote_wins {
        (remote.clone(), local)
    } else {
        (local.clone(), remote)
    };

    let winner_has_explicit_time =
        parse_iso8601_millis(winner.get("updatedAt").and_then(|v| v.as_str())).is_some();

    for (k, v) in loser {
        if k == "updatedAt" {
            continue;
        }
        let winner_missing = match winner.get(k) {
            None => true,
            Some(Value::Null) => true,
            Some(Value::String(s)) => s.trim().is_empty(),
            _ => false,
        };
        let is_known_key = KNOWN_OVERRIDE_KEYS.contains(&k.as_str());
        if winner_missing && (!is_known_key || !winner_has_explicit_time) {
            winner.insert(k.clone(), v.clone());
        }
    }

    (winner, remote_wins)
}

fn entry_non_empty_score(entry: &Map<String, Value>) -> usize {
    let mut score = 0;
    if let Some(fields) = entry.get("fields").and_then(|v| v.as_array()) {
        for f in fields {
            if let Some(val) = f.get("value").and_then(|v| v.as_str()) {
                let trimmed = val.trim();
                if !trimmed.is_empty() && trimmed != "无" && trimmed != "-" {
                    score += 1;
                }
            }
        }
    }
    score
}

fn override_non_empty_score(ov: &Map<String, Value>) -> usize {
    let mut score = 0;
    for (k, v) in ov {
        if k == "updatedAt" {
            continue;
        }
        match v {
            Value::String(s) => {
                let trimmed = s.trim();
                if !trimmed.is_empty() && trimmed != "品牌未注明" && trimmed != "无品牌" {
                    score += 1;
                }
            }
            Value::Bool(true) => score += 1,
            Value::Null | Value::Bool(false) => {}
            _ => score += 1,
        }
    }
    score
}

fn normalize_gear_token(raw: &str) -> String {
    raw.split_whitespace()
        .collect::<Vec<&str>>()
        .join(" ")
        .to_lowercase()
}

fn label_matches_numbered_prefix(label: &str, prefix: &str) -> bool {
    if label == prefix {
        return true;
    }
    if let Some(suffix) = label.strip_prefix(prefix) {
        return !suffix.is_empty() && suffix.chars().all(|c| c.is_ascii_digit());
    }
    false
}

/// 日期 + 核心器材指纹（用于跨端不同 UUID 录入同一场剃须时防重）
fn core_gear_fingerprint(entry: &Map<String, Value>) -> Option<String> {
    let date = entry
        .get("date")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())?;
    let fields = entry.get("fields").and_then(|v| v.as_array())?;

    let mut razors: Vec<String> = Vec::new();
    let mut blades: Vec<String> = Vec::new();
    let mut brushes: Vec<String> = Vec::new();
    let mut soaps: Vec<String> = Vec::new();

    for f in fields {
        let label = f
            .get("label")
            .and_then(|v| v.as_str())
            .map(str::trim)
            .unwrap_or("");
        let val = normalize_gear_token(f.get("value").and_then(|v| v.as_str()).unwrap_or(""));
        if val.is_empty() || val == "无" || val == "-" {
            continue;
        }
        if label_matches_numbered_prefix(label, "剃须刀") {
            razors.push(val);
        } else if label_matches_numbered_prefix(label, "刀片") {
            blades.push(val);
        } else if label == "剃须刷" {
            brushes.push(val);
        } else if label == "剃须皂" {
            soaps.push(val);
        }
    }

    let non_empty_groups = [
        !razors.is_empty(),
        !blades.is_empty(),
        !brushes.is_empty(),
        !soaps.is_empty(),
    ]
    .into_iter()
    .filter(|&b| b)
    .count();
    if non_empty_groups < 2 {
        return None;
    }

    razors.sort();
    blades.sort();
    brushes.sort();
    soaps.sort();

    let canonical = format!(
        "{}\u{1F}{}\u{1F}{}\u{1F}{}\u{1F}{}",
        date,
        razors.join("+"),
        blades.join("+"),
        brushes.join("+"),
        soaps.join("+")
    );
    Some(fnv1a_64_hex(&canonical))
}

fn extract_process_text(entry: &Map<String, Value>) -> String {
    let Some(fields) = entry.get("fields").and_then(|v| v.as_array()) else {
        return String::new();
    };
    for f in fields {
        if f.get("label").and_then(|v| v.as_str()).map(str::trim) == Some("过程") {
            return f
                .get("value")
                .and_then(|v| v.as_str())
                .map(str::trim)
                .unwrap_or("")
                .to_string();
        }
    }
    String::new()
}

fn are_process_texts_compatible(a: &Map<String, Value>, b: &Map<String, Value>) -> bool {
    let pa = extract_process_text(a);
    let pb = extract_process_text(b);
    pa.is_empty() || pb.is_empty() || pa == pb
}

fn pick_canonical_duplicate_id(a: &str, b: &str) -> String {
    let a_local = a.starts_with("local-");
    let b_local = b.starts_with("local-");
    if a_local != b_local {
        return if a_local {
            b.to_string()
        } else {
            a.to_string()
        };
    }
    if a <= b {
        a.to_string()
    } else {
        b.to_string()
    }
}

fn merge_history_arrays(local: Vec<Value>, remote: Vec<Value>) -> Vec<Value> {
    let mut result: Vec<Value> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();

    for item in remote.into_iter().chain(local.into_iter()) {
        let key = canonical_json_string(&item);
        if !key.is_empty() && seen.insert(key) {
            result.push(item);
        }
    }

    if result.len() > MAX_HISTORY_DEPTH {
        let start = result.len() - MAX_HISTORY_DEPTH;
        result = result.split_off(start);
    }
    result
}

fn merge_unknown_objects(
    local: &Map<String, Value>,
    remote: &Map<String, Value>,
    remote_is_newer: bool,
) -> Map<String, Value> {
    let mut merged = local.clone();
    for (k, rv) in remote {
        let next_val = match merged.get(k) {
            Some(lv) => {
                if let (Some(l_sub), Some(r_sub)) = (lv.as_object(), rv.as_object()) {
                    Some(Value::Object(merge_unknown_objects(
                        l_sub,
                        r_sub,
                        remote_is_newer,
                    )))
                } else if remote_is_newer {
                    Some(rv.clone())
                } else {
                    None
                }
            }
            None => Some(rv.clone()),
        };
        if let Some(v) = next_val {
            merged.insert(k.clone(), v);
        }
    }
    merged
}
