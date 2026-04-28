#! /bin/bash
# has issues related to timeouts and sleep iterations
TEMPLATE_VM_ID='105'
LAST_VM_ID=$(qm list | awk '{print $1}' | tail -1)
NEW_VM_ID=$(( $LAST_VM_ID + 1 ))
DEFAULT_VM_NAME="$NEW_VM_ID-test"
BASE_IP='10.1.0.'
GW='10.1.0.1'
NET_MASK='255.255.255.0'
DNS=''8.8.8.8

echo
read -p "Enter VM ID ($NEW_VM_ID): " VM_ID
read -p "Enter VM Name ($DEFAULT_VM_NAME): " VM_NAME
echo

if [ -n "$VM_NAME" ]; then
    $DEFAULT_VM_NAME=$VM_NAME
fi

if [ -n "$VM_ID" ]; then
    $NEW_VM_ID=$VM_ID
fi

EXIT_CODE=$(qm clone $TEMPLATE_VM_ID $NEW_VM_ID --name $DEFAULT_VM_NAME)
sleep 30

if [ "$?" == "0" ]; then
    echo "$NEW_VM_ID:           Created."
else
    echo "ERROR:"
    echo $EXIT_CODE
fi

EXIT_CODE=$(qm start $NEW_VM_ID)
sleep 120

if [ "$?" == "0" ]; then
    echo "$NEW_VM_ID:           Started."
else
    echo "ERROR:"
    echo $EXIT_CODE
fi

#
SET_IP="cmd /c netsh interface ipv4 set address name=Ethernet static $BASE_IP$NEW_VM_ID $NET_MASK $GW"
SET_DNS="cmd /c netsh interface ipv4 set dns name=Ethernet static $DNS"
REN_VM=("powershell.exe /c Rename-Computer -NewName $DEFAULT_VM_NAME")
REBOOT_VM=("cmd /c shutdown -r -f -t 3")

EXIT_CODE=$(qm guest exec $NEW_VM_ID -- $SET_IP)

if [ "$(echo $EXIT_CODE | jq '.exitcode')" == "0" ]; then
    echo "IP Address:    $BASE_IP$NEW_VM_ID"
else
    echo "ERROR:"
    echo $EXIT_CODE
fi

EXIT_CODE=$(qm guest exec $NEW_VM_ID -- $SET_DNS)

if [ "$(echo $EXIT_CODE | jq '.exitcode')" == "0" ]; then
    echo "DNS Server:    $DNS"
else
    echo "ERROR:"
    echo $EXIT_CODE
fi

EXIT_CODE=$(qm guest exec $NEW_VM_ID -- $REN_VM)

if [ "$(echo $EXIT_CODE | jq '.exitcode')" == "0" ]; then
    
    echo "$NEW_VM_ID:           Renamed to $DEFAULT_VM_NAME"
    
    EXIT_CODE=$(qm guest exec $NEW_VM_ID -- $REBOOT_VM)

    if [ "$(echo $EXIT_CODE | jq '.exitcode')" == "0" ]; then
        echo "Reboot Status: Rebooted"
        echo
    else
        echo "ERROR:"
        echo $EXIT_CODE
    fi
else
    echo "ERROR:"
    echo $EXIT_CODE
fi

