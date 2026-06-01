# Lean toolchain image — reproducible Lean 4 + Mathlib builds for formalizer agents.
# Published by .github/workflows/images.yml to ghcr.io/claude-monad/lean-toolchain.
#
# The image ships elan + the pinned Lean toolchain and warms the Mathlib build cache so
# agent builds are fast and identical on every node. Bump LEAN/MATHLIB in lockstep with
# claude-monad/math-lean (lean-toolchain + lakefile.toml).
FROM ubuntu:24.04

ARG LEAN_VERSION=v4.30.0
ARG MATHLIB_REV=v4.30.0

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl git ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

# elan (Lean toolchain manager) + the pinned toolchain
ENV ELAN_HOME=/root/.elan
ENV PATH=$ELAN_HOME/bin:$PATH
RUN curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
      | sh -s -- -y --default-toolchain "leanprover/lean4:${LEAN_VERSION}"

# Warm the Mathlib cache: build a throwaway project that requires the pinned Mathlib and
# pull the prebuilt oleans, so node-side `lake build` does not recompile Mathlib.
WORKDIR /opt/warm
RUN printf 'name = "warm"\n\n[[require]]\nname = "mathlib"\nscope = "leanprover-community"\ngit = "https://github.com/leanprover-community/mathlib4.git"\nrev = "%s"\n' "${MATHLIB_REV}" > lakefile.toml \
    && echo "leanprover/lean4:${LEAN_VERSION}" > lean-toolchain \
    && lake update >/dev/null 2>&1 || true \
    && lake exe cache get >/dev/null 2>&1 || true

WORKDIR /work
# Agents mount their checkout at /work and run e.g. `lake exe cache get && lake build`.
CMD ["bash"]
