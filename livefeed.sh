#!/bin/bash
###############################################################################
# livefeed.sh - Zero-Latency Endoscopy Live Feed
#
# Ultra-low-latency GStreamer pipeline for HDMI USB capture cards on Pi.
# Console mode — renders directly to display via DRM/KMS or framebuffer.
# No X11, no Wayland, no desktop needed.
###############################################################################

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"
WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FRAMERATE="${FRAMERATE:-60}"
# ─────────────────────────────────────────────────────────────────────────────

log() { echo "[livefeed] $(date '+%H:%M:%S') $*" >&2; }

# ─── Wait for video device ──────────────────────────────────────────────────
wait_for_device() {
    local retries=0
    while [ ! -e "$VIDEO_DEVICE" ]; do
        retries=$((retries + 1))
        if [ $retries -gt 60 ]; then
            log "ERROR: $VIDEO_DEVICE not found after 60s."
            exit 1
        fi
        log "Waiting for $VIDEO_DEVICE ... ($retries/60)"
        sleep 1
    done
    log "Device $VIDEO_DEVICE is ready."
}

# ─── Wait for DRM to be ready ───────────────────────────────────────────────
wait_for_drm() {
    local retries=0
    while ! ls /dev/dri/card* &>/dev/null; do
        retries=$((retries + 1))
        if [ $retries -gt 30 ]; then
            log "WARNING: No DRM device after 30s."
            return 1
        fi
        log "Waiting for DRM ... ($retries/30)"
        sleep 1
    done
    log "DRM devices: $(ls /dev/dri/card* 2>/dev/null)"
    return 0
}

# ─── Configure V4L2 device ──────────────────────────────────────────────────
configure_device() {
    log "Configuring $VIDEO_DEVICE → ${WIDTH}x${HEIGHT}@${FRAMERATE}fps MJPG"
    v4l2-ctl -d "$VIDEO_DEVICE" \
        --set-fmt-video=width="$WIDTH",height="$HEIGHT",pixelformat=MJPG \
        2>/dev/null || true
    v4l2-ctl -d "$VIDEO_DEVICE" \
        --set-parm="$FRAMERATE" \
        2>/dev/null || true
}

# ─── Prepare console for video display ───────────────────────────────────────
prepare_console() {
    # Disable screen blanking
    echo 0 > /sys/module/kernel/parameters/consoleblank 2>/dev/null || true
    setterm -blank 0 -powerdown 0 2>/dev/null || true

    # Hide cursor
    echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null || true
    setterm --cursor off 2>/dev/null || true

    # Clear screen
    clear 2>/dev/null || true
    # Disable VT console blanking
    echo -ne "\033[9;0]" 2>/dev/null || true
}

# ─── Try a GStreamer pipeline, return 0 on success ───────────────────────────
try_pipeline() {
    local description="$1"
    local pipeline="$2"

    log "Trying: $description"
    log "Pipeline: gst-launch-1.0 -e $pipeline"

    # Test-launch for 3 seconds to see if it works
    timeout 5 gst-launch-1.0 -e $pipeline &>/dev/null &
    local pid=$!
    sleep 3

    if kill -0 "$pid" 2>/dev/null; then
        # Still running after 3s = success! Kill the test and return success
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        log "SUCCESS: $description works!"
        return 0
    else
        log "FAILED: $description"
        return 1
    fi
}

# ─── Build the source part of the pipeline ───────────────────────────────────
get_source() {
    echo "v4l2src device=${VIDEO_DEVICE} io-mode=mmap do-timestamp=true ! image/jpeg,width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE}/1 ! queue max-size-buffers=1 max-size-time=0 max-size-bytes=0 leaky=downstream ! jpegdec ! videoconvert"
}

# ─── Find working pipeline with auto-detection ──────────────────────────────
find_working_pipeline() {
    local source
    source=$(get_source)

    # ── Attempt 1: kmssink with each DRM card ────────────────────────────
    for card in /dev/dri/card*; do
        if [ -e "$card" ]; then
            local card_num="${card##*/dev/dri/card}"

            # Try without connector-id first (auto-detect)
            local pipeline="${source} ! kmssink driver-name=vc4"
            if try_pipeline "kmssink with vc4 driver on card${card_num}" "$pipeline"; then
                echo "$pipeline"
                return 0
            fi

            # Try generic kmssink
            pipeline="${source} ! kmssink"
            if try_pipeline "kmssink generic on card${card_num}" "$pipeline"; then
                echo "$pipeline"
                return 0
            fi
        fi
    done

    # ── Attempt 2: fbdevsink (framebuffer) ───────────────────────────────
    if [ -e /dev/fb0 ] && gst-inspect-1.0 fbdevsink &>/dev/null; then
        local pipeline="${source} ! videoscale ! fbdevsink"
        if try_pipeline "fbdevsink on /dev/fb0" "$pipeline"; then
            echo "$pipeline"
            return 0
        fi
    fi

    # ── Attempt 3: waylandsink (if wayland is available) ─────────────────
    if gst-inspect-1.0 waylandsink &>/dev/null; then
        local pipeline="${source} ! waylandsink"
        if try_pipeline "waylandsink" "$pipeline"; then
            echo "$pipeline"
            return 0
        fi
    fi

    # ── Attempt 4: ximagesink (if X is somehow running) ──────────────────
    if [ -n "${DISPLAY:-}" ] && gst-inspect-1.0 ximagesink &>/dev/null; then
        local pipeline="${source} ! ximagesink"
        if try_pipeline "ximagesink" "$pipeline"; then
            echo "$pipeline"
            return 0
        fi
    fi

    # ── Attempt 5: autovideosink (let GStreamer decide) ──────────────────
    local pipeline="${source} ! autovideosink"
    log "Falling back to autovideosink..."
    echo "$pipeline"
    return 0
}

# ─── Cleanup on exit ────────────────────────────────────────────────────────
cleanup() {
    log "Shutting down live feed..."
    kill "$GST_PID" 2>/dev/null || true
    wait "$GST_PID" 2>/dev/null || true
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
    log "═══════════════════════════════════════════════════"

    wait_for_device
    wait_for_drm || true
    configure_device
    prepare_console

    # List available sinks for debugging
    log "Available video sinks:"
    for sink in kmssink fbdevsink waylandsink ximagesink glimagesink autovideosink; do
        if gst-inspect-1.0 "$sink" &>/dev/null; then
            log "  ✓ $sink"
        else
            log "  ✗ $sink (not available)"
        fi
    done
    log "DRM devices: $(ls -la /dev/dri/ 2>/dev/null || echo 'none')"
    log "Framebuffer: $(ls -la /dev/fb* 2>/dev/null || echo 'none')"

    # Find a working pipeline
    local pipeline
    pipeline=$(find_working_pipeline)

    log "═══════════════════════════════════════════════════"
    log "FINAL PIPELINE: gst-launch-1.0 -e $pipeline"
    log "═══════════════════════════════════════════════════"

    # Launch with realtime priority
    if command -v chrt &>/dev/null; then
        log "Launching with realtime scheduling..."
        chrt -f 50 gst-launch-1.0 -e $pipeline &
    else
        gst-launch-1.0 -e $pipeline &
    fi
    GST_PID=$!

    log "GStreamer PID: $GST_PID — Live feed running."
    wait "$GST_PID"
}

main "$@"
