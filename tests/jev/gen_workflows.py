#!/usr/bin/env python3
"""Write the thin per-graph workflows from the table below.

Every graph has one workflow in workflows/<id>.rn, and they differ only in the
graph id, the doc comment, the declared params, the approval and the defaults.
The interpreter is lib/interp.rn; a workflow is the front door and the pin.
The pin line is left alone if the file exists (tests/jev/pin.sh owns it).

    python3 tests/jev/gen_workflows.py          write the files
    python3 tests/jev/gen_workflows.py --check  exit 1 if one differs (ignoring the pin)
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WF = os.path.join(HERE, "..", "..", "jev", "workflows")
ZERO = "sha256:" + "0" * 64

TAIL = """//
// The graph is read through `jev_graph` and hash-checked against PIN before it
// runs; change the graph and the pin together (tests/jev/pin.sh).

const GRAPH = "%(id)s";
const PIN = "%(pin)s";

pub fn workflow() {
    #{
        name: "%(id)s",
        description: "%(desc)s",
        approval: "%(approval)s",
        params: #{
            "type": "object",
            "properties": #{
%(props)s
            },%(required)s
        },
    }
}

pub async fn run(args) {
    run_pinned(GRAPH, PIN, %(input)s).await
}
"""

TRIAGE_PROPS = [
    ("distro", "string", "Run the commands inside this WSL distribution."),
    ("ssh", "string", "Run the commands on this host over ssh (user@host or host; key-based)."),
    ("ssh_port", "integer", "The ssh port, with ssh. Default 22."),
]

WORKFLOWS = [
    dict(
        id="wiki-hop",
        approval="mutating",
        desc="Reach a target Wikipedia article from a start article by following links in the browser plugin, a chooser scoring the links on each page. Parks on a person when the chooser is unsure. Needs the browser plugin and the jev service.",
        props=[
            ("start", "string", "The article to start from, as it appears in the URL after /wiki/ (Cat, Ancient_Egypt)."),
            ("goal", "string", "The title of the article to reach."),
        ],
        required=["start", "goal"],
        input="args",
        head="""// jev/workflows/wiki-hop.rn -- run the `wiki-hop` graph (graphs/wiki-hop.json).
//
//   eidolon workflow run <plugin dir> wiki-hop --args '{"start":"Cat","goal":"Egypt"}'
//
// Opens the start article and follows article links toward the goal, one link at a
// time, until the page's title or heading is the goal (exact, or an entailment of
// "this is the article about <goal>"). Each hop: snapshot the page, ask the chooser
// to score the links, click the best; a link the chooser is unsure about parks the
// run on a person (`eidolon workflow resume ... --answer <n>`).
//
// It drives the browser plugin (`browser_open`, `browser_snapshot`, `browser_click`,
// `browser_back`), confined to https://en.wikipedia.org, and needs the jev service
// for `jev_choose` and `jev_entail` (README, Prerequisites). A hop costs about five
// steps of the host's 200-step cap, so a run is bounded at roughly thirty hops.
""",
    ),
    dict(
        id="ctf-juice-recon",
        approval="read_only",
        desc="Read-only recon of a local OWASP Juice Shop lab at 127.0.0.1:3001: its HTTP headers and robots.txt. Two fixed curl commands; optionally run inside a WSL distro.",
        props=[("distro", "string", "Run the curls inside this WSL distribution. Omit when the lab listens on this machine.")],
        required=[],
        input="with_defaults(args, #{})",
        head="""// jev/workflows/ctf-juice-recon.rn -- run the `ctf-juice-recon` graph (graphs/ctf-juice-recon.json).
//
//   eidolon workflow run <plugin dir> ctf-juice-recon
//   eidolon workflow run <plugin dir> ctf-juice-recon --args '{"distro":"Ubuntu"}'
//
// Reads the response headers and robots.txt of an OWASP Juice Shop lab listening
// on 127.0.0.1:3001, with two fixed read-only curl commands (`jev_juice_headers`,
// `jev_juice_robots`), and reports both as notes. No chooser, no model. With
// `distro` the curls run inside that WSL distribution (where the lab listens);
// without it, on this machine. Local lab only: the URL is in the tools, not an
// argument.
""",
    ),
    dict(
        id="triage-linux",
        approval="read_only",
        desc="Triage an unfamiliar Linux box with a fixed menu of read-only commands, a chooser picking each next one: what it is, what it exposes, what is running, what looks out of place. Here by default; distro or ssh to run elsewhere. Needs the jev service.",
        props=TRIAGE_PROPS,
        required=[],
        input="with_defaults(args, #{})",
        head="""// jev/workflows/triage-linux.rn -- run the `triage-linux` graph (graphs/triage-linux.json).
//
//   eidolon workflow run <plugin dir> triage-linux
//   eidolon workflow run <plugin dir> triage-linux --args '{"ssh":"user@host"}'
//
// What is this box, what does it expose, what is running, and does anything look
// out of place -- from a fixed menu of read-only commands, each its own vouched
// tool (`jev_os_release`, `jev_uname`, ... `jev_processes`). The chooser picks the
// next command; an NLI guard ends a question early when its answer is already
// known. Parks on a person when the chooser is unsure or unreachable. Needs the jev
// service (README, Prerequisites).
//
// Where the commands run is an argument: here by default, `distro` for a WSL
// distribution, `ssh` (and `ssh_port`) for another host.
""",
    ),
    dict(
        id="triage-wsl",
        approval="read_only",
        desc="Triage a WSL distribution (Ubuntu by default) with a fixed menu of read-only commands run through wsl.exe, a chooser picking each next one. Needs a Windows host and the jev service.",
        props=[("distro", "string", "The WSL distribution. Default Ubuntu.")],
        required=[],
        input='with_defaults(args, #{ distro: "Ubuntu" })',
        head="""// jev/workflows/triage-wsl.rn -- run the `triage-wsl` graph (graphs/triage-wsl.json).
//
//   eidolon workflow run <plugin dir> triage-wsl
//   eidolon workflow run <plugin dir> triage-wsl --args '{"distro":"Debian"}'
//
// triage-linux run inside a WSL distribution (Ubuntu unless `distro` says
// otherwise): the same commands through `wsl.exe -d <distro> -e bash -lc ...`, so a
// Windows host triages its own Linux side without the host shell in between. Needs
// wsl.exe, so a Windows host, and the jev service (README, Prerequisites).
""",
    ),
    dict(
        id="triage-botforge",
        approval="read_only",
        desc="Read-only recon of the BotForge range guest over ssh with a fixed menu of commands, the chooser's pick always taken (no confidence floor, no NLI). ssh defaults to mford@127.0.0.1 port 2222. Needs the jev service for jev_choose.",
        props=[
            ("ssh", "string", "The host to triage over ssh. Default mford@127.0.0.1."),
            ("ssh_port", "integer", "The ssh port. Default 2222."),
        ],
        required=[],
        input='with_defaults(args, #{ ssh: "mford@127.0.0.1", ssh_port: 2222 })',
        head="""// jev/workflows/triage-botforge.rn -- run the `triage-botforge` graph (graphs/triage-botforge.json).
//
//   eidolon workflow run <plugin dir> triage-botforge
//   eidolon workflow run <plugin dir> triage-botforge --args '{"ssh":"user@host","ssh_port":22}'
//
// triage-linux for an unattended run on a small chooser: no NLI guards, floor and
// margin 0, so the chooser's pick is always taken and a run never parks on low
// confidence. The commands are the same nine read-only recon commands; they run
// over ssh on the BotForge range guest (mford@127.0.0.1, port 2222) unless `ssh`
// and `ssh_port` say otherwise. Nothing it runs can change the Aeacus score. Needs
// the jev service for `jev_choose` (README, Prerequisites), not `jev_entail`.
""",
    ),
]


def render(w, pin):
    props = ",\n".join(
        '                "%s": #{ "type": "%s", "description": "%s" }' % (n, t, d.replace('"', '\\"'))
        for n, t, d in w["props"]
    )
    props += ","
    required = ""
    if w["required"]:
        required = '\n            "required": [%s],' % ", ".join('"%s"' % r for r in w["required"])
    return w["head"] + TAIL % dict(
        id=w["id"], pin=pin, desc=w["desc"], approval=w["approval"],
        props=props, required=required, input=w["input"],
    )


def main():
    check = "--check" in sys.argv
    bad = False
    for w in WORKFLOWS:
        path = os.path.join(WF, w["id"] + ".rn")
        have = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        pin = ZERO
        if have:
            m = re.search(r'^const PIN = "(sha256:[0-9a-f]+)";$', have, re.M)
            if m:
                pin = m.group(1)
        want = render(w, pin)
        if have == want:
            print("ok     " + w["id"])
        elif check:
            print("STALE  " + w["id"], file=sys.stderr)
            bad = True
        else:
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(want)
            print("wrote  " + w["id"])
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
