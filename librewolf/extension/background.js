"use strict";

// The librewolf bridge, browser side. The README beside this file is the whole
// picture; this is the half that runs inside the browser.
//
// What this half owns, and what it deliberately does not:
//
//   * The toolbar click is the *only* way a tab is ever attached. No message, command
//     or API can attach one, and no path here renews one. `activeTab` is granted to
//     that click and to nothing else. Firefox documents the grant as tied to the
//     document the click happened on, but this file does not lean on that: *we* end
//     the attachment ourselves on every new document in the tab, on its close, on a
//     host that goes away, and on any navigation that arrives while a click is still
//     being confirmed. The browser's own expiry is a second line, never the rule.
//   * Every read is bound to the attachment *and to the document* it was issued
//     for. The document's identity is its `performance.timeOrigin`, read inside
//     the page: it changes on every new document, including a reload at the same
//     URL, which no URL comparison can see and which a revocation event may not
//     have reached the host about yet. The check runs here, in the page, and the
//     host repeats it against its own record.
//   * Page text is data. Nothing read from a page is interpreted, stored,
//     marked up, or put back into a page. Read-only means the DOM is never
//     written to — not even a marker attribute — so an element can carry no
//     handle across calls and none is pretended.
//   * Secrets are what this must not carry out of a page. The outline names
//     elements; it never contains a form control's *value*, and an element that
//     is not rendered is not in it at all. See `structureCode`.

const HOST_NAME = "eidolon_librewolf";
const ADDON_ID = "librewolf-bridge@eidolon.local";
const EXT_VERSION = "0.1.0";

const DEFAULT_MAX_CHARS = 8000;
const MAX_CHARS = 200000;
const DEFAULT_MAX_NODES = 400;
const MAX_NODES = 4000;

let port = null;
let heartbeat = null;
let reconnectDelayMs = 2000;
let attached = null; // {tab_id, url, title, generation, time_origin, attached_at_ms}
let generation = 0; // monotonic; every attach takes the next value

// Bumped by every click and by everything that ends one. A confirmation still
// awaiting an answer belongs to a consent that may since have been replaced or
// withdrawn, and it must not attach anything when it comes back: see the click
// listener. One counter covers all of it, because "this consent is no longer the
// newest one" and "something has since been withdrawn" have the same answer.
let consentSeq = 0;

// The click whose probes are in flight, if any: {tab_id, seq}. The revocation
// listeners have to know about it, because a tab whose *click* is still being
// confirmed is not yet `attached` — and a navigation while a probe is out would
// otherwise let both probes run in the replacement document and attach that.
let pendingClick = null;

/// Withdraw the click being confirmed, if it is on `tabId` (or on any tab when
/// `tabId` is null). Returns whether anything was withdrawn.
function cancelPendingClick(tabId, reason) {
    if (!pendingClick) return false;
    if (tabId !== null && pendingClick.tab_id !== tabId) return false;
    consentSeq += 1;
    log("withdrawing the click on tab", pendingClick.tab_id, "because", reason);
    pendingClick = null;
    return true;
}

/// Let go of the record of a click, when its own confirmation concludes.
function concludePendingClick(seq) {
    if (pendingClick && pendingClick.seq === seq) pendingClick = null;
}

function log(...args) {
    console.debug("librewolf bridge:", ...args);
}

// ---- the native port -------------------------------------------------------

function connect() {
    if (port) return port;
    try {
        port = browser.runtime.connectNative(HOST_NAME);
    } catch (e) {
        log("connectNative failed:", e && e.message);
        port = null;
        scheduleReconnect();
        return null;
    }
    port.onMessage.addListener(onCommand);
    port.onDisconnect.addListener(() => {
        const err = browser.runtime.lastError;
        log("the native host is gone", err && err.message);
        port = null;
        // Without the host there is nowhere for a read to go, so the attachment
        // is over as far as the assistant is concerned, whatever the browser
        // still thinks it granted.
        attached = null;
        cancelPendingClick(null, "the native host is gone");
        scheduleReconnect();
    });
    // The host serves one add-on and checks this id as well as the one the
    // browser put on its command line.
    send({ v: 1, type: "hello", addon: ADDON_ID, ext_version: EXT_VERSION });
    // The host treats our silence as the browser's death — end of stream is not a
    // reliable signal, and this is: this page and the browser go together. Thirty
    // seconds of quiet ends the host, so say something well inside that.
    if (heartbeat === null) heartbeat = setInterval(() => send({ v: 1, type: "heartbeat" }), 5000);
    return port;
}

function scheduleReconnect() {
    const wait = reconnectDelayMs;
    reconnectDelayMs = Math.min(reconnectDelayMs * 2, 60000);
    setTimeout(connect, wait);
}

function send(msg) {
    if (!port) return false;
    try {
        port.postMessage(msg);
        reconnectDelayMs = 2000;
        return true;
    } catch (e) {
        log("post failed:", e && e.message);
        port = null;
        scheduleReconnect();
        return false;
    }
}

function announceAttached() {
    if (attached) send({ v: 1, type: "state", attached: attached });
}

function announceDetached(reason, url) {
    send({
        v: 1,
        type: "state",
        attached: null,
        reason: reason,
        url: url || null,
        generation: generation,
    });
}

// ---- the click is the attachment -------------------------------------------

browser.browserAction.onClicked.addListener(async (tab) => {
    if (!tab || typeof tab.id !== "number") return;
    const url = tab.url || "";
    if (!/^https?:\/\//.test(url)) {
        // activeTab grants this tab, but the bridge reads http(s) pages only.
        detach("the page is not an http(s) page", url);
        return;
    }

    const mine = ++consentSeq;
    pendingClick = { tab_id: tab.id, seq: mine };
    const first = await probe(tab.id);
    if (mine !== consentSeq) {
        // A later click, a detach, or a navigation on this very tab happened while
        // this one was waiting. The person's newest act is the one that counts, and
        // a withdrawn one must not come back to life here.
        concludePendingClick(mine);
        log("a later click or a revocation superseded this one; nothing attached");
        return;
    }
    if (!first) return; // probe() said why

    // Confirming the document. The probe's answer describes the document it ran
    // in, and an await is a window in which the tab can navigate — a same-URL
    // reload included — so the attachment may not be built on it unverified.
    // Two reads of the same identity with no await between the second and the
    // assignment is what this permission set can honestly offer; the read path
    // checks the document again on every call.
    const again = await probe(tab.id);
    if (mine !== consentSeq) {
        concludePendingClick(mine);
        log("a later click or a revocation superseded this one; nothing attached");
        return;
    }
    if (
        !again ||
        again.href !== first.href ||
        again.time_origin !== first.time_origin ||
        again.nonce !== first.nonce
    ) {
        concludePendingClick(mine);
        detach("the document changed while the click was being confirmed", again && again.href);
        return;
    }
    concludePendingClick(mine);

    generation += 1;
    attached = {
        tab_id: tab.id,
        url: again.href || url,
        title: tab.title || "",
        generation: generation,
        time_origin: again.time_origin,
        nonce: again.nonce,
        attached_at_ms: Date.now(),
    };
    log("attached tab", tab.id, "as generation", generation);
    connect();
    announceAttached();
});

function detach(reason, url) {
    // Everything still in flight belongs to a consent that is over.
    consentSeq += 1;
    const was = attached;
    attached = null;
    if (was) log("detaching:", reason);
    announceDetached(reason, url || (was && was.url) || null);
}

// ---- revocation ------------------------------------------------------------

// A new document being fetched ends the attachment: a reload, a same-origin link, a
// redirect, a cross-origin jump, a form post — every one of them loads a new
// document, whatever the origin, and this rule does not care which. (Firefox's own
// activeTab grant is tied to the document too, but nothing here waits for the browser
// to act, and nothing here assumes it has.) This listener makes the host's record
// agree at once rather than at the next read, and it is also what withdraws a click
// whose confirmation is still in flight — a tab with a pending click is not
// `attached` yet, so an `attached`-only listener would miss it.
browser.tabs.onUpdated.addListener((tabId, changeInfo) => {
    if (changeInfo.status !== "loading") return;
    // The tab's *click* may still be being confirmed, with nothing attached yet.
    cancelPendingClick(tabId, "its document began loading");
    if (attached && tabId === attached.tab_id) {
        detach("a new document began loading", attached.url);
    }
});

browser.tabs.onRemoved.addListener((tabId) => {
    cancelPendingClick(tabId, "the tab was closed");
    if (attached && tabId === attached.tab_id) {
        detach("the tab was closed", attached.url);
    }
});

// ---- commands from the host ------------------------------------------------

async function onCommand(msg) {
    if (!msg || msg.type !== "command") return;
    const id = msg.id;
    const op = msg.op;

    if (op === "detach") {
        const was = attached;
        if (
            was &&
            (msg.generation !== was.generation || msg.time_origin !== was.time_origin || msg.nonce !== was.nonce)
        ) {
            // A detach aimed at an attachment that is already over. Honouring it would
            // end a *newer* click's attachment, and that click is a later and separate
            // consent: the command is refused, and nothing is detached.
            reply(
                id,
                was,
                false,
                null,
                "that detach was issued for an attachment that is no longer the current one; nothing was detached",
            );
            return;
        }
        detach("the assistant detached the tab", was && was.url);
        reply(id, null, true, { detached: true, was: was ? was.url : null });
        return;
    }
    if (!attached) {
        reply(id, null, false, null, "no tab is attached — the extension's toolbar button is what attaches one");
        return;
    }
    const expected = attached;
    if (
        msg.generation !== expected.generation ||
        msg.time_origin !== expected.time_origin ||
        msg.nonce !== expected.nonce
    ) {
        reply(
            id,
            expected,
            false,
            null,
            "this request was issued for a different attachment or document than the one attached now",
        );
        return;
    }
    if (op === "read") return runRead(id, expected, msg.args || {});
    if (op === "structure") return runStructure(id, expected, msg.args || {});
    reply(id, expected, false, null, "unknown op " + op);
}

async function runRead(id, expected, args) {
    const max = clampInt(args.max, DEFAULT_MAX_CHARS, MAX_CHARS);
    const got = await inject(expected, readCode(max), "read");
    if (got.error) return reply(id, expected, false, null, got.error);
    if (typeof got.page.text !== "string") {
        return reply(id, expected, false, null, "the page yielded nothing readable");
    }
    // `expected` is the right label here only because inject() proved the text
    // came from a document with that time origin. It did not always: a check that
    // merely asked whether the field existed let a same-URL reload through, and
    // the reply then carried the *expected* origin beside another document's text.
    reply(id, expected, true, {
        url: got.page.href,
        title: got.page.title,
        text: got.page.text,
        truncated: !!got.page.truncated,
    });
}

async function runStructure(id, expected, args) {
    const maxNodes = clampInt(args.max_nodes, DEFAULT_MAX_NODES, MAX_NODES);
    const got = await inject(expected, structureCode(maxNodes), "structure");
    if (got.error) return reply(id, expected, false, null, got.error);
    reply(id, expected, true, {
        url: got.page.href,
        title: got.page.title,
        nodes: got.page.nodes || [],
        truncated: !!got.page.truncated,
    });
}

// Inject, then decide whether anything from it may be used. Two things must hold:
// the document it ran in must be the one that was attached — the same *time
// origin*, not merely the same URL, because a reload at the same URL is a new
// document — and the attachment must still be the one the request named.
async function inject(expected, code, what) {
    let value;
    try {
        const out = await browser.tabs.executeScript(expected.tab_id, {
            code: code,
            runAt: "document_idle",
        });
        value = out && out[0];
    } catch (e) {
        // Restricted or privileged pages, a tab that closed, a grant that is
        // already gone. Fail closed and say so.
        const why = "the page could not be read (restricted or privileged page, or the tab is gone)";
        detach(why + ": " + (e && e.message ? e.message : e));
        return { error: why };
    }
    if (!value || typeof value !== "object") {
        return { error: "the page returned nothing; nothing from it is returned" };
    }
    if (
        typeof value.time_origin !== "number" ||
        typeof value.nonce !== "string" ||
        value.time_origin !== expected.time_origin ||
        value.href !== expected.url ||
        value.nonce !== expected.nonce
    ) {
        detach("the document changed while a " + what + " was in flight", value.href || expected.url);
        return { error: "the document changed while this " + what + " was in flight; nothing from it is returned" };
    }
    if (!attached || attached.generation !== expected.generation || attached.time_origin !== expected.time_origin) {
        return { error: "the attachment changed while this " + what + " was in flight; nothing from it is returned" };
    }
    // Named `page` and not `value`, so that a grep for a DOM value read in this file
    // finds nothing: the outline and the read never take one out of a document.
    return { page: value };
}

function reply(id, expected, ok, result, error) {
    const msg = {
        v: 1,
        type: "result",
        id: id,
        ok: !!ok,
        generation: expected ? expected.generation : generation,
        time_origin: expected ? expected.time_origin : null,
        nonce: expected ? expected.nonce : null,
    };
    if (ok) msg.result = result;
    else msg.error = error || "the extension refused";
    send(msg);
}

// ---- reading a document, without touching it -------------------------------

function clampInt(value, fallback, cap) {
    const n = Number(value);
    if (!Number.isFinite(n) || n < 1) return fallback;
    return Math.min(Math.floor(n), cap);
}

// The document's identity as it is now. Used at attach time (twice, so that an
// await cannot slip a navigation between the check and the record) and again by
// every read, so that "the same URL" can never stand in for "the same document".
// The document's identity, in one place and interpolated into every injected script.
//
// The nonce is the identity. It lives on the *sandbox's own global*, not on the page's
// window and not in the DOM, and it is created the first time this extension looks at
// a document. Measured in a disposable LibreWolf, that global is distinct from the page
// window (`globalThis === window` is false), the value survives between two
// `executeScript` calls in one document, and the page's own script cannot see it. So a
// reload at the same URL gets a fresh sandbox and therefore a fresh nonce, whether or
// not any revocation event arrived, and whether or not the clock happens to read the
// same. `performance.timeOrigin` is kept beside it as a second, independent signal:
// LibreWolf ships privacy.resistFingerprinting, and a timestamp is not an identity.
//
// `browser_snapshot`'s refs are not the model here either: nothing is written into the
// page, so nothing about it can be read by it.
const IDENTITY = `(function () {
    var g = globalThis;
    var nonce = g.__eidolon_doc_nonce;
    if (typeof nonce !== "string") {
        nonce = "n" + Math.random().toString(36).slice(2, 12) + Date.now().toString(36);
        g.__eidolon_doc_nonce = nonce;
    }
    return { href: location.href, time_origin: performance.timeOrigin, nonce: nonce };
})()`;

function identityCode() {
    return `(() => { try { return ${IDENTITY}; } catch (e) { return null; } })()`;
}

async function probe(tabId) {
    try {
        const out = await browser.tabs.executeScript(tabId, {
            code: identityCode(),
            runAt: "document_idle",
        });
        const got = out && out[0];
        if (!got || typeof got.time_origin !== "number") {
            detach("this page cannot be read: it disclosed no document identity");
            return null;
        }
        return got;
    } catch (e) {
        detach(
            "this page cannot be read (restricted or privileged page): " +
                (e && e.message ? e.message : e),
        );
        return null;
    }
}

// `read` returns what the page renders, which is what a person sitting there
// would read: `innerText` leaves out hidden text and does not include a form
// control's value, a password field's included. Values never appear here.
function readCode(max) {
    return `(() => {
        const identity = ${IDENTITY};
        try {
            // Only rendered text. innerText leaves out hidden text, script text and a
            // form control's value. There is deliberately no textContent fallback: it
            // would hand back exactly the hidden and script text a person cannot see,
            // which is how a page's secrets leave with a read that looks empty. A
            // document with no rendered text yields nothing, and says so.
            const source = document.body || document.documentElement;
            const text = source && typeof source.innerText === "string" ? source.innerText : "";
            return Object.assign({}, identity, {
                title: document.title || "",
                text: text.slice(0, ${max + 1}),
                truncated: text.length > ${max},
            });
        } catch (e) {
            return Object.assign({}, identity, { error: String(e) });
        }
    })()`;
}

// The outline names elements; it must not carry their contents out of the page.
// Two rules, and both are load-bearing:
//
//   * A *label* comes from attributes or rendered text, never from a value. The
//     earlier version read `el.value`, which exported a password field's value and
//     a hidden CSRF token as node names; `innerText` is a label for most elements
//     but is the *value* for a `textarea` or a `select`, so it is not read there.
//   * An element that is not rendered is not in the outline, and the walk stops at
//     it — which is how a `display:none` ancestor keeps its whole subtree,
//     including any secret sitting in it, out of the answer. `input[type=hidden]`
//     is skipped by type rather than by trusting the UA stylesheet.
function structureCode(maxNodes) {
    return `(() => {
        const identity = ${IDENTITY};
        const LIMIT = ${maxNodes};
        const VISIT_LIMIT = 20000;
        const nodes = [];
        let visited = 0;
        const collapse = (s) => String(s === undefined || s === null ? "" : s)
            .replace(/\\s+/g, " ").trim().slice(0, 120);

        const rendered = (el, style) => {
            if (el.hidden) return false;
            if (!style) return false;
            if (style.display === "none") return false;
            if (style.visibility === "hidden" || style.visibility === "collapse") return false;
            if (style.opacity === "0" || style.opacity === 0) return false;
            return true;
        };

        const label = (el) => {
            const tag = (el.localName || "").toLowerCase();
            let out = "";
            if (el.getAttribute) {
                out = el.getAttribute("aria-label")
                    || el.getAttribute("alt")
                    || el.getAttribute("title")
                    || el.getAttribute("placeholder")
                    || "";
            }
            // What a person sees beside the control beats the developer's name attribute.
            if (!out && el.labels && el.labels.length) out = el.labels[0].innerText || "";
            if (!out && el.getAttribute) out = el.getAttribute("name") || "";
            // Not for a textarea or a select: their innerText is what a person
            // typed or chose, which is a value however it is spelled.
            if (!out && tag !== "textarea" && tag !== "select" && el.innerText) out = el.innerText;
            return collapse(out);
        };

        const roleOf = (el) => {
            if (!el || !el.tagName) return null;
            const tag = el.tagName.toLowerCase();
            if (el.getAttribute) {
                const role = el.getAttribute("role");
                if (role) return collapse(role);
            }
            if (tag === "a") return el.hasAttribute("href") ? "link" : null;
            if (tag === "button") return "button";
            if (tag === "input") return "input:" + (el.getAttribute("type") || "text");
            if (tag === "select") return "select";
            if (tag === "textarea") return "textarea";
            if (tag === "form") return "form";
            if (tag === "nav") return "navigation";
            if (tag === "main") return "main";
            if (tag === "header") return "banner";
            if (tag === "footer") return "contentinfo";
            if (tag === "img") return "img";
            if (/^h[1-6]$/.test(tag)) return tag;
            return null;
        };

        const walk = (el, depth) => {
            if (nodes.length >= LIMIT || visited >= VISIT_LIMIT) return;
            if (!el || !el.tagName) return;
            visited += 1;
            const tag = (el.localName || el.tagName).toLowerCase();
            if (tag === "input" && (el.getAttribute("type") || "text").toLowerCase() === "hidden") return;
            let style = null;
            try {
                style = window.getComputedStyle(el);
            } catch (e) {
                return;
            }
            if (!rendered(el, style)) return;
            const role = roleOf(el);
            if (role) nodes.push({ role: role, name: label(el), depth: depth });
            const kids = el.children || [];
            for (let i = 0; i < kids.length; i++) {
                if (nodes.length >= LIMIT || visited >= VISIT_LIMIT) return;
                walk(kids[i], depth + 1);
            }
        };

        try {
            if (document.body) walk(document.body, 0);
            return Object.assign({}, identity, {
                title: document.title || "",
                nodes: nodes,
                truncated: nodes.length >= LIMIT || visited >= VISIT_LIMIT,
            });
        } catch (e) {
            return Object.assign({}, identity, { error: String(e) });
        }
    })()`;
}

// ---- start -----------------------------------------------------------------

log("librewolf bridge extension", EXT_VERSION, "starting");
connect();
