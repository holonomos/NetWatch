# Contributing to NetWatch

Thanks for taking a look. NetWatch is a config-generation pipeline first and a
running fabric second: almost everything is derived from a single source of
truth, so the golden rule is **edit the source, regenerate the output — never
hand-edit generated files**.

## Single source of truth

`topology.yml` defines every node, link, ASN, IP address, and protocol timer.
All FRR configs, the Prometheus/Grafana/Loki stack config, and several fabric
shell scripts are rendered from it by `generator/generate.py` using Jinja2
templates under `generator/templates/`.

## Regenerating config

After changing `topology.yml` (or any template), regenerate:

```bash
make generate          # convenience wrapper
# or, equivalently:
python3 generator/generate.py
```

This rewrites:

- `generated/` — FRR, Prometheus, Grafana, Loki, and dnsmasq config (git-ignored).
- Five scripts in `scripts/fabric/`: `setup-bridges.sh`, `setup-frr-links.sh`,
  `setup-server-links.sh`, `status.sh`, and `teardown.sh`.

**Do not hand-edit any of those.** The five generated scripts carry a
`DO NOT HAND-EDIT` header and are produced from
`generator/templates/scripts/*.j2`. To change their behavior, edit the matching
`.j2` template and re-run `generate.py`. The remaining `scripts/fabric/*.sh`
(the `configure-*.sh`, `setup-evpn.sh`, and `evpn-metrics-collector.sh`) are
handwritten and may be edited directly.

## Validation

There is no CI pipeline. Before opening a PR, run the static checks locally:

```bash
python3 generator/generate.py     # must exit 0 and leave a clean tree
bash -n scripts/**/*.sh           # syntax-check shell scripts (handwritten and generated)
```

Booting the fabric (`make up`) requires a Linux host with libvirt/KVM and the
golden box already baked; see `docs/RUNBOOK.md`.

## Style

- Shell: handwritten scripts use `#!/usr/bin/env bash` and `set -euo pipefail`
  where safe.
- A repo-root `.editorconfig` defines indentation and whitespace conventions.
- Keep documentation honest. The one known data-plane limitation is documented
  in `docs/KNOWN-ISSUES.md`; please don't paper over it.
