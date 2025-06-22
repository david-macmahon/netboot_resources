# Netboot Resources

A collection of files that are useful for setting up an Ubuntu netboot root
filesystem.  The main functionality is provided by the script
[`netbootstrap.sh`](bootstrap/netbootstrap.dh).

## netbootstrap.sh

Make a netboot-able Ubuntu root file system directory.

### Usage

```
netbootstrap.sh NFS_SERVER_IP NFS_SUBNET

NFS_SERVER_IP is the IP address on the current host that netboot clients will
use to mount the netboot root filesystem (and others).  This value is used
when creating /etc/fstab in the netboot root filesystem.

NFS_SUBNET is the subnet over which the netboot root filesystem (and others)
will be NFS exported.  This value is is used when modifying /etc/exports on
the netboot NFS server.

Example: netbootstrap.sh 10.0.1.1 10.0.1.0/24
```

The bootstrap process can be customized by setting these environment variables,
shown here with their default values, before running `netbootstrap.sh`:

- Which release (by codename) and architecture to target.  Technically, `ARCH`
  defaults to `$(dpkg --print-architecture)`, but if that command fails then
  the default of `amd64` is used.

  ```sh
  CODENAME="noble"
  ARCH="amd64"
  ```

- Where to install various netboot components

  ```sh
  SRV_ROOT="/srv"
  ```

- Where to install files for TFTP

  ```sh
  TFTPBOOT_DIR="${SRV_ROOT}/tftpboot"
  ```

### What it does

The `netbootstrap.sh` script performs two main function:

- Build the root filesystem
- Configure the head node

The last few steps of stitching together the DHCP server, TFTP server, and PXE
boot menu on the head node are heavily dependent on the local configuration.
Additional resources to support these remaining few tasks will be developed and
included in this repository.  Stay tuned!

Read on for details of what the script does.

#### Build the root filesystem

1. Use `debootstrap` to create a minimalistic root filesystem (rootfs)

   This will run `debootstrap` to create the base root filesystem if the
   destination does not exist.  If the destination does exist, then it will
   skip the `debootstrap` step and assume that it was already initialized
   appropriately.  This is to support the manual creation of the netboot root
   filesystem if desired.  Note that `netbootstrap.sh` downloads a modern
   version of `debootstrap` to avoid problems such as an old `debootstrap`
   version not knowing about newer OS releases, so manual creation should
   rarely be necessary.

2. Make the rootfs chroot-able

   To be chroot-able (and friendly to `apt`), the netboot root filesystem needs
   to have `/proc`, `/sys`, and `/dev/pts` mounted in the netboot root
   filesystem tree.  If `/proc` is already mounted in the netboot root
   filesystem, then this script will assume that all of these mounts have been
   already configured.  If `/proc` is NOT mounted in the netboot root
   filesystem, this script will modify `/etc/fstab` to include lines that
   specify how to mount `/proc`, `/sys`, and `/dev/pts`, as well as a tmpfs
   mount on `/tmp` and bind mount of `/homa` in the netboot root filesystem
   tree and then mount them.  The existing `/etc/fstab` is backed up to
   `/etc/fstab.netbootstrap.YYYYmmddHHMMSS`, where `YYYYmmddHHMMSS` is the time
   of the backup, before any modifications are made.

   This step also copies a utility script `nbroot` to `/usr/local/sbin` on the
   head node.  This script is a convenience wrapper around `chroot` to simplify
   `chroot`-ing to netboot root filesystems.

3. chroot into rootfs and install additional packages (and remove some).

   This beefs up the netboot rootfs with more packages and removes some
   conventional boot related packages that we don't want/need for netboot.  This
   step also removes the `/etc/hostname` file from the netboot rootfs.  This
   step will be skipped if it looks like it has already been done.

4. Add some netboot-specific `tmpfiles.d` files to rootfs `/etc/tmpfiles.d`.

   All the netboot clients NFS mount the same rootfs as read-only.  Some daemons
   expect to be able to write state information to `/var`, which it part of the
   read-only root file system.  To facilitate this, the netboot nodes also NFS
   mount a host-specific directory from the head node as read-write.  To create
   the requisite subdirectories and symlinks, files provided in
   [`netboot_root_files/etc/tmpfiles.d`](../netboof_root_files/etc/tmpfiles.d)
   are copied to the `/etc/tmpfiles.d` directory of rootfs.  See the comments in
   [`netboot-base.conf`](../netboof_root_files/etc/tmpfiles.d/netboot-base.conf)
   for more details.

5. Run `systemd-tmpfiles --create` in the rootfs for the new `tmpfiles.d`
   files.

   The symlinks in the rootfs cannot be created by the netboot clients because
   they mount rootfs as read-only, so the symlinks must be pre-created on the
   head node by `chroot`-ing into rootfs and running `systemd-tmpfiles
   --create`.

6. Setup `initramfs-tools` in rootfs and run `update-initramfs`.

   The initramfs filesystem performs early initialization of a booting system.
   The `initramfs-tools` package provides a convenient way to add various
   customizations to this process.  In addition to a netboot specific
   [`initramfs.conf`](../netboot_root_files/etc/initramfs-tools/initramfs.conf)
   file, an additional script is included to mount the host-specific read-write
   persistent filesystem as early as possible.

7. Setup `/etc/fstab` file in rootfs.

   The `/etc/fstab` file of the rootfs is configured to include the NFS root
   directory and the `/home` directory.  Entries are also created for `tmpfs`
   filesystems `/tmp` and `/var/lib/sudo`.  The file is not modified if it looks
   like it has already been configured.

#### Setup the head node

At this point rootfs is technically netbootable, but in order for clients to
actually netboot it some additional configuration is required on the head
node.


8. Install a few packages on the head node (that may already be installed):

   The following packages are required on the head node for netbooting.

   - nfs-kernel-server
   - syslinux-common
   - pxelinux

9. Setup `/etc/exports` to export the rootfs and persistentfs

   The `/etc/exports` file on the current host is modified to export the netboot
   rootfs and persistentfs (the parent directory that will contain the host
   specific persistent filesystems) and `/home` over the `NFS_SUBNET` subnet.
   The existing `/etc/exports` file will be backed up prior to modification in a
   manner similar to `/etc/fstab`.  This step also creates the parent directory
   for the host-specific persistent directories.

10. Copy some files to a tftpboot directory on the head node

    The PXE boot process uses TFTP to transfer boot related files to the netboot
    clients.  These files are copied or symlinked to a common directory that
    defaults to `/srv/tftpboot`, but can be overidden by exporting the
    `TFTPBOOT_DIR` environemt variable before running this script.

## Next steps

A few essential steps are remain to be done at this point:

- Finalize the configuration of the PXE boot menu.

  This could be as simple as renaming (or symlinking) the sample PXE
  configuration file created in the last step to `default`.

- Finalize the configuration of the DHCP and TFTP servers to support PXE boot.

  This step depends on which programs are being used to provide these services.

- Create per-host subdirectories in persistentfs.

  This can be accomplished by running the ansible playbook
  `playbooks/persistent-dirs.yml`.  That playbook requires that the
  `persistent_root` ansible variable is set to the directory specified as
  `PERSISTENT_ROOT` in the `netbootstrap.sh` script, e.g.
  `/srv/noble/persistent`.  This ansible can be defined in the inventory file
  or on the `ansible-playbook` command line.  For example:

      ansible-playbook -e persistent_root=/srv/noble/persistent playbooks/persistent-dirs.yml

- Setup users in the netboot root

  The recommended approach is to run LDAP on the head node and configure the
  netboot systems to authenticate users against the LDAP database on the head
  node.  The ansible playbook `playbooks/ldap-auth.yml` can be used to install
  the requisite packages and setup a basic `/etc/ldap.conf` file.  It requires
  that the ansible variable `netboot_domain` be set to the domain used in the
  LDAP server.  Typically this is `<oranization_name>.pvt`.  If the LDAP server
  to be used is not the first host in the ansible inventory's `head_nodes`
  group, then the `ldap_server` variable can be used to specify the desired
  LDAP server.

      ansible-playbook -e netboot_domain=bl.pvt playbooks/ldap-auth.yml

  If you wish to avoid LDAP, you may want to simply copy the non-system
  users/groups from the head node's `/etc` files to the netboot's `/etc` files.
  Note that the UIDs and GIDs of system users and groups may differ between head
  node and netboot nodes, so copying those is strongly discouraged.  If you go
  this way, don't forget to copy the corresponding entries is `/etc/shadow` and
  `/etc/gshadow`.

- Setup rsyslog to send log messages to the head node

    ansible-playbook netboot_resources/playbooks/rsyslog.yml

- Install additional drivers on the netboot nodes (e.g. GPU drivers, NIC
  drivers, etc.)

- Configure additional network interfaces on the netboot nodes.

  These are getting somewhat outside the scope of establishing a viable netboot
  system, but resources for some additional sysadmin tasks like these will also
  be made available here.

## Ansible playbooks

Ansible playbooks included in the `playbooks` subdirectory of this repository
are listed here with a brief description of what they do.

- `autofs.yml` - Setup the automounter for netboot nodes
- `dev-tools.yml` - Install useful development tools
- `ether-hosts.yml` - Manage /etc/ethers and /etc/hosts on headnode [!]
- `glusterfs.yml` - Install glusterd and config automounts on netboot nodes
- `julia.yml` - Installs Julia for the netboot nodes
- `ldap-auth.yml` - Configures netboot nodes to authenticate via LDAP
- `lldpd.yml` - Obsolete.
- `mlx_ofed.yml` - Deprecated past Ubuntu 22.
- `nfs-kernel-server.yml` - Installs nfs-kernel-server for netboot nodes
- `nvidia-cuda.yml` - Installs CUDA toolkit for netboot nodes
- `nvidia-drivers.yml` - Installedgg CUDA kernel dirvers for netboot nodes
- `persistent-dirs.yml` - Creates rsistent dirs on head node for netboot nodes
- `persistent-exports.yml` - Setup NFS exports for hosts with `exports` defined
- `persistent-local-mounts.yml` - Setup netboot local mounts (e.g. `/datax`)
- `persistent-net-udev.yml` - Setup udev rules based on `net_iface` settings
- `persistent-netplan.yml` - Setup netplan based on `net_iface` settings
- `persistent-systemd.yml` - Setup systemd netboot-persistent.target etc
- `prometheus-node-exporter.yml` - Install node exporter for netboot nodes
- `python.yml` - Install `python-is-python3` package for netboot nodes
- `rsyslog.yml` - Setup netboot rsyslog to log to head node
- `timesync.yml` - Setup netboot time zone install `systemd-timesyncd`
