# tests/browser

The browser tools' answer when the service is not running.

```bash
t=$(mktemp -d)
HOME=$t XDG_CONFIG_HOME=$t/cfg XDG_STATE_HOME=$t/state XDG_DATA_HOME=$t/data \
  bash tests/browser/run.sh
```

The plugin is copied from the repo unchanged into the throwaway config, vouched for there,
and given the token file its verbs resolve — so the call gets as far as the dial. The test
refuses to run at all if something answers on `127.0.0.1:8090`: it is about a service that
is not there, and a live one would be navigated. It starts nothing, fetches nothing, and
makes no network request beyond the loopback dial that fails.

`service-down.rn` is the workflow it runs (copied into the temp plugin's `workflows/`;
it is not shipped in the plugin). It checks every verb that reaches the service —
`browser_open`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_read`,
`browser_back` — answers with the command that starts it, `eidolon plugins service start
browser`, rather than a bare connection refusal.
