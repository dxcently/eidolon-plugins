#!/usr/bin/env bash
# throwaway.sh: the browser proof, against a disposable LibreWolf profile and
# local pages — never the operator's session.
#
#   t=$(mktemp -d)
#   HOME=$t XDG_CONFIG_HOME=$t/cfg XDG_STATE_HOME=$t/state XDG_DATA_HOME=$t/data \
#     bash tests/librewolf/throwaway.sh
#
# What it drives, end to end: the browser spawns the host as its native messaging
# host, the extension connects with the right add-on id, the host's loopback
# endpoint answers reads and structure calls out of real pages, a new document ends
# the attachment, a second and third attach work, `detach` ends it, and killing the
# browser takes the host with it.
#
# The pages carry the extraction semantics the unit tests can only mock: a password
# field, a hidden CSRF input, a link and an input inside `display:none`, a
# `hidden`-attribute link, a `visibility:hidden` block, a textarea with content, an
# ordinary input with a value, and a page whose visible text is empty. What a person
# can see is in the answer; what they cannot see is asserted not to be.
#
# WHAT THIS DOES NOT PROVE. A headless browser has no toolbar, so there is no click
# to make. The harness *substitutes* the click: it appends a test-only script to a
# copy of the extension which attaches the active tab on request, and gives that copy
# a host permission for the local test origin so the read path can run without a
# person. The shipped extension keeps `activeTab` and the toolbar click alone, and
# nothing here is evidence that the click and the `activeTab` grant it creates work.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
. "$here/guard.sh"
require_temp_config || exit 2

browser=${EIDOLON_LIBREWOLF_BROWSER:-librewolf}
command -v "$browser" >/dev/null || { echo "no '$browser' on PATH (set EIDOLON_LIBREWOLF_BROWSER)" >&2; exit 2; }

# The binary under test, and its provenance. A stale binary would make this whole
# run say nothing about the sources beside it, so the default path is rebuilt here
# every time (cargo is incremental) and what was used is printed with its digest.
if [ -n "${EIDOLON_LIBREWOLF_BIN:-}" ]; then
    bin=$EIDOLON_LIBREWOLF_BIN
    [ -x "$bin" ] || { echo "EIDOLON_LIBREWOLF_BIN=$bin is not executable" >&2; exit 2; }
    echo "note: EIDOLON_LIBREWOLF_BIN was set; not rebuilding, and testing whatever is there"
else
    bin=$repo/target/debug/eidolon-librewolf
    echo "building the host from the sources beside this test ..."
    (cd "$repo" && cargo build -p eidolon-librewolf) >&2 || exit 2
fi
echo "ok   host under test: $bin"
echo "     $(sha256sum "$bin" | cut -c1-32)…  mtime $(date -r "$bin" '+%Y-%m-%d %H:%M:%S')"
newest=$(find "$repo/librewolf/service/src" "$repo/librewolf/service/Cargo.toml" -type f -newer "$bin" | head -1)
if [ -n "$newest" ] && [ -z "${EIDOLON_LIBREWOLF_BIN:-}" ]; then
    echo "FAIL the host binary is older than $newest (harness problem)" >&2
    exit 1
fi

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
port=${EIDOLON_LIBREWOLF_PORT:-$(free_port)}
webport=$(free_port)
export EIDOLON_LIBREWOLF_PORT=$port
# The host treats the extension's silence as the browser's death (end of stream is
# not reliable — a content process can hold the pipe). The shipped default is 30s;
# the proof shortens it so the last check does not have to wait out the default.
export EIDOLON_LIBREWOLF_SILENCE_S=${EIDOLON_LIBREWOLF_SILENCE_S:-6}

lwpid=""
webpid=""
cleanup() {
    if [ -n "$lwpid" ]; then kill "$lwpid" 2>/dev/null || true; fi
    if [ -n "$webpid" ]; then kill "$webpid" 2>/dev/null || true; fi
    return 0
}
trap cleanup EXIT

fail() { echo "FAIL $*" >&2; exit 1; }

# ---- the pages -------------------------------------------------------------

pages=$HOME/pages
mkdir -p "$pages"

cat > "$pages/page-one.html" <<'EOF'
<!doctype html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="12;url=page-two.html">
<title>Bridge page one</title>
<h1>Bridge page one</h1>
<p>UNIQUE-TEXT-ONE</p>
<a href="page-two.html">a link to page two</a>
<!-- An experiment, not the plugin: can a value be kept in the content script's own
     world, out of the page's reach, across two injections in one document? The
     extension writes #sandbox-diag; this page's own script writes #nonce-diag, looking
     for the same value through the window it can see. -->
<pre id="sandbox-diag">sandbox-diag: pending</pre>
<pre id="nonce-diag">nonce-diag: pending</pre>
<script>
  setInterval(function () {
    var v = window.__eidolon_nonce_probe;
    document.getElementById("nonce-diag").textContent =
      "nonce-diag: page-sees " + (typeof v === "string" ? v : "nothing");
  }, 400);
</script>
EOF

# Everything a page hides, and one thing it shows. The values are distinctive so
# that their absence is a check and not an impression.
cat > "$pages/page-two.html" <<'EOF'
<!doctype html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="16;url=page-three.html">
<title>Bridge page two</title>
<h1>Bridge page two</h1>
<p>UNIQUE-TEXT-TWO</p>
<form>
  <label for="pw">Password</label>
  <input id="pw" type="password" name="password" value="PASSWORD-SECRET-alpha">
  <input type="hidden" name="csrf_token" value="CSRF-SECRET-beta">
  <input type="text" name="email" placeholder="Your email" value="EMAIL-SECRET-zeta">
  <textarea name="notes">TEXTAREA-SECRET-epsilon</textarea>
  <button type="submit">Send</button>
</form>
<div style="display:none">
  <a href="/hidden">HIDDEN-LINK-SECRET-gamma</a>
  <input type="text" name="note" value="HIDDEN-VALUE-delta">
</div>
<div hidden><a href="/hidden2">HIDDEN-ATTR-LINK-SECRET-eta</a></div>
<div style="visibility:hidden"><a href="/hidden3">VISIBILITY-HIDDEN-LINK-SECRET-theta</a></div>
EOF

# A document with nothing a person can read, and a script holding a secret: a read
# of it must come back empty, not full.
cat > "$pages/page-three.html" <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>Bridge page three</title>
<script>const SCRIPT_ONLY_SECRET = "SCRIPT-ONLY-SECRET-zzz";</script>
<p id="empty"></p>
EOF

(cd "$pages" && exec python3 -m http.server "$webport" --bind 127.0.0.1) >/dev/null 2>&1 &
webpid=$!

# ---- the profile, the host manifest, and a copy of the extension ----------

profile=$HOME/profile
extdir=$profile/extensions/librewolf-bridge@eidolon.local
mkdir -p "$extdir"
cp -r "$repo/librewolf/extension/." "$extdir/"

# The copy differs from the shipped extension in exactly two ways, both marked:
# the background script gets a test-only attach trigger, and the manifest grants
# the local test origin so that trigger can work without a click.
python3 - "$extdir" "$webport" <<'PY'
import json, sys
extdir, webport = sys.argv[1], sys.argv[2]
manifest = json.load(open(f"{extdir}/manifest.json"))
# A match pattern carries no port; this grants the loopback host, all ports.
manifest["permissions"] = ["nativeMessaging", "activeTab", "http://127.0.0.1/*"]
manifest["background"] = {"scripts": ["background.js", "test-attach.js"], "persistent": True}
json.dump(manifest, open(f"{extdir}/manifest.json", "w"), indent=2)
open(f"{extdir}/test-attach.js", "w").write(f'''// TEST ONLY. Appended by tests/librewolf/throwaway.sh to a *copy* of the
// extension, to stand in for a toolbar click a headless browser cannot produce.
// None of this is in the shipped extension and none of it is evidence that the
// click works. Failures are reported to the host as a detachment reason, which is
// the one channel the harness can read.
const TEST_ATTACH_URL = "http://127.0.0.1:{webport}/should-attach";
function testReport(what) {{
    send({{ v: 1, type: "state", attached: null, reason: "test-attach: " + what, url: null, generation: generation }});
}}
setInterval(async () => {{
    if (attached) return;
    try {{
        const r = await fetch(TEST_ATTACH_URL, {{ cache: "no-store" }});
        if (!r.ok) return;
        const tabs = (await browser.tabs.query({{ currentWindow: true }})) || [];
        const seen = tabs.map((t) => t.id + (t.active ? "*" : "") + ":" + (t.url || "<no url>")).join(" | ");
        const tab =
            (tabs.find((t) => (t.url || "").startsWith("http://127.0.0.1:"))) ||
            (tabs.find((t) => t.active)) ||
            tabs[0];
        if (!tab) {{ testReport("no tab at all; tabs: " + seen); return; }}
        const identity = await probe(tab.id);
        if (!identity) {{ testReport("probe failed on tab " + tab.id + " (" + (tab.url || "<no url>") + "); tabs: " + seen); return; }}
        // The clock this fork gives a document, for the record: LibreWolf ships
        // privacy.resistFingerprinting = true, which coarsens timers, and this is the
        // only signal a document's identity has. Printed, not trusted.
        let clock = "";
        try {{
            const out = await browser.tabs.executeScript(tab.id, {{
                code: "(() => ({{ time_origin: performance.timeOrigin, now: performance.now(), date: Date.now() }}))()",
                runAt: "document_idle",
            }});
            clock = JSON.stringify((out && out[0]) || null);
        }} catch (e) {{ clock = "unavailable"; }}
        // The nonce experiment (test only). Two injections in one document, to see
        // whether a value put on the sandbox's own global survives between them and
        // whether the page can see it. The answer goes into the page, where the
        // harness reads it back through a normal read; the page's own script writes its
        // half into a second element.
        try {{
            const A = '(function () {{ var fresh = typeof globalThis.__eidolon_nonce_probe !== "string";' +
                ' if (fresh) {{ globalThis.__eidolon_nonce_probe = "N" + Math.random().toString(36).slice(2, 10); }}' +
                ' return {{ fresh: fresh, where: (globalThis === window ? "global-is-window" : "global-distinct") }}; }})()';
            const B = '(function () {{ return {{ fresh: typeof globalThis.__eidolon_nonce_probe !== "string" }}; }})()';
            const ra = (await browser.tabs.executeScript(tab.id, {{ code: A, runAt: "document_idle" }}))[0];
            const rb = (await browser.tabs.executeScript(tab.id, {{ code: B, runAt: "document_idle" }}))[0];
            const note = "sandbox-diag: first=" + JSON.stringify(ra) + " second=" + JSON.stringify(rb);
            const write = "(function (txt) {{ var d = document.getElementById('sandbox-diag'); if (d) {{ d.textContent = txt; }} return true; }})";
            await browser.tabs.executeScript(tab.id, {{ code: "(" + write + ")(" + JSON.stringify(note) + ")", runAt: "document_idle" }});
        }} catch (e) {{
            testReport("nonce experiment failed: " + (e && e.message));
        }}
        testReport("attached tab " + tab.id + " clock " + clock);
        generation += 1;
        attached = {{
            tab_id: tab.id,
            url: identity.href || tab.url || "",
            title: tab.title || "",
            generation: generation,
            time_origin: identity.time_origin,
            // The document identity, from the same probe the shipped code makes: the
            // host refuses an attachment that does not name its document.
            nonce: identity.nonce,
            attached_at_ms: Date.now(),
        }};
        connect();
        announceAttached();
        console.debug("test-attach: attached tab", tab.id, "as generation", generation);
    }} catch (e) {{
        testReport("tick failed: " + (e && e.message));
    }}
}}, 700);
''')
PY

# Sideloading an unpacked extension from the profile's extensions directory needs
# the scope prefs; the operator's own config sets the same two for the charta
# new-tab page.
cat > "$profile/user.js" <<'EOF'
user_pref("extensions.autoDisableScopes", 0);
user_pref("extensions.enabledScopes", 15);
user_pref("xpinstall.signatures.required", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("app.update.enabled", false);
user_pref("browser.aboutConfig.showWarning", false);
EOF

nmh=$HOME/.librewolf/native-messaging-hosts
mkdir -p "$nmh"
"$bin" --print-host-manifest > "$nmh/eidolon_librewolf.json"
jq -e '.allowed_extensions[0] == "librewolf-bridge@eidolon.local"' "$nmh/eidolon_librewolf.json" >/dev/null \
    || fail "the host manifest printed by --print-host-manifest is not the one this test needs"
echo "ok   the host manifest is installed in the throwaway HOME"

# ---- drive it --------------------------------------------------------------

call() {
    curl -sS --max-time 25 -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
        -d "$1" "http://127.0.0.1:$port/call"
}
health() { curl -sS --max-time 5 "http://127.0.0.1:$port/health"; }
read_now() { call '{"method":"read","args":{"max":20000}}'; }
structure_now() { call '{"method":"structure","args":{"max_nodes":2000}}'; }

# wait_for <seconds> <shell test ...>
wait_for() {
    local deadline=$(( $(date +%s) + $1 )); shift
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if eval "$@" >/dev/null 2>&1; then return 0; fi
        sleep 0.3
    done
    return 1
}

attach_now() {   # wait for a fresh attachment on a page matching $1
    local wanted=$1
    touch "$pages/should-attach"
    wait_for 30 "call '{\"method\":\"status\",\"args\":{}}' | jq -e '.result.url | test(\"$wanted\")' >/dev/null" || {
        rm -f "$pages/should-attach"
        fail "no attachment on $wanted: $(call '{"method":"status","args":{}}')"
    }
    rm -f "$pages/should-attach"
    call '{"method":"status","args":{}}' | jq -c '.result'
}

echo "ok   launching $browser headless, profile $profile"
ps -eo pid= | sort > "$HOME/pids-before"
"$browser" --profile "$profile" --no-remote -headless \
    "http://127.0.0.1:$webport/page-one.html" >"$HOME/browser.log" 2>&1 &
lwpid=$!

wait_for 30 '[ -s "$HOME/.config/eidolon/librewolf.token" ]' || fail "the host never made its token file"
token=$(cat "$HOME/.config/eidolon/librewolf.token")
echo "ok   the browser spawned the host and it made a token at \$HOME/.config/eidolon/librewolf.token"
wait_for 30 '[ "$(health | jq -r .browser_connected 2>/dev/null)" = true ]' \
    || fail "the extension never connected to the host: $(health) $(tail -5 "$HOME/browser.log" 2>/dev/null)"
echo "ok   the extension connected: $(health | jq -c .)"

# 1. page one: attach, read, structure.
one=$(attach_now page-one)
echo "ok   attached: $one"

read=$(read_now)
echo "$read" | jq -e '.ok == true and (.result.text | test("UNIQUE-TEXT-ONE"))' >/dev/null \
    || fail "read did not return the attached page's text: $read"
echo "$read" | jq -e '.result.untrusted == true' >/dev/null || fail "a read must say its content is untrusted: $read"
echo "ok   read the attached tab's text out of the live DOM ($(echo "$read" | jq -r '.result.text | length') chars)"
# The document nonce is the identity the read path rests on, so its two assumptions are
# checked here rather than assumed: the content script's own world is *not* the page's
# window and keeps a value between injections, and the page cannot see that value.
sandbox_line=$(echo "$read" | jq -r '.result.text' | grep 'sandbox-diag' || true)
echo "$sandbox_line" | grep -q '"fresh":true' && echo "$sandbox_line" | grep -q '"fresh":false' \
    || fail "a value in the content script's world did not survive between two injections: $sandbox_line"
echo "$sandbox_line" | grep -q 'global-distinct' \
    || fail "the injected script's global looked like the page's window, so a nonce there would be a page marker: $sandbox_line"
echo "$read" | jq -r '.result.text' | grep -q 'page-sees nothing' \
    || fail "the page could see the document nonce, which makes it a marker the page can read and forge"
echo "ok   the document nonce is out of the page's reach and survives between injections"
echo "     $(echo "$sandbox_line" | head -c 120)".

structure=$(structure_now)
echo "$structure" | jq -e '[.result.nodes[] | select(.role == "h1")] | length >= 1' >/dev/null \
    || fail "structure found no heading: $structure"
echo "$structure" | jq -e '[.result.nodes[] | select(.role == "link")] | length >= 1' >/dev/null \
    || fail "structure found no link: $structure"
echo "$structure" | jq -e '.result.note | test("not an accessibility tree")' >/dev/null \
    || fail "structure must say what it is derived from: $structure"
echo "ok   structure returned $(echo "$structure" | jq -r '.result.nodes | length') DOM-derived nodes"

# 2. the page navigates on its own (a new document): the attachment must be over.
wait_for 30 'call "{\"method\":\"status\",\"args\":{}}" | jq -e ".ok == false" >/dev/null' \
    || fail "the attachment survived a new document: $(call '{"method":"status","args":{}}')"
after_nav=$(read_now)
echo "$after_nav" | jq -e '.ok == false' >/dev/null || fail "a read after navigation returned something: $after_nav"
echo "$after_nav" | jq -r .error | grep -q "no tab is attached" || fail "the refusal does not name the attachment: $after_nav"
echo "ok   a new document ended the attachment"

# 3. page two: what a page hides must not come out of it.
two=$(attach_now page-two)
echo "ok   attached again: $two"

read2=$(read_now)
echo "$read2" | jq -e '.result.text | test("UNIQUE-TEXT-TWO")' >/dev/null || fail "the second read missed: $read2"
for secret in PASSWORD-SECRET-alpha CSRF-SECRET-beta EMAIL-SECRET-zeta HIDDEN-VALUE-delta \
              HIDDEN-LINK-SECRET-gamma HIDDEN-ATTR-LINK-SECRET-eta VISIBILITY-HIDDEN-LINK-SECRET-theta; do
    if echo "$read2" | grep -q "$secret"; then fail "read carried $secret out of the page: $read2"; fi
done
echo "ok   read carried none of the hidden values out of the page"

structure2=$(structure_now)
echo "$structure2" | jq -e '[.result.nodes[] | select(.role == "input:password")] | length >= 1' >/dev/null \
    || fail "the password field should still be described, without its contents: $structure2"
echo "$structure2" | jq -e '[.result.nodes[] | select(.role == "input:hidden")] | length == 0' >/dev/null \
    || fail "a hidden input must not be in the outline: $structure2"
for secret in PASSWORD-SECRET-alpha CSRF-SECRET-beta EMAIL-SECRET-zeta HIDDEN-VALUE-delta \
              HIDDEN-LINK-SECRET-gamma HIDDEN-ATTR-LINK-SECRET-eta VISIBILITY-HIDDEN-LINK-SECRET-theta \
              TEXTAREA-SECRET-epsilon; do
    if echo "$structure2" | grep -q "$secret"; then fail "structure carried $secret out of the page: $structure2"; fi
done
echo "ok   structure named $(echo "$structure2" | jq -r '.result.nodes | length') elements and none of their values"

call '{"method":"detach","args":{}}' | jq -e '.ok == true' >/dev/null || fail "detach failed"
after_detach=$(read_now)
echo "$after_detach" | jq -r .error | grep -q "the assistant detached the tab" || fail "detach's reason is not reported: $after_detach"
echo "ok   detach ended the attachment and later reads say so"

# 4. page three: a document with nothing a person can read, and a script with a
#    secret in it. The read must be empty rather than full.
wait_for 40 'call "{\"method\":\"status\",\"args\":{}}" | jq -e ".ok == false" >/dev/null' \
    || fail "the second page never navigated away (harness timing)"
three=$(attach_now page-three)
echo "ok   attached to the empty page: $three"
read3=$(read_now)
echo "$read3" | jq -e '.ok == true' >/dev/null || fail "the empty page could not be read: $read3"
echo "$read3" | jq -e '.result.text == ""' >/dev/null \
    || fail "a page with no visible text must read as empty: $read3"
if echo "$read3" | grep -q "SCRIPT-ONLY-SECRET-zzz"; then fail "the script's text came back with the read: $read3"; fi
echo "ok   an empty-looking document read as empty, and its script's text did not come with it"

# 5. the browser goes away, and the host must go with it.
ps -eo pid,args | grep -- "-contentproc" | grep -oE -- "-parentPid [0-9]+" | awk '{print $2}' \
    | sort -u > "$HOME/parents"
bp=$(comm -13 "$HOME/pids-before" "$HOME/parents" | head -1)
[ -n "$bp" ] || fail "could not find the browser process to stop (harness problem, not the plugin's)"
echo "ok   stopping the browser (pid $bp) and its content processes"
kill -TERM "$bp" 2>/dev/null || true
for p in $(ps -eo pid,args | grep -F -- "-parentPid $bp" | grep -v grep | awk '{print $1}'); do
    kill -TERM "$p" 2>/dev/null || true
done
wait_for 20 "! kill -0 $bp 2>/dev/null" || fail "the browser (pid $bp) did not stop (harness problem, not the plugin's)"
wait_for 40 '! curl -sf --max-time 2 http://127.0.0.1:'"$port"'/health >/dev/null 2>&1' \
    || fail "the host is still answering after the browser died"
echo "ok   the host exited with the browser"

echo "ok   throwaway proof complete (the shipped click + activeTab path is NOT covered by this run)"
