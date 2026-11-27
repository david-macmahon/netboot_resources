# NixOS configuration for the cluster netboot image.
#
# The build is site-parameterized: with no `cluster` argument this is a
# GENERIC image (self-naming, stateless, ephemeral ssh host keys) -- the
# default-fallback node state. Cluster data (private repo) activates the
# identity features: the persistent-storage mount, shared ssh host keys
# served from the persistent tree, and admin ssh access.
#
# netboot-minimal.nix imports netboot-base.nix, which imports
# netboot.nix (the module providing system.build.netbootRamdisk /
# netbootIpxeScript / squashfsStore) plus the base and
# installation-device profiles.  The netboot module is NOT part of the
# default NixOS module list, so it must be imported explicitly.
#
# The stock udev module is replaced by a patched copy
# (./udev-nixos-patched.nix): the build host's kernel 4.4 cannot run
# the systemd 260 tools used by that module's builders (statx(2) is
# missing; see the copy's header comment for the full story).
#
# IDENTITY MODEL (two modes, selected by the kernel cmdline):
#   hostname=<name> present  -> identity mode: the cmdline is provided by
#     the node's registry-rendered iPXE script. Hostname is set early
#     (before networking, so DHCP registers the right name in DNS), and
#     /persistent symlinks to the node's storage anchor under the
#     whole-tree NFS mount /persistent-parent/<name>.
#   hostname= absent         -> generic mode: no persistent anchor, no
#     symlink; the node is stateless triage (hostname refinement is a
#     follow-up -- see the session notes).
#
# ssh host keys live in the persistent tree
# (<persistentRoot>/.ssh-host-keys/), NOT baked into the image: they
# survive image rebuilds by construction, no private key lands in the
# world-readable nix store, and generic-mode nodes get stable keys too.
# sshd is ordered after remote-fs.target so the mount is up first.
{ cluster ? null }:

{ modulesPath, lib, ... }:

let
  # Site features activate only when cluster data is provided.
  persistentDevice =
    if cluster == null then null
    else "${cluster.nfsServer}:${cluster.persistentRoot}";
  sshAuthorizedKeys =
    if cluster == null then [ ]
    else cluster.nixos.sshAuthorizedKeys or [ ];
in
{
  imports = [
    "${modulesPath}/installer/netboot/netboot-minimal.nix"
    ./udev-nixos-patched.nix
  ];

  disabledModules = [ "services/hardware/udev.nix" ];

  # NFS client support for the persistent-storage mount.
  boot.supportedFilesystems = [ "nfs" ];

  fileSystems =
    if persistentDevice == null then { } else {
      # Whole-tree export (see the registry's exports artifact): every
      # node mounts the persistent ROOT; the node's own anchor is the
      # /persistent-parent/<hostname> subdirectory, addressed via the
      # /persistent symlink created by nixos-identity. Mounting the root
      # rather than the per-node path is what keeps a single fstab
      # entry valid for every node -- and what lets an unknown node
      # boot without any per-node mount existing.
      "/persistent-parent" = {
        device = persistentDevice;
        fsType = "nfs";
        options = [ "rw" "noatime" ];
      };
    };

  # SSH access. Server keys come from the persistent tree in site builds
  # (stable across image rebuilds); in generic builds NixOS generates
  # fresh keys at boot (ephemeral -- fine for unregistered triage nodes).
  # Admin access is key-only, via the cluster-declared public keys.
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
    hostKeys =
      if persistentDevice == null
      then [ ] # keep the default: generate at boot
      else [ {
        # Served from the whole-tree persistent mount (stable across
        # image rebuilds); the file must exist before first boot
        # (one-time generation on the head node -- see the notes).
        path = "/persistent-parent/.ssh-host-keys/ssh_host_ed25519_key";
        type = "ed25519";
      } ];
  };
  systemd.services.sshd.after = [ "remote-fs.target" ];
  users.users.root.openssh.authorizedKeys.keys = sshAuthorizedKeys;

  # Two-mode identity. Runs before networking (so the DHCP request
  # carries the right hostname and dnsmasq registers it in DNS) and
  # before sshd. Creating the /persistent symlink needs no mount: it
  # dangles until remote-fs.target mounts /persistent-parent.
  systemd.services.nixos-identity = {
    description = "Set boot identity from the kernel cmdline";
    wantedBy = [ "sysinit.target" ];
    before = [ "network-pre.target" "sshd.service" "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    script = ''
      host=""
      for p in $(cat /proc/cmdline); do
        case "$p" in
          hostname=*) host=''${p#hostname=} ;;
        esac
      done
      if [ -n "$host" ]; then
        echo "$host" > /etc/hostname
        hostname "$host"
        mkdir -p /persistent-parent
        ln -sfn "/persistent-parent/$host" /persistent
        echo "nixos-identity: identity mode (hostname=$host)"
      else
        echo "nixos-identity: generic mode (no hostname= on cmdline)"
      fi
    '';
  };
}
