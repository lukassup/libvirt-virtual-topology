#!/bin/bash
set -euo pipefail

source vars.sh

for vm in ${VMS[@]}; do
  sudo virsh --quiet domuuid --domain "$vm" &>/dev/null && {
    sudo virsh destroy --domain "$vm" || : # ignore failure on stopped vms
    sudo virsh undefine --domain "$vm"
  }
done

sudo virsh --quiet net-uuid --network "$NETWORK_NAME" &>/dev/null && {
  sudo virsh net-destroy --network "$NETWORK_NAME"
  sudo virsh net-undefine --network "$NETWORK_NAME"
}
