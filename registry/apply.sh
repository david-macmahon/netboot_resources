#!/usr/bin/env bash
#
# registry-apply: verify, build and deploy rendered netboot-registry
# artifacts on this head node. Generic machinery (public repo); the cluster
# repo (registry.nix, node data, ./result symlink) is site data.
#
# Usage:
#   registry-apply.sh [--diff] [--build] [--cluster-repo DIR]
#
# The artifact source is the cluster repo's `result` symlink. This script
# guarantees: apply only ever deploys a tree that provably matches the
# current registry sources.
#
# Resolution matrix for `result`:
#   missing                  -> refuse unless --build (same as stale)
#   present, valid, fresh    -> proceed
#   present, valid, stale    -> refuse unless --build
#   dangling (target gone)   -> refuse, even with --build (fix by hand)
#   foreign (not a registry-artifacts tree) -> refuse, even with --build
#   freshness unverifiable   -> refuse in apply mode
#
# --build performs the build as the 'nix' user (NEVER as root: root-built
# store paths would be un-GC-able in a single-user store), scrapes the
# resulting store path, and re-creates the `result` symlink as the calling
# user, registering it as a garbage-collection root when possible.
#
# Actions (after resolution):
#   /etc/hosts      replace the marker-delimited netboot-registry block and
#                   remove any legacy (ansible-era) lines for registry IPs
#                   carrying dotted (FQDN) names. Serves the head node's
#                   own resolver; dnsmasq gets the same data via addn-hosts.
#   /etc/ethers     remove registry-node entries only (DHCP reservations
#                   moved to the dhcp-hostsfile). Everything else --
#                   historical entries and read-ethers -- stays.
#   /etc/exports    replace the marker-delimited managed-exports block
#                   (whole-tree export of the persistent root; client
#                   subnet and options come from cluster data), then
#                   `exportfs -ra` -- no daemon restart needed.
#   TFTP/HTTP trees when the cluster declares `nixos` facts (the
#                   nixos-paths manifest names the tree locations): install
#                   the shared pxelinux.cfg/<profile> menus + ipxe.lkrn
#                   into the TFTP tree, and the shared dispatch.ipxe +
#                   per-node by-mac/<mac>.ipxe scripts + image payload
#                   symlinks into the HTTP tree. Per-node hexip entries
#                   are SYMLINKS to the shared menus (manifest-driven,
#                   the hand-era tree shape). Installs are whole-file:
#                   install(1) unlinks the destination first. Registry-
#                   generated content missing from the current artifact
#                   tree is withdrawn (deleted) -- pxe profile -> null
#                   returns the node to the site default via pxelinux's
#                   fallback cascade.
#   /etc/dnsmasq.d  install netboot-registry.conf ONLY (static pointers;
#                   config directives are NOT re-read on SIGHUP, so a
#                   CONTENT change in netboot-registry.conf forces a
#                   restart). Data files do NOT live here: dnsmasq's conf-dir parses EVERY file
#                   in the config dir as config, and hosts-format data is
#                   fatal as config ("bad option" at startup -- learned
#                   2026-11-23, service outage).
#   /etc/netboot-registry
#                   install dhcp-hosts (the HUP-reloadable DHCP data file
#                   netboot-registry.conf points at). Cluster DNS deliberately has
#                   NO file here: dnsmasq serves the /etc/hosts managed
#                   block directly (its default behavior), so an
#                   addn-hosts copy would be pure duplication -- the
#                   block is the single DNS channel for the head node AND the
#                   cluster, and site entries outside it (power strips,
#                   etc.) stay resolvable. Removes stale data files left
#                   by earlier layouts (registry.{hosts,dhcp-hosts} in
#                   /etc/dnsmasq.d; hosts in /etc/netboot-registry).
#   persistent dirs materialize <persistent-root>/by-mac/<mac> anchors and
#                   <persistent-root>/<name> -> by-mac/<mac> symlinks, plus a
#                   per-node ssh host key inside each anchor (generated once).
#   dnsmasq         SIGHUP if only HUP-reloadable data changed; full
#                   restart when netboot-registry.conf is newly installed
#                   OR its content changed (config is not re-read on
#                   SIGHUP). Preflight runs `dnsmasq --test` WITH the same -7
#                   conf-dir the service uses (bare --test never loads
#                   the drop-in directory).
#
# --diff makes no changes. It follows the same resolution matrix, but a
# freshness check that cannot run (e.g. unprivileged) downgrades to a
# loud warning instead of a refusal.

set -euo pipefail

# Prefix every line, so multi-line messages (e.g. a diagnosis line plus an
# action line) stay visually consistent on stderr.
die()  { echo "$*" | sed 's/^/registry-apply: /' >&2; exit 1; }
warn() { echo "registry-apply: WARNING: $*" >&2; }

usage() {
  cat <<'EOF'
usage: registry-apply.sh [--diff] [--build] [--cluster-repo DIR]

Deploys the cluster registry artifacts to this head node. The artifact
source is <cluster-repo>/result; apply only ever deploys a tree that
provably matches the current registry sources.

  --diff            preview only; makes no changes
  --build           build as user 'nix' and re-point ./result as needed
                    (this is the fix for: missing or stale result)
  --cluster-repo    cluster repo containing registry.nix and ./result
                    (default: . -- the invoking directory must be the
                    cluster repo; override with NIX_NETBOOT_CLUSTER_REPO)

result states: missing/stale/older-generation -> rerun with --build;
dangling/foreign -> refused (fix by hand: rm the symlink if intentional).
apply requires root.
EOF
  exit 2
}

MODE=apply
DO_BUILD=0
# Transitional default: the invoking directory IS the cluster repo
# (registry.nix and ./result live there). Override with --cluster-repo
# or NIX_NETBOOT_CLUSTER_REPO. This disappears at flake-ification.
CLUSTER_REPO="${NIX_NETBOOT_CLUSTER_REPO:-.}"

while [ $# -gt 0 ]; do
  case $1 in
    --diff) MODE=diff ;;
    --build) DO_BUILD=1 ;;
    --cluster-repo) shift; [ $# -gt 0 ] || usage; CLUSTER_REPO=$1 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

REGISTRY_NIX="$CLUSTER_REPO/registry.nix"
RESULT="$CLUSTER_REPO/result"
[ -r "$REGISTRY_NIX" ] || die "no registry.nix in $CLUSTER_REPO (use --cluster-repo DIR)"

if [ "$MODE" = apply ] && [ "$(id -u)" -ne 0 ]; then
  die "apply mode requires root (use --diff for a preview)"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DNS_CHANGED=0

# ---- run a command as the nix user -----------------------------------------
# Builds and evaluation write to /nix/store, which in a single-user install
# belongs to the 'nix' account. Run as root: sudo -u nix works without a
# password. The profile script provides PATH and NIX_PATH.

as_nix() {
  sudo -u nix -H bash -c '
    for f in "$HOME/.nix-profile/etc/profile.d/nix.sh" \
             /nix/var/nix/profiles/default/etc/profile.d/nix.sh; do
      [ -r "$f" ] && . "$f" && break
    done
    exec "$@"
  ' _ "$@"
}

# ---- build as nix, re-point result as the caller ----------------------------
# nix-instantiate is cheap even when everything is built (drv already in the
# store); realization of already-present outputs is a no-op.

# Nix emits "you did not specify '--add-root'" for every unregistered
# GC-able result. Inside do_build, both evaluation and realization are
# deliberately unregistered at that instant (registration happens next,
# as the calling user), so the warning is expected noise there. Filter
# ONLY that line; every other stderr line passes through untouched --
# real nix errors must stay visible.
drop_addroot_warning() {
  grep -v "^warning: you did not specify '--add-root';" >&2
}

do_build() {
  # Progress goes to stderr: the caller captures this function's stdout,
  # which must contain ONLY the resulting store path.
  echo "registry: evaluating/building as user 'nix'..." >&2
  local drv out
  drv=$(as_nix nix-instantiate "$REGISTRY_NIX" 2> >(drop_addroot_warning)) \
    || die "nix-instantiate failed"
  drv=$(echo "$drv" | tail -1)
  case "$drv" in
    /nix/store/*-registry-artifacts.drv) ;;
    *) die "unexpected instantiation output: $drv" ;;
  esac
  out=$(as_nix nix-store -r "$drv" 2> >(drop_addroot_warning)) || die "build (nix-store -r) failed"
  out=$(echo "$out" | tail -1)
  case "$out" in
    /nix/store/*-registry-artifacts) ;;
    *) die "unexpected build output: $out" ;;
  esac
  # Re-point ./result as the CALLING user, then try to register it as a
  # garbage-collection root. The indirect root lives in
  # /nix/var/nix/gcroots/auto (owned by the nix account) and merely points
  # at the result symlink, so it survives later re-pointing. Registration
  # options, in order: (a) nix-store --add-root as the caller (root; the
  # -r re-realizes, a no-op since 'nix' just built it), (b) a NON-interactive
  # sudo -u nix symlink into gcroots/auto (passwordless-nixadm users; never
  # prompts thanks to -n), (c) unregistered, with a warning.
  if nix-store --add-root "$RESULT" -r "$drv" >/dev/null 2>&1; then
    echo "registry: built $out; result -> $(basename "$out") (GC root registered)" >&2
  else
    ln -sfn "$out" "$RESULT"
    if sudo -n -u nix ln -sfn "$RESULT" \
        /nix/var/nix/gcroots/auto/netboot-registry-result 2>/dev/null; then
      echo "registry: built $out; result -> $(basename "$out") (GC root registered via nix account)" >&2
    else
      warn "GC root not registered (add-root needs root; passwordless sudo -u nix unavailable); symlink created unregistered"
      echo "registry: built $out; result -> $(basename "$out")" >&2
    fi
  fi
  [ "$(readlink -f "$RESULT")" = "$out" ] || die "symlink verification failed"
  echo "$out"
}

# ---- resolve the artifact directory -----------------------------------------

ART=""

resolve_artifacts() {
  if [ -L "$RESULT" ]; then
    local target have want
    target=$(readlink "$RESULT")
    if [ ! -e "$RESULT" ]; then
      die "result symlink is DANGLING (points at '$target', which no longer exists; GC'd or removed?). Refusing even with --build.
If intentional: rm $RESULT, then rerun."
    fi
    ART=$(readlink -f "$RESULT")
    missing=""
    for f in etc-hosts.managed exports.managed dnsmasq-registry.conf \
             dnsmasq-registry.dhcp-hosts persistent-dirs; do
      [ -r "$ART/$f" ] || missing="$missing $f"
    done
    if [ -n "$missing" ]; then
      # A tree from an OLDER GENERATION of our own artifact family (built
      # before a new artifact type was added) is stale, not foreign: the
      # store-path name marks the family. Handle it exactly like staleness
      # -- rebuildable with --build. Only trees that don't look like the
      # family at all are foreign, i.e. hand-fixable mispointings.
      case "$(basename "$ART")" in
        *-registry-artifacts)
          if [ "$DO_BUILD" = 1 ]; then
            ART=$(do_build)
          else
            die "result is from an OLDER GENERATION of the artifact family (missing:$missing).
Rerun with --build."
          fi
          ;;
        *)
          die "result points at '$target', which is not a registry-artifacts tree (missing:$missing). Refusing even with --build.
If intentional: rm $RESULT, then rerun."
          ;;
      esac
    fi
    # Freshness: Nix can predict the current build's store path without
    # building. Instantiation is pure evaluation (cheap). Both halves of
    # the check run under as_nix: the projection query too, since
    # `nix-store` is not in the calling user's PATH (single-user install)
    # and a bare invocation fails silently into an empty `want`, which
    # then read as "fresh" -- the 2026-11-23 stale-diff bug.
    #
    # --build overrides every inconclusive branch: it is an explicit
    # "rebuild regardless of what the freshness check could determine",
    # not a flag the check can silently ignore. do_build fails loudly.
    if drv=$(as_nix nix-instantiate "$REGISTRY_NIX" 2>/dev/null | tail -1); then
      case "$drv" in
        /nix/store/*-registry-artifacts.drv)
          want=$(as_nix nix-store -q --outputs "$drv" 2>/dev/null | head -1) || want=""
          if [ -z "$want" ]; then
            if [ "$DO_BUILD" = 1 ]; then
              ART=$(do_build)
            elif [ "$MODE" = apply ]; then
              die "cannot project the current build's output path (freshness unverifiable) -- refusing to deploy an unverifiable tree.
Rerun with --build."
            else
              warn "cannot verify freshness (projection query failed); showing diff of possibly-stale tree"
            fi
          elif [ "$ART" != "$want" ]; then
            if [ "$DO_BUILD" = 1 ]; then
              ART=$(do_build)
            else
              die "result is STALE (points at $(basename "$ART"); current registry builds to $(basename "$want")).
Rerun with --build."
            fi
          fi
          ;;
        *)
          if [ "$DO_BUILD" = 1 ]; then
            ART=$(do_build)
          elif [ "$MODE" = apply ]; then
            die "unexpected instantiation output ($drv) -- refusing to deploy an unverifiable tree.
Rerun with --build."
          else
            warn "unexpected instantiation output ($drv); cannot verify freshness"
          fi
          ;;
      esac
    else
      if [ "$DO_BUILD" = 1 ]; then
        ART=$(do_build)
      elif [ "$MODE" = apply ]; then
        die "cannot evaluate registry (nix unavailable or broken?) -- refusing to deploy an unverifiable tree.
Rerun with --build."
      else
        warn "cannot verify freshness (unprivileged or nix unavailable); showing diff of possibly-stale tree"
      fi
    fi
  elif [ -e "$RESULT" ]; then
    die "$RESULT exists but is not a symlink. Refusing."
  else
    # missing: same as stale
    if [ "$DO_BUILD" = 1 ]; then
      ART=$(do_build)
    else
      die "no result symlink in $CLUSTER_REPO.
Rerun with --build."
    fi
  fi
}

resolve_artifacts

# ---- parse the registry out of the artifacts -------------------------------
# IPs: first field of each (non-comment) hosts line, regex-escaped.
IPS=$(grep -v '^#' "$ART/etc-hosts.managed" | awk 'NF {print $1}' | sort -u \
      | sed 's/\./\\./g' | paste -sd'|')
# MACs: first field of each (non-comment) dhcp-hosts line.
MACS=$(grep -v '^#' "$ART/dnsmasq-registry.dhcp-hosts" | awk -F, 'NF {print $1}' \
       | sort -u | paste -sd'|')
# Node names: leading label of the first name on each hosts line.
NAMES=$(grep -v '^#' "$ART/etc-hosts.managed" \
        | awk 'NF {split($2, a, "."); print a[1]}' | sort -u | paste -sd'|')
PROOT=$(sed -n 's/^# persistent-root: //p' "$ART/persistent-dirs" | head -1)
# PXE artifact tree locations (only present when some node has a `pxe`
# profile): parsed from the nixos-paths manifest, persistent-dirs style.
TFTPDIR=""
HTTPDIR=""
PAYLOADDIR=""
if [ -r "$ART/nixos-paths" ]; then
  TFTPDIR=$(sed -n 's/^# tftp-dir: //p' "$ART/nixos-paths" | head -1)
  HTTPDIR=$(sed -n 's/^# http-dir: //p' "$ART/nixos-paths" | head -1)
  PAYLOADDIR=$(sed -n 's/^# payload-dir: //p' "$ART/nixos-paths" | head -1)
  [ -n "$TFTPDIR" ] && [ -n "$HTTPDIR" ] && [ -n "$PAYLOADDIR" ] || {
    die "nixos-paths manifest is missing tftp-dir, http-dir or payload-dir"
  }
fi

[ -n "$IPS" ] && [ -n "$MACS" ] && [ -n "$NAMES" ] || {
  die "could not parse registry data from artifacts in $ART"
}
[ -n "$PROOT" ] || {
  die "persistent-dirs manifest has no persistent-root line"
}

# ---- /etc/hosts ------------------------------------------------------------
# New content = current file minus (our old marker block) minus (any line
# for a registry IP carrying dotted names), with the fresh block inserted
# after the legacy ansible marker line if present, else appended.
sed '/^# BEGIN netboot-registry managed entries/,/^# END netboot-registry managed entries/d' /etc/hosts \
  | grep -vE "^(${IPS})[[:space:]]+.*\." > "$TMP/hosts.pruned"
awk -v block="$ART/etc-hosts.managed" '
  { print }
  !done && /^# The following entries are managed by ansible$/ {
    while ((getline line < block) > 0) print line
    close(block); done = 1
  }
  END {
    if (!done) { print ""; while ((getline line < block) > 0) print line }
  }
' "$TMP/hosts.pruned" > "$TMP/hosts.new"

# ---- /etc/ethers -------------------------------------------------------------
# Removal only: registry MACs (case-insensitive) and ansible's per-node
# comment lines for registry nodes. Historical/other-site entries stay.
grep -viE "^(${MACS})([[:space:]]|$)" /etc/ethers 2>/dev/null \
  | grep -vE "^# Ansible-managed entries for (${NAMES})[ (]" > "$TMP/ethers.new" \
  || true
[ -s "$TMP/ethers.new" ] || : > "$TMP/ethers.new"

# ---- /etc/exports -------------------------------------------------------------
# New content = current file minus our marker block, with the fresh block
# appended. Whole-tree export of the persistent root: the client subnet
# and options are site policy from cluster data, so this block changes
# only when policy does -- never with node churn. (awk normalizes the
# trailing newline before appending, keeping the splice idempotent.)
sed '/^# BEGIN netboot-registry managed exports/,/^# END netboot-registry managed exports/d' \
  /etc/exports 2>/dev/null \
  | awk -v block="$ART/exports.managed" \
      '{ print } END { while ((getline line < block) > 0) print line }' \
  > "$TMP/exports.new"

# ---- report / apply -----------------------------------------------------------
if [ "$MODE" = diff ]; then
  echo "=== artifact source: $ART ==="
  echo "=== /etc/hosts (proposed change) ==="
  diff -u /etc/hosts "$TMP/hosts.new" || true
  echo "=== /etc/ethers (proposed change) ==="
  diff -u /etc/ethers "$TMP/ethers.new" || true
  echo "=== /etc/exports (proposed change) ==="
  diff -u /etc/exports "$TMP/exports.new" || true
  for pair in "/etc/dnsmasq.d/netboot-registry.conf:dnsmasq-registry.conf" \
              "/etc/netboot-registry/dhcp-hosts:dnsmasq-registry.dhcp-hosts"; do
    dst=${pair%%:*}; src=${pair##*:}
    if [ -f "$dst" ]; then
      echo "=== $dst (proposed change) ==="
      diff -u "$dst" "$ART/$src" || true
    else
      echo "=== $dst (NEW file) ==="
      sed 's/^/  + /' "$ART/$src"
    fi
  done
  # Stale files from earlier layouts: data files in the dnsmasq config
  # dir (dnsmasq parses them as config and dies on restart), the dropped
  # addn-hosts copy, and the pre-rename config pointer name. Report removal.
  for f in /etc/dnsmasq.d/registry.hosts /etc/dnsmasq.d/registry.dhcp-hosts \
           /etc/dnsmasq.d/registry.conf /etc/netboot-registry/hosts; do
    if [ -f "$f" ]; then
      echo "=== STALE (superseded layout; will be REMOVED) ==="
      echo "    $f"
    fi
  done
  echo "=== persistent dirs under $PROOT ==="
  grep -v '^#' "$ART/persistent-dirs" | awk 'NF' \
    | while read -r mac name; do
        printf '  mkdir -p %s/by-mac/%s; ln -sfn by-mac/%s %s/%s\n' \
          "$PROOT" "$mac" "$mac" "$PROOT" "$name"
      done
  if [ -n "$TFTPDIR" ]; then
    echo "=== TFTP tree under $TFTPDIR ==="
    if [ -d "$ART/pxelinux.cfg" ]; then
      for f in "$ART"/pxelinux.cfg/*; do
        dst="$TFTPDIR/pxelinux.cfg/$(basename "$f")"
        if [ -f "$dst" ] && ! [ -L "$dst" ]; then
          echo "=== $dst (proposed change) ==="
          diff -u "$dst" "$f" || true
        else
          echo "=== $dst (NEW file) ==="
          sed 's/^/  + /' "$f"
        fi
      done
    fi
    if [ -e "$ART/ipxe.lkrn" ]; then
      dst="$TFTPDIR/ipxe.lkrn"
      # -L: the artifact is a SYMLINK (linkFarm); stat it through.
      if [ -f "$dst" ] && cmp -s "$dst" "$ART/ipxe.lkrn"; then
        echo "=== $dst (unchanged, $(stat -Lc%s "$ART/ipxe.lkrn") bytes) ==="
      else
        echo "=== $dst (NEW or changed; $(stat -Lc%s "$ART/ipxe.lkrn") bytes) ==="
      fi
    fi
    # Per-node hexip SYMLINKS (hexip -> shared menu), manifest-driven.
    if [ -r "$ART/pxe-symlinks" ]; then
      grep -v '^#' "$ART/pxe-symlinks" | awk 'NF' \
        | while read -r hexip target; do
            if [ -L "$TFTPDIR/pxelinux.cfg/$hexip" ] \
               && [ "$(readlink "$TFTPDIR/pxelinux.cfg/$hexip")" = "$target" ]; then
              echo "  ln -sfn $target $hexip  (already in place)"
            else
              echo "  ln -sfn $target $hexip  (NEW or retargeted)"
            fi
          done
    fi
    echo "=== HTTP tree under $HTTPDIR ==="
    # Artifact entries are SYMLINKS (linkFarm): match -type f -o -type l,
    # and strip the nixos-netboot/ prefix -- the artifact tree's
    # nixos-netboot/ CONTENTS map onto the HTTP dir root.
    for f in $(cd "$ART" && find nixos-netboot \( -type f -o -type l \) -name '*.ipxe'); do
      dst="$HTTPDIR/${f#nixos-netboot/}"
      if [ -f "$dst" ] && ! [ -L "$dst" ]; then
        echo "=== $dst (proposed change) ==="
        diff -u "$dst" "$ART/$f" || true
      else
        echo "=== $dst (NEW file) ==="
        sed 's/^/  + /' "$ART/$f"
      fi
    done
    # Image payload symlinks (the image build maintains PAYLOADDIR).
    for f in bzImage initrd netboot.ipxe; do
      if [ -L "$HTTPDIR/$f" ] && [ "$(readlink "$HTTPDIR/$f")" = "$PAYLOADDIR/$f" ]; then
        echo "  ln -sfn $PAYLOADDIR/$f $f  (already in place)"
      elif [ -e "$HTTPDIR/$f" ]; then
        echo "  ln -sfn $PAYLOADDIR/$f $f  (REPLACES existing non-registry content)"
      else
        [ -e "$PAYLOADDIR/$f" ] || echo "  WARNING: payload missing: $PAYLOADDIR/$f (apply will REFUSE; build the image first)"
        echo "  ln -sfn $PAYLOADDIR/$f $f  (NEW)"
      fi
    done
    # Withdrawal previews: registry-generated content (by marker, or by
    # symlink target) in the live trees that the current artifact set
    # no longer contains.
    while IFS= read -r -d '' f; do
      base=$(basename "$f")
      grep -q "netboot-registry-managed" "$f" 2>/dev/null || continue
      [ -e "$ART/pxelinux.cfg/$base" ] && continue
      echo "=== STALE (registry-generated; will be REMOVED) ==="
      echo "    $f"
    done < <(find "$TFTPDIR/pxelinux.cfg" -maxdepth 1 -type f -print0 2>/dev/null)
    if [ ! -e "$ART/ipxe.lkrn" ] && [ -f "$TFTPDIR/ipxe.lkrn" ]; then
      echo "=== STALE (registry-generated; will be REMOVED) ==="
      echo "    $TFTPDIR/ipxe.lkrn"
    fi
    while IFS= read -r -d '' link; do
      target=$(readlink "$link") || continue
      tgtbase=$(basename "$target")
      owned=0
      [ -e "$ART/pxelinux.cfg/$tgtbase" ] && owned=1
      if [ "$owned" = 0 ] && [ -f "$TFTPDIR/pxelinux.cfg/$tgtbase" ]; then
        grep -q "netboot-registry-managed" "$TFTPDIR/pxelinux.cfg/$tgtbase" 2>/dev/null && owned=1
      fi
      [ "$owned" = 1 ] || continue
      hexip=$(basename "$link")
      if [ ! -r "$ART/pxe-symlinks" ] || ! grep -q "^$hexip " "$ART/pxe-symlinks"; then
        echo "=== STALE (registry-generated; will be REMOVED) ==="
        echo "    $link -> $target"
      fi
    done < <(find "$TFTPDIR/pxelinux.cfg" -maxdepth 1 -type l -print0 2>/dev/null)
    while IFS= read -r -d '' f; do
      rel=${f#"$HTTPDIR"/}
      grep -q "netboot-registry-managed" "$f" 2>/dev/null || continue
      [ -e "$ART/nixos-netboot/$rel" ] && continue
      echo "=== STALE (registry-generated; will be REMOVED) ==="
      echo "    $f"
    done < <(find "$HTTPDIR" -type f -name '*.ipxe' -print0 2>/dev/null)
  fi
  echo "=== dnsmasq action ==="
  # dnsmasq re-reads on SIGHUP exactly: the hosts block, /etc/ethers
  # (read-ethers), and the dhcp-hostsfile (dnsmasq(8): dhcp-host
  # data "can be changed without re-starting dnsmasq ... re-read when
  # dnsmasq receives SIGHUP"). netboot-registry.conf is NOT reloadable
  # (config is parsed only at startup). PXE/persistent/exports changes
  # below never touch dnsmasq and must not trigger a reload.
  DCONF_CHANGED=0
  DDATA_CHANGED=0
  if [ ! -f /etc/dnsmasq.d/netboot-registry.conf ] \
     || ! cmp -s /etc/dnsmasq.d/netboot-registry.conf "$ART/dnsmasq-registry.conf"; then
    DCONF_CHANGED=1
  fi
  cmp -s /etc/hosts "$TMP/hosts.new" || DDATA_CHANGED=1
  if [ -f /etc/ethers ] && ! cmp -s /etc/ethers "$TMP/ethers.new"; then
    DDATA_CHANGED=1
  fi
  if [ -f /etc/netboot-registry/dhcp-hosts ]; then
    cmp -s /etc/netboot-registry/dhcp-hosts "$ART/dnsmasq-registry.dhcp-hosts" || DDATA_CHANGED=1
  else
    DDATA_CHANGED=1 # first-time install
  fi
  if [ "$DCONF_CHANGED" = 1 ]; then
    echo "  RESTART dnsmasq (netboot-registry.conf new or changed; config is not re-read on SIGHUP)"
  elif [ "$DDATA_CHANGED" = 1 ]; then
    echo "  HUP dnsmasq (hosts block, ethers, or dhcp-hosts changed -- all SIGHUP-reloadable)"
  else
    echo "  none (no dnsmasq-read data changed)"
  fi
  exit 0
fi

# apply mode from here on

if ! cmp -s /etc/hosts "$TMP/hosts.new"; then
  cp --preserve=mode,ownership /etc/hosts "$TMP/hosts.bak"
  cat "$TMP/hosts.new" > /etc/hosts
  DNS_CHANGED=1
  echo "hosts: updated"
fi

if [ -f /etc/ethers ] && ! cmp -s /etc/ethers "$TMP/ethers.new"; then
  cp --preserve=mode,ownership /etc/ethers "$TMP/ethers.bak"
  cat "$TMP/ethers.new" > /etc/ethers
  DNS_CHANGED=1
  echo "ethers: updated"
fi

EXPORTS_CHANGED=0
if [ ! -f /etc/exports ]; then
  cat "$TMP/exports.new" > /etc/exports
  EXPORTS_CHANGED=1
  echo "exports: created"
elif ! cmp -s /etc/exports "$TMP/exports.new"; then
  cp --preserve=mode,ownership /etc/exports "$TMP/exports.bak"
  cat "$TMP/exports.new" > /etc/exports
  EXPORTS_CHANGED=1
  echo "exports: updated"
fi

# Restart needed if netboot-registry.conf is newly installed OR its
# CONTENT changes: dnsmasq does not re-read config files on SIGHUP.
RESTART=0
if [ ! -f /etc/dnsmasq.d/netboot-registry.conf ]; then
  RESTART=1
  RESTART_WHY="first-time install of netboot-registry.conf"
elif ! cmp -s /etc/dnsmasq.d/netboot-registry.conf "$ART/dnsmasq-registry.conf"; then
  RESTART=1
  RESTART_WHY="netboot-registry.conf content changed (config is not re-read on SIGHUP)"
fi

# Back up everything this run may change BEFORE changing anything, so the
# preflight revert below restores the exact pre-run state.
mkdir -p /etc/netboot-registry
for f in /etc/dnsmasq.d/netboot-registry.conf /etc/netboot-registry/dhcp-hosts; do
  [ -f "$f" ] && cp -a "$f" "$TMP/$(basename "$f").prev"
done
# Stale files from earlier layouts (see diff section): the pre-rename
# config pointer keeps its own stale name below.
for f in /etc/dnsmasq.d/registry.hosts /etc/dnsmasq.d/registry.dhcp-hosts \
         /etc/dnsmasq.d/registry.conf /etc/netboot-registry/hosts; do
  [ -f "$f" ] && cp -a "$f" "$TMP/$(basename "$f").stale"
done

install -m 644 "$ART/dnsmasq-registry.conf"       /etc/dnsmasq.d/netboot-registry.conf
# dhcp-hosts is SIGHUP-reloadable: track whether it actually changed so
# the HUP at the end is honest (an exports-only or PXE-only run must
# NOT bounce dnsmasq).
if ! cmp -s /etc/netboot-registry/dhcp-hosts "$ART/dnsmasq-registry.dhcp-hosts"; then
  install -m 644 "$ART/dnsmasq-registry.dhcp-hosts" /etc/netboot-registry/dhcp-hosts
  DNS_CHANGED=1
  echo "dnsmasq: dhcp-hosts updated"
else
  echo "dnsmasq: dhcp-hosts unchanged"
fi
echo "dnsmasq: netboot-registry.conf -> /etc/dnsmasq.d"
# Migration: remove files from superseded layouts (including the old
# config pointer name).
rm -f /etc/dnsmasq.d/registry.hosts /etc/dnsmasq.d/registry.dhcp-hosts \
      /etc/dnsmasq.d/registry.conf /etc/netboot-registry/hosts

# Preflight: never bounce dnsmasq (cluster DHCP+DNS) on a config that
# fails its own syntax check.  On failure, revert everything this run
# changed and exit without touching the running dnsmasq.  (This is
# preflight validation, not a rollback mechanism: the standing recovery
# path is editing the registry and re-running.)
#
# The test MUST load the drop-in directory the way the running service
# does (init script: dnsmasq ... -7 $CONFIG_DIR): a bare `dnsmasq
# --test` reads only /etc/dnsmasq.conf and passes right over a fatal
# file in /etc/dnsmasq.d -- this exact blind spot caused the
# 2026-11-23 outage (distro's ExecStartPre has the same gap).
[ -f /etc/default/dnsmasq ] && . /etc/default/dnsmasq
if ! dnsmasq --test ${CONFIG_DIR:+ -7 $CONFIG_DIR} \
             ${DNSMASQ_OPTS:+ $DNSMASQ_OPTS} --local-service > /dev/null 2>&1
then
  echo "$0: dnsmasq --test FAILED; reverting this run's changes:" >&2
  dnsmasq --test ${CONFIG_DIR:+ -7 $CONFIG_DIR} \
          ${DNSMASQ_OPTS:+ $DNSMASQ_OPTS} --local-service 2>&1 | sed 's/^/    /' >&2
  [ -f "$TMP/hosts.bak" ] && cat "$TMP/hosts.bak" > /etc/hosts
  [ -f "$TMP/ethers.bak" ] && cat "$TMP/ethers.bak" > /etc/ethers
  for f in netboot-registry.conf; do
    if [ -f "$TMP/$f.prev" ]
    then
      cp -a "$TMP/$f.prev" "/etc/dnsmasq.d/$f"
    else
      rm -f "/etc/dnsmasq.d/$f"
    fi
  done
  for f in dhcp-hosts; do
    if [ -f "$TMP/$f.prev" ]
    then
      cp -a "$TMP/$f.prev" "/etc/netboot-registry/$f"
    else
      rm -f "/etc/netboot-registry/$f"
    fi
  done
  # Stale files return to their old locations exactly as found.
  [ -f "$TMP/registry.hosts.stale" ] && cp -a "$TMP/registry.hosts.stale" /etc/dnsmasq.d/registry.hosts
  [ -f "$TMP/registry.dhcp-hosts.stale" ] && cp -a "$TMP/registry.dhcp-hosts.stale" /etc/dnsmasq.d/registry.dhcp-hosts
  [ -f "$TMP/registry.conf.stale" ] && cp -a "$TMP/registry.conf.stale" /etc/dnsmasq.d/registry.conf
  [ -f "$TMP/hosts.stale" ] && cp -a "$TMP/hosts.stale" /etc/netboot-registry/hosts
  echo "$0: reverted; dnsmasq left running with its previous configuration" >&2
  exit 1
fi

mkdir -p "$PROOT/by-mac"
grep -v '^#' "$ART/persistent-dirs" | awk 'NF' | while read -r mac name; do
  anchor="$PROOT/by-mac/$mac"
  mkdir -p "$anchor/.ssh-host-keys"
  ln -sfn "by-mac/$mac" "$PROOT/$name"
  # Per-node ssh host key: the netboot image presents it once /persistent
  # is mounted (bind-mounted over the baked-in key by
  # nixos-persistent-keys). Generated ONCE at anchor creation; re-runs
  # keep the existing key so node identity never churns.
  if [ ! -s "$anchor/.ssh-host-keys/ssh_host_ed25519_key" ]; then
    ssh-keygen -t ed25519 -N "" \
      -C "netboot persistent host key $name ($mac)" \
      -f "$anchor/.ssh-host-keys/ssh_host_ed25519_key" >/dev/null
    chmod 600 "$anchor/.ssh-host-keys/ssh_host_ed25519_key"
    echo "persistent: generated host key for $name"
  fi
done
echo "persistent: anchors + host keys + symlinks materialized under $PROOT"

# ---- apply the exports change ---------------------------------------------
# exportfs -ra re-reads the table live; no daemon restart needed. On
# failure, restore the previous file and re-export so the kernel table
# matches the file again.
if [ "${EXPORTS_CHANGED:-0}" = 1 ]; then
  if ! exportfs -ra; then
    echo "$0: exportfs -ra FAILED; restoring previous /etc/exports" >&2
    [ -f "$TMP/exports.bak" ] && cat "$TMP/exports.bak" > /etc/exports
    exportfs -ra || warn "exportfs -ra failed even after restoring /etc/exports; inspect by hand"
    exit 1
  fi
  echo "exports: exportfs -ra applied"
  # Verify the export is actually being SERVED (not just in the kernel
  # table): showmount queries mountd. (exportfs -s would also work on
  # modern nfs-utils but does not exist on Ubuntu 16.04's version.)
  showmount -e localhost 2>/dev/null | grep -qF "$PROOT" \
    || warn "persistent root not visible via 'showmount -e localhost': $PROOT"
fi

# ---- TFTP/HTTP trees for the PXE artifacts ---------------------------------
# Whole-file installs; `install` UNLINKS the destination first. Withdrawal
# is DELETION: a `pxe` profile -> null removes the node's hexip symlink
# and MAC-keyed iPXE script, returning the node to the site default via
# pxelinux's fallback cascade. Only registry-generated content is ever
# withdrawn: files by their "netboot-registry-managed" marker, hexip
# symlinks by their target (a marker-carrying shared menu). Hand-era
# files and symlinks are left alone.
if [ -n "$TFTPDIR" ]; then
  mkdir -p "$TFTPDIR/pxelinux.cfg" "$HTTPDIR/by-mac"
  # Image payloads served next to the scripts: the scripts' `chain
  # netboot.ipxe` is relative and resolves here. The image build
  # maintains the payload dir (nixos-paths manifest); these symlinks
  # follow its result symlink.
  for f in bzImage initrd netboot.ipxe; do
    [ -e "$PAYLOADDIR/$f" ] \
      || die "image payload missing: $PAYLOADDIR/$f (build the image first)"
    ln -sfn "$PAYLOADDIR/$f" "$HTTPDIR/$f"
  done
  # Shared menus (marker-carrying regular files; install unlinks first).
  # Artifact entries are SYMLINKS (linkFarm): match -type f -o -type l;
  # install copies the symlink's target content.
  if [ -d "$ART/pxelinux.cfg" ]; then
    find "$ART/pxelinux.cfg" -maxdepth 1 \( -type f -o -type l \) \
      -exec install -m 644 {} "$TFTPDIR/pxelinux.cfg/" \;
  fi
  # Per-node hexip SYMLINKS, manifest-driven. -f replaces anything in the
  # way, including hand-era symlinks when the registry takes over a node.
  if [ -r "$ART/pxe-symlinks" ]; then
    grep -v '^#' "$ART/pxe-symlinks" | awk 'NF' \
      | while read -r hexip target; do
          ln -sfn "$target" "$TFTPDIR/pxelinux.cfg/$hexip"
        done
  fi
  if [ -e "$ART/ipxe.lkrn" ]; then
    install -m 644 "$ART/ipxe.lkrn" "$TFTPDIR/ipxe.lkrn"
  fi
  # Shared dispatcher + per-node MAC-keyed scripts.
  if [ -f "$ART/nixos-netboot/dispatch.ipxe" ]; then
    install -m 644 "$ART/nixos-netboot/dispatch.ipxe" "$HTTPDIR/dispatch.ipxe"
  fi
  find "$ART/nixos-netboot/by-mac" -maxdepth 1 \( -type f -o -type l \) -name '*.ipxe' \
    -exec install -m 644 {} "$HTTPDIR/by-mac/" \;
  echo "pxe: $(find "$ART/pxelinux.cfg" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | wc -l) shared menu(s), $(grep -cv '^#\|^$' "$ART/pxe-symlinks" 2>/dev/null || echo 0) hexip link(s), $(find "$ART/nixos-netboot/by-mac" -maxdepth 1 \( -type f -o -type l \) -name '*.ipxe' 2>/dev/null | wc -l) ipxe script(s)"
  # Withdrawals.
  while IFS= read -r -d '' link; do
    target=$(readlink "$link") || continue
    tgtbase=$(basename "$target")
    owned=0
    [ -e "$ART/pxelinux.cfg/$tgtbase" ] && owned=1
    if [ "$owned" = 0 ] && [ -f "$TFTPDIR/pxelinux.cfg/$tgtbase" ]; then
      grep -q "netboot-registry-managed" "$TFTPDIR/pxelinux.cfg/$tgtbase" 2>/dev/null && owned=1
    fi
    [ "$owned" = 1 ] || continue
    hexip=$(basename "$link")
    if [ ! -r "$ART/pxe-symlinks" ] || ! grep -q "^$hexip " "$ART/pxe-symlinks"; then
      rm -f "$link"
      echo "pxe: withdrew symlink $hexip (pxe profile removed; node returns to site default)"
    fi
  done < <(find "$TFTPDIR/pxelinux.cfg" -maxdepth 1 -type l -print0 2>/dev/null)
  while IFS= read -r -d '' f; do
    base=$(basename "$f")
    grep -q "netboot-registry-managed" "$f" 2>/dev/null || continue
    [ -e "$ART/pxelinux.cfg/$base" ] && continue
    rm -f "$f"
    echo "pxe: withdrew $base"
  done < <(find "$TFTPDIR/pxelinux.cfg" -maxdepth 1 -type f -print0 2>/dev/null)
  if [ ! -e "$ART/ipxe.lkrn" ] && [ -f "$TFTPDIR/ipxe.lkrn" ]; then
    rm -f "$TFTPDIR/ipxe.lkrn"
    echo "pxe: withdrew ipxe.lkrn"
  fi
  while IFS= read -r -d '' f; do
    rel=${f#"$HTTPDIR"/}
    grep -q "netboot-registry-managed" "$f" 2>/dev/null || continue
    [ -e "$ART/nixos-netboot/$rel" ] && continue
    rm -f "$f"
    echo "pxe: withdrew $rel"
  done < <(find "$HTTPDIR" -type f -name '*.ipxe' -print0 2>/dev/null)
fi

if [ "${RESTART:-0}" = 1 ]; then
  echo "dnsmasq: restarting ($RESTART_WHY)"
  systemctl restart dnsmasq
elif [ "${DNS_CHANGED:-0}" = 1 ]; then
  echo "dnsmasq: sending SIGHUP (hosts block, ethers, or dhcp-hosts changed; all SIGHUP-reloadable)"
  pkill -HUP dnsmasq
else
  echo "dnsmasq: no dnsmasq-read data changed, no reload"
fi
