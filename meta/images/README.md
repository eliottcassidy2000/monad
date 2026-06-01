# meta/images — containerized toolchains

Reproducible build environments so every node produces identical results regardless of host
drift. **Claude itself is not containerized** (it runs native and account-pinned — see the
root CLAUDE.md → Account Architecture); only the *builds agents invoke* run in these images.

| Image | Registry tag | Used by |
|-------|--------------|---------|
| `lean-toolchain/` | `ghcr.io/claude-monad/lean-toolchain` | formalizer (`lake build`) |
| `compute/` | `ghcr.io/claude-monad/compute` | math-quick-compute (python scripts) |

## Build & publish

These are built and pushed by GitHub Actions (`.github/workflows/images.yml`) on any change
under `meta/images/**`, because the operator/bootstrap host has no Docker. To build locally on
a node that does:

```bash
docker build -t ghcr.io/claude-monad/lean-toolchain meta/images/lean-toolchain
docker build -t ghcr.io/claude-monad/compute        meta/images/compute
```

## Version pins

`lean-toolchain` pins `LEAN_VERSION` / `MATHLIB_REV` via build args. Keep them in lockstep
with `claude-monad/math-lean` (`lean-toolchain` + `lakefile.toml`). Bumping there → bump the
build args here → CI republishes the image.

## Use from an agent

Agents don't call `docker run` directly; they go through
[`../execution/run-in-toolchain.sh`](../execution/run-in-toolchain.sh), which mounts the
current checkout at `/work` and runs the build inside the right image.
