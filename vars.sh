#!/bin/bash

CACHE_DIR=~/.cache/virt-images
BASE_URL=https://cloud.debian.org/images/cloud/bookworm/latest
IMAGE_NAME=debian-12-genericcloud-amd64.qcow2

NETWORK_NAME=mgmt-net01
BRIDGE_NAME=virbr100
NETWORK_IPADDR=172.31.255
SPINE_AS=65500

VMS=(
  oob-mgmt-server
  leaf01
  leaf02
  spine01
  spine02
)
