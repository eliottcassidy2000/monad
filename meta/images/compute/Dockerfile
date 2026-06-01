# Compute image — reproducible Python scientific stack for math-quick-compute agents.
# Published by .github/workflows/images.yml to ghcr.io/claude-monad/compute.
#
# Mirrors the libraries the compute agent already uses in eliottcassidy2000/math so that
# `./run_and_save.sh script.py` produces identical results on every node.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
      numpy scipy sympy networkx pandas matplotlib \
      galois more-itertools tqdm

WORKDIR /work
# Agents mount their math checkout at /work and run computation scripts.
CMD ["python3"]
