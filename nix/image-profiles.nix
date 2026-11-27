# Image profile library: named NixOS configuration modules that vary the
# BUILT image. The cluster picks profile NAMES per node
# (nodes.<name>.imageProfile, default "base"); the image build
# instantiates exactly the profiles in use, producing one payload
# directory per profile (<payload-dir>/<profile>/).
#
# Scope discipline: a profile is for hardware/driver variety that
# genuinely needs different packages in the image (GPU driver flavors).
# Per-node variation that needs no different packages -- disks, fabric
# IPs, service activation -- belongs in the persistent tree (the anchor
# shadows the rootfs), never here. Keep the set small; "pin per profile
# and bump deliberately" is the upgrade policy (a profile may pin its
# own nixpkgs revision when a driver needs one; the NVIDIA kernel module
# must build against the image's kernel, so big driver jumps can force
# a whole-pin bump).
{
  # No GPU-specific configuration.
  base = null;
}
