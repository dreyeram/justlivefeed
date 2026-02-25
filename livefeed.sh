#!/bin/bash
###############################################################################
# livefeed.sh - Zero-Latency Endoscopy Live Feed
#
# Ultra-low-latency GStreamer pipeline for HDMI USB capture cards.
# Renders directly to the display hardware — no desktop environment needed.
#
# Works in CONSOLE MODE (no X11/Wayland required).
# Uses KMS/DRM for direct display output = absolute minimum latency.
###############################################################################

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"
WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FRAMERATE="${FRAMERATE:-60}"
FORMAT="${FORMAT:-image/jpeg}"         # MJPG for low USB bandwidth
SINK="${SINK:-auto}"                   # auto | kms | fb | drm
FULLSCREEN="${FULLSCREEN:-true}"
# ─────────────────────────────────────────────────────────────────────────────

log() { echo "[livefeed] $(date '+%H:%M:%S') $*"; }

# ─── Wait for video device ──────────────────────────────────────────────────
wait_for_device() {
    local retries=0
    while [ ! -e "$VIDEO_DEVICE" ]; do
        retries=$((retries + 1))
        if [ $retries -gt 60 ]; then
            log "ERROR: $VIDEO_DEVICE not found after 60s. Exiting."
            exit 1
        fi
        log "Waiting for $VIDEO_DEVICE ... ($retries/60)"
        sleep 1
    done
    log "Device $VIDEO_DEVICE is ready."
}

# ─── Wait for DRM/KMS to be ready ───────────────────────────────────────────
wait_for_drm() {
    local retries=0
    while [ ! -e /dev/dri/card0 ] && [ ! -e /dev/dri/card1 ]; do
        retries=$((retries + 1))
        if [ $retries -gt 30 ]; then
            log "WARNING: No DRM device found after 30s, continuing anyway..."
            return
        fi
        log "Waiting for DRM device ... ($retries/30)"
        sleep 1
    done
    log "DRM device ready."
}

# ─── Configure V4L2 device ──────────────────────────────────────────────────
configure_device() {
    log "Configuring $VIDEO_DEVICE → ${WIDTH}x${HEIGHT}@${FRAMERATE}fps MJPG"

    # Set MJPG format explicitly
    v4l2-ctl -d "$VIDEO_DEVICE" \
        --set-fmt-video=width="$WIDTH",height="$HEIGHT",pixelformat=MJPG \
        2>/dev/null || true

    # Set framerate
    v4l2-ctl -d "$VIDEO_DEVICE" \
        --set-parm="$FRAMERATE" \
        2>/dev/null || true
}

# ─── Find the correct DRM connector ─────────────────────────────────────────
find_drm_connector() {
    # Try to find HDMI connector ID from DRM
    local card=""
    for c in /dev/dri/card*; do
        if [ -e "$c" ]; then
            card="$c"
            break
        fi
    done

    if [ -z "$card" ]; then
        echo ""
        return
    fi

    # Try common connector IDs for HDMI on Pi
    # Connector 32 is often HDMI-A-1 on Pi 4/5
    for conn_id in 32 33 34 35 36 37 38 39 40 41 42 43 44 45; do
        echo "$conn_id"
        return
    done

    echo ""
}

# ─── Build the GStreamer pipeline ────────────────────────────────────────────
build_pipeline() {
    log "Detecting display output method..."

    # Source: V4L2 with minimal buffering
    local src="v4l2src device=${VIDEO_DEVICE} io-mode=mmap do-timestamp=true"

    # Caps: MJPG from capture card
    local caps="${FORMAT},width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE}/1"

    # Decoder: JPEG decode (single step, very fast)
    local decoder="jpegdec"

    # Queue: Absolute minimum buffering - drop old frames instantly
    local queue="queue max-size-buffers=1 max-size-time=0 max-size-bytes=0 leaky=downstream"

    # Video convert
    local convert="videoconvert"

    # Scale to match display (in case resolutions differ)
    local scale="videoscale"

    # ─── Determine the best sink for CONSOLE mode ────────────────────────
    local sink_element=""

    if [ "$SINK" != "auto" ]; then
        case "$SINK" in
            kms|drm)
                sink_element="kmssink sync=false"
                ;;
            fb)
                sink_element="fbdevsink sync=false"
                ;;
            *)
                sink_element="$SINK sync=false"
                ;;
        esac
        log "Using forced sink: $sink_element"
    else
        # Auto-detect: Priority for console (no X11) mode
        # 1. kmssink  - Direct KMS/DRM output (BEST for console mode)
        # 2. fbdevsink - Framebuffer (works everywhere)

        if gst-inspect-1.0 kmssink &>/dev/null && [ -e /dev/dri/card0 -o -e /dev/dri/card1 ]; then
            sink_element="kmssink sync=false"
            log "Using sink: kmssink (direct KMS/DRM - lowest latency)"
        elif gst-inspect-1.0 fbdevsink &>/dev/null && [ -e /dev/fb0 ]; then
            sink_element="fbdevsink sync=false"
            log "Using sink: fbdevsink (framebuffer)"
        else
            # Fallback: try autovideosink
            sink_element="autovideosink sync=false"
            log "Using sink: autovideosink (fallback)"
        fi
    fi

    # The complete pipeline
    echo "${src} ! ${caps} ! ${queue} ! ${decoder} ! ${convert} ! ${scale} ! ${sink_element}"
}

# ─── Disable screen blanking ────────────────────────────────────────────────
disable_blanking() {
    # Disable console blanking
    if [ -w /sys/module/kernel/parameters/consoleblank ]; then
        echo 0 > /sys/module/kernel/parameters/consoleblank 2>/dev/null || true
    fi
    setterm -blank 0 -powerdown 0 2>/dev/null || true

    # Disable DPMS if X is somehow running
    if command -v xset &>/dev/null && [ -n "${DISPLAY:-}" ]; then
        xset s off 2>/dev/null || true
        xset -dpms 2>/dev/null || true
        xset s noblank 2>/dev/null || true
    fi

    # Hide the console cursor so it doesn't appear over the video
    echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null || true
    setterm --cursor off 2>/dev/null || true

    # Clear the console so no text appears behind/around the video
    clear 2>/dev/null || true
    echo -ne "\033[9;0]" 2>/dev/null || true  # disable console blanking via VT
}

# ─── Cleanup on exit ────────────────────────────────────────────────────────
cleanup() {
    log "Shutting down live feed..."
    kill "$GST_PID" 2>/dev/null || true
    wait "$GST_PID" 2>/dev/null || true
    # Restore console cursor
    setterm --cursor on 2>/dev/null || true
    log "Done."
}
trap cleanup EXIT INT TERM

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    log "═══════════════════════════════════════════════════"
    log "  Zero-Latency Endoscopy Live Feed"
    log "  Device: $VIDEO_DEVICE"
    log "  Resolution: ${WIDTH}x${HEIGHT}@${FRAMERATE}fps"
    log "  Mode: CONSOLE (direct hardware display)"
    log "═══════════════════════════════════════════════════"

    wait_for_device
    wait_for_drm
    configure_device
    disable_blanking

    local pipeline
    pipeline=$(build_pipeline)
    log "Pipeline: gst-launch-1.0 -e $pipeline"

    # Launch GStreamer with realtime priority if possible
    if command -v chrt &>/dev/null; then
        log "Launching with realtime scheduling (FIFO priority 50)..."
        chrt -f 50 gst-launch-1.0 -e $pipeline &
    else
        gst-launch-1.0 -e $pipeline &
    fi
    GST_PID=$!

    log "GStreamer PID: $GST_PID"
    log "Live feed is running."

    # Wait for GStreamer process
    wait "$GST_PID"
}

main "$@"
