# Unified gpmc maintenance

Canonical source: `../gpmc` (repository `Cc-Cece/gpmc`).
The consumer snapshot is generated, not an independently maintained fork.
See the canonical `docs/MAINTENANCE.md` and `INTEGRATION-LOG.md`.

Update explicitly from the canonical checkout, then review and commit all changed
snapshots, manifests, ZIP (desktop) and lock files together:

```sh
python tools/sync_gpmc.py --source ../gpmc
python tools/sync_gpmc.py --check
```

Builds verify the committed content lock offline. No checkout of another client
and no runtime network installation is required. `source_tree_sha256` pins the
actual content; `source_base_commit` is informational when work is uncommitted.
Do not edit vendored gpmc or patch its wire payloads in a platform bridge.

Platform adapters remain owned by this client. Add reusable protocol improvements
in canonical gpmc first, validate there, then explicitly update consumers.
