#!/bin/bash
set -euo pipefail

source vars.sh

###
#   Part I - Download VM images
#

mkdir -p "$CACHE_DIR"
pushd "$CACHE_DIR"
[ -f "${CACHE_DIR}/debian-12.SHA512SUMS" -a -f "${CACHE_DIR}/${IMAGE_NAME}" ] || {
  curl -L "${BASE_URL}/SHA512SUMS" -o "${CACHE_DIR}/debian-12.SHA512SUMS"
  curl -L "${BASE_URL}/${IMAGE_NAME}" -o "${CACHE_DIR}/${IMAGE_NAME}"
}
sha512sum -c --ignore-missing "${CACHE_DIR}/debian-12.SHA512SUMS"
popd

##
#   Part II - Networking
#

TMPFILE=$(mktemp)

cat > "$TMPFILE" <<EOF
<network>
  <name>$NETWORK_NAME</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${BRIDGE_NAME}' stp='on' delay='0'/>
  <mac address='52:54:00:00:ff:fe'/>
  <ip address='172.31.255.254' netmask='255.255.255.0'>
   <dhcp>
    <range start='172.31.255.1' end='172.31.255.253' />
   </dhcp>
  </ip>
</network>
EOF

sudo virsh --quiet net-uuid --network "$NETWORK_NAME" &>/dev/null || {
  sudo virsh net-define --validate --file "$TMPFILE"
  sudo virsh net-start --network "$NETWORK_NAME"
}
rm -f "$TMPFILE"
sudo virsh net-autostart --network "$NETWORK_NAME"

for index in "${!VMS[@]}"; do
  vm=${VMS[$index]}
  # NOTE: limit is 255 hosts
  printf -v mac '52:54:00:00:00:%02X' $(($index + 1))
  printf -v ip "${NETWORK_IPADDR}.%d" $(($index + 1))
  echo "${vm} => mac: $mac, ip: $ip"
  sudo virsh net-update --command add-last --section ip-dhcp-host --network "$NETWORK_NAME"  "<host mac='${mac}' name='${vm}' ip='${ip}' />"
done

###
#   Part III - Create cloud-init data
#

for index in "${!VMS[@]}"; do
  vm=${VMS[$index]}
  index1=$(($index + 1))
  # NOTE: limit is 255 hosts
  printf -v mac '52:54:00:00:00:%02X' $index1
  ssh_key="$(cat ~/.ssh/id_rsa.pub)"
  mkdir -p "${CACHE_DIR}/${vm}"
  pushd "${CACHE_DIR}/${vm}"
  cat > meta-data <<-EOF
instance-id: ${vm}
hostname: ${vm}
EOF
  cat > network-config <<-EOF
version: 2
ethernets:
  eth0:
    set-name: eth0
    dhcp4: true
    match:
      macaddress: '$mac'
EOF
  [[ ! $vm =~ *oob-mgmt-* ]] && cat >> network-config <<-EOF
  swp1:
    set-name: swp1
    match:
      name: enp8s0
  swp2:
    set-name: swp2
    match:
      name: enp9s0
vrfs:
  vrf-main:
    table: 1000
    interfaces: [swp1, swp2]
EOF
  # different BGP ASN for spines
  echo "$vm" | grep -q spine && bgp_as=$SPINE_AS || bgp_as=$((65500 + $index))
  cat > user-data <<-EOF
#cloud-config
users:
  - name: debian
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - '$ssh_key'

package_update: true
packages:
- lldpd
- frr
EOF
  [[ ! $vm =~ *oob-mgmt-* ]] && cat >> user-data <<-EOF
runcmd:
- netplan apply
- sysctl -w net.ipv4.ip_forward=1
- sysctl -w net.ipv6.conf.default.forwarding=1
- sysctl -w net.ipv6.conf.all.forwarding=1
- systemctl enable lldpd.service
- systemctl start lldpd.service
- ip address add 10.1.1.$index/32 dev vrf-main
- sed -i -e's/^bgpd=no/bgpd=yes/' -e 's/^bfdd=no/bfdd=yes/' -e 's/^#frr_profile="datacenter"/frr_profile="datacenter"/' /etc/frr/daemons
- systemctl restart frr.service
write_files:
- content: |
    net.ipv4.ip_forward=1
    net.ipv6.conf.default.forwarding=1
    net.ipv6.conf.all.forwarding=1
  path: /etc/sysctl.d/30-ipforward.conf
- content: |
    log syslog informational
    route-map REDISTRIBUTE permit 10
      match interface vrf-main
    
    router bgp $bgp_as vrf vrf-main
      bgp router-id 10.1.1.$index
      bgp bestpath as-path multipath-relax
      neighbor fabric peer-group
      neighbor fabric remote-as external
      neighbor fabric bfd
      neighbor swp1 interface peer-group fabric
      neighbor swp2 interface peer-group fabric
      address-family ipv4 unicast
        neighbor fabric activate
        redistribute connected route-map REDISTRIBUTE
      exit-address-family
  path: /etc/frr/frr.conf
EOF
  sudo genisoimage -quiet -output "/var/lib/libvirt/boot/${vm}.cloudinit.iso" -volid cidata -joliet -rock user-data meta-data network-config
  popd
done

###
#   Part IV - Define VMs
#

for vm in ${VMS[@]}; do
  sudo cp -fv "${CACHE_DIR}/${IMAGE_NAME}" "/var/lib/libvirt/images/${vm}.qcow2"
done


for index in "${!VMS[@]}"; do
  vm=${VMS[$index]}
  # NOTE: limit is 255 hosts
  printf -v mac '52:54:00:00:00:%02X' $(($index + 1))
  sudo virt-install \
    --name "${vm}" \
    --os-variant debian12 \
    --disk "/var/lib/libvirt/images/${vm}.qcow2" \
    --disk path="/var/lib/libvirt/boot/${vm}.cloudinit.iso" \
    --import \
    --vcpu 1 \
    --memory 512 \
    --network="network=${NETWORK_NAME},mac=${mac}" \
    --graphics none \
    --sound none \
    --console pty,target_type=serial \
    --autostart \
    --noautoconsole \
    --print-xml | sudo virsh define --file /dev/stdin
done

##
#   Part V - Create topology links
#

#leaf01 --> spine01 & spine02
sudo virsh attach-device --domain leaf01 link-leaf01-spine01.xml --config
sudo virsh attach-device --domain leaf01 link-leaf01-spine02.xml --config

#leaf02 --> spine01 & spine02
sudo virsh attach-device --domain leaf02 link-leaf02-spine01.xml --config
sudo virsh attach-device --domain leaf02 link-leaf02-spine02.xml --config

#spine01 --> leaf01 & leaf02
sudo virsh attach-device --domain spine01 link-spine01-leaf01.xml --config
sudo virsh attach-device --domain spine01 link-spine01-leaf02.xml --config

#spine02 --> leaf01 & leaf02
sudo virsh attach-device --domain spine02 link-spine02-leaf01.xml --config
sudo virsh attach-device --domain spine02 link-spine02-leaf02.xml --config

##
#   Part VI - Start VMs
#

for vm in ${VMS[@]}; do
  sudo virsh start --domain "$vm"
done
