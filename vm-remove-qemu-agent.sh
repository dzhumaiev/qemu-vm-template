#!/bin/bash

echo
read -p "Enter VM ID: " VM_ID
echo
EXIT_CODE=$(qm guest exec $VM_ID -- cmd /c "C:\Program Files\qemu-ga\qemu-ga.exe" -s vss-uninstall)

if [ "$(echo $EXIT_CODE | jq '.exitcode')" == "0" ]; then
    echo "GEMU-GA VSS: Removed"
else
    echo "ERROR:"
    echo $EXIT_CODE
fi

EXIT_CODE=$(qm guest exec $VM_ID -- cmd /c "C:\Program Files\qemu-ga\qemu-ga.exe" -s uninstall)

if [ "$(echo $EXIT_CODE | jq '.exitcode')" == "0" ]; then
    echo "GEMU-GA:     Removed"
else
    echo "ERROR:"
    echo $EXIT_CODE
fi

EXIT_CODE=$(qm guest exec $VM_ID -- cmd /c shutdown -r -f -t 3)

if [ "$(echo $EXIT_CODE | jq '.exitcode')" == "0" ]; then
    echo "$VM_ID:         Sent to Reboot."
    echo
else
    echo "ERROR:"
    echo $EXIT_CODE
fi
