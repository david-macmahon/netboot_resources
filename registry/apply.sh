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
#                   <persistent-root>/<name> -> by-mac/<mac> symlinks.
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
                    (default: ./bl_netboot, relative to the invoking
                    directory; override with NIX_NETBOOT_CLUSTER_REPO)

result states: missing/stale/older-generation -> rerun with --build;
dangling/foreign -> refused (fix by hand: rm the symlink if intentional).
apply requires root.
EOF
  exit 2
}

MODE=apply
DO_BUILD=0
# Transitional default (machinery is imported by absolute path in the
# cluster repo's registry.nix). Relative to the invoking directory;
# override with --cluster-repo or NIX_NETBOOT_CLUSTER_REPO. This
# disappears at flake-ification.
CLUSTER_REPO="${NIX_NETBOOT_CLUSTER_REPO:-./bl_netboot}"

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
CHANGED=0

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
  echo "=== dnsmasq action ==="
  if [ ! -f /etc/dnsmasq.d/netboot-registry.conf ]; then
    echo "  RESTART dnsmasq (first-time install of netboot-registry.conf)"
  elif ! cmp -s /etc/dnsmasq.d/netboot-registry.conf "$ART/dnsmasq-registry.conf"; then
    echo "  RESTART dnsmasq (netboot-registry.conf CONTENT changed; config is not re-read on SIGHUP)"
  else
    echo "  HUP dnsmasq (if any file above changed)"
  fi
  exit 0
fi

# apply mode from here on

if ! cmp -s /etc/hosts "$TMP/hosts.new"; then
  cp --preserve=mode,ownership /etc/hosts "$TMP/hosts.bak"
  cat "$TMP/hosts.new" > /etc/hosts
  CHANGED=1
  echo "hosts: updated"
fi

if [ -f /etc/ethers ] && ! cmp -s /etc/ethers "$TMP/ethers.new"; then
  cp --preserve=mode,ownership /etc/ethers "$TMP/ethers.bak"
  cat "$TMP/ethers.new" > /etc/ethers
  CHANGED=1
  echo "ethers: updated"
fi

EXPORTS_CHANGED=0
if [ ! -f /etc/exports ]; then
  cat "$TMP/exports.new" > /etc/exports
  EXPORTS_CHANGED=1
  CHANGED=1
  echo "exports: created"
elif ! cmp -s /etc/exports "$TMP/exports.new"; then
  cp --preserve=mode,ownership /etc/exports "$TMP/exports.bak"
  cat "$TMP/exports.new" > /etc/exports
  EXPORTS_CHANGED=1
  CHANGED=1
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
install -m 644 "$ART/dnsmasq-registry.dhcp-hosts" /etc/netboot-registry/dhcp-hosts
# Migration: remove files from superseded layouts (including the old
# config pointer name).
rm -f /etc/dnsmasq.d/registry.hosts /etc/dnsmasq.d/registry.dhcp-hosts \
      /etc/dnsmasq.d/registry.conf /etc/netboot-registry/hosts
echo "dnsmasq: netboot-registry.conf -> /etc/dnsmasq.d; dhcp-hosts -> /etc/netboot-registry/"

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
  mkdir -p "$PROOT/by-mac/$mac"
  ln -sfn "by-mac/$mac" "$PROOT/$name"
done
echo "persistent: anchors + symlinks materialized under $PROOT"

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

if [ "${RESTART:-0}" = 1 ]; then
  echo "dnsmasq: restarting ($RESTART_WHY)"
  systemctl restart dnsmasq
elif [ "$CHANGED" = 1 ]; then
  echo "dnsmasq: sending SIGHUP"
  pkill -HUP dnsmasq
else
  echo "dnsmasq: no changes, no reload"
fi
