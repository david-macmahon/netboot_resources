#!/bin/bash

# # `nix_install.sh`
#
# ## Usage
#
# ```
# nix_install.sh
# ```
#
# The script takes no arguments and must be run as the `nix` user (the
# account created by `nix_setup.sh`), NOT as root.  The typical
# invocation is:
#
#     sudo -iu nix bootstrap/nix_install.sh
#
# Note that `sudo -iu` executes this script as the `nix` user, so the
# script must be readable (and its directory traversable) by that user.
# If the `nix` user cannot read the repository, copy this script to a
# readable location (e.g. /tmp) and run it from there.
#
# ## Overview
#
# Perform the unprivileged portion of the Nix installation as the
# `nix` service account.  The privileged, host-level preparation
# (creating the `nix` account and `/nix`) is performed by
# `nix_setup.sh`, which must be run first, as root.
#
# The script performs the following steps:
#
# 1. Check identity and prerequisites
#
#    The script refuses to run as root (running the installer as root
#    would create a root-owned store, defeating the purpose of the
#    service account), and aborts with guidance if `/nix` is not
#    writable (i.e. `nix_setup.sh` has not been run).
#
# 2. Install Nix (or skip if already installed)
#
#    Runs the official installer from https://nixos.org/nix/install in
#    single-user (`--no-daemon`) mode.  The installer is verified to
#    be non-interactive in this mode.  It is also invoked with
#    `--no-channel-add`, so that it does not pre-subscribe the
#    `nixpkgs` channel to nixpkgs-unstable; this script pins the
#    channel itself (step 3).
#
# 3. Configure Nix sandboxing (only on hosts where it is unsupported)
#
#    Detection asks Nix itself: a trivial derivation is built and the
#    log is inspected for Nix's own "auto-disabling sandboxing"
#    sandbox-fallback warning.  Probing with bare unshare(2) is NOT
#    sufficient: on the Ubuntu 16.04 host this project targets,
#    `unshare --user --mount` succeeds while Nix's fuller sandbox
#    setup still fails, so only Nix's own verdict is trustworthy.
#    If the warning appears, `sandbox = false` is written to the nix
#    user configuration (`~/.config/nix/nix.conf`) to make the
#    fallback explicit and silence the warning.  An existing `sandbox`
#    setting is left untouched.
#
# 4. Pin the NixOS channel (skip if already pinned correctly)
#
#    Ensures a `nixpkgs` channel pointing at the NixOS release named
#    by the `NIXPKGS_CHANNEL` variable, then updates it.  The URL is
#    checked, not just the channel name, because the Nix installer
#    pre-subscribes `nixpkgs` to nixpkgs-unstable.  Fresh installs
#    avoid this via `--no-channel-add` (step 2), but the URL check
#    also repairs systems where an earlier run of this script or a
#    manual installer run left the wrong URL in place.  When the URL
#    already matches, no update is forced; update channels manually
#    when desired.
#
# 5. Verify the installation and print a usage hint
#
# ## Details
#
# - The script requires `tar` and `xz`, and either `curl` or `wget`.
#   The installer downloads its binary tarball using the host's
#   `curl`/`wget`, so on older hosts the `ca-certificates` package may
#   need updating first (e.g. on Ubuntu 16.04, if TLS verification
#   fails, run
#
#       apt-get update && apt-get install --reinstall ca-certificates
#
#   as root, before running this script).
#
# - The installation requires roughly 1-2 GB under `/nix`, plus a few
#   more GB the first time a netboot image is built.  Evaluating a
#   NixOS configuration takes on the order of 2-4 GB of RAM.
#
# - Idempotency: every step is skipped if its effect is already in
#   place, so the script can safely be re-run.

# The variables below allow for some customization by setting the
# environment variables before calling this script.

# The service account that owns the Nix store (created by nix_setup.sh)
NIX_USER="${NIX_USER:-nix}"

# Which NixOS release (by channel name) to pin
NIXPKGS_CHANNEL="${NIXPKGS_CHANNEL:-nixos-26.05}"

# Where to download the Nix installer from
NIX_INSTALLER_URL="${NIX_INSTALLER_URL:-https://nixos.org/nix/install}"

# The Nix store location is fixed at `/nix` (see comments in nix_setup.sh)
NIX_ROOT="/nix"

# 1. Check identity and prerequisites

if [ -n "$1" ]
then
    echo "usage: $(basename $0) (takes no arguments)"
    exit 1
fi

invoking_user="$(id -un)"
if [ "$invoking_user" = "root" ]
then
    echo "$0: this script must NOT be run as root; run it as the '$NIX_USER'" >&2
    echo "user instead, e.g.:" >&2
    echo "" >&2
    echo "    sudo -iu $NIX_USER $0" >&2
    exit 1
fi
if [ "$invoking_user" != "$NIX_USER" ]
then
    echo "$0: expected to run as '$NIX_USER' but invoked as '$invoking_user'" >&2
    exit 1
fi

if [ ! -w "$NIX_ROOT" ]
then
    echo "$0: $NIX_ROOT is not writable; has 'nix_setup.sh' been run as root yet?" >&2
    exit 1
fi

for util in tar xz
do
    if ! command -v "$util" > /dev/null
    then
        echo "$0: '$util' is required but not installed"
        exit 1
    fi
done

if ! command -v curl > /dev/null && ! command -v wget > /dev/null
then
    echo "$0: either 'curl' or 'wget' is required to download the installer"
    exit 1
fi

# 2. Install Nix (or skip if already installed)

if nix_version="$(nix --version 2> /dev/null)"
then
    echo "Nix is already installed: $nix_version"
else
    echo "installing Nix (single-user, non-interactive)"
    if command -v curl > /dev/null
    then
        fetch_cmd="curl -L ${NIX_INSTALLER_URL}"
    else
        fetch_cmd="wget -O- ${NIX_INSTALLER_URL}"
    fi
    bash -c "${fetch_cmd} | sh -s -- --no-daemon --no-channel-add"
fi

# Make the (possibly freshly installed) Nix available in this shell.
# This is needed because PATH was set from the login profile before the
# installation happened, so a freshly installed `nix` is not yet on it.
if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]
then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

# 3. Configure Nix sandboxing (only on hosts where it is unsupported)

nix_conf_dir="$HOME/.config/nix"
nix_conf="$nix_conf_dir/nix.conf"

if [ -f "$nix_conf" ] && grep -Eq '^[[:space:]]*sandbox[[:space:]]*=' "$nix_conf"
then
    echo "a 'sandbox' setting is already present in $nix_conf, leaving it alone"
else
    # Probe by asking Nix itself: build a trivial derivation and watch
    # for Nix's own sandbox-fallback warning (see comments above).
    probe_dir="$(mktemp -d /tmp/nix_sandbox_probe.XXXXXX)"
    cat > "$probe_dir/probe.nix" <<'EOF'
derivation {
  name = "nix-sandbox-probe";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" "echo ok > \$out" ];
}
EOF
    if ! drv="$(nix-instantiate "$probe_dir/probe.nix" 2> /dev/null)"
    then
        echo "could not instantiate the sandbox probe; leaving the Nix configuration alone"
    else
        probe_log="$(nix-store -r "$drv" 2>&1)"
        if echo "$probe_log" | grep -q "auto-disabling sandboxing"
        then
            echo "sandboxing is not supported on this host (per Nix's own sandbox fallback)"
            mkdir -p "$nix_conf_dir"
            {
                echo "# Nix sandboxing does not work on this host (verified by probing a"
                echo "# trivial build); Nix's sandbox-fallback would disable sandboxing"
                echo "# on every build anyway.  Added by bootstrap/nix_install.sh."
                echo "sandbox = false"
            } >> "$nix_conf"
            echo "added 'sandbox = false' to $nix_conf"
        elif [ -n "$probe_log" ]
        then
            echo "sandbox probe build was noisy but did not report the sandbox fallback;"
            echo "leaving the Nix configuration alone:"
            echo "$probe_log"
        else
            echo "sandboxing appears to be supported; leaving the Nix configuration alone"
        fi
    fi
    rm -rf "$probe_dir"
fi

# 4. Pin the NixOS channel

channel_url="https://nixos.org/channels/${NIXPKGS_CHANNEL}"
current_url="$(nix-channel --list 2> /dev/null | grep '^nixpkgs ' | awk '{print $2}')"

if [ "$current_url" = "$channel_url" ]
then
    echo "channel nixpkgs is already pinned to ${channel_url} (not updating)"
else
    if [ -n "$current_url" ]
    then
        echo "re-pointing channel nixpkgs from '${current_url}' to '${channel_url}'"
        nix-channel --remove nixpkgs
    else
        echo "adding channel nixpkgs -> ${channel_url}"
    fi
    nix-channel --add "$channel_url" nixpkgs
    echo "updating channel nixpkgs (this may take a minute)"
    nix-channel --update
fi

# 5. Verify the installation

if ! nix_version="$(nix --version 2> /dev/null)"
then
    echo "$0: Nix installation verification failed"
    exit 1
fi

echo "Nix is ready: $nix_version"

echo ""
echo "To build the stock netboot image, run:"
echo ""
echo "    nix-build '<nixpkgs/nixos>' -A config.system.build.netboot"
echo ""
echo "The resulting artifacts (bzImage, initrd, netboot.ipxe) appear in ./result"
echo "relative to the working directory of that command."
