# Registry artifact renderer for netboot clusters.
#
# Consumes a "cluster" value holding site-level settings plus the node
# registry, and produces a content-addressed tree (linkFarm) of deployable
# artifacts:
#
#   etc-hosts.managed   managed block for /etc/hosts (marker-delimited)
#   ethers.managed      managed block for /etc/ethers (marker-delimited)
#   exports.managed     managed block for /etc/exports (marker-delimited)
#   persistent-dirs     manifest of persistent-storage anchors to materialize
#   pxelinux.cfg/<hexip>  one file per node with a non-null `pxe` profile
#
# Cluster value shape (site data lives in the private cluster repo):
#
#   {
#     site           = "example_site";
#     domain         = "node.example";   # netboot node DNS domain
#     ipmiDomain     = "bmc.example";    # BMC DNS domain
#     ipmiSuffix     = "x";              # BMC name = <node-name> + suffix
#     sitePrefix     = "ex";             # optional; renders <prefix>-<name> aliases
#     nfsServer      = "10.0.0.1";
#     persistentRoot = "/srv/nixos/persistent";
#     nodes = {
#       <name> = {
#         mac     = "aa:bb:cc:dd:ee:ff";  # primary NIC: DHCP + PXE + persistent
#         ip      = "10.0.0.n";           #   anchor key; required, no placeholders
#         ipmi    = { mac = "..."; ip = "10.0.1.n"; };    # optional BMC
#         role    = "compute";            # free-form; "head" = no /persistent
#         pxe     = null;                 # null = no PXE file managed yet
#         aliases = [ "oldname" ];        # optional extra DNS names
#       };
#     };
#   }
#
# Design rules enforced here:
#   * MACs are normalized (trimmed, lowercased, '-' -> ':') BEFORE uniqueness
#     asserts, so case/separator variants can't masquerade as distinct hosts.
#   * A node with a missing or malformed MAC/IP is a BUILD-TIME ERROR. The
#     registry never emits placeholder entries (# TBD etc.).
#   * Identity is the functional name plus the primary MAC. Canonical names
#     are not part of the schema; anything worth keeping can ride `aliases`.

{ cluster }:

let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;

  nodes = cluster.nodes;
  nodeNames = lib.sort (a: b: a < b) (builtins.attrNames nodes);

  fail = msg: builtins.throw "registry: ${msg}";

  # ---- small helpers ------------------------------------------------------

  trim = s: lib.strings.trim s;

  # Normalize a MAC: trim whitespace, lowercase, dashes -> colons.
  normMac = s: lib.toLower (lib.replaceStrings [ "-" ] [ ":" ] (trim (toString s)));

  macOk = m:
    lib.strings.match "([0-9a-f]{2}:){5}[0-9a-f]{2}" m != null;

  # String octet -> int (no builtins.parseInt in this Nix).
  digitVal = c:
    lib.head (lib.filter
      (i: lib.elemAt (lib.stringToCharacters "0123456789") i == c)
      (lib.range 0 9));
  toInt = s: lib.foldl' (acc: c: acc * 10 + digitVal c) 0 (lib.stringToCharacters s);

  hexDigits = lib.stringToCharacters "0123456789ABCDEF";
  hexByte = n: lib.elemAt hexDigits (n / 16) + lib.elemAt hexDigits (lib.mod n 16);

  # dotted-quad IPv4 -> 8-char uppercase hex, pxelinux.cfg style (10.0.0.75 ->
  # 0A00004B).
  hexip = ip:
    lib.concatMapStrings (o: hexByte (toInt (trim o))) (lib.splitString "." ip);

  # Left-pad-ish: pad s with spaces to at least w columns.
  pad = w: s: s + lib.concatStrings (lib.replicate (lib.max 0 (w - lib.stringLength s)) " ");

  assertUnique = what: list:
    assert lib.assertMsg
      (lib.length (lib.unique list) == lib.length list)
      "registry: duplicate ${what}: ${lib.concatStringsSep ", " list}";
    true;

  # ---- per-node validation -------------------------------------------------

  checkNode = name: n:
    let
      mac = if n.mac or null == null then "" else normMac n.mac;
      ip = if n.ip or null == null then "" else trim (toString n.ip);
      hasIpmi = n.ipmi or null != null;
      imac = if hasIpmi then normMac n.ipmi.mac else "";
      iip = if hasIpmi then trim (toString n.ipmi.ip) else "";
      nameOk = lib.strings.match "[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?" name != null;
    in
    assert lib.assertMsg nameOk
      "registry: node name '${name}' is not a valid hostname";
    assert lib.assertMsg (macOk mac)
      ("registry: node ${name}: missing or malformed primary MAC ('${mac}'). " +
        "DHCP, PXE and persistent storage all key on it; the registry never " +
        "emits placeholder entries -- supply the real MAC in the node data.");
    assert lib.assertMsg (lib.strings.match "[0-9.]+" ip != null && ip != "")
      "registry: node ${name}: missing or malformed IP ('${ip}')";
    if hasIpmi then
      assert lib.assertMsg (macOk imac)
        "registry: node ${name}: malformed IPMI MAC ('${imac}')";
      assert lib.assertMsg (lib.strings.match "[0-9.]+" iip != null && iip != "")
        "registry: node ${name}: missing or malformed IPMI IP ('${iip}')";
      n
    else
      n;

  checkedNodes = lib.mapAttrs checkNode nodes;

  # Global uniqueness across the whole registry.
  ethMacs = map (n: normMac n.mac) (lib.attrValues checkedNodes);
  ethIps = map (n: trim n.ip) (lib.attrValues checkedNodes);
  ipmiNodes = lib.filter (n: n.ipmi or null != null) (lib.attrValues checkedNodes);
  ipmiMacs = map (n: normMac n.ipmi.mac) ipmiNodes;
  ipmiIps = map (n: trim n.ipmi.ip) ipmiNodes;

  assertUniqueness = [
    (assertUnique "primary MACs" ethMacs)
    (assertUnique "primary IPs" ethIps)
    (assertUnique "IPMI MACs" ipmiMacs)
    (assertUnique "IPMI IPs" ipmiIps)
    (assertUnique "MACs (all interfaces)" (ethMacs ++ ipmiMacs))
  ];

  # ---- /etc/hosts block ----------------------------------------------------

  # BMC name: <node><ipmiSuffix> unless the node overrides it.
  ipmiName = name: n: n.ipmi.name or "${name}${cluster.ipmiSuffix or "x"}";

  nodeHostLine = name:
    let
      n = checkedNodes.${name};
      names =
        [ "${name}.${cluster.domain}" ]
        ++ lib.optional (cluster.sitePrefix or null != null)
          "${cluster.sitePrefix}-${name}.${cluster.domain}"
        ++ map (a: "${a}.${cluster.domain}") (n.aliases or [ ])
        ++ lib.optional (n.role or "" == "head") name;
    in
    pad 16 (trim n.ip) + lib.concatStringsSep "  " names;

  ipmiHostLine = name:
    let
      n = checkedNodes.${name};
    in
    assert lib.assertMsg (n.ipmi or null != null)
      "registry: node ${name}: hosts renderer hit node without ipmi";
    pad 16 (trim n.ipmi.ip) + "${ipmiName name n}.${cluster.ipmiDomain}";

  # Nodes that carry IPMI entries, sorted by BMC name for stable output.
  ipmiNodeNames = lib.sort (a: b: lib.toLower (ipmiName a checkedNodes.${a})
    < lib.toLower (ipmiName b checkedNodes.${b}))
    (lib.filter (name: checkedNodes.${name}.ipmi or null != null) nodeNames);

  # ---- /etc/hosts block -----------------------------------------------------
  # ONE rendered hosts content, ONE channel (design decision, revised from
  # the earlier "option (a)" two-channel design): the marker-delimited block
  # in /etc/hosts serves BOTH consumers -- the head node's own resolver
  # (nsswitch reads /etc/hosts: zero-dependency, survives dnsmasq being
  # down) AND dnsmasq's cluster DNS (dnsmasq reads /etc/hosts by default and
  # re-reads it on SIGHUP; no `no-hosts` directive is set). Site entries
  # living outside the block (power strips, appliances, ...) remain cluster-
  # resolvable the same way. A separate addn-hosts file was tried and
  # dropped: pure duplication of the block. /etc/netboot-registry/ keeps
  # only what CANNOT ride in a hosts file: the DHCP reservations.

  hostsBody = ''
    ${lib.concatStringsSep "\n" (map nodeHostLine nodeNames)}

    # IPMI/BMC interfaces (${cluster.ipmiDomain})
    ${lib.concatStringsSep "\n" (map ipmiHostLine ipmiNodeNames)}
  '';

  hostsManaged = ''
    # BEGIN netboot-registry managed entries -- GENERATED FILE, DO NOT EDIT.
    # Regenerate from the node registry (nodes/*.nix in the cluster repo)
    # and redeploy with the registry apply script.
    ${hostsBody}
    # END netboot-registry managed entries
  '';

  # ---- /etc/ethers block ----------------------------------------------------
  # dnsmasq on the head node runs with `read-ethers`, so these entries are
  # both the ARP source AND the DHCP static reservations (including the
  # static-only IPMI range).

  ethersNode = name:
    let
      n = checkedNodes.${name};
      ipmiLines = lib.optionals (n.ipmi or null != null) [
        "${pad 20 (normMac n.ipmi.mac)}${trim n.ipmi.ip}"
      ];
    in
    lib.concatStringsSep "\n" ([ "# ${name}" ] ++ [
      "${pad 20 (normMac n.mac)}${trim n.ip}"
    ] ++ ipmiLines);

  ethersManaged = ''
    # BEGIN netboot-registry managed entries -- GENERATED FILE, DO NOT EDIT.
    # TRANSITIONAL: rendered only for the cutover. Registry DHCP
    # reservations have moved to the dnsmasq dhcp-hostsfile; the apply
    # script uses this block to REMOVE the registry's entries from
    # /etc/ethers (other, non-registry entries and read-ethers stay).
    ${lib.concatStringsSep "\n\n" (map ethersNode nodeNames)}
    # END netboot-registry managed entries
  '';

  # ---- /etc/exports block ---------------------------------------------------
  # Whole-tree export of the persistent root: ONE line per client spec,
  # independent of fleet size. Per-node exports would scale /etc/exports
  # with the cluster AND couple node boot-time mounts to deploy ordering;
  # whole-tree keeps the exports block constant (policy, not node data)
  # and lets any node mount its anchor as long as NFS is up. Client
  # subnet(s) and options are site policy, declared in the cluster data
  # (nfs.clients / nfs.options); a missing or empty declaration is a
  # build-time error, consistent with the placeholder-free rule.

  nfsClients = cluster.nfs.clients or
    (fail "cluster data is missing nfs.clients (list of client specs, e.g. [ \"10.0.0.0/24\" ])");
  nfsOptions = cluster.nfs.options or
    (fail "cluster data is missing nfs.options (export options string, e.g. \"rw,no_root_squash\")");
  nfsClients' =
    if nfsClients == [ ] || nfsClients == [ "" ]
    then fail "nfs.clients must list at least one non-empty client spec"
    else nfsClients;

  exportsLines = lib.concatStringsSep "\n"
    (map (client: "${cluster.persistentRoot} ${client}(${nfsOptions})")
      nfsClients');

  exportsManaged = ''
    # BEGIN netboot-registry managed exports -- GENERATED FILE, DO NOT EDIT.
    # Regenerate from the node registry (nodes/*.nix in the cluster repo)
    # and redeploy with the registry apply script.
    ${exportsLines}
    # END netboot-registry managed exports
  '';

  # ---- dnsmasq DHCP reservations -------------------------------------------
  # Replaces /etc/ethers + read-ethers for registry nodes. Installed as a
  # dhcp-hostsfile (one host per line, format = right-hand side of
  # dhcp-host=); dnsmasq re-reads it on SIGHUP. No hostnames here on
  # purpose: DHCP-derived DNS names would inherit the global `domain=`
  # setting (wrong domain for the mgt subnet); all names come from the
  # hosts-format files instead. read-ethers stays enabled for the
  # historical non-registry entries in /etc/ethers.

  dhcpHostLine = name:
    let
      n = checkedNodes.${name};
      ipmiLines = lib.optionals (n.ipmi or null != null) [
        "${normMac n.ipmi.mac},${trim n.ipmi.ip}"
      ];
    in
    lib.concatStringsSep "\n"
      ([ "${normMac n.mac},${trim n.ip}" ] ++ ipmiLines);

  dnsmasqDhcpHostsFile = ''
    # Registry-rendered DHCP reservations, installed as a dnsmasq
    # dhcp-hostsfile (at /etc/netboot-registry/dhcp-hosts -- never in
    # /etc/dnsmasq.d, which dnsmasq parses as config). GENERATED from
    # the node registry -- do not edit here;
    # redeploy with the registry apply script. dnsmasq re-reads this file
    # on SIGHUP.
    ${lib.concatStringsSep "\n" (map dhcpHostLine nodeNames)}
  '';

  # ---- dnsmasq static pointer file ------------------------------------------
  # The only config-directive file. Configuration is NOT re-read on SIGHUP
  # (unlike the file it points to), so this file should rarely change; the
  # apply script restarts dnsmasq whenever its CONTENT changes.

  dnsmasqConfFile = ''
    # Netboot registry drop-in: static pointers to the registry-rendered
    # files (which ARE re-read on SIGHUP). Generated by the registry
    # machinery; edit the cluster repo's node registry, not this file.
    #
    # Cluster DNS comes from the /etc/hosts managed block (dnsmasq reads
    # /etc/hosts by default and re-reads it on SIGHUP). The DHCP data file
    # lives in /etc/netboot-registry/, NOT here: dnsmasq's conf-dir loads
    # EVERY file in /etc/dnsmasq.d as a config file, and hosts-format data
    # is fatal as config ("bad option" at startup). Only genuine config
    # directives belong in the dnsmasq config directory.
    dhcp-hostsfile=/etc/netboot-registry/dhcp-hosts
  '';

  # ---- persistent-storage manifest -----------------------------------------
  # One line per netboot node:  <mac> <name>
  # The apply script materializes:
  #   <persistentRoot>/by-mac/<mac>      real dir   (chassis-stable anchor)
  #   <persistentRoot>/<name> -> by-mac/<mac>   symlink (what nodes mount)
  # Head nodes are excluded (they are not netbooted and own their disks).

  persistentNodes = lib.filter (name: checkedNodes.${name}.role or "" != "head")
    nodeNames;

  persistentManifest = ''
    # persistent-root: ${cluster.persistentRoot}
    # Registry persistent-storage manifest: <primary-mac> <node-name>
    # Anchor dirs are MAC-keyed (the chassis-stable property), symlinks are
    # functional-name-keyed (what nodes mount over /persistent).
    ${lib.concatStringsSep "\n"
      (map (name: "${normMac checkedNodes.${name}.mac} ${name}") persistentNodes)}
  '';

  # ---- per-node PXE files ----------------------------------------------------
  # pxelinux.cfg/<hexip> files, one per node with a non-null `pxe` profile.
  # Profiles are defined here in the machinery; site data only references
  # them by name. An unknown profile is a build error.

  pxeProfiles = { }; # extended as boot profiles are integrated (e.g. nixos)

  pxeNodeNames = lib.filter (name: checkedNodes.${name}.pxe or null != null)
    nodeNames;

  assertPxeProfiles = map
    (name:
      assert lib.assertMsg
        (lib.hasAttr checkedNodes.${name}.pxe pxeProfiles)
        ("registry: node ${name}: unknown pxe profile " +
          "'${toString checkedNodes.${name}.pxe}' (known: " +
          "${lib.concatStringsSep ", " (lib.attrNames pxeProfiles)})");
      true)
    pxeNodeNames;

  pxeFiles = map (name:
    { name = "pxelinux.cfg/${hexip checkedNodes.${name}.ip}";
      path = pxeProfiles.${checkedNodes.${name}.pxe};
    }) pxeNodeNames;

  # ---- artifacts ---------------------------------------------------------------

  artifacts = pkgs.linkFarm "registry-artifacts" (
    [
      { name = "etc-hosts.managed"; path = pkgs.writeText "etc-hosts.managed" hostsManaged; }
      { name = "dnsmasq-registry.conf"; path = pkgs.writeText "dnsmasq-registry.conf" dnsmasqConfFile; }
      { name = "dnsmasq-registry.dhcp-hosts"; path = pkgs.writeText "dnsmasq-registry.dhcp-hosts" dnsmasqDhcpHostsFile; }
      { name = "exports.managed"; path = pkgs.writeText "exports.managed" exportsManaged; }
      { name = "ethers.managed"; path = pkgs.writeText "ethers.managed" ethersManaged; }
      { name = "persistent-dirs"; path = pkgs.writeText "persistent-dirs" persistentManifest; }
    ]
    ++ pxeFiles
  );

in
assert lib.all lib.id (assertUniqueness ++ assertPxeProfiles);
artifacts
