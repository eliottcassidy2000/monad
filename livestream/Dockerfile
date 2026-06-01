# Multi-stage: nginx-rtmp + Python dashboard + FFmpeg in one container
FROM alpine:3.19 AS base

# Install nginx with RTMP module, FFmpeg, Python
RUN apk add --no-cache \
    nginx-mod-rtmp \
    ffmpeg \
    python3 \
    py3-pip \
    py3-flask \
    py3-requests \
    curl \
    bash

# Create directories
RUN mkdir -p /tmp/hls /tmp/hls-composite /app /var/log/nginx

# Copy nginx config
COPY nginx.conf /etc/nginx/nginx.conf

# Copy application
COPY dashboard.py restream.py requirements.txt /app/

# Install Python deps (if not available via apk)
RUN pip3 install --break-system-packages --no-cache-dir -r /app/requirements.txt 2>/dev/null || true

# Startup script
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 1935 8080 8088

WORKDIR /app
CMD ["/app/entrypoint.sh"]
