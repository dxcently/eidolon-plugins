# tests/websearch

The websearch tool's offline checks: its answer with no grant, and its parsing over canned replies.

```bash
t=$(mktemp -d)
HOME=$t XDG_CONFIG_HOME=$t/cfg XDG_STATE_HOME=$t/state XDG_DATA_HOME=$t/data \
  bash tests/websearch/run.sh
```

`guard.sh` refuses unless HOME and XDG_CONFIG_HOME are temp directories. The plugin is
copied unchanged into the throwaway config and vouched for there. Nothing is granted, and
nothing reaches the network.

- `no-grant.rn`: the call without the `secret:ollama` grant stops at the grant check and
  names it. An empty query is refused before the endpoint is named.
- `parse-cases.rn`: canned replies (good, no `results`, items missing fields, non-JSON,
  HTTP 500, non-list results, zero results) and `max_results` of each type, through the
  parsing functions. Those functions sit between `// parse:begin` and `// parse:end` in
  `tools/search.rn`, and run.sh appends them to the test workflow, so the test runs the
  shipped bytes.

Not covered here: a successful search against Ollama. The endpoint is `https://ollama.com`,
fixed in the tool, and the repo's tests make no call to it.
