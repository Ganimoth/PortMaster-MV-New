#!/bin/bash

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source $controlfolder/control.txt
source $controlfolder/device_info.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

# Variables
GAMEDIR="/$directory/ports/dusklight"
cd "$GAMEDIR" || exit 1

# Keep one launch of log history: warm-boot cache diagnostics are read from the
# PREVIOUS session's log, which the truncation below would otherwise destroy.
cp -f "$GAMEDIR/log.txt" "$GAMEDIR/log.prev.txt" 2>/dev/null
> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1

mkdir -p "$GAMEDIR/assets"

# Look for a user-supplied disc image (GameCube/Wii .iso, or Dolphin/nodtool .rvz)
shopt -s nullglob nocaseglob
discs=("$GAMEDIR"/assets/*.iso "$GAMEDIR"/assets/*.rvz)
shopt -u nocaseglob
if [ ${#discs[@]} -eq 0 ]; then
    pm_message "No Twilight Princess disc image found in dusklight/assets. See README.md for dumping instructions."
    sleep 15
    exit 1
fi

# Keep config/saves/shader caches inside the port directory instead of $HOME
export XDG_DATA_HOME="$GAMEDIR/runtime"
mkdir -p "$XDG_DATA_HOME"

# The game keeps its config, saves and shader caches under this directory (SDL
# pref path OrgName/AppName = TwilitRealm/Dusklight). It lives in runtime/,
# which a zip re-install never overwrites.
DUSK_USER_DIR="$XDG_DATA_HOME/TwilitRealm/Dusklight"
mkdir -p "$DUSK_USER_DIR"

# Ship the port's tuned defaults as a config file players can edit, instead of
# forcing them via --cvar on every launch. The zip places config.json.default
# directly in this directory (the one runtime/ file it ships); config.json is
# the live config the game reads and writes, seeded from the default only when
# absent so in-game and hand edits survive. Restore a broken config with
# `cp config.json.default config.json`, or delete config.json to re-seed here.
if [ ! -f "$DUSK_USER_DIR/config.json" ] && [ -f "$DUSK_USER_DIR/config.json.default" ]; then
  echo "Seeding config.json from config.json.default (first run)."
  cp -f "$DUSK_USER_DIR/config.json.default" "$DUSK_USER_DIR/config.json"
fi

# Drop the on-disk shader caches when a newer game binary is installed, so a stale
# entry from a previous build can never be replayed. The gles backend keeps two
# caches under runtime/ (which a zip re-install never overwrites):
#   - pipeline_cache.db        : the pipeline-config warm list (what to precompile)
#   - program_binary_cache.db  : the driver's compiled GL program binaries
# The program-binary cache also self-invalidates on a driver fingerprint change
# (GL_VENDOR/RENDERER/VERSION + binary-format list), but wiping both on a new binary
# is clean and cheap. Caches are KEPT across normal launches so warm boots reuse them
# and skip the multi-minute cold shader-compile storm.
#
# (Warm boots deliberately keep pipeline_cache.db now: the Mali-G31 warm-boot black
# screen was a Dawn-era failure — its blob cache feeding the render worker — and is
# gone by construction on the gles backend, which never calls glProgramBinary on the
# render worker's live pipelines. The old every-launch wipe stopgap is removed.)
CACHE_DIR="$DUSK_USER_DIR"
if [ "$GAMEDIR/dusklight.aarch64" -nt "$CACHE_DIR/pipeline_cache.db" ]; then
  # Plain echo, not pm_message: pm_message pops a GUI helper that grabs the display
  # right before we launch and leaves rendering broken. Just log it.
  echo "New Dusklight build detected - clearing stale shader caches."
  rm -f "$CACHE_DIR"/pipeline_cache.db* "$CACHE_DIR"/program_binary_cache.db* \
        "$CACHE_DIR"/program_binary_cache.loading
fi

export LD_LIBRARY_PATH="$GAMEDIR/libs.${DEVICE_ARCH}:$LD_LIBRARY_PATH"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"

# Force SDL3 to select the bundled shim's "sdl2" video driver, not a native one.
# Aurora only takes the borrowed-EGL + EFB present path when
# SDL_GetCurrentVideoDriver()=="sdl2"; otherwise it hands Dawn a wgpu::Surface,
# and Dawn's GLES backend has NO Wayland/kmsdrm swapchain support (SwapChainEGL
# falls the WaylandSurface case straight through to "cannot be supported on EGL")
# -> device lost at boot, black screen (seen on ROCKNIX/sway, Adreno/freedreno).
# On Mali/PowerVR SDL3 has no native driver to grab, so it fell through to the
# shim on its own; a real Mesa stack (wayland/kmsdrm) DOES, so the selection must
# be pinned. Safe everywhere: the shim clears SDL_VIDEODRIVER before initializing
# the inner firmware SDL2, so the inner layer still auto-picks its own driver
# (kmsdrm on ArkOS, fbdev "mali" on Knulli).
export SDL_VIDEODRIVER=sdl2

# ROCKNIX is a real Mesa stack running under sway/wayland. Its inner SDL2 does
# NOT reliably auto-pick wayland (it can land on x11/kmsdrm first and fail), so
# pin the inner driver explicitly there. Other CFWs are left on auto-pick above.
# CFW_NAME comes from device_info.txt (sourced at the top); this is the same
# ROCKNIX gate the other PortMaster ports use.
if [ "$CFW_NAME" = "ROCKNIX" ]; then
  export SDL3SHIM_SDL2_VIDEODRIVER=wayland
fi

# (No MESA_SHADER_CACHE_DISABLE: the Mali/PowerVR targets run libmali, not Mesa, so it
# was inert there; and on a Mesa device — Adreno/ROCKNIX — the gles backend disables its
# own program-binary cache and relies on Mesa's on-disk shader cache for warm boots, so
# that cache must stay enabled. The Dawn-era relink segfault it worked around is gone.)

# Pin CPU/GPU/memory-controller governors to performance for the session and
# restore the previous ones after the game exits. The stock ondemand-family
# governors leave the CPU at ~1.0 of 1.296 GHz under this game's bursty frame
# load (measured on RK3326: ~15 fps vs ~18 fps in the same scene) and let the
# GPU/DMC clock down similarly. Deliberately generic sysfs rather than the
# CFW's perfmax: ArkOS-family perfmax hardcodes RK3326 device paths, takes
# over /dev/tty1 and plays splash media — the class globs below cover any
# device. Nodes without a "performance" governor are left alone. If the
# launcher itself is killed the pin persists until reboot; harmless.
GOV_NODES=()
GOV_PREV=()
for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor \
         /sys/class/devfreq/*/governor; do
  [ -f "$g" ] || continue   # unmatched glob stays literal without nullglob
  case "$g" in
    */cpufreq/*) avail="${g%/*}/scaling_available_governors" ;;
    *)           avail="${g%/*}/available_governors" ;;
  esac
  if [ -r "$avail" ] && ! grep -qw performance "$avail"; then
    continue
  fi
  prev="$(cat "$g" 2>/dev/null)"
  [ "$prev" = "performance" ] && continue
  GOV_NODES+=("$g")
  GOV_PREV+=("$prev")
  $ESUDO sh -c "echo performance > '$g'" 2>/dev/null
done

restore_governors() {
  local i
  for i in "${!GOV_NODES[@]}"; do
    [ -n "${GOV_PREV[$i]}" ] && \
      $ESUDO sh -c "echo '${GOV_PREV[$i]}' > '${GOV_NODES[$i]}'" 2>/dev/null
  done
}

$GPTOKEYB "dusklight.aarch64" >/dev/null 2>&1 &

pm_platform_helper "$GAMEDIR/dusklight.aarch64" > /dev/null
# Hand the disc we located above straight to the binary. With a valid --dvd the
# game opens the disc, persists the path to config, and boots the game directly;
# without it, a fresh install (empty runtime/, no saved isoPath) drops into the
# prelaunch disc-picker ("ISO has not been found") instead of starting.
#
# The port's tuned gameplay/enhancement defaults (skip the prelaunch and preset
# dialogs, no update check, no toasts, hide the pipeline widget, decoupled
# 30 Hz sim clock, frame interpolation off, half internal resolution) now live
# in config.json.default -> config.json so players can change them; they are no
# longer forced via --cvar here. See README.md.
#
# --backend opengles stays on the command line ON PURPOSE, not in config: Mali
# has no Vulkan driver, and with a missing or corrupted config.json the game
# resolves backend "auto", tries Vulkan first, and that failed attempt's window
# create/destroy cycle breaks the following OpenGLES EFB present init -> startup
# abort (field crash on a fresh R36 install). Forcing it here guarantees the
# game still boots even when config.json is broken - exactly the case a player
# hits after mis-editing it. config.json sets it too, for clarity.
#
# --log-level 1 = INFO: drops the per-resource [DEBUG] flood that scrolls the
# boot screen and bloats log.txt, while keeping adapter/render/EFB INFO lines
# (crash reports aren't log-gated, so they still print).
./dusklight.aarch64 --backend opengles --log-level 1 --dvd "${discs[0]}"

$ESUDO kill -9 $(pidof gptokeyb2) 2>/dev/null
restore_governors
pm_finish
