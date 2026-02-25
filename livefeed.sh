#!/bin/bash
###############################################################################
# livefeed.sh - Zero-Latency Endoscopy Live Feed
#
# Ultra-low-latency GStreamer pipeline for HDMI USB capture cards.
# Renders directly to the display hardware for glass-to-glass minimum latency.
###############################################################################

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"
WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FRAMERATE="${FRAMERATE:-60}"
FORMAT="${FORMAT:-image/jpeg}"         # MJPG for low USB bandwidth
SINK="${SINK:-auto}"                   # auto | kms | gl | fb | x11
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

# ─── Detect best available video sink ────────────────────────────────────────
detect_sink() {
    if [ "$SINK" != "auto" ]; then
        echo "$SINK"
        return
    fi

    # Priority order for lowest latency:
    # 1. kmssink    - Direct KMS/DRM, bypasses compositor entirely (lowest latency)
    # 2. glimagesink - OpenGL, very fast on Pi with GPU
    # 3. fbdevsink  - Direct framebuffer
    # 4. ximagesink - X11 fallback
    # 5. autovideosink - GStreamer auto-detect

    if gst-inspect-1.0 kmssink &>/dev/null; then
        echo "kms"
    elif gst-inspect-1.0 glimagesink &>/dev/null; then
        echo "gl"
    elif gst-inspect-1.0 fbdevsink &>/dev/null; then
        echo "fb"
    elif gst-inspect-1.0 ximagesink &>/dev/null; then
        echo "x11"
    else
        echo "autovideosink"
    fi
}

# ─── Build the GStreamer pipeline ────────────────────────────────────────────
build_pipeline() {
    local sink_type
    sink_type=$(detect_sink)
    log "Using sink: $sink_type"

    # Source: V4L2 with minimal buffering
    local src="v4l2src device=${VIDEO_DEVICE} io-mode=mmap do-timestamp=true"

    # Caps: MJPG from capture card
    local caps="${FORMAT},width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE}/1"

    # Decoder: JPEG decode (single step, very fast)
    local decoder="jpegdec"

    # Queue: Absolute minimum buffering - drop old frames instantly
    local queue="queue max-size-buffers=1 max-size-time=0 max-size-bytes=0 leaky=downstream"

    # Video convert (needed for some sinks)
    local convert="videoconvert"

    # Build sink element based on detection
    local sink_element
    case "$sink_type" in
        kms)
            # KMS: Direct to display, zero compositor overhead
            # Try to find the right connector
            sink_element="kmssink can-scale=false sync=false"
            ;;
        gl)
            sink_element="glimagesink sync=false"
            ;;
        fb)
            sink_element="fbdevsink sync=false"
            ;;
        x11)
            sink_element="ximagesink sync=false"
            ;;
        *)
            sink_element="autovideosink sync=false"
            ;;
    esac

    # The complete pipeline - every element tuned for minimum latency
    echo "${src} ! ${caps} ! ${queue} ! ${decoder} ! ${convert} ! ${sink_element}"
}

# ─── Disable screen blanking ────────────────────────────────────────────────
disable_blanking() {
    # Disable DPMS
    if command -v xset &>/dev/null && [ -n "${DISPLAY:-}" ]; then
        xset s off 2>/dev/null || true
        xset -dpms 2>/dev/null || true
        xset s noblank 2>/dev/null || true
    fi

    # Disable console blanking
    if [ -w /sys/module/kernel/parameters/consoleblank ]; then
        echo 0 > /sys/module/kernel/parameters/consoleblank 2>/dev/null || true
    fi
    setterm -blank 0 -powerdown 0 2>/dev/null || true
}

# ─── Cleanup on exit ────────────────────────────────────────────────────────
cleanup() {
    log "Shutting down live feed..."
    kill "$GST_PID" 2>/dev/null || true
    wait "$GST_PID" 2>/dev/null || true
    log "Done."
}
trap cleanup EXIT INT TERM

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    log "═══════════════════════════════════════════════════"
    log "  Zero-Latency Endoscopy Live Feed"
    log "  Device: $VIDEO_DEVICE"
    log "  Resolution: ${WIDTH}x${HEIGHT}@${FRAMERATE}fps"
    log "═══════════════════════════════════════════════════"

    wait_for_device
    configure_device
    disable_blanking

    local pipeline
    pipeline=$(build_pipeline)
    log "Pipeline: gst-launch-1.0 $pipeline"

    # Launch GStreamer with realtime priority if possible
    if command -v chrt &>/dev/null; then
        log "Launching with realtime priority..."
        chrt -f 50 gst-launch-1.0 -e $pipeline &
    else
        gst-launch-1.0 -e $pipeline &
    fi
    GST_PID=$!

    log "GStreamer PID: $GST_PID"
    log "Live feed is running. Press Ctrl+C to stop."

    # Wait for GStreamer process
    wait "$GST_PID"
}

main "$@"
