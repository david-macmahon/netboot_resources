#!/bin/bash

# # `nix_setup.sh`
#
# ## Usage
#
# ```
# nix_setup.sh [USERNAME ...]
# ```
#
# Must be run as root (e.g. via sudo).  It refuses to run otherwise.
# Each USERNAME argument is added to the `nixadm` group.
#
# ## Overview
#
# Set up the complete Nix administrative environment on this host: a
# dedicated `nix` service account owning a single-user installation of
# the Nix package manager in a store (`/nix`), plus passwordless sudo
# access to the account for human admins via the `nixadm` group
# (admins can already sudo to `nix` with a password; the passwordless
# access is a convenience).
#
# This script performs the privileged, host-level steps.  The
# unprivileged steps (installing Nix itself, pinning the nixpkgs
# channel) are performed by `nix_install.sh`, which is run as the
# `nix` user, e.g.:
#
#     sudo -iu nix bootstrap/nix_install.sh
#
# The script performs the following steps:
#
# 1. Check privileges and prerequisites
#
# 2. Pre-flight check of `/nix` (no side effects yet)
#
#    If `/nix` already exists and is owned by someone other than the
#    `nix` user, the script aborts before creating anything.  This
#    covers both a single-user Nix installation owned by another user
#    and a store left behind by a deleted account (a bare uid reported
#    as the owner indicates the latter).  Adopting an existing store is
#    a deliberate, manual action; see the abort message for guidance.
#
#    Ownership is checked here, rather than writability, for two
#    reasons: the `nix` account may not exist yet (a writability test
#    as `nix` requires the account), and the abort must happen before
#    the account is created to avoid leaving a half-configured system
#    behind.
#
# 3. Validate the sudoers fragment (no side effects yet)
#
#    The fragment `bootstrap/sudoers.d/nix` is staged as a root-owned,
#    mode-0440 copy and validated with `visudo -cf`, since `visudo`
#    requires the files it checks to be owned by root and not writable
#    by others, and the repository copy is owned by the developer.
#    The group and run-as target are then extracted from the fragment
#    and compared with the `NIXADM_GROUP` and `NIX_USER` variables.
#    Nothing is created or installed until validation passes: a
#    syntactically broken fragment can lock admins out of sudo
#    entirely, a mismatched group would silently produce an inert
#    rule, and a mismatched run-as target could grant passwordless
#    access to an unintended account.
#
# 4. Create the `nix` service account (or verify an existing one)
#
#    The account is created with a locked password and a real login
#    shell (`/bin/bash`) so that admins can `sudo -iu nix`.  A real
#    shell is required: `sudo -i` runs the target user's shell, so an
#    account with `/usr/sbin/nologin` would exit immediately.
#
# 5. Create `/nix` (or verify an existing one)
#
#    Created with mode 0755 and owned by the `nix` user.  This replaces
#    the one `sudo` invocation that the Nix installer would otherwise
#    perform from within the `nix` account, so that nothing in the
#    install process requires privilege escalation.
#
#    The Nix store location is fixed at `/nix`.  If the store should
#    live on a different filesystem (e.g. `/srv`), set up a bind mount
#    such as
#
#        /srv/nix  /nix  none  bind  0  0
#
#    BEFORE running this script, making sure the source directory is
#    owned by the `nix` user (bind mounts preserve the underlying
#    directory's ownership).
#
# 6. Verify that `/nix` is writable by the `nix` user
#
#    Ownership alone is not sufficient (e.g. the mode bits could have
#    been stripped), so the functional check is performed by running
#    `test -w` as the `nix` user via `sudo -u`.  Since this script runs
#    as root, no sudoers configuration is needed for this: root is
#    always permitted to run sudo and is exempt from authentication.
#    Note that the test must run as `nix` because a writability test
#    run as root would trivially succeed (root bypasses permission
#    bits), making it meaningless.
#
# 7. Create the `nixadm` group (or verify an existing one)
#
# 8. Install the sudoers fragment (or verify an existing one)
#
#    Installed as `/etc/sudoers.d/nix` with mode 0440.  Skipped if the
#    installed copy matches the repository copy and has the expected
#    mode and ownership.  After installing, `visudo -cf` is run on the
#    installed file; if it fails, the file is removed again rather
#    than leaving a broken sudoers entry behind.  Re-running this
#    script after editing the repository copy re-installs the updated
#    fragment.
#
# 9. Add each USERNAME argument to the `nixadm` group
#
#    Users are checked for existence and for prior membership.  A
#    nonexistent USERNAME is reported as an error and does not abort
#    the remaining users.
#
#    NOTE: group-based sudo rules are matched against the group
#    memberships of the invoking shell's process, which are fixed at
#    login time.  An admin added to the group by this script must
#    therefore re-login (or open a fresh shell via `su - <user>` or
#    `newgrp <group>`) before the passwordless rule takes effect in
#    their existing sessions.
#
# 10. Print a usage hint for `nix_install.sh`
#
# ## Details
#
# - The script requires `sudo`, `visudo`, `getent`, `stat`, `adduser`,
#   `groupadd`, and `usermod`.
#
# - The sudoers fragment lives at `bootstrap/sudoers.d/nix` in the
#   repository, which is the source of truth: see the comments in that
#   file for what the rule grants (the `nix` account's privileges
#   only, never root).
#
# - For testing, set `SUDOERS_DIR` to a directory other than
#   `/etc/sudoers.d` (cf. the `FSTAB`/`EXPORTS` overrides in
#   `netbootstrap.sh`).
#
# - The `nix` account is intentionally unprivileged and
#   password-locked: it needs disk space and network access, nothing
#   more.
#
# - Idempotency: every step is skipped if its effect is already in
#   place, so the script can safely be re-run.

# The variables below allow for some customization by setting the
# environment variables before calling this script.

# Name of the service account that will own the Nix store
NIX_USER="${NIX_USER:-nix}"

# Group whose members may act as the `nix` user
NIXADM_GROUP="${NIXADM_GROUP:-nixadm}"

# Explicit GID for that group (optional).  Default: auto-allocated.
# When set: must be a unique, non-zero, non-negative integer; if the
# group already exists at a different GID it is migrated with
# `groupmod -g` (idempotent on re-run).  Note that auto-allocation
# considers all group sources NSS provides, which on some systems
# includes a directory service.
NIXADM_GID="${NIXADM_GID:-}"

# Directory to install the sudoers fragment into (override when testing)
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"

# The Nix store location is fixed at `/nix` (see comments above)
NIX_ROOT="/nix"

# 1. Check privileges and prerequisites

for arg in "$@"
do
    case "$arg" in
        -*) echo "usage: $(basename $0) [USERNAME ...] (USERNAMES must not start with '-')" >&2
            exit 1;;
    esac
done

if [ "$(id -u)" -ne 0 ]
then
    echo "$0: must be run as root (e.g. via sudo)"
    exit 1
fi

for util in sudo visudo getent stat adduser groupadd usermod
do
    if ! command -v "$util" > /dev/null
    then
        echo "$0: '$util' is required but not installed"
        exit 1
    fi
done

# 2. Pre-flight check of `/nix` (no side effects yet)

if [ -e "$NIX_ROOT" ]
then
    nix_owner="$(stat -c '%U' "$NIX_ROOT")"
    nix_owner_uid="$(stat -c '%u' "$NIX_ROOT")"
    if [ "$nix_owner" != "$NIX_USER" ]
    then
        echo "$0: $NIX_ROOT exists but is owned by '$nix_owner' (uid $nix_owner_uid)," >&2
        echo "not '$NIX_USER'.  This may be a single-user Nix installation owned by" >&2
        echo "another user, or a store left behind by a deleted account (a bare" >&2
        echo "uid above indicates the latter)." >&2
        echo "" >&2
        echo "To adopt the existing store, create the '$NIX_USER' account if it does" >&2
        echo "not exist, run 'chown -R $NIX_USER: $NIX_ROOT' as root (after reviewing" >&2
        echo "its contents), and re-run this script.  If the contents are not needed," >&2
        echo "the directory can simply be removed instead." >&2
        exit 1
    else
        echo "$NIX_ROOT already exists and is owned by '$NIX_USER'"
    fi
else
    echo "$NIX_ROOT does not exist (will be created below)"
fi

# 3. Validate the sudoers fragment (no side effects yet)
#
# Locate the repository sudoers fragment
script_dir="$(cd "$(dirname "$0")" && pwd)"
sudoers_src="${script_dir}/sudoers.d/nix"

if [ ! -f "$sudoers_src" ]
then
    echo "$0: sudoers fragment not found at $sudoers_src"
    exit 1
fi

sudoers_dest="${SUDOERS_DIR}/$(basename "$sudoers_src")"

# Stage a root-owned, mode-0440 copy for validation, since `visudo`
# requires the files it checks to be owned by root and not writable by
# others, and the repository copy is owned by the developer.
stage="$(mktemp /tmp/nix_sudoers_stage.XXXXXX)"
cleanup() {
    rm -f "$stage"
}
trap cleanup EXIT

install -o root -g root -m 0440 "$sudoers_src" "$stage"

if ! visudo -cf "$stage" > /dev/null
then
    echo "$0: $sudoers_src failed visudo validation, not installing anything:" >&2
    visudo -cf "$stage" >&2
    exit 1
fi

# Check that the fragment matches this script's expectations
sudoers_group="$(grep '^%' "$stage" | head -n 1 | awk '{print $1}' | tr -d '%')"
sudoers_runas="$(grep '^%' "$stage" | head -n 1 | sed -n 's/.*=(\([^)]*\)).*/\1/p')"

if [ -z "$sudoers_group" ] || [ -z "$sudoers_runas" ]
then
    echo "$0: could not determine the group and/or run-as target from $sudoers_src"
    exit 1
fi

if [ "$sudoers_group" != "$NIXADM_GROUP" ]
then
    echo "$0: $sudoers_src grants access to group '%${sudoers_group}' but this" >&2
    echo "script manages group '$NIXADM_GROUP'.  Update one or the other so that" >&2
    echo "they agree, then re-run this script." >&2
    exit 1
fi

if [ "$sudoers_runas" != "$NIX_USER" ]
then
    echo "$0: $sudoers_src grants access to account '$sudoers_runas' but this" >&2
    echo "script manages account '$NIX_USER'.  Update one or the other so that" >&2
    echo "they agree, then re-run this script." >&2
    exit 1
fi

# 4. Create the `nix` service account

if getent passwd "$NIX_USER" > /dev/null
then
    echo "user '$NIX_USER' already exists"
else
    echo "creating service account '$NIX_USER'"
    adduser --disabled-password --gecos "Nix build account" "$NIX_USER"
fi

# Ensure a real login shell (e.g. if the account pre-existed with nologin)
nix_shell="$(getent passwd "$NIX_USER" | cut -d: -f7)"
case "$nix_shell" in
    /usr/sbin/nologin|/bin/false|/usr/bin/false)
        echo "user '$NIX_USER' has shell '$nix_shell', switching to /bin/bash"
        usermod -s /bin/bash "$NIX_USER"
        ;;
esac

# 5. Create `/nix` owned by the `nix` user

if [ -e "$NIX_ROOT" ]
then
    echo "$NIX_ROOT already exists"
else
    echo "creating $NIX_ROOT (mode 0755, owner $NIX_USER)"
    mkdir -m 0755 "$NIX_ROOT"
    chown "$NIX_USER:" "$NIX_ROOT"
fi

# 6. Verify that `/nix` is writable by the `nix` user

if sudo -u "$NIX_USER" test -w "$NIX_ROOT"
then
    echo "$NIX_ROOT is writable by '$NIX_USER'"
else
    echo "$0: $NIX_ROOT is not writable by '$NIX_USER' despite being owned by" >&2
    echo "'$NIX_USER'.  Check its mode bits, e.g.:  chmod u+w $NIX_ROOT" >&2
    exit 1
fi

# 6b. Detect a pre-existing Nix installation and sanity-check it.
#
# nix_setup.sh never installs Nix itself (that is nix_install.sh's job,
# run unprivileged afterwards); this step determines which of the two
# applies at the end of the run and, when Nix is already present, gives
# the existing installation a quick health check.

# Locate the nix binary: per-user profile (Nix >= 2.4 XDG-state layout,
# e.g. ~nix/.nix-profile -> ~/.local/state/nix/profiles/profile) or the
# classic /nix/var/nix/profiles/default layout.
nix_home="$(getent passwd "$NIX_USER" | cut -d: -f6)"
nix_bin=""
for cand in "$nix_home/.nix-profile/bin/nix" \
            "$NIX_ROOT/var/nix/profiles/default/bin/nix"
do
    if [ -x "$cand" ]
    then
        nix_bin="$cand"
        break
    fi
done
nix_installed=false

if [ -z "$nix_bin" ]
then
    echo "no existing Nix installation found (nix_install.sh will provide one)"
elif sudo -u "$NIX_USER" "$nix_bin" --version > /dev/null 2>&1
then
    nix_installed=true
    echo "Nix is already installed: $(sudo -u "$NIX_USER" "$nix_bin" --version 2>/dev/null | head -1)"

    nix_store_bin="${nix_bin%/*}/nix-store"
    if sudo -u "$NIX_USER" "$nix_store_bin" --verify > /dev/null 2>&1
    then
        echo "store database verifies OK"
    else
        echo "$0: WARNING: 'nix-store --verify' reported problems; investigate with" >&2
        echo "'sudo -iu $NIX_USER nix-store --verify --check-contents'" >&2
    fi

    # Root-owned strata inside the NIX_USER-owned tree would leave the
    # nix account unable to reach its own state (see step 7b's comment).
    strata="$(find "$NIX_ROOT/var" -maxdepth 3 \! -user "$NIX_USER" 2>/dev/null | head -5)"
    if [ -n "$strata" ]
    then
        echo "$0: WARNING: non-$NIX_USER-owned paths under $NIX_ROOT/var:" >&2
        echo "$strata" >&2
        echo "(fix with e.g.:  chown -R $NIX_USER: <path>)" >&2
    fi
else
    echo "$0: WARNING: a Nix binary exists at $nix_bin but cannot be run" >&2
    echo "as '$NIX_USER'; check ownership and permissions under $NIX_ROOT" >&2
fi

# 7. Create the `nixadm` group (GID per NIXADM_GID if set; see above)

case "$NIXADM_GID" in
    '') ;;
    0|*[!0-9]*)
        echo "$0: NIXADM_GID must be a non-zero, non-negative integer (got '$NIXADM_GID')" >&2
        exit 1;;
    *)
        if getent group "$NIXADM_GID" > /dev/null
        then
            conflict_group="$(getent group "$NIXADM_GID" | cut -d: -f1)"
            if [ "$conflict_group" != "$NIXADM_GROUP" ]
            then
                echo "$0: NIXADM_GID $NIXADM_GID is already in use by group" >&2
                echo "'$conflict_group'" >&2
                exit 1
            fi
            # Occupied by NIXADM_GROUP itself: already migrated (or about
            # to be verified) -- not a conflict.
        fi;;
esac

current_gid="$(getent group "$NIXADM_GROUP" | cut -d: -f3)"  # empty if absent

if [ -z "$current_gid" ]
then
    echo "creating group '$NIXADM_GROUP'"
    if [ -n "$NIXADM_GID" ]
    then
        groupadd -g "$NIXADM_GID" "$NIXADM_GROUP"
    else
        groupadd "$NIXADM_GROUP"
    fi
elif [ -n "$NIXADM_GID" ] && [ "$current_gid" != "$NIXADM_GID" ]
then
    # Migrate an existing group to the requested GID.  The member list
    # is name-based and unaffected; files owned by the old GID are not
    # retagged (check with:  find / -xdev -gid "$current_gid")
    echo "migrating group '$NIXADM_GROUP' from GID $current_gid to $NIXADM_GID"
    groupmod -g "$NIXADM_GID" "$NIXADM_GROUP"
else
    echo "group '$NIXADM_GROUP' already exists (GID $current_gid)"
fi

# 7b. Let NIXADM_GROUP members register GC roots as themselves.
#
# Indirect GC roots live in /nix/var/nix/gcroots/auto, owned by the
# NIX_USER account.  Grant the admin group write access there (setgid
# for group inheritance of new entries), so members can run
# `nix-store --add-root ...` as themselves without sudo.  A directory
# already handed to some other group is left alone (warn + manual
# hint), so the script never clobbers a deliberate local choice.
gcroots_auto="$NIX_ROOT/var/nix/gcroots/auto"
if [ ! -e "$gcroots_auto" ]
then
    # Create inside the NIX_USER-owned tree AS the nix user, so that any
    # missing intermediate directories (/nix/var, /nix/var/nix, ...) are
    # nix-owned from birth; creating them as root would leave the nix
    # account unable to write its own var tree on a fresh install.
    sudo -u "$NIX_USER" mkdir -p "$gcroots_auto"
fi
cur_owner="$(stat -c '%U' "$gcroots_auto")"
cur_group="$(stat -c '%G' "$gcroots_auto")"
if [ "$cur_owner" = root ] \
   || { [ "$cur_owner" = "$NIX_USER" ] && [ "$cur_group" = "$NIX_USER" ]; }
then
    # Freshly created by the mkdir above, or still in the nix-install
    # default state: configure it.
    chown "$NIX_USER" "$gcroots_auto"
    chgrp "$NIXADM_GROUP" "$gcroots_auto"
    chmod 2775 "$gcroots_auto"
    echo "$gcroots_auto is group-writable by '$NIXADM_GROUP' (admins may register GC roots)"
elif [ "$cur_owner" = "$NIX_USER" ] && [ "$cur_group" = "$NIXADM_GROUP" ] \
     && [ "$(stat -c '%a' "$gcroots_auto")" = 2775 ]
then
    echo "$gcroots_auto is already group-writable by '$NIXADM_GROUP'"
else
    echo "$0: $gcroots_auto is ${cur_owner}:${cur_group} -- neither the default" >&2
    echo "state nor '$NIXADM_GROUP'; leaving it untouched.  To hand it to" >&2
    echo "'$NIXADM_GROUP' manually:  chown $NIX_USER:$NIXADM_GROUP $gcroots_auto && chmod 2775 $gcroots_auto" >&2
fi

# 8. Install the sudoers fragment

sudoers_new=false
if [ -e "$sudoers_dest" ] \
   && cmp -s "$sudoers_src" "$sudoers_dest" \
   && [ "$(stat -c '%a' "$sudoers_dest")" = "440" ] \
   && [ "$(stat -c '%U:%G' "$sudoers_dest")" = "root:root" ]
then
    echo "$sudoers_dest is already installed and up to date"
else
    mkdir -p "$SUDOERS_DIR"
    echo "installing $sudoers_src as $sudoers_dest (mode 0440)"
    install -o root -g root -m 0440 "$sudoers_src" "$sudoers_dest"
    sudoers_new=true

    # Validate the installed file and remove it if validation fails,
    # so that a broken sudoers entry is never left behind
    if ! visudo -cf "$sudoers_dest" > /dev/null
    then
        echo "$0: installed $sudoers_dest failed visudo validation, removing it:" >&2
        visudo -cf "$sudoers_dest" >&2
        rm -f "$sudoers_dest"
        exit 1
    fi
fi

# 9. Add USERNAME arguments to the `nixadm` group

rc=0
added_any=false
for user in "$@"
do
    if ! getent passwd "$user" > /dev/null
    then
        echo "$0: no such user '$user', skipping" >&2
        rc=1
        continue
    fi
    if id -nG "$user" | grep -qw "$NIXADM_GROUP"
    then
        echo "user '$user' is already in group '$NIXADM_GROUP'"
    else
        echo "adding user '$user' to group '$NIXADM_GROUP'"
        usermod -aG "$NIXADM_GROUP" "$user"
        added_any=true
    fi
done

if [ "$added_any" = true ]
then
    echo ""
    echo "NOTE: newly added group members must log out and back in (or open a"
    echo "fresh shell via 'su - <user>' or 'newgrp $NIXADM_GROUP') before the"
    echo "passwordless sudo rule takes effect in their existing sessions."
fi

# 10. Print next-step guidance

echo ""
if [ "$sudoers_new" = true ]
then
    echo "Members of group '$NIXADM_GROUP' may now run commands as the '$NIX_USER'"
    echo "user without a password."
    echo ""
fi
if [ "$nix_installed" = true ]
then
    echo "Nix is installed and verified; no installation step is needed."
    echo "Re-run this script any time to re-check the setup."
else
    echo "Next, run the unprivileged installation script as the '$NIX_USER' user:"
    echo ""
    echo "    sudo -iu $NIX_USER $script_dir/nix_install.sh"
    echo ""
    echo "If the '$NIX_USER' user cannot read this repository (e.g. restrictive home"
    echo "directory permissions), copy 'nix_install.sh' somewhere readable first,"
    echo "e.g.:  cp $script_dir/nix_install.sh /tmp/ && chmod a+rx /tmp/nix_install.sh"
fi

exit $rc
