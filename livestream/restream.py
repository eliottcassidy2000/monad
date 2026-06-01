#!/usr/bin/env python3
"""
restream.py — FFmpeg-based stream compositor and restreamer.

Manages FFmpeg processes that:
1. Read from nginx-rtmp ingest streams
2. Composite multiple inputs into a single output
3. Push the composite to YouTube, Twitch, and nginx-rtmp /composite

Controlled via the dashboard's REST API (start/stop/switch sources).
"""

import subprocess
import threading
import json
import time
import os
import signal
import sys
from pathlib import Path

STATE_FILE = os.environ.get("RESTREAM_STATE", "/tmp/restream-state.json")
RTMP_BASE = os.environ.get("RTMP_BASE", "rtmp://127.0.0.1:1935")

class RestreamEngine:
    def __init__(self):
        self.processes = {}      # platform -> subprocess.Popen
        self.compositor = None   # compositor subprocess
        self.lock = threading.Lock()
        self.state = {
            "active_sources": [],
            "layout": "single",  # single, side-by-side, pip
            "outputs": {},       # platform -> {enabled, key, url}
            "compositor_running": False,
            "stats": {}
        }
        self._load_state()

    def _load_state(self):
        if os.path.exists(STATE_FILE):
            try:
                with open(STATE_FILE) as f:
                    saved = json.load(f)
                # Restore config but not runtime state
                self.state["outputs"] = saved.get("outputs", {})
                self.state["layout"] = saved.get("layout", "single")
            except Exception:
                pass

    def _save_state(self):
        try:
            with open(STATE_FILE, "w") as f:
                json.dump(self.state, f, indent=2)
        except Exception:
            pass

    def get_status(self):
        """Return current engine status."""
        with self.lock:
            status = dict(self.state)
            status["active_processes"] = list(self.processes.keys())
            status["compositor_running"] = self.compositor is not None and self.compositor.poll() is None
            return status

    def set_output(self, platform, url, key, enabled=True):
        """Configure an output platform."""
        with self.lock:
            self.state["outputs"][platform] = {
                "url": url,
                "key": key,
                "enabled": enabled
            }
            self._save_state()

    def remove_output(self, platform):
        """Remove an output platform."""
        self.stop_output(platform)
        with self.lock:
            self.state["outputs"].pop(platform, None)
            self._save_state()

    def set_layout(self, layout):
        """Set compositor layout: single, side-by-side, pip."""
        with self.lock:
            self.state["layout"] = layout
            self._save_state()
        # Restart compositor with new layout if running
        if self.compositor and self.compositor.poll() is None:
            self.restart_compositor()

    def set_sources(self, sources):
        """Set which stream keys are active in the composite."""
        with self.lock:
            self.state["active_sources"] = sources
            self._save_state()
        if self.compositor and self.compositor.poll() is None:
            self.restart_compositor()

    def _build_compositor_cmd(self):
        """Build the FFmpeg command for compositing active sources."""
        sources = self.state["active_sources"]
        layout = self.state["layout"]

        if not sources:
            return None

        inputs = []
        for src in sources:
            inputs.extend(["-i", f"{RTMP_BASE}/live/{src}"])

        if len(sources) == 1 or layout == "single":
            # Single source — just passthrough
            cmd = [
                "ffmpeg", "-y",
                "-rw_timeout", "5000000",
                *inputs,
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-b:v", "4500k",
                "-maxrate", "4500k",
                "-bufsize", "9000k",
                "-c:a", "aac",
                "-b:a", "160k",
                "-ar", "44100",
                "-g", "60",
                "-f", "flv",
                f"{RTMP_BASE}/composite/live"
            ]
        elif layout == "side-by-side" and len(sources) >= 2:
            # Side by side — two sources horizontally
            cmd = [
                "ffmpeg", "-y",
                "-rw_timeout", "5000000",
                *inputs,
                "-filter_complex",
                "[0:v]scale=960:540[left];[1:v]scale=960:540[right];"
                "[left][right]hstack=inputs=2[out]",
                "-map", "[out]",
                "-map", "0:a?",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-b:v", "4500k",
                "-maxrate", "4500k",
                "-bufsize", "9000k",
                "-c:a", "aac",
                "-b:a", "160k",
                "-ar", "44100",
                "-g", "60",
                "-f", "flv",
                f"{RTMP_BASE}/composite/live"
            ]
        elif layout == "pip" and len(sources) >= 2:
            # Picture-in-picture — main with small overlay
            cmd = [
                "ffmpeg", "-y",
                "-rw_timeout", "5000000",
                *inputs,
                "-filter_complex",
                "[0:v]scale=1920:1080[main];"
                "[1:v]scale=480:270[pip];"
                "[main][pip]overlay=W-w-20:H-h-20[out]",
                "-map", "[out]",
                "-map", "0:a?",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-b:v", "4500k",
                "-maxrate", "4500k",
                "-bufsize", "9000k",
                "-c:a", "aac",
                "-b:a", "160k",
                "-ar", "44100",
                "-g", "60",
                "-f", "flv",
                f"{RTMP_BASE}/composite/live"
            ]
        else:
            # Fallback: first source only
            cmd = [
                "ffmpeg", "-y",
                "-rw_timeout", "5000000",
                "-i", f"{RTMP_BASE}/live/{sources[0]}",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-b:v", "4500k",
                "-c:a", "aac",
                "-b:a", "160k",
                "-g", "60",
                "-f", "flv",
                f"{RTMP_BASE}/composite/live"
            ]

        return cmd

    def start_compositor(self):
        """Start the FFmpeg compositor process."""
        with self.lock:
            if self.compositor and self.compositor.poll() is None:
                return {"error": "Compositor already running"}

            cmd = self._build_compositor_cmd()
            if not cmd:
                return {"error": "No active sources configured"}

            try:
                self.compositor = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE
                )
                self.state["compositor_running"] = True
                return {"ok": True, "pid": self.compositor.pid}
            except Exception as e:
                return {"error": str(e)}

    def stop_compositor(self):
        """Stop the FFmpeg compositor."""
        with self.lock:
            if self.compositor and self.compositor.poll() is None:
                self.compositor.send_signal(signal.SIGINT)
                try:
                    self.compositor.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.compositor.kill()
            self.compositor = None
            self.state["compositor_running"] = False
            return {"ok": True}

    def restart_compositor(self):
        """Restart compositor with current settings."""
        self.stop_compositor()
        time.sleep(1)
        return self.start_compositor()

    def start_output(self, platform):
        """Start restreaming to a platform."""
        with self.lock:
            if platform in self.processes and self.processes[platform].poll() is None:
                return {"error": f"{platform} already streaming"}

            config = self.state["outputs"].get(platform)
            if not config:
                return {"error": f"No config for {platform}"}

            url = config["url"]
            key = config["key"]
            dest = f"{url}/{key}"

            cmd = [
                "ffmpeg", "-y",
                "-rw_timeout", "5000000",
                "-i", f"{RTMP_BASE}/composite/live",
                "-c", "copy",
                "-f", "flv",
                dest
            ]

            try:
                proc = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE
                )
                self.processes[platform] = proc
                return {"ok": True, "platform": platform, "pid": proc.pid}
            except Exception as e:
                return {"error": str(e)}

    def stop_output(self, platform):
        """Stop restreaming to a platform."""
        with self.lock:
            proc = self.processes.get(platform)
            if proc and proc.poll() is None:
                proc.send_signal(signal.SIGINT)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
            self.processes.pop(platform, None)
            return {"ok": True, "platform": platform}

    def start_all(self):
        """Start compositor and all enabled outputs."""
        result = self.start_compositor()
        if "error" in result:
            return result
        time.sleep(2)  # Let compositor stabilize
        results = {"compositor": result}
        for platform, config in self.state["outputs"].items():
            if config.get("enabled", True):
                results[platform] = self.start_output(platform)
        return results

    def stop_all(self):
        """Stop everything."""
        results = {}
        for platform in list(self.processes.keys()):
            results[platform] = self.stop_output(platform)
        results["compositor"] = self.stop_compositor()
        return results

    def cleanup(self):
        """Clean up all processes on shutdown."""
        self.stop_all()


# Singleton engine instance
engine = RestreamEngine()
