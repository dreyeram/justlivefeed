# Zero-Latency Endoscopy Live Feed

Ultra-low-latency live video feed system for Raspberry Pi with HDMI USB capture cards. Designed for endoscopy — where every millisecond matters.

## Architecture

```
USB Capture Card → v4l2src → jpegdec → kmssink → Display
     (MJPG)        (V4L2)    (decode)   (direct)   (HDMI)
```

**~1 frame latency (16ms at 60fps)** — No browser, no web server, no encoding overhead. GStreamer pipes video directly to display hardware.

## Quick Start

### On your Raspberry Pi:

```bash
# 1. Clone the repo
cd ~
git clone https://github.com/prantikm07/justlivefeed.git
cd justlivefeed

# 2. Install (one command)
sudo bash install.sh

# 3. Reboot — feed starts automatically
sudo reboot
```

That's it. The live feed will start automatically on every boot.

## Configuration

Edit the service file to change settings:

```bash
sudo nano /etc/systemd/system/livefeed.service
```

| Variable | Default | Description |
|----------|---------|-------------|
| `VIDEO_DEVICE` | `/dev/video0` | V4L2 capture device |
| `WIDTH` | `1920` | Capture width |
| `HEIGHT` | `1080` | Capture height |
| `FRAMERATE` | `60` | Target framerate |
| `SINK` | `auto` | Display sink (`auto`, `kms`, `gl`, `fb`, `x11`) |

After editing:
```bash
sudo systemctl daemon-reload
sudo systemctl restart livefeed
```

## Commands

| Action | Command |
|--------|---------|
| Check status | `sudo systemctl status livefeed` |
| View logs | `sudo journalctl -u livefeed -f` |
| Stop feed | `sudo systemctl stop livefeed` |
| Restart feed | `sudo systemctl restart livefeed` |
| Disable auto-start | `sudo systemctl disable livefeed` |
| Enable auto-start | `sudo systemctl enable livefeed` |
| Run manually | `sudo /opt/livefeed/livefeed.sh` |

## Troubleshooting

### No video output
```bash
# Check if device exists
ls -la /dev/video*

# Check device capabilities
v4l2-ctl -d /dev/video0 --list-formats-ext

# Check service logs
sudo journalctl -u livefeed -n 50
```

### Wrong resolution
```bash
# List supported formats
v4l2-ctl -d /dev/video0 --list-formats-ext

# Edit the service Environment variables to match a supported resolution
sudo systemctl edit livefeed
```

### High latency
```bash
# Verify MJPG is being used (not YUYV)
v4l2-ctl -d /dev/video0 --get-fmt-video

# Ensure sync=false is in the pipeline (it is by default)
# Check if the capture card supports 60fps at your resolution
```

### Feed doesn't start on boot
```bash
# Check service status
sudo systemctl status livefeed

# Re-enable if needed
sudo systemctl enable livefeed

# Check if device is available at boot time
# The service waits up to 60 seconds for the device
```

## Uninstall

```bash
cd ~/justlivefeed
sudo bash uninstall.sh
```

## Requirements

- Raspberry Pi (3B+, 4, or 5)
- HDMI USB Capture Card (UVC compatible)
- Raspberry Pi OS (Bookworm or Bullseye)
- Display connected via HDMI

## How It Works

1. **Boot** → systemd starts `livefeed.service`
2. **Wait** → Script waits for `/dev/video0` to appear (up to 60s)
3. **Configure** → Sets capture card to MJPG 1920x1080@60fps
4. **Pipeline** → GStreamer: `v4l2src → jpegdec → kmssink`
5. **Display** → Video renders directly to display hardware
6. **Recovery** → If pipeline crashes, systemd restarts in 2 seconds

No browser. No web server. No encoding. No network. Just raw video, directly on screen.
