# OCP4 SNO Boot-in-place with Pre-caching

Install Single Node OpenShift on an edge factory device using image pre-caching.

We want to avoid downloading all the images that are required for bootstrapping and installing OpenShift Container Platform. The limited bandwidth at remote single-node OpenShift sites can cause long deployment times. We also don't want the ZTP/Telco complexity and overhead with ZTP/Assisted Installer, we just want boot-in-place with pre-caching.

Motivations:

- not a telco workload which has very good bandwidth normally (and we do not want all the ztp/ran/telco stuff, just the pre-cache factory edge tech)
- ztp pre-cache tech (control exactly what images to pre-cache)
- bootstrap in place for a SNO factory machine
- install SNO at the edge on bare metal
- factory machine is very bandwidth constrained (so cannot easily use assisted installer or agent installer)
- will join ACM and be controlled by a hub post-install
- experimental support for bootstrap certificates that are valid for longer than the 24 hr default

🛠️ These instructions are very manually intensive .. one day i may automate this ... 🛠️

You can choose OPENSHIFT_VERSION of 4.12.8 or 4.13.1 - the ignition files for both are checked in and working. Use the appropriate version for your use case, the docs cover 4.13.1 version.

## (1) prerequisite tools and hardware and sizing

- fedora core workstation
  - laptop used for creating usb's, iso's and downloading assets, used as a jumphost
  - install fedora media writer for usb creation

   ```bash
   dnf -y install mediawriter
   ```

- git clone this repo

   ```bash
   git clone github.com/eformat/ocp4-sno-inplace-precache.git
   cd ocp4-sno-inplace-precache
   ```

- openshift-install
  - download version of OpenShift install go binary

   ```bash
   OPENSHIFT_VERSION=4.13.1
   SYSTEM_OS_ARCH=$(uname -m)
   SYSTEM_OS_FLAVOR=linux
   wget https://mirror.openshift.com/pub/openshift-v4/${SYSTEM_OS_ARCH}/clients/ocp/${OPENSHIFT_VERSION}/openshift-install-${SYSTEM_OS_FLAVOR}.tar.gz
   tar xzvf openshift-install-${SYSTEM_OS_FLAVOR}.tar.gz
   chmod 755 openshift-install
   ```

- coreos-installer
  - download latest version of coreos installer

   ```bash
   COREOS_INSTALLER_VERSION=latest
   SYSTEM_OS_ARCH=$(uname -m)
   COREOS_FLAVOR=amd64
   wget -O coreos-installer https://mirror.openshift.com/pub/openshift-v4/${SYSTEM_OS_ARCH}/clients/coreos-installer/${COREOS_INSTALLER_VERSION}/coreos-installer_${COREOS_FLAVOR}
   chmod 755 coreos-installer
   ```

- rhcos-live-iso
  - download matching version of rhcos-live iso

   ```bash
   RHCOS_MAJOR_VERSION=4.13
   RHCOS_MINOR_VERSION=4.13.0
   SYSTEM_OS_ARCH=$(uname -m)
   wget -O rhcos-${RHCOS_MINOR_VERSION}-${SYSTEM_OS_ARCH}-live.${SYSTEM_OS_ARCH}.iso https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/${RHCOS_MAJOR_VERSION}/${RHCOS_MINOR_VERSION}/rhcos-${RHCOS_MINOR_VERSION}-${SYSTEM_OS_ARCH}-live.${SYSTEM_OS_ARCH}.iso
   ```

- 2 usb's disks
  - x1 usb stick for install of factory machine iso (min. 8GB size)
  - x1 usb hdd or large stick for precache of images (min. 100GB, may need up to 300GB size depending on inventory)

- factory machine
  - minimum specs - x86_64, 8 cores, 16GB RAM, 1x 1TB SDD, 2 usb ports, Ethernet

## (2) factory machine static ip allocation, dns, ntp, networking

We assume we want a Static IP configuration for out factory machine. We need these parameters as minimum:

```bash
ip='192.168.86.45'
gateway='192.168.86.1'
netmask='255.255.255.0'
hostname='bip'
interface='enp0s25'
nameserver='192.168.86.27'
```

The factory machine will need to be able to resolve common DNS names for SNO that will be installed on it. So on the `nameserver` host configure the OpenShift wildcard A records for our `domain` e.g. If using `bind` on linux edit /var/named/dynamic.domain.db

```bash
api.bip IN      A      192.168.86.45
api-int.bip IN  A      192.168.86.45
*.apps.bip IN   A      192.168.86.45
```

and reload named and test

```bash
systemctl reload named
```

```bash
dig api.bip.domain
```

`FIXME` override ntp source at install time.

NTP is default and the factory machine will need to be able to see the fedora time servers

The fedora workstation should be able to see the factory machine and network for debug purposes and be able to ssh to it.

## (3) precache

We use the ZTP precache helper image and instructions to download our SNO image dependencies. Here are the instructions for creating this cache on a usb ssd drive that is 298GiB in size. Note that just OpenShift itself will need about 60GiB, you need more space for more operators and you also need some overhead for unzipping during the install. 250-300GiB should be adequate for most installs. We do *not* use the RAN/DU profile help or settings - that is for telco workloads.

Assuming our usb is /sda on the fedora workstation:

```bash
wipefs -a /dev/sda
```

Partition it:

```bash
podman run -v /dev:/dev --privileged \
  --rm quay.io/openshift-kni/telco-ran-tools:latest -- \
  factory-precaching-cli partition \
  -d /dev/sda \
  -s 298
```

Checks:

```bash
# check partitions
lsblk /dev/sda
# need a GPT partition table
gdisk -l /dev/sda
# verify formatted as xfs
lsblk -f /dev/sda1
```

Mount it:

```bash
mount /dev/sda1 /mnt/
```

Create a pull secret for root from our Red Hat pull secret:

```bash
cat <path to>/pull-secret | jq . > /root/.docker/config.json
```

Check our ACM HUB cluster versions to make sure we get the same image versions for download:

```bash
oc get csv -A | grep -i advanced-cluster-management
oc get csv -A | grep -i multicluster-engine
```

Start a default precache and then halt it:

```bash
podman run -v /mnt:/mnt -v /root/.docker:/root/.docker --privileged --rm quay.io/openshift-kni/telco-ran-tools -- \
   factory-precaching-cli download \
   -r 4.13.1 \
   --acm-version 2.7.4 \
   --mce-version 2.2.4 \
   --parallel 10 \
   -f /mnt
```

`Ctrl-C` this and then edit the file on disk

```bash
vi /mnt/imageset.yaml
```

Substitute in our pre-prepared file. Be explicit about versions to minimize image download size. Choose your operators and versions e.g. you can use these commands to list all operators in a particular catalog:

```bash
oc mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v4.13
oc mirror list operators --catalog registry.redhat.io/redhat/certified-operator-index:v4.13
```

For OpenShift v4.13.1 i used in this as an example (see [pre-cahe](/pre-cache) directory for 4.12,4.13 imageset yaml files):

```yaml
---
apiVersion: mirror.openshift.io/v1alpha2
kind: ImageSetConfiguration
mirror:
  platform:
    channels:
    - name: stable-4.13
      minVersion: 4.13.1
      maxVersion: 4.13.1
  additionalImages:
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.13
      packages:
        - name: multicluster-engine
          channels:
            - name: 'stable-2.2'
              minVersion: 2.2.4
              maxVersion: 2.2.4
        - name: lvms-operator
          channels:
            - name: 'stable-4.13'
              minVersion: 4.13.1
              maxVersion: 4.13.1
        - name: nfd
          channels:
            - name: 'stable'
              minVersion: 4.13.0-202305262054
              maxVersion: 4.13.0-202305262054
        - name: mtv-operator
          channels:
            - name: 'release-v2.4'
              minVersion: 2.4.1
              maxVersion: 2.4.1
        - name: kubevirt-hyperconverged
          channels:
            - name: 'stable'
              minVersion: 4.13.0
              maxVersion: 4.13.0
        - name: kubernetes-nmstate-operator
          channels:
            - name: 'stable'
              minVersion: 4.13.0-202305262054
              maxVersion: 4.13.0-202305262054
    - catalog: registry.redhat.io/redhat/certified-operator-index:v4.13
      packages:
        - name: gpu-operator-certified
          channels:
            - name: 'v23.3'
              minVersion: 23.3.2
              maxVersion: 23.3.2
```

Now rerun precache with the `--skip-imageset` argument set so it uses our file:

```bash
podman run -v /mnt:/mnt -v /root/.docker:/root/.docker --privileged --rm quay.io/openshift-kni/telco-ran-tools -- \
   factory-precaching-cli download \
   -r 4.13.1 \
   --acm-version 2.7.4 \
   --mce-version 2.2.4 \
   --parallel 10 \
   --skip-imageset \
   -f /mnt
```

Depending on your broadband speed (and mine is 50/20 which is pretty rubbish, i ran this overnight):

```bash
Summary:

Release:                            4.13.1
ACM Version:                        2.7.4
MCE Version:                        2.2.4
Include DU Profile:                 No
Workers:                            10

Total Images:                       320
Downloaded:                         320
Skipped (Previously Downloaded):    0
Download Failures:                  0
Time for Download:                  5h10m54s
```

and it used up this much space:

```bash
$ df -kh /mnt
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       298G   94G  205G  32% /mnt
```

## (4) usb iso create

Generate Single Node OpenShift Bootstrap In Place Config

```bash
mkdir cluster
cp install-config.yaml cluster/
./openshift-install create single-node-ignition-config --dir=cluster
```

Make ignition easier to read

```bash
cat cluster/bootstrap-in-place-for-live-iso.ign | jq . > cluster/bootstrap-in-place-for-live-iso-formatted.ign
```

Apply the diffs to the ignition to enable precache features, works around known bugs. The `bootstrap-in-place-for-live-iso-formatted-with-boot-beauty.ign` is sanitized to remove all secrets, contains the base64 encoded [mods](./mods/) files and systemd changes.

`FIXME` - we jq/butane like automation for all this.

```bash
meld \
  bootstrap-in-place-for-live-iso-formatted-with-boot-beauty-4.13.1.ign \
  cluster/bootstrap-in-place-for-live-iso-formatted.ign
```

Hostname Issue - RFE: https://github.com/coreos/fedora-coreos-tracker/issues/697

We need to customize the `master-update.fcc` file and base64 encode it with the hostname of the factory machine else hostname is not set correctly after reboot.

```bash
    - path: /etc/hostname
      mode: 0644
      contents:
        inline: bip
```

Create iso with embedded ignition

```bash
./coreos-installer iso ignition embed \
  -fi cluster/bootstrap-in-place-for-live-iso-formatted.ign rhcos-4.13.0-x86_64-live.x86_64.iso \
  -o rhcos-live.x86_64.iso
```

Setup our Static IP networking kernel arguments

```bash
ip='192.168.86.45'
gateway='192.168.86.1'
netmask='255.255.255.0'
hostname='bip'
interface='enp0s25'
nameserver='192.168.86.27'
CORE_OS_INSTALLER_ARGS="rd.neednet=1 ip=${ip}::${gateway}:${netmask}:${hostname}:${interface}:none:${nameserver}"
```

Apply the kernel args our boot iso

```bash
./coreos-installer iso kargs modify -a "${CORE_OS_INSTALLER_ARGS}" rhcos-live.x86_64.iso
```

Check all looks well

```bash
./coreos-installer iso kargs show rhcos-live.x86_64.iso
```

📀📀 Burn ISO to USB using Fedora Mediawriter ! 💾💾

## (5) copy and create precache on-machine-disk

Boot factory machine with iso disk usb.

Create disk partition for precache on main factory sdd disk /dev/sda here. We need to allow for coreos-installer to create partitions 1-4. We have a new 1TB drive and want 250GiB from the *end* of the drive to be our precache partition. Format the partition with xfs.

```bash
wipefs -a /dev/sda
sgdisk --zap-all /dev/sda
sgdisk -n 5:-250GiB:0 /dev/sda -g -c:5:data
mkfs.xfs -f /dev/sda5
```

Now also plugin the 300GB usb drive (in this case /dev/sdc1) so we can copy the precache images across to /dev/sda.

```bash
lsblk
mkdir /mnt/system
mkdir /mnt/cache
mount /dev/sda5 /mnt/system
mount /dev/sdc1 /mnt/cache
cp -Ra /mnt/cache/* /mnt/system/
umount /mnt/system /mnt/cache
```

This will take some time to copy.

Once done, remove the precache  300GB usb drive.

Reboot from the iso disk usb.

Notes: `FIXME` - recover this sda5 space at some point post SNO install. We COULD just use the second 300GB drive (labelled data) and just plug that in for both install phases - since the copy scripts use data labelled disk to podman ? rather than create on-machine-disk copies. This would negate the need for this /sda5 creation and copy stage. Although /dev/sda5 it could be kept around for a reinstall from scratch.

## (6) bootkube bootstrap

Two services run at first - `precache-images.service` and `bootkube.service`.

The precache-images.service pulls images into podman, if you ssh to factory machine using core@host you can check using

```bash
podman images
```

If either of these services fail - see trouble shooting guide.

```bash
journalctl -b -f -u precache-images.service -u bootkube.service
```

Success should look like this in journal log

```bash
Jun 08 09:25:13 bip systemd[1]: precache-images.service: Succeeded.
Jun 08 09:27:19 bip systemd[1]: bootkube.service: Succeeded.
```

The coreos image is now written to the factory server /dev/sda disk i.e.

```bash
journalctl -f
```

```bash
Jun 08 09:27:53 bip install-to-disk.sh[7674]: Read disk 2.2 GiB/4.1 GiB (53%)
```

Which should succeed and the server now reboots.

```bash
Bootstrap completed, server is going to reboot.
The system is going down for reboot at Thu 2023-06-08 09:29:22 UTC!
```

🪛🪛 Unplug the usb drive as server reboots !! we need to boot from /sda now 🪛🪛

## (7) pivot for rpm-ostree, MCD firstboot.service

`FIXME` - A pivot rpm-ostree may occur ?

`FIXME` - the first two services post bootstrap do not use the cache - even in ZTP the precache-ocp-images.service waits for the machine-config-daemon-pull.service. More work required here.

```bash
systemctl status machine-config-daemon-firstboot.service
systemctl status machine-config-daemon-pull.service
```

`FIXME` - We can see on the core NIC the following traffic post install from these activities - ideally these are cached as well / we fix the service ordering.

```bash
[core@bip ~]$ ifconfig enp0s25
enp0s25: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        ether 28:d2:44:d3:ef:1c  txqueuelen 1000  (Ethernet)
        RX packets 1006876  bytes 1432512465 (1.3 GiB)
```

## (8) bootkube post bootstrap

Once rebooted the SNO installation continues till completion.

```bash
journal -f -b -u bootkube.service
```

```bash
export KUBECONFIG=/etc/kubernetes/bootstrap-secrets/kubeconfig
oc get node
oc get csr
oc get co
```

You can monitor from the fedora jumphost as well using generated kubeconfig

```bash
export KUBECONFIG=<path to>/cluster/auth/kubeconfig
./openshift-install --dir=cluster --log-level debug wait-for install-complete
oc get co
```

And eventually login using kubadmin

```bash
oc whoami --show-console
cat <path to>/cluster/auth/kubeadmin-password
```

## Troubleshooting

### DNS is not set?, check you didn't set the wrong interface name

if you guess the factory Ethernet connection name and set it incorrectly when creating the iso:

```bash
# set this
interface='eth0'
# instead of
interface='enp0s25'
```

things may work up to a point. NetworkManager may try its best and create another connection e.g called "Wired connection 1" here:

```bash
[root@bip ~]# nmcli con show
NAME                UUID                                  TYPE      DEVICE  
Wired connection 1  b44d7e21-11b1-38cf-b352-8f1eaedc4ffb  ethernet  enp0s25 
eth0                6d882650-b5a7-4c6c-bfe3-2f940dcd2095  ethernet  --  
```

However things like DNS may not be set correctly i.e. nameserver is set to first hop host incorrectly:

```bash
[root@bip ~]# cat /etc/resolv.conf 
# Generated by NetworkManager
search lan
nameserver 192.168.86.1
```

You want to see only your interface `enp0s25` and correctly configured dns server:

```
[root@bip ~]# nmcli connection  show
NAME     UUID                                  TYPE      DEVICE  
enp0s25  63e019de-8381-4b4b-b61e-aefc90a3854a  ethernet  enp0s25

[root@bip ~]# cat /etc/resolv.conf 
# Generated by NetworkManager
nameserver 192.168.86.27
```

### Delete SNO disk partitions and retry

You created the precache, tried an install, it failed, you can retry from scratch without deleting the whole install disk, just remove the partitions created by OpenShift:

```bash
sgdisk -p /dev/sda
# in this case partition 5 has the data for precache so keep it, delete the others
sgdisk -d 1 -d 2 -d 3 -d 4 /dev/sda
```

### SSH to factory machine and see failed systemd units

You boot the factory machine iso and login via ssh core@ip.address and see:

```bash
[systemd]
Failed Units: 1
  precache-images.service
```

Debug in the journal log:

```bash
journalctl -b -f -u precache-images.service -u bootkube.service
```

Check disk partitions in particular (e.g. in this example - `loop` is the running kernel in memory, `sda` is the factory machine main ssd, `sdb` is is the boot iso)

```bash
[root@bip ~]# lsblk 
NAME   MAJ:MIN RM   SIZE RO TYPE MOUNTPOINT
loop0    7:0    0   5.7G  0 loop /run/ephemeral
loop1    7:1    0     1G  1 loop /sysroot
sda      8:0    0 931.5G  0 disk 
`-sda5   8:5    0   250G  0 part
sdb      8:16   1  29.3G  0 disk /run/media/iso
|-sdb1   8:17   1   1.1G  0 part 
`-sdb2   8:18   1   4.5M  0 part 
```

Try running the script by itself - the custom scripts are all here:

```bash
[root@bip ~]# /usr/local/bin/extract-ai.sh
```

### Oh dear, my dog ate my precache partition and has no data in it 🐕

If you are cleaning up partitions on the factory machine and see this:

```bash
[root@bip ~]# sgdisk -d 1 -d 2 -d 3 -d 4 /dev/sda
Warning: The kernel is still using the old partition table.
The new table will be used at the next reboot or after you
run partprobe(8) or kpartx(8)
The operation has completed successfully.
```

Be wary ... your `/dev/sda5` may also get its data deleted which you must then recopy from usb 😿😿😿

### Your boot certificate has expired

If the first bootstrap step takes longer than 3-5 minutes, and does not restart, you login to the factory machine, check the logs:

```bash
journalctl -b -f -u precache-images.service -u bootkube.service
```

and see messages such as this:

```bash
Jun 08 09:09:25 bip bootkube.sh[13943]: Unable to connect to the server: x509: certificate has expired or is not yet valid: current time 2023-06-08T09:09:25Z is after 2023-06-08T07:49:18Z
...
Jun 08 09:11:39 bip bootkube.sh[18055]: Error: Post "https://localhost:6443/api/v1/namespaces/kube-system/events": x509: certificate has expired or is not yet valid: current time 2023-06-08T09:11:39Z is after 2023-06-08T07:49:18Z
```

There is no easy way around this, you must regenerate you ignition (24hr hardcoded cert expiry).

💥💥 Experimental 💥💥

Do this if you want to pre-create usb iso's and need them done ahead of time and have bootstrap certs stay valid for longer than 24hr.

Build a custom openshift-installer binary for OpenShift v4.13.1 that sets all ValidityOneDay certs to ValidityOneYear certs (WARNING: they are short lived so others cannot use them nefariously).

```bash
wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.13.1/openshift-install-src-4.13.1-x86_64.tar.gz
tar xzvf openshift-install-src-4.13.1-x86_64.tar.gz
-- vi - replace all CertCfg: ValidityOneDay -> ValidityOneYear
-- hack the build.sh so we are not tagging it to git
./hack/build.sh
+ go build -mod=vendor -ldflags ' -s -w' -tags ' release' -o bin/openshift-install ./cmd/openshift-install
```

```bash
# use our custom built installer image to generate ignition
installer-8864eb719931836cf909b7f28513fc9a072cd8e4/bin/openshift-install create single-node-ignition-config --dir=cluster2

# check /opt/openshift/tls/kubelet-signer.crt is now valid for 1 Year

echo <cert base64 contents> | base64 -d | openssl x509 -text

Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: 6023397017867592810 (0x539767aca725246a)
        Signature Algorithm: sha256WithRSAEncryption
        Issuer: OU = openshift, CN = kubelet-signer
        Validity
            Not Before: Jun  8 19:26:35 2023 GMT
            Not After : Jun  7 19:26:35 2024 GMT
```

In generated ignition make sure /usr/local/bin/release-image.sh -> points to a non-ci image (compiled installer will generate registry.ci.openshift.org/origin/release)

### CNI OVNKubernetes hangs

If the install hangs on CNI with an error like this:

```bash
[root@bip ~] journalctl -f

Jun 08 18:32:08 bip kubenswrapper[2657]: E0608 18:32:08.363840    2657 pod_workers.go:965] "Error syncing pod, skipping" err="network is not ready: container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: No CNI configuration file in /etc/kubernetes/cni/net.d/. Has your network provider started?" pod="openshift-network-diagnostics/network-check-target-85lvz" podUID=851cdca1-01ae-4cb5-bdaa-dc3aca8634b6
```

I am pretty sure this is a bug / race condition. No files in

```bash
[root@bip ~]# ls /etc/kubernetes/cni/net.d/
00-multus.conf  multus.d  whereabouts.d
```

Just reboot the node again, it should come up OK and continue.

## Useful Links 📖
- [manage disk partitions with sgdisk](https://fedoramagazine.org/managing-partitions-with-sgdisk/)
- [ztp pre-caching tooling](https://docs.openshift.com/container-platform/4.13/scalability_and_performance/ztp_far_edge/ztp-precaching-tool.html)
  - [telco-ran-tools source code docs](https://github.com/openshift-kni/telco-ran-tools/blob/main/docs/ztp-precaching.md)
- bootstrap in place
  - [lab work](https://github.com/eformat/ocp4-sno-inplace)
  - [prodct docs](https://docs.openshift.com/container-platform/4.13/installing/installing_sno/install-sno-installing-sno.html)
- [openshift appliance](https://github.com/openshift/appliance)
- [coreos-installer customizing](https://github.com/coreos/coreos-installer/blob/main/docs/customizing-install.md)
- [fedora-coreos docs](https://docs.fedoraproject.org/en-US/fedora-coreos/sysconfig-network-configuration)
