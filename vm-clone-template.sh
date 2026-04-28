#!/bin/bash

# to get <VM ID>:
# qm list
# to clone qeme VM template with ID + 1 increament 
# vm-clone-template.sh <VM ID>

TEMPLATE_VM_ID=$1
LAST_VM_ID=$(qm list | awk '{print $1}' | tail -1)
NEW_VM_ID=$($LAST_VM_ID + 1)

qm clone $TEMPLATE_VM_ID $NEW_VM_ID --name vm5-test

