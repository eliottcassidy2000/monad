#!/bin/bash
set -e

echo "[livestream] Starting nginx-rtmp..."
nginx -g "daemon on;"

echo "[livestream] Starting dashboard on :8080..."
cd /app
exec python3 dashboard.py
