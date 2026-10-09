"use strict";

// The extension's browser path, driven for real: the *shipped* background.js is
// loaded into a context with a fake `browser` and a fake DOM, and the code strings
// it injects (`readCode`, `structureCode`, `identityCode`) are actually run against
// that DOM. So these are tests of the browser half, not of a Rust stand-in.
//
//   node tests/librewolf/js/test.js        (or: bash tests/librewolf/js/run.sh)
//
// Every finding this file pins has a *witness* beside it: the pre-fix logic, kept
// here verbatim, run against the same fixture, asserted to fail. A regression test
// that cannot fail proves nothing, so the bug is reproduced in the same run that
// shows the fix closing it. If the witness stops applying (because the shipped code
// moved), the witness test says so instead of quietly passing.

const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const EXT = path.join(__dirname, "..", "..", "..", "librewolf", "extension", "background.js");
const SOURCE = fs.readFileSync(EXT, "utf8");
const ADDON = "librewolf-bridge@eidolon.local";

let failures = 0;
const ok = (name) => console.log("ok   " + name);
const fail = (name, detail) => {
    failures += 1;
    console.log("FAIL " + name + (detail === undefined ? "" : ": " + detail));
};
const check = (name, cond, detail) => (cond ? ok(name) : fail(name, detail));
const has = (haystack, needle) => String(haystack).indexOf(needle) !== -1;

// ---- a small fake DOM ------------------------------------------------------

function node(tag, attrs = {}, opts = {}) {
    const style = Object.assign({ display: "block", visibility: "visible", opacity: "1" }, opts.style || {});
    return {
        tagName: tag.toUpperCase(),
        localName: tag,
        children: opts.children || [],
        hidden: !!opts.hidden,
        innerText: opts.text === undefined ? "" : opts.text,
        labels: opts.labels,
        // Deliberately present on every element: the shipped code must never read it.
        value: opts.value,
        _attrs: attrs,
        _style: style,
        hasAttribute(n) {
            return Object.prototype.hasOwnProperty.call(attrs, n);
        },
        getAttribute(n) {
            return Object.prototype.hasOwnProperty.call(attrs, n) ? String(attrs[n]) : null;
        },
    };
}

function pageState(overrides = {}) {
    return Object.assign(
        {
            href: "https://example.test/page-one",
            timeOrigin: 1000,
            title: "Bridge test page",
            body: node("body"),
            // The content script's own world for this document. It survives between
            // injections and it dies with the document — which is exactly what the
            // measured browser behaviour is, and what the document nonce rests on.
            sandbox: {},
        },
        overrides,
    );
}

// A new document at the address given: a fresh sandbox, whatever the clock says.
function navigate(page, { href = page.href, timeOrigin = page.timeOrigin, body = page.body } = {}) {
    page.href = href;
    page.timeOrigin = timeOrigin;
    page.body = body;
    page.sandbox = {};
    return page;
}

function runInPage(code, page) {
    const globals = Object.assign({}, page.sandbox);
    globals.document = { title: page.title, body: page.body, documentElement: page.body };
    globals.location = { href: page.href };
    globals.performance = { timeOrigin: page.timeOrigin };
    // Measured in the disposable browser: `globalThis` in an injected script is *not*
    // the page's window.
    globals.window = { getComputedStyle: (el) => el._style };
    const out = vm.runInNewContext(code, globals);
    page.sandbox = globals;
    return out;
}

// ---- the extension, loaded as it ships (or as patched for a witness) -------

function load({ page = pageState(), script = null, patches = [], patchAll = [] } = {}) {
    let source = SOURCE;
    for (const [before, after] of patchAll) {
        const count = source.split(before).length - 1;
        if (count === 0) {
            throw new Error("a witness patch (all) found nothing to replace; the shipped code moved:\n" + before);
        }
        source = source.split(before).join(after);
    }
    for (const [before, after] of patches) {
        const count = source.split(before).length - 1;
        if (count !== 1) {
            throw new Error(
                "a witness patch did not apply exactly once (" + count + " matches); the shipped code moved:\n" + before,
            );
        }
        source = source.replace(before, after);
    }

    const sent = [];
    const injected = [];
    const listeners = { click: [], updated: [], removed: [] };
    const env = {
        page,
        onDisconnect: null,
        // By default every injection runs the real code string against the page, which
        // is what makes this a test of the browser path rather than of a mock.
        script: script || (async (_tabId, code) => runInPage(code, env.page)),
    };
    const port = {
        postMessage: (m) => sent.push(JSON.parse(JSON.stringify(m))),
        onMessage: { addListener: () => {} },
        onDisconnect: { addListener: (fn) => { env.onDisconnect = fn; } },
    };
    const browser = {
        runtime: { connectNative: () => port, lastError: undefined },
        browserAction: { onClicked: { addListener: (fn) => listeners.click.push(fn) } },
        tabs: {
            async executeScript(tabId, opts) {
                injected.push(opts.code);
                return [await env.script(tabId, opts.code, injected.length)];
            },
            onUpdated: { addListener: (fn) => listeners.updated.push(fn) },
            onRemoved: { addListener: (fn) => listeners.removed.push(fn) },
        },
    };
    const ctx = vm.createContext({
        browser,
        console: { debug() {}, log() {}, error() {} },
        setTimeout: () => 0,
        setInterval: () => 0,
        clearInterval: () => {},
    });
    vm.runInContext(source, ctx, { filename: "background.js" });
    vm.runInContext("function __setAttached(a) { attached = a; }", ctx);

    const get = (name) => vm.runInContext(name, ctx);
    const call = (name, ...args) => vm.runInContext(name, ctx)(...args);
    return {
        sent,
        injected,
        listeners,
        env,
        get,
        call,
        run: (code) => vm.runInContext(code, ctx),
        state: () => ({ attached: get("attached"), generation: get("generation"), consentSeq: get("consentSeq") }),
        /// The identity of the document as it is now, read the way the extension reads it
        /// — nonce included. A hand-made answer that leaves the nonce out is a different
        /// document as far as the extension is concerned, which is the point.
        identity() {
            const identityOf = vm.runInContext("identityCode", ctx);
            return runInPage(identityOf(), env.page);
        },
        attach(tabId, href, timeOrigin, generation) {
            const id = this.identity();
            call("__setAttached", {
                tab_id: tabId,
                url: id ? id.href : href,
                title: "A page",
                generation,
                time_origin: id ? id.time_origin : timeOrigin,
                nonce: id ? id.nonce : null,
                attached_at_ms: 1,
            });
            vm.runInContext("generation = " + generation, ctx);
        },
        command: (msg) => call("onCommand", msg),
        /// A command as the host builds one: naming the attachment and the document it
        /// holds, so a test never has to remember to fill in the nonce by hand.
        commandFor(record, op, args = {}, id = 1) {
            return this.command({
                v: 1,
                type: "command",
                id,
                op,
                generation: record.generation,
                time_origin: record.time_origin,
                nonce: record.nonce,
                args,
            });
        },
        states: () => sent.filter((m) => m.type === "state"),
        results: () => sent.filter((m) => m.type === "result"),
        replyFor: (id) => sent.filter((m) => m.type === "result" && m.id === id).pop(),
    };
}

function deferred() {
    let resolve;
    const promise = new Promise((r) => (resolve = r));
    return { promise, resolve };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- 1. the outline: labels, never values; nothing unrendered --------------

function secretsPage() {
    return pageState({
        body: node("body", {}, {
            children: [
                node("h1", {}, { text: "Bridge test page" }),
                node("a", { href: "/page-two" }, { text: "to page two" }),
                // Bare: no aria-label, no title. The pre-fix label() fell through to
                // el.value for exactly this shape, which is the common one.
                node("input", { type: "password", name: "password" }, { value: "hunter2-CORRECT-HORSE" }),
                node("input", { type: "hidden", name: "csrf_token" }, { value: "CSRF-TOKEN-abc123" }),
                node("div", { style: "display:none" }, {
                    style: { display: "none" },
                    children: [
                        node("p", {}, { text: "HIDDEN-BLOCK-TEXT" }),
                        node("a", { href: "/hidden" }, { text: "HIDDEN-LINK-TEXT" }),
                        node("input", { type: "text", name: "note" }, { value: "HIDDEN-INPUT-VALUE" }),
                    ],
                }),
                node("div", {}, { hidden: true, children: [node("p", {}, { text: "HIDDEN-ATTR-TEXT" })] }),
                node("div", {}, { style: { visibility: "hidden" }, children: [node("p", {}, { text: "VIS-HIDDEN-TEXT" })] }),
                node("div", {}, { style: { opacity: "0" }, children: [node("p", {}, { text: "OPACITY-ZERO-TEXT" })] }),
                node("input", { type: "text", name: "email", placeholder: "Your email" }, { value: "noah@example.invalid" }),
                node("input", { type: "checkbox", name: "remember", "aria-label": "" }, { labels: [{ innerText: "Remember me" }] }),
                node("textarea", {}, { text: "TYPED-IN-TEXTAREA" }),
                node("button", {}, { text: "Send" }),
            ],
        }),
    });
}

const SECRETS = [
    "hunter2-CORRECT-HORSE",
    "CSRF-TOKEN-abc123",
    "HIDDEN-BLOCK-TEXT",
    "HIDDEN-LINK-TEXT",
    "HIDDEN-INPUT-VALUE",
    "HIDDEN-ATTR-TEXT",
    "VIS-HIDDEN-TEXT",
    "OPACITY-ZERO-TEXT",
    "noah@example.invalid",
    "TYPED-IN-TEXTAREA",
];

// The pre-fix outline, kept verbatim as the witness: `el.value` as a name, and no
// filter for rendering or for hidden inputs.
const ORIGINAL_STRUCTURE = `(() => {
    const identity = { href: location.href, time_origin: performance.timeOrigin };
    const LIMIT = 400;
    const nodes = [];
    const collapse = (s) => String(s === undefined || s === null ? "" : s)
        .replace(/\\s+/g, " ").trim().slice(0, 120);
    const label = (el) => {
        let out = "";
        if (el.getAttribute) {
            out = el.getAttribute("aria-label") || el.getAttribute("alt") || el.getAttribute("title") || "";
        }
        if (!out && el.value) out = el.value;
        if (!out && el.innerText) out = el.innerText;
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
        if (/^h[1-6]$/.test(tag)) return tag;
        return null;
    };
    const walk = (el, depth) => {
        if (nodes.length >= LIMIT) return;
        const role = roleOf(el);
        if (role) nodes.push({ role: role, name: label(el), depth: depth });
        const kids = el.children || [];
        for (let i = 0; i < kids.length; i++) walk(kids[i], depth + 1);
    };
    if (document.body) walk(document.body, 0);
    return Object.assign({}, identity, { title: document.title || "", nodes: nodes, truncated: false });
})()`;

async function structureOf(handle) {
    const page = handle.env.page;
    handle.attach(1, page.href, page.timeOrigin, 1);
    await handle.commandFor(handle.state().attached, "structure", {}, 1);
    return handle.replyFor(1);
}

async function testOutline() {
    const page = secretsPage();
    const reply = await structureOf(load({ page }));
    const json = JSON.stringify(reply);
    check("structure: the reply is ok", reply && reply.ok === true, json);
    const names = (reply.result.nodes || []).map((n) => n.name).join(" | ");
    check("structure: the heading and its text are there", has(names, "Bridge test page"), names);
    check("structure: a link is there", has(names, "to page two"), names);
    check("structure: a button is there", has(names, "Send"), names);
    check("structure: a labelled control is named by its label", has(names, "Remember me"), names);
    check("structure: an ordinary input is named, not valued", has(names, "Your email"), names);
    for (const secret of SECRETS) {
        check("structure: " + secret + " is not in the outline", !has(json, secret), json);
    }
    const roles = (reply.result.nodes || []).map((n) => n.role);
    check("structure: the password field is still described", roles.indexOf("input:password") !== -1, JSON.stringify(roles));
    check("structure: and named by its field name, not its contents", has(names, "password"), names);
    check("structure: no node for a hidden input", roles.indexOf("input:hidden") === -1, JSON.stringify(roles));

    // The witness: the same fixture against the pre-fix outline leaks exactly what
    // this test says the shipped one does not.
    const witness = runInPage(ORIGINAL_STRUCTURE, page);
    const witnessJson = JSON.stringify(witness);
    check("witness: the pre-fix outline exported the password", has(witnessJson, "hunter2-CORRECT-HORSE"));
    check("witness: the pre-fix outline exported the hidden CSRF token", has(witnessJson, "CSRF-TOKEN-abc123"));
    check("witness: the pre-fix outline exported a hidden link's text", has(witnessJson, "HIDDEN-LINK-TEXT"));
    check("witness: the pre-fix outline exported a hidden input's value", has(witnessJson, "HIDDEN-INPUT-VALUE"));
    check("witness: the pre-fix outline exported a textarea's typed value", has(witnessJson, "TYPED-IN-TEXTAREA"));
}

// ---- 2. read: rendered text only -------------------------------------------

async function readOf(handle, body, id = 1) {
    handle.attach(1, handle.env.page.href, handlyPage(handle).timeOrigin, 1);
    await handle.commandFor(handle.state().attached, "read", {}, id);
    return handle.replyFor(id);
}
function handlyPage(handle) {
    return handle.env.page;
}

async function testRead() {
    const page = pageState({ body: node("body", {}, { text: "hello people" }) });
    let reply = await readOf(load({ page }), page.body);
    check("read: returns the rendered text", reply.ok === true && reply.result.text === "hello people", JSON.stringify(reply));

    // A body whose rendered text is empty, with the text a person cannot see sitting
    // in textContent. The old code fell back to it; the shipped code must not.
    const hidden = pageState({ body: node("body", {}, { text: "" }) });
    hidden.body.textContent = "SCRIPT-ONLY-SECRET-zzz";
    reply = await readOf(load({ page: hidden }), hidden.body);
    const json = JSON.stringify(reply);
    check("read: an empty rendered body stays empty", reply.ok === true && reply.result.text === "", json);
    check("read: hidden/script text is not returned", !has(json, "SCRIPT-ONLY-SECRET-zzz"), json);

    const witness = runInPage(
        `(() => { const body = document.body;
           const text = body ? (body.innerText || body.textContent || "") : "";
           return { text: text }; })()`,
        hidden,
    );
    check("witness: the pre-fix fallback returned the hidden/script text", has(String(witness.text), "SCRIPT-ONLY-SECRET-zzz"), String(witness.text));
}

// ---- 3. a same-URL reload is refused ---------------------------------------

async function testSameUrlReload() {
    // A real click attaches, so the nonce is the shipped code's own.
    const page = pageState({ body: node("body", {}, { text: "OLD DOCUMENT TEXT" }) });
    const handle = load({ page });
    await click(handle, 1);
    const record = handle.state().attached;
    check(
        "same-url reload: the click attached, with a document nonce",
        record && typeof record.nonce === "string" && record.nonce.length > 0,
        JSON.stringify(record),
    );

    // The document is replaced at the same address, and the clock reads the same: only
    // the content script's own world — and so the nonce — is new. This is the case that
    // neither a URL nor a timestamp can see.
    navigate(page, { body: node("body", {}, { text: "NEW DOCUMENT TEXT" }) });
    await handle.commandFor(record, "read", {}, 7);
    const reply = handle.replyFor(7);
    const json = JSON.stringify(reply);
    check("same-url reload: the read is refused", reply && reply.ok === false, json);
    check("same-url reload: no text from the replacement document is returned", !has(json, "NEW DOCUMENT TEXT"), json);
    check("same-url reload: the extension let the attachment go", handle.state().attached === null, JSON.stringify(handle.state()));
    check(
        "same-url reload: the host is told why",
        handle.states().some((m) => m.attached === null && has(m.reason || "", "document changed")),
        JSON.stringify(handle.states()),
    );

    // The second line, on its own: with the nonce comparison patched out of the guard,
    // the clock is what refuses a document whose time origin moved. This is not the
    // mechanism — it is the check that stands behind it.
    {
        const page2 = pageState({ body: node("body", {}, { text: "OLD DOCUMENT TEXT" }) });
        const h2 = load({
            page: page2,
            // The nonce comparison goes, and the `||` with it: what is left is the clock.
            patches: [[
                `        value.href !== expected.url ||
        value.nonce !== expected.nonce
`,
                `        value.href !== expected.url
`,
            ]],
        });
        await click(h2, 1);
        const record2 = h2.state().attached;
        navigate(page2, { body: node("body", {}, { text: "NEW DOCUMENT TEXT" }), timeOrigin: 9999 });
        await h2.commandFor(record2, "read", {}, 8);
        const reply2 = h2.replyFor(8);
        check("second line: the clock alone refuses a moved document", reply2 && reply2.ok === false, JSON.stringify(reply2));
        check("second line: and its text does not come back", !has(JSON.stringify(reply2), "NEW DOCUMENT TEXT"), JSON.stringify(reply2));
    }

    // The witness: the guard as it was — the field's presence and the URL, nothing more
    // — hands the replacement document's text back under the old identity.
    {
        const page3 = pageState({ body: node("body", {}, { text: "OLD DOCUMENT TEXT" }) });
        const h3 = load({
            page: page3,
            patches: [[
                `        typeof value.time_origin !== "number" ||
        typeof value.nonce !== "string" ||
        value.time_origin !== expected.time_origin ||
        value.href !== expected.url ||
        value.nonce !== expected.nonce`,
                `        typeof value.time_origin !== "number" ||
        value.href !== expected.url`,
            ]],
        });
        await click(h3, 1);
        const record3 = h3.state().attached;
        navigate(page3, { body: node("body", {}, { text: "NEW DOCUMENT TEXT" }) });
        await h3.commandFor(record3, "read", {}, 9);
        const reply3 = h3.replyFor(9);
        const witnessJson = JSON.stringify(reply3);
        check("witness: the pre-fix guard accepted the replacement document", reply3 && reply3.ok === true, witnessJson);
        check("witness: the pre-fix reply carried the replacement's text", has(witnessJson, "NEW DOCUMENT TEXT"), witnessJson);
        check("witness: and labelled it with the attached document's nonce", reply3.nonce === record3.nonce, witnessJson);
    }
}

// ---- 4. the click, and what may cancel it ----------------------------------

function click(handle, tabId) {
    return handle.listeners.click[0]({ id: tabId, url: handle.env.page.href, title: "A page" });
}

async function testClickRaces() {
    // (a) a revocation lands while the click's probe is still out.
    {
        const page = pageState({ body: node("body", {}, { text: "TEXT" }) });
        const gate = deferred();
        let first = true;
        const handle = load({
            page,
            script: async (_t, code) => {
                if (first) {
                    first = false;
                    return gate.promise;
                }
                return runInPage(code, page);
            },
        });
        const pending = click(handle, 1);
        await sleep(0);
        handle.call("detach", "the assistant detached the tab", null);
        gate.resolve(handle.identity());
        await pending;
        check("click: a detach during the probe cancels the attach", handle.state().attached === null, JSON.stringify(handle.state()));
        check(
            "click: no attachment is announced",
            !handle.states().some((m) => m.attached),
            JSON.stringify(handle.states()),
        );
    }

    // (b) a second click lands while the first is still waiting; the newer one wins.
    {
        const page = pageState({ body: node("body", {}, { text: "TEXT" }) });
        const gate = deferred();
        let first = true;
        const handle = load({
            page,
            script: async (_t, code) => {
                if (first) {
                    first = false;
                    return gate.promise;
                }
                return runInPage(code, page);
            },
        });
        const older = click(handle, 1);
        await sleep(0);
        await click(handle, 2);
        const afterNewer = handle.state().attached;
        gate.resolve(handle.identity());
        await older;
        const after = handle.state().attached;
        check("click: the newer click attaches", afterNewer && afterNewer.tab_id === 2, JSON.stringify(afterNewer));
        check("click: the older probe does not overwrite it", after && after.tab_id === 2, JSON.stringify(after));
    }

    // (c) the document changes between the probe and the confirmation.
    {
        const page = pageState({ body: node("body", {}, { text: "TEXT" }) });
        let calls = 0;
        const handle = load({
            page,
            script: async (_t, code) => {
                calls += 1;
                if (calls === 2) page.timeOrigin = 4242;
                return runInPage(code, page);
            },
        });
        await click(handle, 1);
        check("click: a document that changes under the probe is not attached", handle.state().attached === null, JSON.stringify(handle.state()));
        check(
            "click: and the reason says the confirmation failed",
            handle.states().some((m) => m.attached === null && has(m.reason || "", "confirmed")),
            JSON.stringify(handle.states()),
        );
    }

    // Witness: without the confirmation and the sequence, the awaited probe attaches
    // the tab even though the consent was withdrawn while it waited.
    {
        const page = pageState({ body: node("body", {}, { text: "TEXT" }) });
        const gate = deferred();
        let first = true;
        const handle = load({
            page,
            script: async (_t, code) => {
                if (first) {
                    first = false;
                    return gate.promise;
                }
                return runInPage(code, page);
            },
            patchAll: [["if (mine !== consentSeq) {", "if (false) {"]],
        });
        const pending = click(handle, 1);
        await sleep(0);
        handle.call("detach", "the assistant detached the tab", null);
        gate.resolve(handle.identity());
        await pending;
        check(
            "witness: the pre-fix click resurrected an attachment after a detach",
            handle.state().attached !== null,
            JSON.stringify(handle.state()),
        );
    }

    // A non-http page is refused at the click, with the id never attached.
    {
        const handle = load();
        await handle.listeners.click[0]({ id: 3, url: "about:config", title: "x" });
        check("click: a non-http page never attaches", handle.state().attached === null);
    }
}


// ---- 4b. a click whose confirmation is still out ---------------------------

async function testPendingClickLifecycle() {
    // (a) the clicked tab navigates while the first probe is still out. Nothing is
    // attached at that point, so an `attached`-only listener would miss it entirely
    // and the replacement document would be attached.
    {
        const page = pageState({ body: node("body", {}, { text: "TEXT" }) });
        const gate = deferred();
        let calls = 0;
        const handle = load({
            page,
            script: async (_t, code) => {
                calls += 1;
                if (calls === 1) return gate.promise;
                return runInPage(code, page);
            },
        });
        const pending = click(handle, 1);
        await sleep(0);
        page.href = "https://example.test/replacement";
        page.timeOrigin = 7777;
        handle.listeners.updated[0](1, { status: "loading" });
        gate.resolve(handle.identity());
        await pending;
        check("pending click: a navigation on the clicked tab withdraws it", handle.state().attached === null, JSON.stringify(handle.state()));
        check("pending click: and no attachment is announced", !handle.states().some((m) => m.attached), JSON.stringify(handle.states()));
    }

    // (b) the clicked tab closes while the first probe is out.
    {
        const page = pageState();
        const gate = deferred();
        const handle = load({ page, script: async (_t, code) => (gate.pending ? gate.promise : runInPage(code, page)) });
        handle.env.gate = gate;
        let first = true;
        handle.env.script = async (_t, code) => {
            if (first) {
                first = false;
                return gate.promise;
            }
            return runInPage(code, page);
        };
        const pending = click(handle, 1);
        await sleep(0);
        handle.listeners.removed[0](1);
        gate.resolve(handle.identity());
        await pending;
        check("pending click: a closed tab withdraws it", handle.state().attached === null, JSON.stringify(handle.state()));
    }

    // (c) the native host goes away while the first probe is out: there is nowhere
    // for an attachment to be served, so it must not be made.
    {
        const page = pageState();
        const gate = deferred();
        let first = true;
        const handle = load({
            page,
            script: async (_t, code) => {
                if (first) {
                    first = false;
                    return gate.promise;
                }
                return runInPage(code, page);
            },
        });
        const pending = click(handle, 1);
        await sleep(0);
        handle.env.onDisconnect();
        gate.resolve(handle.identity());
        await pending;
        check("pending click: a lost host withdraws it", handle.state().attached === null, JSON.stringify(handle.state()));
    }

    // (d) two clicks in flight, and the *older* one's tab closes: the newer one is
    // unaffected and still completes.
    {
        const page = pageState();
        const gA = deferred();
        const gB = deferred();
        const gates = [gA, gB];
        const handle = load({ page, script: async (_t, code) => (gates.length ? gates.shift().promise : runInPage(code, page)) });
        const a = click(handle, 1);
        await sleep(0);
        const b = click(handle, 2);
        await sleep(0);
        handle.listeners.removed[0](1); // the older click's tab closes
        gB.resolve(handle.identity());
        await b;
        gA.resolve(handle.identity());
        await a;
        const attached = handle.state().attached;
        check("pending click: closing the older click's tab leaves the newer one alone", attached && attached.tab_id === 2, JSON.stringify(attached));
    }

    // Witness: with the listeners as they were — returning unless a tab is already
    // attached — the navigation of a tab whose click is pending is not seen at all,
    // and the replacement document is attached.
    {
        const page = pageState({ body: node("body", {}, { text: "TEXT" }) });
        const gate = deferred();
        let calls = 0;
        const handle = load({
            page,
            script: async (_t, code) => {
                calls += 1;
                if (calls === 1) return gate.promise;
                return runInPage(code, page);
            },
            patches: [[
                `    if (changeInfo.status !== "loading") return;
    // The tab's *click* may still be being confirmed, with nothing attached yet.
    cancelPendingClick(tabId, "its document began loading");
`,
                `    if (changeInfo.status !== "loading") return;
    if (!attached || tabId !== attached.tab_id) return;
`,
            ]],
        });
        const pending = click(handle, 1);
        await sleep(0);
        page.href = "https://example.test/replacement";
        page.timeOrigin = 7777;
        handle.listeners.updated[0](1, { status: "loading" });
        gate.resolve(handle.identity());
        await pending;
        const attached = handle.state().attached;
        check(
            "witness: the pre-fix listeners let the replacement document attach",
            attached !== null && attached.url === "https://example.test/replacement",
            JSON.stringify(attached),
        );
    }
}

// ---- 5. commands: the generation is checked, both ways ---------------------

async function testCommandGenerations() {
    const page = pageState({ body: node("body", {}, { text: "TEXT" }) });
    const handle = load({ page });
    handle.attach(5, page.href, page.timeOrigin, 2);
    const record = handle.state().attached;

    await handle.command({
        v: 1, type: "command", id: 1, op: "read", generation: 1, time_origin: page.timeOrigin, args: {},
    });
    let reply = handle.replyFor(1);
    check("commands: a read issued for an older attachment is refused", reply.ok === false, JSON.stringify(reply));
    check("commands: and nothing was injected", handle.injected.length === 0, String(handle.injected.length));

    await handle.command({ v: 1, type: "command", id: 2, op: "read", args: {},
        generation: record.generation, time_origin: 7.5, nonce: record.nonce });
    reply = handle.replyFor(2);
    check("commands: a read issued for another clock is refused", reply.ok === false, JSON.stringify(reply));

    await handle.command({ v: 1, type: "command", id: 6, op: "read", args: {},
        generation: record.generation, time_origin: record.time_origin,
        nonce: "a-nonce-from-another-document" });
    reply = handle.replyFor(6);
    check("commands: a read issued for another document is refused", reply.ok === false, JSON.stringify(reply));
    check("commands: and nothing was injected for it", handle.injected.length === 0, String(handle.injected.length));

    const before = JSON.stringify(handle.state().attached);
    // A detach issued for the *previous* attachment, but well-formed for this document:
    // the refusal must be about the attachment, not about a missing nonce.
    await handle.command({ v: 1, type: "command", id: 3, op: "detach", args: {},
        generation: 1, time_origin: record.time_origin, nonce: record.nonce });
    reply = handle.replyFor(3);
    check("commands: a stale detach is refused", reply.ok === false, JSON.stringify(reply));
    check(
        "commands: a stale detach does not revoke a newer attachment",
        JSON.stringify(handle.state().attached) === before,
        JSON.stringify(handle.state().attached),
    );

    await handle.commandFor(record, "detach", {}, 4);
    reply = handle.replyFor(4);
    check("commands: a matching detach is honoured", reply.ok === true, JSON.stringify(reply));
    check("commands: and the attachment is gone", handle.state().attached === null);

    await handle.commandFor(record, "read", {}, 5);
    reply = handle.replyFor(5);
    check("commands: a read after detach is refused", reply.ok === false && has(reply.error, "no tab is attached"), JSON.stringify(reply));
}

// ---- 6. a page that cannot be injected into --------------------------------

async function testInjectionFailure() {
    const page = pageState();
    const handle = load({
        page,
        script: async () => {
            throw new Error("Missing host permission for the tab");
        },
    });
    handle.attach(1, page.href, page.timeOrigin, 1);
    await handle.commandFor(handle.state().attached, "read", {}, 1);
    const reply = handle.replyFor(1);
    check("refusal: an uninjectable page is reported, not guessed at", reply.ok === false && has(reply.error, "restricted or privileged"), JSON.stringify(reply));
    check("refusal: and the attachment is let go", handle.state().attached === null);
}

// ---- run -------------------------------------------------------------------

async function main() {
    console.log("# the librewolf extension's browser path, against the shipped background.js");
    await testOutline();
    await testRead();
    await testSameUrlReload();
    await testClickRaces();
    await testPendingClickLifecycle();
    await testCommandGenerations();
    await testInjectionFailure();
    if (failures) {
        console.log("\n" + failures + " check(s) failed");
        process.exit(1);
    }
    console.log("\nok   every browser-path check holds");
}

main().catch((e) => {
    console.error(e);
    process.exit(2);
});
