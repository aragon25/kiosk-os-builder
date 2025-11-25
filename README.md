 # kiosk-os-builder

A small image-builder for Raspberry Pi kiosk systems. This project provides configuration templates and scripts to produce bootable SD/flash images for different kiosk flavors (SYS_full, SYS_lite, OEM variants). It is designed to be scriptable and configurable via per-build config files found in `config_template/`.

---

## 📦 Features

- Build full or lite kiosk system images for Raspberry Pi using configurable templates
- Per-OEM customization via `config_template/OEM_NAME` subfolders
- Reusable `builder/build_images.sh` orchestration plus wrapper scripts: `build_SYS_full.sh`, `build_SYS_lite.sh`, `build_OEM_NAME.sh`
- Boot partition and rootfs templates (bootfs / rootfs) arranged to be copied into image files
- Minimal external dependencies; intended for use in a Linux environment (WSL2, VM, or native)

---

## 🧪 Usage

Primary entrypoints:

- `build_SYS_full.sh` — build a full-featured kiosk image (uses `config_template/SYS_full`)
- `build_SYS_lite.sh` — build a lightweight kiosk image (uses `config_template/SYS_lite`)
- `build_OEM_NAME.sh` — build a vendor/OEM-specific image using `config_template/OEM_NAME`
- `builder/build_images.sh` — lower-level orchestrator used by the wrappers; accepts config paths and build targets

Run an example build (from repository root):

```bash
cd kiosk-os-builder
./build_SYS_lite.sh
```

> Note: wrapper scripts call the builder with preconfigured config files. Inspect them to see which options are passed.

---

## ⚙️ Configuration

Configuration templates live in `config_template/`. Key templates include:

- `bullseye-rpi3-lite.conf` — example config for lite images targeting Raspberry Pi 3 with Bullseye
- `bullseye-rpi3-full.conf` — example config for full images targeting Raspberry Pi 3 with Bullseye
- `bullseye-rpi3-NAME.conf` — example config for OEM images targeting Raspberry Pi 3 with Bullseye

Typical template layout (under `config_template/SYS_<flavor>/`):

- `bootfs/` — files that will be copied to the FAT boot partition (e.g., `config.txt`, `config-custom.txt`, overlays)
- `rootfs/` — a tree that will be placed into the root filesystem (e.g., `home/pi/auto-installer.sh`, `home/pi/deb_file.deb`)

Typical OEM template layout (under `config_template/OEM_<flavor>/`):

- `bootfs/` — files that will be copied to the FAT boot partition (e.g., `config-custom.txt`)
- `rootfs/` — a tree that will be placed into the root filesystem (e.g., `CONFIG/setup/auto-installer.sh`, `CONFIG/setup/deb_file.deb`)

Edit or copy a template to create a custom build. Keep paths relative in templates so the builder can copy them into images.

---

## 🧰 Dependencies

Required tools (run on a Linux host):

- `bash`, `coreutils`
- `parted`, `losetup`, `mkfs.vfat`, `mkfs.ext4` (or use loopback tools appropriate for your platform)
- `rsync`, `tar`, `xz` (if used by scripts)

On Windows, run the builder inside WSL2 or a Linux VM to ensure the required tools are available.

---

## 📁 Files & Templates

Define what goes into `bootfs` and `rootfs` within a template. Common items:

- `bootfs/config.txt` — main boot configuration for Raspberry Pi
- `bootfs/config-custom.txt` — additional include file the builder appends
- `bootfs/overlays/*.dtbo` — device tree overlays required by hardware
- `rootfs/home/pi/auto-installer.sh` — post-install or first-boot scripts to prepare the kiosk environment

Keep template files minimal and idempotent; scripts under `rootfs` should be safe to re-run.

---

## ⚙️ Lifecycle & Hooks

The builder supports pre/post hooks via the wrapper scripts or by editing `builder/build_images.sh`. Use these hooks to perform:

- custom file generation
- checksum/signing of final images
- pushing artifacts to a release directory

If you need to run extra actions, add them to the wrapper script before or after the `builder/build_images.sh` call.

---

## 🧪 Test & Output

After a successful build, the resulting image(s) will be placed in the builder's output directory (check `builder/build_images.sh` for the exact `release` or `images` path). Typical test flow:

1. Build the image:
```bash
./build_SYS_full.sh
```
2. Flash to SD card (use `rpi-imager` or `dd` carefully):
```bash
sudo dd if=release/kiosk_sys_full.img of=/dev/sdX bs=4M status=progress conv=fsync
```
3. Boot the device and verify kiosk behavior.

---

## ⚠️ Safety & recommendations

- Always test builds on a spare SD card or VM before deploying to production kiosks.
- Review `config_template/*/bootfs/config-custom.txt` and any `auto-installer.sh` scripts before building — they may contain device-specific or destructive commands.
- Use a disposable test environment when automating packaging or releases.

---

## Examples

Build a lite image for testing:

```bash
cd 0_APPS_GITHUB/kiosk-os-builder
./build_SYS_lite.sh
```

Create an OEM image for `OEM_NAME` (ensure `config_template/OEM_NAME` exists):

```bash
./build_OEM_NAME.sh
```
