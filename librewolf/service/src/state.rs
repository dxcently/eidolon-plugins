//! What the browser has told this host, and what a read is allowed to act on.
//!
//! The extension owns the browser side — the toolbar click, the `activeTab`
//! grant, which document is loaded. This module owns the *record* of that, and
//! the rule that a read is answered only when the attachment it was issued
//! against is still the current one, with the same **document** behind it.
//!
//! Document identity is `performance.timeOrigin`, which the extension reads
//! from inside the page. It is the start time of the document, so it changes on
//! every new document — including a reload at the *same URL*, which a URL
//! comparison cannot see and which a revocation event may not have reached us
//! about yet. Both checks are here and both fail closed:
//!
//! 1. the reply must name the generation and time origin we issued against;
//! 2. our own record must still be that same attachment and document at the
//!    moment the reply lands — a revocation that raced the read wins.
//!
//! Neither check is a substitute for the extension's own check inside the page;
//! this is the half that can be tested without a browser, and the extension
//! repeats it before it will send anything back.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

pub const DEFAULT_MAX_CHARS: usize = 8000;
pub const MAX_CHARS: usize = 200_000;
pub const DEFAULT_MAX_NODES: usize = 400;
pub const MAX_NODES: usize = 4000;

/// How long a command may take before the tool is told it did not answer. The
/// extension is a page read, not a download; a read that takes this long is a
/// bug or a wedged browser, and waiting longer only holds the service's lock.
pub const COMMAND_TIMEOUT: Duration = Duration::from_secs(30);

/// A detach is a message to the extension and nothing more — it does no page work —
/// so the caller is not made to wait a read's timeout for the acknowledgement. The
/// record is cleared either way; this only bounds how long the caller waits to hear
/// that the page-facing half let go of the grant.
pub const DETACH_TIMEOUT: Duration = Duration::from_secs(10);

/// A tab the operator attached with the extension's toolbar button.
#[derive(Clone, Debug, PartialEq)]
pub struct Attachment {
    pub tab_id: i64,
    pub url: String,
    pub title: String,
    /// The extension's monotonic attachment counter.
    pub generation: u64,
    /// `performance.timeOrigin` of the document that was attached — a second,
    /// independent signal beside the nonce, kept because LibreWolf ships
    /// `privacy.resistFingerprinting` and a timestamp is not an identity.
    pub time_origin: f64,
    /// The per-document nonce the extension keeps in its own content-script world.
    /// This is the identity: a reload at the same URL gets a new one, and the page
    /// cannot read or forge it. Opaque here — this host only checks that the answer
    /// names the one the attachment was made with.
    pub nonce: String,
    pub attached_at_ms: u64,
}

impl Attachment {
    /// The record the `librewolf_status` tool is answered with.
    pub fn record(&self) -> Value {
        json!({
            "tab_id": self.tab_id,
            "url": self.url,
            "title": self.title,
            "generation": self.generation,
            "time_origin": self.time_origin,
            "nonce": self.nonce,
            "attached_at_ms": self.attached_at_ms,
        })
    }
}

/// Why an attachment ended. Kept after the fact so the next call can say what
/// happened instead of only that nothing is attached.
#[derive(Clone, Debug, PartialEq)]
pub struct Revocation {
    pub generation: u64,
    pub reason: String,
    pub url: Option<String>,
}

#[derive(Default)]
pub struct State {
    /// Set by the extension's `hello`. False again when the port closes.
    pub connected: bool,
    pub addon: Option<String>,
    pub attachment: Option<Attachment>,
    pub last_revocation: Option<Revocation>,
}

/// Only http(s) pages are read: the bridge has no business in `about:`,
/// `file:`, `view-source:`, or another extension's pages, and a click that
/// lands on one is refused rather than half-served.
pub fn is_http(url: &str) -> bool {
    url.starts_with("http://") || url.starts_with("https://")
}

impl State {
    /// Record an attachment the extension reported. A redundant push of the
    /// record we already hold is a no-op; anything that cannot be ordered
    /// against what we have is an error, and the caller revokes rather than
    /// guesses.
    pub fn attach(&mut self, a: Attachment) -> Result<(), String> {
        if !is_http(&a.url) {
            return Err(format!(
                "only http(s) pages can be attached; the click reported {}",
                quote(&a.url)
            ));
        }
        if a.nonce.is_empty() {
            return Err(
                "an attachment must name the document it is for, and this one carried no nonce"
                    .into(),
            );
        }
        if self.attachment.as_ref() == Some(&a) {
            return Ok(());
        }
        // The same generation wearing a different document is not orderable: a
        // generation is one attachment, a nonce is one document.
        if let Some(current) = &self.attachment
            && current.generation == a.generation
        {
            return Err("the same generation was offered for two different documents".into());
        }
        let floor = self
            .attachment
            .as_ref()
            .map(|c| c.generation)
            .or_else(|| self.last_revocation.as_ref().map(|r| r.generation))
            .unwrap_or(0);
        if a.generation <= floor {
            return Err(format!(
                "generation {} does not move past {floor}",
                a.generation
            ));
        }
        self.attachment = Some(a);
        Ok(())
    }

    /// End the attachment, recording why. A no-op when nothing is attached.
    pub fn revoke(&mut self, reason: &str, url: Option<String>) -> Option<Revocation> {
        let ended = self.attachment.take()?;
        let rev = Revocation {
            generation: ended.generation,
            reason: reason.to_string(),
            url: url.or_else(|| Some(ended.url.clone())),
        };
        self.last_revocation = Some(rev.clone());
        Some(rev)
    }

    /// The sentence a call gets when there is nothing to read. It names the one
    /// act that can change that, because no call this host serves can.
    pub fn no_attachment_reason(&self) -> String {
        if !self.connected {
            return "the LibreWolf bridge extension has not connected to this host: open LibreWolf with the librewolf bridge extension enabled".into();
        }
        match &self.last_revocation {
            Some(rev) => format!(
                "no tab is attached — the previous attachment ended because {}; click the extension's toolbar button on the tab you want the assistant to see{}",
                rev.reason,
                rev.url
                    .as_deref()
                    .map(|u| format!(" (it was {})", quote(u)))
                    .unwrap_or_default()
            ),
            None => "no tab is attached — click the librewolf bridge extension's toolbar button on the tab you want the assistant to see; the click is what attaches it, and nothing here can do it for you".into(),
        }
    }

    pub fn health(&self) -> Value {
        json!({
            "status": "ok",
            "browser_connected": self.connected,
            "attached": self.attachment.is_some(),
        })
    }
}

/// The host's side of the bridge: the record, the channel to the extension, and
/// the requests waiting on it.
pub struct Bridge {
    inner: Mutex<State>,
    to_ext: mpsc::UnboundedSender<Value>,
    pending: Mutex<HashMap<u64, oneshot::Sender<Value>>>,
    next_id: AtomicU64,
    expected_addon: String,
    /// When anything last arrived from the extension. The extension and the
    /// browser die together, so this is how the host tells a live browser from a
    /// corpse that is still holding the pipes.
    last_seen: Mutex<Instant>,
}

impl Bridge {
    pub fn new(expected_addon: &str, to_ext: mpsc::UnboundedSender<Value>) -> Bridge {
        Bridge {
            inner: Mutex::new(State::default()),
            to_ext,
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(0),
            expected_addon: expected_addon.to_string(),
            last_seen: Mutex::new(Instant::now()),
        }
    }

    pub fn lock(&self) -> MutexGuard<'_, State> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn health(&self) -> Value {
        self.lock().health()
    }

    /// The `librewolf_status` answer: the attachment the toolbar click created,
    /// or the reason there is none. There is no path through this function that
    /// creates or renews one.
    pub fn status(&self) -> Result<Value, String> {
        let st = self.lock();
        match &st.attachment {
            Some(a) => Ok(a.record()),
            None => Err(st.no_attachment_reason()),
        }
    }

    /// How many commands are waiting on an answer. Test-only: the rule it checks is
    /// that no exit from a command leaves a waiter behind for the next caller.
    #[cfg(test)]
    fn pending_len(&self) -> usize {
        self.pending.lock().unwrap_or_else(|e| e.into_inner()).len()
    }

    /// How long since anything arrived from the extension.
    pub fn idle(&self) -> Duration {
        self.last_seen
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .elapsed()
    }

    /// Handle one message from the extension.
    pub fn deliver(&self, msg: Value) {
        *self.last_seen.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now();
        match msg.get("type").and_then(Value::as_str) {
            Some("hello") => {
                let addon = msg.get("addon").and_then(Value::as_str).unwrap_or("");
                let mut st = self.lock();
                if addon != self.expected_addon {
                    crate::note!(
                        "native host: refusing a hello from {addon:?}; this host serves {}",
                        self.expected_addon
                    );
                    st.connected = false;
                    return;
                }
                st.connected = true;
                st.addon = Some(addon.to_string());
            }
            Some("state") => self.record_state(&msg),
            // The extension says so at a fixed interval; anything at all resets
            // the clock, and this is the cheapest of those.
            Some("heartbeat") => {}
            Some("result") => {
                let Some(id) = msg.get("id").and_then(Value::as_u64) else {
                    crate::note!("native host: a result arrived with no id");
                    return;
                };
                let waiter = self
                    .pending
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .remove(&id);
                match waiter {
                    Some(tx) => {
                        let _ = tx.send(msg);
                    }
                    None => {
                        crate::note!("native host: a result for unknown command {id} was dropped")
                    }
                }
            }
            other => crate::note!("native host: ignoring a message of type {other:?}"),
        }
    }

    fn record_state(&self, msg: &Value) {
        let mut st = self.lock();
        match msg.get("attached") {
            None | Some(Value::Null) => {
                let reason = msg
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("the extension detached the tab");
                let url = msg.get("url").and_then(Value::as_str).map(str::to_string);
                if st.revoke(reason, url.clone()).is_none() && st.last_revocation.is_none() {
                    // A detachment with nothing attached: record the reason for the
                    // next call's error, without inventing an attachment. An earlier
                    // reason is not overwritten — it is the one that explains how the
                    // attachment actually ended.
                    st.last_revocation = Some(Revocation {
                        generation: msg.get("generation").and_then(Value::as_u64).unwrap_or(0),
                        reason: reason.to_string(),
                        url,
                    });
                }
            }
            Some(a) => {
                let att = Attachment {
                    tab_id: a.get("tab_id").and_then(Value::as_i64).unwrap_or(-1),
                    url: a
                        .get("url")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    title: a
                        .get("title")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    generation: a.get("generation").and_then(Value::as_u64).unwrap_or(0),
                    time_origin: a
                        .get("time_origin")
                        .and_then(Value::as_f64)
                        .unwrap_or(f64::NAN),
                    nonce: a
                        .get("nonce")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    attached_at_ms: a.get("attached_at_ms").and_then(Value::as_u64).unwrap_or(0),
                };
                if let Err(e) = st.attach(att) {
                    crate::note!("native host: refusing an attachment: {e}");
                    st.revoke(
                        &format!("the host refused the attachment it was offered: {e}"),
                        None,
                    );
                }
            }
        }
    }

    /// The native messaging port closed, or the writer failed: nothing can be
    /// served any more. The attachment is ended (its `activeTab` grant died with
    /// the port's owner) and every waiting request is failed at once, by
    /// dropping the sender each is waiting on.
    pub fn disconnect(&self) {
        let mut st = self.lock();
        st.connected = false;
        st.addon = None;
        st.revoke("the browser closed the native messaging port", None);
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }

    /// Issue a command bound to the *current* attachment, and refuse the answer
    /// unless both the answer and our own record still name it. See the module
    /// comment for the two checks and why neither alone is enough.
    async fn bounded_command(&self, op: &str, args: Value) -> Result<Value, String> {
        let expected = {
            let st = self.lock();
            if !st.connected {
                return Err(st.no_attachment_reason());
            }
            st.attachment
                .clone()
                .ok_or_else(|| st.no_attachment_reason())?
        };
        let id = self.next_id.fetch_add(1, Ordering::SeqCst) + 1;
        let (tx, rx) = oneshot::channel();
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id, tx);
        let msg = json!({
            "v": 1,
            "type": "command",
            "id": id,
            "op": op,
            "generation": expected.generation,
            "time_origin": expected.time_origin,
            "nonce": expected.nonce,
            "args": args,
        });
        if self.to_ext.send(msg).is_err() {
            self.pending
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&id);
            return Err("this host has lost its connection to the browser".into());
        }
        let reply = match tokio::time::timeout(COMMAND_TIMEOUT, rx).await {
            Ok(Ok(v)) => v,
            Ok(Err(_)) => {
                return Err(format!(
                    "the bridge dropped this {op} before it was answered (the browser closed, or the host restarted)"
                ));
            }
            Err(_) => {
                self.pending
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .remove(&id);
                return Err(format!(
                    "the extension did not answer this {op} within {}s",
                    COMMAND_TIMEOUT.as_secs()
                ));
            }
        };
        let st = self.lock();
        let Some(now) = st.attachment.as_ref() else {
            return Err(format!(
                "the tab was detached while this {op} was in flight; nothing from it is returned ({})",
                st.no_attachment_reason()
            ));
        };
        if now.generation != expected.generation {
            return Err(format!(
                "the attachment changed while this {op} was in flight (generation {} to {}); nothing from it is returned",
                expected.generation, now.generation
            ));
        }
        if now.nonce != expected.nonce {
            return Err(format!(
                "the document changed while this {op} was in flight (a different document is attached now); \
                 nothing from it is returned"
            ));
        }
        if now.time_origin != expected.time_origin {
            return Err(format!(
                "the document changed while this {op} was in flight (time origin {} to {}); nothing from it is returned",
                expected.time_origin, now.time_origin
            ));
        }
        if reply.get("ok").and_then(Value::as_bool) != Some(true) {
            return Err(reply
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("the extension refused without a reason")
                .to_string());
        }
        // The answer must be about the attachment and the document we asked
        // about. The extension checks this too; a host that only trusted the
        // extension's `ok` would be trusting a bug in a page-facing component.
        if reply.get("generation").and_then(Value::as_u64) != Some(expected.generation) {
            return Err(format!(
                "the extension answered about attachment {}, not {}",
                reply.get("generation").and_then(Value::as_u64).unwrap_or(0),
                expected.generation
            ));
        }
        if reply.get("nonce").and_then(Value::as_str) != Some(expected.nonce.as_str()) {
            return Err(
                "the extension answered from a different document than the one attached; nothing from it is returned"
                    .into(),
            );
        }
        if reply.get("time_origin").and_then(Value::as_f64) != Some(expected.time_origin) {
            return Err(format!(
                "the extension answered about a different document than the one attached (time origin {}, not {})",
                reply
                    .get("time_origin")
                    .and_then(Value::as_f64)
                    .unwrap_or(f64::NAN),
                expected.time_origin
            ));
        }
        Ok(reply.get("result").cloned().unwrap_or(Value::Null))
    }

    /// The attached tab's visible text, as the page renders it.
    pub async fn read(&self, args: &Value) -> Result<Value, String> {
        let max = clamp(
            args.get("max").and_then(Value::as_i64),
            DEFAULT_MAX_CHARS,
            MAX_CHARS,
        );
        let out = self.bounded_command("read", json!({ "max": max })).await?;
        let text = out.get("text").and_then(Value::as_str).unwrap_or("");
        let (text, cut) = truncate_chars(text, max);
        Ok(json!({
            "url": out.get("url").cloned().unwrap_or(Value::Null),
            "title": out.get("title").cloned().unwrap_or(Value::Null),
            "text": text,
            "truncated": cut || out.get("truncated").and_then(Value::as_bool).unwrap_or(false),
            "untrusted": true,
        }))
    }

    /// The attached tab's DOM-derived outline.
    pub async fn structure(&self, args: &Value) -> Result<Value, String> {
        let max_nodes = clamp(
            args.get("max_nodes").and_then(Value::as_i64),
            DEFAULT_MAX_NODES,
            MAX_NODES,
        );
        let out = self
            .bounded_command("structure", json!({ "max_nodes": max_nodes }))
            .await?;
        let nodes: Vec<Value> = out
            .get("nodes")
            .and_then(Value::as_array)
            .map(|v| v.iter().take(max_nodes).cloned().collect())
            .unwrap_or_default();
        Ok(json!({
            "url": out.get("url").cloned().unwrap_or(Value::Null),
            "title": out.get("title").cloned().unwrap_or(Value::Null),
            "nodes": nodes,
            "truncated": out.get("truncated").and_then(Value::as_bool).unwrap_or(false),
            "note": "derived from the DOM (tags and role attributes), not an accessibility tree",
            "untrusted": true,
        }))
    }

    /// End the attachment. The extension is told first so it can drop the
    /// `activeTab` grant it is holding; the local record is cleared either way,
    /// because a refusal from the page-facing half must not leave this host
    /// believing it still has a tab.
    pub async fn detach(&self) -> Result<Value, String> {
        let expected = {
            let st = self.lock();
            if !st.connected {
                return Err(st.no_attachment_reason());
            }
            st.attachment
                .clone()
                .ok_or_else(|| st.no_attachment_reason())?
        };

        // Tell the extension first, so it stops using the tab. (No API withdraws the
        // browser's own activeTab grant; what ends here is the bridge's attachment,
        // and every read refuses without one.)
        let id = self.next_id.fetch_add(1, Ordering::SeqCst) + 1;
        let (tx, rx) = oneshot::channel();
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id, tx);
        let msg = json!({
            "v": 1, "type": "command", "id": id, "op": "detach",
            "generation": expected.generation, "time_origin": expected.time_origin,
            "nonce": expected.nonce, "args": {},
        });
        let sent = self.to_ext.send(msg).is_ok();
        if !sent {
            // Nothing is waiting on an answer that can never come.
            self.pending
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&id);
        }

        // The record is cleared *now*, not when the extension answers: a detach the
        // caller has been told about must not stay readable for up to the command
        // timeout. And it is cleared only if the attachment is still the one this
        // detach named — a toolbar click that has happened since is a later and
        // separate consent, and this command must not revoke it.
        let cleared = {
            let mut st = self.lock();
            let still_ours = st.attachment.as_ref().is_some_and(|a| {
                a.generation == expected.generation
                    && a.time_origin == expected.time_origin
                    && a.nonce == expected.nonce
            });
            if still_ours {
                st.revoke("the assistant detached the tab", Some(expected.url.clone()))
                    .is_some()
            } else {
                false
            }
        };

        let mut extension_told = false;
        if sent {
            match tokio::time::timeout(DETACH_TIMEOUT, rx).await {
                Ok(Ok(v)) => {
                    extension_told = true;
                    if v.get("ok").and_then(Value::as_bool) != Some(true) {
                        return Err(format!(
                            "the extension refused to detach ({}); the attachment was dropped here anyway",
                            v.get("error")
                                .and_then(Value::as_str)
                                .unwrap_or("no reason given")
                        ));
                    }
                }
                // The bridge dropped it (the port closed) or the extension was too
                // slow: either way the record is already cleared, and the waiter is
                // not left behind for the next caller to trip over.
                Ok(Err(_)) => {}
                Err(_) => {
                    self.pending
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .remove(&id);
                }
            }
        }

        Ok(json!({
            "detached": true,
            "was": expected.url,
            "cleared": cleared,
            "extension_told": extension_told,
        }))
    }
}

/// `Some(max)` from the caller, clamped into `[1, cap]`; the default when absent
/// or not a number.
pub fn clamp(given: Option<i64>, default: usize, cap: usize) -> usize {
    match given {
        Some(n) if n >= 1 => (n as usize).min(cap),
        Some(_) => 1,
        None => default,
    }
}

/// The first `max` characters (code points, not bytes), and whether anything was
/// left over.
pub fn truncate_chars(s: &str, max: usize) -> (String, bool) {
    match s.char_indices().nth(max) {
        Some((i, _)) => (s[..i].to_string(), true),
        None => (s.to_string(), false),
    }
}

/// One string in single quotes, the way this host's messages quote what a peer
/// sent. Copied from the browser service's `text.rs` rather than shared: the two
/// crates are independent, and a plugin's files are meant to travel whole.
pub fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\'' => out.push_str("\\'"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out.push('\'');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attachment(generation: u64, url: &str, origin: f64) -> Attachment {
        Attachment {
            tab_id: 41,
            url: url.into(),
            title: "A page".into(),
            generation,
            time_origin: origin,
            nonce: format!("nonce-of-generation-{generation}"),
            attached_at_ms: 1_700_000_000_000,
        }
    }

    #[test]
    fn an_http_page_can_be_attached() {
        let mut st = State::default();
        st.attach(attachment(1, "https://example.com/a", 100.0))
            .unwrap();
        assert_eq!(st.attachment.as_ref().unwrap().tab_id, 41);
        assert!(st.no_attachment_reason().is_empty() || st.attachment.is_some());
    }

    #[test]
    fn a_page_that_is_not_http_is_refused() {
        let mut st = State::default();
        for url in [
            "about:config",
            "file:///home/noah/notes.txt",
            "view-source:https://example.com/",
            "moz-extension://abc/page.html",
        ] {
            let err = st.attach(attachment(1, url, 1.0)).unwrap_err();
            assert!(err.contains("only http(s) pages"), "{url}: {err}");
            assert!(st.attachment.is_none());
        }
    }

    #[test]
    fn a_generation_that_does_not_move_forward_is_refused() {
        let mut st = State::default();
        st.attach(attachment(5, "https://example.com/a", 1.0))
            .unwrap();
        // A different record at the same generation is not orderable — and it is
        // refused by name, because that is what it is: one generation cannot be two
        // documents.
        let err = st
            .attach(attachment(5, "https://example.com/b", 2.0))
            .unwrap_err();
        assert!(err.contains("two different documents"), "{err}");
        // And after a revocation, the revoked generation cannot come back.
        st.revoke("a new document began loading", None);
        let err = st
            .attach(attachment(5, "https://example.com/c", 3.0))
            .unwrap_err();
        assert!(err.contains("does not move past 5"), "{err}");
        st.attach(attachment(6, "https://example.com/c", 4.0))
            .unwrap();
        assert_eq!(st.attachment.as_ref().unwrap().generation, 6);
    }

    #[test]
    fn the_same_generation_for_another_document_is_refused() {
        // A generation is one attachment; a nonce is one document. The same generation
        // wearing a different document is not orderable, and the host refuses it rather
        // than believing the newer claim.
        let mut st = State::default();
        st.attach(attachment(4, "https://example.com/a", 10.0))
            .unwrap();
        let mut other = attachment(4, "https://example.com/a", 10.0);
        other.nonce = "a-different-nonce".into();
        let err = st.attach(other).unwrap_err();
        assert!(err.contains("two different documents"), "{err}");
    }

    #[test]
    fn an_attachment_without_a_document_nonce_is_refused() {
        let mut st = State::default();
        let mut nameless = attachment(1, "https://example.com/a", 1.0);
        nameless.nonce = String::new();
        let err = st.attach(nameless).unwrap_err();
        assert!(err.contains("no nonce"), "{err}");
    }

    #[test]
    fn a_repeated_push_of_the_same_record_is_a_no_op() {
        let mut st = State::default();
        let a = attachment(1, "https://example.com/a", 100.0);
        st.attach(a.clone()).unwrap();
        st.attach(a.clone()).unwrap();
        assert_eq!(st.attachment, Some(a));
    }

    #[test]
    fn revoking_records_why_and_only_once() {
        let mut st = State::default();
        st.attach(attachment(3, "https://example.com/a", 10.0))
            .unwrap();
        let rev = st.revoke(
            "a new document began loading",
            Some("https://example.com/a".into()),
        );
        assert_eq!(rev.unwrap().generation, 3);
        assert!(st.attachment.is_none());
        assert!(
            st.revoke("again", None).is_none(),
            "nothing attached, nothing to revoke"
        );
        assert_eq!(
            st.last_revocation.as_ref().unwrap().reason,
            "a new document began loading"
        );
    }

    #[test]
    fn a_call_with_nothing_attached_names_the_one_act_that_would_change_that() {
        let mut st = State::default();
        assert!(st.no_attachment_reason().contains("has not connected"));
        st.connected = true;
        assert!(
            st.no_attachment_reason()
                .contains("click the librewolf bridge extension's toolbar button")
        );
        st.attach(attachment(1, "https://example.com/a", 1.0))
            .unwrap();
        st.revoke(
            "the tab navigated to a new document",
            Some("https://example.com/b".into()),
        );
        let reason = st.no_attachment_reason();
        assert!(reason.contains("a new document"), "{reason}");
        assert!(reason.contains("https://example.com/b"), "{reason}");
    }

    #[test]
    fn clamping_is_the_hosts_to_decide() {
        assert_eq!(clamp(None, DEFAULT_MAX_CHARS, MAX_CHARS), DEFAULT_MAX_CHARS);
        assert_eq!(clamp(Some(10), DEFAULT_MAX_CHARS, MAX_CHARS), 10);
        assert_eq!(clamp(Some(0), DEFAULT_MAX_CHARS, MAX_CHARS), 1);
        assert_eq!(clamp(Some(-4), DEFAULT_MAX_CHARS, MAX_CHARS), 1);
        assert_eq!(
            clamp(Some(i64::MAX), DEFAULT_MAX_CHARS, MAX_CHARS),
            MAX_CHARS
        );
    }

    #[test]
    fn truncation_counts_characters_not_bytes() {
        assert_eq!(truncate_chars("héllo", 2), ("hé".to_string(), true));
        assert_eq!(truncate_chars("hi", 5), ("hi".to_string(), false));
    }

    /// The two rules a detach has to keep, tested where the interleaving can be
    /// scripted exactly: it clears the record at once rather than when the extension
    /// answers, and it never revokes an attachment a *newer* click created.
    #[tokio::test]
    async fn a_stale_detach_does_not_revoke_a_newer_attachment() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let bridge = std::sync::Arc::new(Bridge::new("librewolf-bridge@eidolon.local", tx));
        bridge.lock().connected = true;
        bridge
            .lock()
            .attach(attachment(1, "https://example.com/a", 1.0))
            .unwrap();

        let detaching = {
            let bridge = bridge.clone();
            tokio::spawn(async move { bridge.detach().await })
        };
        // The command goes out, and the record is cleared straight away...
        let _command = rx.recv().await.expect("the detach command should be sent");
        assert!(
            bridge.lock().attachment.is_none(),
            "the record must be cleared at once"
        );
        // ...while a fresh toolbar click arrives before the detach is answered. That
        // click is a later consent, and the detach that was issued before it must not
        // take it away.
        bridge.deliver(json!({"v": 1, "type": "state", "attached": {
            "tab_id": 9, "url": "https://example.com/b", "title": "B",
            "generation": 2, "time_origin": 55.0, "nonce": "nonce-of-generation-2",
            "attached_at_ms": 2,
        }}));
        let id = json!(1); // the answer that is coming is for the first command
        bridge.deliver(json!({"v": 1, "type": "result", "id": id, "ok": true,
                              "generation": 1, "time_origin": 1.0,
                              "result": {"detached": true}}));
        let answer = detaching.await.unwrap();
        assert!(answer.is_ok(), "{answer:?}");
        let st = bridge.lock();
        let now = st
            .attachment
            .as_ref()
            .expect("the newer click's attachment must survive");
        assert_eq!(now.generation, 2);
        assert_eq!(now.url, "https://example.com/b");
        drop(st);
        assert_eq!(bridge.pending_len(), 0, "no waiter may be left behind");
    }

    #[tokio::test]
    async fn a_command_that_cannot_be_sent_clears_the_record_and_leaves_no_waiter() {
        let (tx, rx) = mpsc::unbounded_channel();
        let bridge = Bridge::new("librewolf-bridge@eidolon.local", tx);
        bridge.lock().connected = true;
        bridge
            .lock()
            .attach(attachment(1, "https://example.com/a", 1.0))
            .unwrap();
        drop(rx); // the writer is gone: every send fails from here
        let answer = bridge.detach().await;
        assert!(
            answer.is_ok(),
            "the record is ours to clear whether or not the extension hears about it: {answer:?}"
        );
        assert_eq!(answer.unwrap()["extension_told"], json!(false));
        assert!(bridge.lock().attachment.is_none());
        assert_eq!(
            bridge.pending_len(),
            0,
            "a failed send must not leave a waiter behind"
        );
    }

    #[tokio::test]
    async fn a_detach_the_extension_refuses_still_clears_the_record_and_the_waiter() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let bridge = std::sync::Arc::new(Bridge::new("librewolf-bridge@eidolon.local", tx));
        bridge.lock().connected = true;
        bridge
            .lock()
            .attach(attachment(1, "https://example.com/a", 1.0))
            .unwrap();
        let detaching = {
            let bridge = bridge.clone();
            tokio::spawn(async move { bridge.detach().await })
        };
        let command = rx.recv().await.expect("the detach command should be sent");
        let id = command["id"].clone();
        bridge.deliver(json!({"v": 1, "type": "result", "id": id, "ok": false,
                              "generation": 1, "time_origin": 1.0,
                              "error": "the tab is gone"}));
        let answer = detaching.await.unwrap();
        assert!(answer.is_err(), "a refusal is reported: {answer:?}");
        assert!(answer.unwrap_err().contains("dropped here anyway"));
        assert!(bridge.lock().attachment.is_none());
        assert_eq!(bridge.pending_len(), 0);
    }

    #[test]
    fn health_says_what_a_glance_needs() {
        let mut st = State::default();
        assert_eq!(st.health()["browser_connected"], json!(false));
        assert_eq!(st.health()["attached"], json!(false));
        st.connected = true;
        st.attach(attachment(1, "https://example.com/a", 1.0))
            .unwrap();
        assert_eq!(st.health()["attached"], json!(true));
    }
}
