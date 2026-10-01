# Porting jev's automation graphs to an eidolon plugin

This is the survey and the plan. It records what the old interpreter was, what
the six graphs actually use of it, and how each piece lands in upstream eidolon.
It is a working document for the port: when the README and this disagree about
what ships, the README is right.

## What is being ported

Source: `Minerva/extensions/jev/` (the old extension-host tools) and
`Minerva/jev/` (the Python service they called).

```
old                                         what it was
------------------------------------------  ---------------------------------------------
extensions/jev/graphs/*.json  (6)           state charts: the programs
jev/automation/run.py         (2.7k lines)  the interpreter: a Python generator that yields
                                            "act" (do this tool call) and "escalate" (ask a person)
jev/automation/{graph,guards,options,       validator, guards, menu building, templates,
  template,a11y}.py                         accessibility-tree parsing
jev/server.py                               FastAPI service: `choose` (jevlike), `entail` (openjev),
                                            and the `automation.*` methods run.py hangs off
extensions/jev/tools/run.rn,resume.rn       the act loop: ask the service for the next action,
                                            eidolon::dispatch it, send the result back
extensions/jev/tools/{stop,runs,order,      the run table (in the service's memory) and its verbs
  warrant}.rn
extensions/jev/tools/{choose,entail}.rn     thin calls to the service
```

The architecture is inverted in the port. The old interpreter lived in a service
and *asked* the Rune tool to perform each action. Upstream now has workflows,
which are Rune programs the harness journals and replays, so the interpreter
becomes a library that runs *inside* the workflow and performs each action
itself through `eidolon::tool_call`.

```
old:  eidolon ── jev_run.rn ──service_call──▶ server.py (interpreter)
                    ▲  act: dispatch(tool, input)        │
                    └──────────── result ────────────────┘

new:  eidolon workflow run <jev dir> <graph>
        └─ workflows/<graph>.rn ─ lib/interp.rn ──tool_call──▶ gate ─▶ tools/*.rn
                                       │                         jev_choose, jev_entail ──▶ jev service (Python)
                                       └─ park ──▶ a person
```

## The features the graphs use

Scanned from the six graphs (a one-off script over the JSON, not shipped). A cell
is "the graph uses it".

| feature | wiki-hop | find-related | ctf-juice-recon | triage-linux | triage-wsl | triage-botforge |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| **actions** | | | | | | |
| `tool` (with `into`) | x | x | x | x | x | x |
| `tool.expect` (a `matches` guard) | | | | x | x | x |
| `push` | x | | x | x | x | x |
| `assign` | x | x | | x | x | x |
| `capture` | | x | | | | |
| **guards** | | | | | | |
| `equals` (with `fold`) | x | | | | | |
| `count` (`gte`) | | | | x | x | x |
| `entails` (`threshold`, `window`, `max_chars`) | x | | | x | x | |
| `matches` (as `expect` only) | | | | x | x | x |
| **menu sources** (`meta.choose.from`) | | | | | | |
| `menu` | | | | x | x | x |
| `lines` (`of`, `skip`) | | | | x | x | x |
| `refs` (`roles`, `within`, `url`) | x | | | | | |
| `transitions` | | | | x | x | x |
| **choose options** | | | | | | |
| `exclude`, `max`, `context` | x | | | x | x | x |
| `also` | | | | x | x | x |
| `label` | x | | | | | |
| `prefer` (an `equals` rule) | x | | | | | |
| per-state `floor`, `ask` | x | | | x | x | x |
| **states** | | | | | | |
| flat states, `always`, `final` + `output` | x | x | x | x | x | x |
| nested states, `initial`, `onDone` | | | | x | x | x |
| `entry`, `exit` | x (entry) | x (entry) | x (entry) | x | x | x |
| `history` (shallow) and `#id.a.b` targets | | | | x | x | x |
| `on: PICK / EMPTY / CLEAN / CONTINUE / ABORT` | PICK, EMPTY | | | PICK, CLEAN, CONTINUE, ABORT | same | same |
| `reenter` | x | | | | | |
| root `on: ERROR` | x | x | x | x | x | x |
| **meta.jev** | | | | | | |
| `defaults` (`floor`, `margin`, `visits`) | x | | | x | x | x |
| `budget` (`steps`, `actions`, `escalations`, `wall_s`) | x | x | x | x | x | x |
| `input` (required) | x | x | | | | |
| `warrant`, `requires`, `schema` | x | x | x | x | x | x |

What the interpreter did that **no graph asks for**, and so is not ported:

- guards `contains`, `exists`, `not`, `and`, `or`, `contradicts`; actions `inc`;
  menu `choose.also` beyond fixed items; `margin`/`visits` per state; deep history
- standing orders (`jev_order`), warrants (`jev_warrant`, `warrant.py`), the
  decision log for training (`decisions.py`), the System One chooser
  (`systemone.py`), persisted parks surviving a service restart
- `wall_s` as a budget (see "Limits of the host" below)

A graph that uses any of these is **refused at load**, naming the feature
(`lib/graph.rn`), never run with it ignored. The list is closed on purpose: it is
the six graphs, and nothing else has been verified.

Adjustments to the decision's list: it named guards `count/entails/equals`; the
graphs also use **`matches`** (inside `tool.expect`), `choose.prefer`,
`choose.label`, `choose.from: transitions`, `reenter`, `description`, and the
accessibility-tree parser (`wiki-hop`'s `refs` source and `h1`). All are ported.

## How choose and entail worked

`jev_choose` and `jev_entail` are not language-model calls. Neither is a causal
LM, so neither has a llama.cpp path.

```
jev_choose   jevlike: a one-pass N-way chooser (PyTorch). context + options ->
             one probability per option, in a single forward pass. A 169 KB
             checkpoint (jev/runs/synthetic.pt, vendored) loads at first use.
             {"probs": {label: p}, "best": label}.   Options must be distinct.
jev_entail   openjev: Qwen3.5-4B fine-tuned as a 3-way NLI cross-encoder.
             premise + hypotheses -> contradiction/entailment/neutral each.
             ~9 GB of weights, downloaded separately, ~20 s first load.
             {"results": [{hypothesis, label, scores: {...}}]}
```

Both were served by `jev/server.py` (`POST /call {method, args}`, bearer token)
and called with `eidolon::service_call`. Neither can be rebuilt as an
`ask_model` call without changing what the graphs mean: the graphs' `floor` and
`margin` are calibrated against jevlike's probabilities, and `triage-botforge`
exists *because* the small checkpoint cannot clear a 0.5 floor.

So the port keeps them as **tools that call that service**, over `api_request`
with a token file, the way the `browser` plugin calls its service. The service
is not part of this plugin: it is Python and torch, and it stays in the Minerva
repo (`jev/server.py`). The plugin declares what it needs and the README says how
to start it. What the plugin gives an operator without the service: the
interpreter, `selftest`, and the two graphs that need no scorer
(`find-related`, `ctf-juice-recon`). `entails` guards that cannot reach the
scorer do not pass (a neutral verdict's answer); a chooser that cannot be
reached parks on a person.

## How the old interpreter's pieces land

| old | new |
|---|---|
| `run.py` generator, `yield act` | `lib/interp.rn`: `eidolon::tool_call` inline |
| `yield escalate`, `jev_resume` | `eidolon::park(question)`; resume is `eidolon workflow resume --answer` |
| `template.py`, `guards.py`, `options.py`, `a11y.py`, `graph.py` | `lib/{value,guards,options,obs,graph}.rn` |
| Python `re` (3 patterns) | `lib/regex.rn`: a small engine (a workflow has no regex) |
| `jev_run {graph, input}` | `eidolon workflow run <jev dir> <graph> --args '{...}'` |
| `jev_resume {run, pick}` | `eidolon workflow resume <session> <run> --plugin <jev dir> --answer <n>` |
| `jev_stop {run}` | cancel the `workflow run` process, or answer a park with `stop` |
| `jev_runs` | `ls` of the sessions directory, or `eidolon log` on one; every run is a session |
| `jev_order` | **dropped**: steering is at parks only |
| `jev_warrant`, warrant blocks | **dropped**: the plugin's verbs are vouched (`eidolon plugins trust jev`); other tools are judged per call |
| `graphs/<id>.json` | `graphs/<id>.json`, read through `jev_graph`, pinned by sha256 in `workflows/<id>.rn` |
| `bash` + literal command strings | one tool per fixed command (`jev_os_release`, ...) |
| `wsl.exe --distribution Ubuntu --exec ...` baked into graph text | optional `distro` run argument |
| the decision log, standing orders, restarts | not ported |

### Pinning

A workflow cannot read a file. `workflows/<graph>.rn` asks the plugin's own
`jev_graph` tool for `graphs/<graph>.json` verbatim and refuses to run unless
`sha256(text)` equals the hash written in the workflow. The text is a journaled
step, so a resumed run replays the graph it started with. Editing a graph without
re-pinning fails closed.

### The state log

`jev_mark` is a no-op tool whose *input* is the record `{graph, kind, state, step,
actions}`. The interpreter calls it when a leaf state is entered, a final state is
entered, a person is asked, and when a run ends without a final state. A run's
journal keeps every step's input, so a viewer reads the active node as the last
`jev_mark` step. `jev_graph {graph}` returns the nodes and edges to draw.

## Limits of the host that shape the port

Read from upstream (`crates/rune/src/workflow.rs`, `host.rs`) and checked by
running.

- A workflow gets `tool_call`, `ask_model`, `park`, `json`, `sha256` and the Rune
  default modules. **No regex, no clock, no file read.**
- A run is **replayed** on resume from its journal, so the program must be
  deterministic. Rune objects have unstable key order; the interpreter sorts keys
  wherever order decides anything (the `transitions` menu is in alphabetical event
  order, where the Python one was in document order).
- **200 steps** per run, a ceiling a plugin can lower and not raise. Every tool
  call, scorer call and mark is a step. `wiki-hop` costs about five steps a hop,
  so its 30-hop budget fits; the step cap is the real bound on a long run, and
  `wall_s` is **not enforced** (no clock).
- In Rune, a closure that calls a lib function must be reachable from every
  workflow or the unit does not link, and a closure that uses a captured value
  moves it out on first call. `lib/` therefore has no closures at all: the regex engine is a flat program run
  with an explicit stack (its first draft was continuation-passing and broke on
  exactly this).
- Integers from `len()` are `u64` and `JSON` integers are `i64`; the interpreter
  normalises before comparing.

## Plan

1. **Survey** (this file).
2. **Interpreter**: `lib/*.rn`, `tools/mark.rn`, `workflows/selftest.rn` (a pure
   graph and fixed-input checks), then `find-related` end to end against real
   `grep` and `read`.
3. **Remaining workflows**: one per graph; the command tools; `distro` and `ssh`
   options; each graph run under mock to its first tool step or park.
4. **UI exposure and packaging**: `jev_graph`, the README (Prerequisites, Install,
   Verify, Uninstall), `plugin.rn`, a row in the top-level README, and an install
   from `file://` followed by Verify.
