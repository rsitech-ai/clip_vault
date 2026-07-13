use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_double};
use std::{collections::HashSet, slice};

#[must_use]
pub fn normalize_text(input: &str) -> String {
    input
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_lowercase()
}

#[must_use]
pub fn fingerprint(input: &str) -> u64 {
    let normalized = normalize_text(input);
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;

    for byte in normalized.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }

    hash
}

#[must_use]
#[allow(
    clippy::cast_precision_loss,
    reason = "term counts are bounded by the input string length and remain exactly representable at app-scale sizes"
)]
pub fn lexical_score(query: &str, text: &str) -> f64 {
    let query_normalized = normalize_text(query);
    let text_normalized = normalize_text(text);

    if query_normalized.is_empty() || text_normalized.is_empty() {
        return 0.0;
    }

    let query_terms = terms(&query_normalized);
    let text_terms = terms(&text_normalized);

    if query_terms.is_empty() || text_terms.is_empty() {
        return 0.0;
    }

    let exact_hits = query_terms
        .iter()
        .filter(|term| text_terms.contains(*term))
        .count();

    let fuzzy_hits = query_terms
        .iter()
        .filter(|term| {
            !text_terms.contains(*term)
                && text_terms
                    .iter()
                    .any(|candidate| candidate.contains(*term) || term.contains(candidate))
        })
        .count();

    let phrase_bonus = if text_normalized.contains(&query_normalized) {
        0.25
    } else {
        0.0
    };
    let intent_bonus = domain_intent_bonus(&query_terms, &text_normalized);

    let score = ((exact_hits as f64) + (fuzzy_hits as f64 * 0.45)) / (query_terms.len() as f64)
        + phrase_bonus
        + intent_bonus;

    score.clamp(0.0, 1.0)
}

fn terms(input: &str) -> HashSet<String> {
    input
        .split(|character: char| !character.is_alphanumeric() && character != '_')
        .filter(|term| term.len() > 1)
        .map(ToOwned::to_owned)
        .collect()
}

fn domain_intent_bonus(query_terms: &HashSet<String>, text: &str) -> f64 {
    let mut bonus: f64 = 0.0;

    if query_terms.contains("sql")
        && (text.contains("select ")
            || text.contains(" from ")
            || text.contains(" where ")
            || text.contains("insert into")
            || text.contains("update "))
    {
        bonus += 0.35;
    }

    if query_terms.contains("error")
        && (text.contains("error:") || text.contains("exception") || text.contains("traceback"))
    {
        bonus += 0.3;
    }

    if query_terms.contains("code")
        && (text.contains("func ")
            || text.contains("class ")
            || text.contains("import ")
            || text.contains('{'))
    {
        bonus += 0.25;
    }

    bonus.min(0.45)
}

#[allow(unsafe_code)]
unsafe fn string_from_raw_parts(input: *const u8, len: usize) -> String {
    if input.is_null() || len == 0 {
        return String::new();
    }

    // SAFETY: Swift passes a valid UTF-8 byte buffer and length for the duration of the call.
    let bytes = unsafe { slice::from_raw_parts(input, len) };
    String::from_utf8_lossy(bytes).to_string()
}

fn c_string(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| CString::new("").expect("empty CString is valid"))
        .into_raw()
}

#[unsafe(no_mangle)]
#[allow(unsafe_code)]
/// Normalizes a UTF-8 byte buffer and returns an owned C string.
///
/// # Safety
///
/// When `input` is non-null and `len` is nonzero, `input` must reference at
/// least `len` readable bytes for the duration of this call. The returned
/// pointer must be released exactly once with [`cv_free_string`].
pub unsafe extern "C" fn cv_normalize_text(input: *const u8, len: usize) -> *mut c_char {
    // SAFETY: The caller upholds the byte-buffer contract documented above.
    c_string(normalize_text(&unsafe {
        string_from_raw_parts(input, len)
    }))
}

#[unsafe(no_mangle)]
#[allow(unsafe_code)]
/// Computes a stable fingerprint for a UTF-8 byte buffer.
///
/// # Safety
///
/// When `input` is non-null and `len` is nonzero, `input` must reference at
/// least `len` readable bytes for the duration of this call.
pub unsafe extern "C" fn cv_fingerprint(input: *const u8, len: usize) -> u64 {
    // SAFETY: The caller upholds the byte-buffer contract documented above.
    fingerprint(&unsafe { string_from_raw_parts(input, len) })
}

#[unsafe(no_mangle)]
#[allow(unsafe_code)]
/// Scores a query byte buffer against a text byte buffer.
///
/// # Safety
///
/// Each non-null pointer with a nonzero corresponding length must reference at
/// least that many readable bytes for the duration of this call.
pub unsafe extern "C" fn cv_lexical_score(
    query: *const u8,
    query_len: usize,
    text: *const u8,
    text_len: usize,
) -> c_double {
    lexical_score(
        // SAFETY: The caller upholds both byte-buffer contracts documented above.
        &unsafe { string_from_raw_parts(query, query_len) },
        // SAFETY: The caller upholds both byte-buffer contracts documented above.
        &unsafe { string_from_raw_parts(text, text_len) },
    )
}

#[unsafe(no_mangle)]
#[allow(unsafe_code)]
/// Releases a C string allocated by this library.
///
/// # Safety
///
/// `value` must be null or a live pointer returned by [`cv_normalize_text`]
/// that has not already been released.
pub unsafe extern "C" fn cv_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }

    // SAFETY: Pointers freed here are allocated by CString::into_raw in this library.
    unsafe {
        drop(CString::from_raw(value));
    }
}

#[unsafe(no_mangle)]
#[allow(unsafe_code)]
/// Compares two NUL-terminated strings after normalization.
///
/// # Safety
///
/// Each non-null pointer must reference a readable NUL-terminated C string for
/// the duration of this call.
pub unsafe extern "C" fn cv_is_same_normalized(left: *const c_char, right: *const c_char) -> bool {
    if left.is_null() || right.is_null() {
        return false;
    }

    // SAFETY: This auxiliary C-string API is for external smoke checks with NUL-terminated strings.
    let left = unsafe { CStr::from_ptr(left) }.to_string_lossy();
    // SAFETY: This auxiliary C-string API is for external smoke checks with NUL-terminated strings.
    let right = unsafe { CStr::from_ptr(right) }.to_string_lossy();

    normalize_text(&left) == normalize_text(&right)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalization_is_stable() {
        assert_eq!(
            normalize_text("  SELECT  *\nFROM Users  "),
            "select * from users"
        );
        assert_eq!(fingerprint("Hello   World"), fingerprint(" hello world "));
    }

    #[test]
    fn lexical_score_prefers_matching_content() {
        let sql = lexical_score(
            "copied sql last week",
            "SELECT id FROM users WHERE active = true",
        );
        let unrelated = lexical_score("copied sql last week", "Meeting notes about launch copy");

        assert!(sql > unrelated);
        assert!(sql > 0.0);
    }

    #[test]
    fn lexical_score_ignores_incidental_short_word_overlap() {
        let score = lexical_score(
            "resizable responsive",
            "This is a review of release risks and remaining work.",
        );

        assert!(score.abs() < f64::EPSILON);
    }

    #[test]
    #[allow(unsafe_code)]
    fn ffi_string_round_trip_and_comparison_are_consistent() {
        let input = b"  Hello   World  ";
        // SAFETY: `input` is readable for its exact length for the duration of the call.
        let normalized = unsafe { cv_normalize_text(input.as_ptr(), input.len()) };
        assert!(!normalized.is_null());

        // SAFETY: `normalized` is a live NUL-terminated string returned above.
        assert_eq!(
            unsafe { CStr::from_ptr(normalized) }.to_bytes(),
            b"hello world"
        );

        let expected = CString::new("hello world").expect("test string contains no NUL");
        // SAFETY: Both pointers reference live NUL-terminated strings for this call.
        assert!(unsafe { cv_is_same_normalized(normalized, expected.as_ptr()) });

        // SAFETY: `normalized` was returned by `cv_normalize_text` and is released once.
        unsafe { cv_free_string(normalized) };
    }
}
