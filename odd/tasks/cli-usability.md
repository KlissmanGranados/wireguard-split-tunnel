# CLI usability improvements for vpn-cli.sh

Objective: implement the 13 usability improvements proposed for `vpn-cli.sh`. Branch: `feat/cli-usability`. Delivery: no commits (user did not authorize). Test runner: none; checks are `bash -n` plus stubbed runs (fake `nmcli` on PATH, `WG_SPLIT_HOME` in a `mktemp -d` dir).

## Specs

- S1 (item 1): Changing the connection name (or interface) must not orphan the existing NetworkManager connection. When a connection with the old name exists, offer: rename it in NM (`nmcli connection modify OLD connection.id NEW`), delete the old one, or keep it. Interface changes are flagged as pending until re-apply.
- S2 (item 2): Warn about unapplied changes. On successful apply, record a snapshot (applied settings + sha256 of `domains.txt` + source `.conf` name) in `generated/.applied`. `status`/menu show `pending changes — run apply` when current state differs. Toggling twice back to the applied value is NOT pending.
- S3 (item 3): `import` subcommand and menu `i` share one function: overwrite prompt when interactive (refuse without `--force` when stdin is not a TTY), and select the imported `.conf`.
- S4 (item 4): Non-interactive `set KEY VALUE` for name, iface, resolver, discover (on/off), autoconnect (on/off), reusing `valid_*`. Name change triggers S1 logic.
- S5 (item 5): `edit` / `domains` opens `${VISUAL:-${EDITOR:-nano}} domains.txt`; afterwards, if interactive and content changed, ask "Apply now? [y/N]".
- S6 (item 6): `verify` runs `ip route get` for the first resolvable domain in `domains.txt` (expect the WireGuard iface) and for a control host outside the list (expect a non-WireGuard iface); prints ✓/✗ per check; non-zero exit on failure.
- S7 (item 7): `status` additionally shows: number of `AllowedIPs` entries in the generated config, last generation time, tunnel IP when active, and the S2 pending warning.
- S8 (item 8): `apply` accepts `--dry-run`, `--verbose`, `--refresh-discovery` and passes them to `update-split-tunnel.sh`; `--dry-run` skips the NetworkManager apply step.
- S9 (item 9): `doctor` checks `nmcli`, `dig`, `curl`, `jq`, `ip`, and the helper scripts; prints what is lost when each is missing; exit non-zero only if a required tool (`nmcli`, helper scripts) is missing.
- S10 (item 10): Menu uses mnemonic letters instead of 1–9 (no key collisions).
- S11 (item 11): `toggle` connects if inactive, disconnects if active.
- S12 (item 12): Help comes from a `usage()` heredoc, not `sed` on line numbers; covers every subcommand.
- S13 (item 13): Bash completion file `completions/vpn-cli.bash` completing subcommands, `set` keys/values, and `.conf` names for `use`. README documents all new commands and how to source the completion.

## Tasks

| ID | Specs | Route | Status |
|----|-------|-------|--------|
| T1 | S1, S2, S3, S12 | delegated (phase-orchestrator) | done (stubbed checks; apply end-to-end not run) |
| T2 | S4, S5, S8, S11 | delegated (phase-orchestrator) | done (stubbed checks; TTY prompt in edit not exercised) |
| T3 | S6, S7, S9 | delegated (phase-orchestrator) | done (stubbed checks; verify not run on live tunnel) |
| T4 | S10, S13 | delegated (phase-orchestrator) | done (stubbed checks) |

## Log

- L1 (2026-11-26): "implementa todo /phase-orchestrator" — referring to the 13 usability proposals for vpn-cli.sh from the previous turn.
