# NixOS configuration for the cluster netboot image (EXPERIMENT - untracked).
#
# Customizations beyond the stock minimal netboot profile are layered
# here as the migration proceeds.
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
{ modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/netboot/netboot-minimal.nix"
    ./udev-nixos-patched.nix
  ];

  disabledModules = [ "services/hardware/udev.nix" ];
}
