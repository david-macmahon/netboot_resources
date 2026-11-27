# Build the netboot boot artifacts for the cluster (EXPERIMENT - untracked).
#
# The `system.build.netboot` attribute of older NixOS releases no longer
# exists (NixOS 26.05): the exports were split into
#   system.build.netbootRamdisk    (initrd with the nix-store squashfs
#                                   prepended inside it)
#   system.build.netbootIpxeScript (iPXE loader script)
#   system.build.kernel            (kernel package)
# with no aggregate.  This file re-creates the classic single-directory
# layout the stock NixOS netboot directory ships:
#
#   bzImage       the kernel
#   initrd        initramfs containing the squashfs nix store
#   netboot.ipxe  iPXE script (references bzImage and initrd by name)
#
# Build from anywhere with:
#   nix-build nix/netboot-image.nix
# (a `result` symlink appears in the working directory).
#
# With a `cluster` argument (cluster data from the private repo), the
# image gains the site's identity features: the persistent-storage NFS
# mount, ssh host keys served from the persistent tree, and the
# cluster-declared admin ssh keys. Without it, the build is the generic
# (site-less) image.
#
# `profileConfig` carries the image profile's NixOS configuration module
# (see nix/image-profiles.nix): hardware/driver variety that genuinely
# needs different packages in the image. Per-node variation that needs
# no different packages belongs in the persistent tree, not here.
{ cluster ? null, profileConfig ? null }:
let
  nixos = import <nixpkgs/nixos> {
    configuration = import ./netboot-config.nix { inherit cluster profileConfig; };
  };
  cfg = nixos.config;
in
nixos.pkgs.linkFarm "netboot-image" [
  {
    name = "bzImage";
    path = "${cfg.system.build.kernel}/${cfg.system.boot.loader.kernelFile}";
  }
  {
    name = "initrd";
    path = "${cfg.system.build.netbootRamdisk}/initrd";
  }
  {
    name = "netboot.ipxe";
    path = "${cfg.system.build.netbootIpxeScript}/netboot.ipxe";
  }
]
