use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::c_char;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

const IMAGE_EXTENSIONS: &[&str] = &["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif"];

#[no_mangle]
pub extern "C" fn scan_photos_json(root: *const c_char) -> *mut c_char {
    if root.is_null() {
        return string_to_ptr("[]".to_string());
    }

    let root = unsafe { CStr::from_ptr(root) };
    let Ok(root) = root.to_str() else {
        return string_to_ptr("[]".to_string());
    };

    let mut photos = Vec::new();
    scan_dir(Path::new(root), &mut photos);
    photos.sort_by(|a, b| b.modified_ms.cmp(&a.modified_ms));
    string_to_ptr(to_json(&photos))
}

#[no_mangle]
pub extern "C" fn free_rust_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(value);
    }
}

#[derive(Debug)]
struct PhotoInfo {
    path: String,
    name: String,
    extension: String,
    modified_ms: u128,
    size_bytes: u64,
}

fn scan_dir(dir: &Path, out: &mut Vec<PhotoInfo>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            scan_dir(&path, out);
            continue;
        }
        if !path.is_file() || !is_image(&path) {
            continue;
        }
        let Ok(metadata) = entry.metadata() else {
            continue;
        };

        let modified_ms = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map(|duration| duration.as_millis())
            .unwrap_or_default();

        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_string();
        let extension = path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();

        out.push(PhotoInfo {
            path: normalize_path(path),
            name,
            extension,
            modified_ms,
            size_bytes: metadata.len(),
        });
    }
}

fn is_image(path: &Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .map(|extension| {
            let extension = extension.to_ascii_lowercase();
            IMAGE_EXTENSIONS.contains(&extension.as_str())
        })
        .unwrap_or(false)
}

fn normalize_path(path: PathBuf) -> String {
    path.to_string_lossy().to_string()
}

fn to_json(photos: &[PhotoInfo]) -> String {
    let mut json = String::from("[");
    for (index, photo) in photos.iter().enumerate() {
        if index > 0 {
            json.push(',');
        }
        json.push('{');
        json.push_str("\"path\":\"");
        json.push_str(&escape_json(&photo.path));
        json.push_str("\",\"name\":\"");
        json.push_str(&escape_json(&photo.name));
        json.push_str("\",\"extension\":\"");
        json.push_str(&escape_json(&photo.extension));
        json.push_str("\",\"modified_ms\":");
        json.push_str(&photo.modified_ms.to_string());
        json.push_str(",\"size_bytes\":");
        json.push_str(&photo.size_bytes.to_string());
        json.push('}');
    }
    json.push(']');
    json
}

fn escape_json(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            ch if ch.is_control() => escaped.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => escaped.push(ch),
        }
    }
    escaped
}

fn string_to_ptr(value: String) -> *mut c_char {
    CString::new(value).unwrap_or_else(|_| CString::new("[]").unwrap()).into_raw()
}
