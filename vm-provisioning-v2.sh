#!/usr/bin/env bash
# vm_provision.sh — Clone, configure, and start a Proxmox VM
# Usage: ./vm_provision.sh <VM_ID> [VM_NAME]
# Example: ./vm_provision.sh 201 web-server-01

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
TEMPLATE_VM_ID='105'
BASE_IP='10.1.0.'
GW='10.1.0.1'
NET_MASK='255.255.255.0'
DNS='8.8.8.8'
NETWORK_IFACE='Ethernet'

# Retry / timeout settings
CLONE_POLL_INTERVAL=5
CLONE_MAX_WAIT=120      # seconds to wait for clone to finish
AGENT_POLL_INTERVAL=10
AGENT_MAX_WAIT=180      # seconds to wait for QEMU guest agent
REBOOT_SETTLE_WAIT=30   # seconds after reboot before verifying
# How long the agent must answer *consecutively* before we trust it is stable.
# The guest agent can restart mid-boot; this catches that by requiring N seconds
# of uninterrupted responses rather than a single ping.
AGENT_STABLE_WINDOW=30  # seconds of consecutive success required
AGENT_STABLE_POLL=5     # probe interval during stability check

# Retry settings for WMI-dependent commands (e.g. Rename-Computer)
GUEST_RETRY_MAX=5
GUEST_RETRY_INTERVAL=15

# Logging
LOG_FILE="/var/log/vm_provision_$(date +%Y%m%d_%H%M%S).log"

# ─── Helpers ──────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [%-5s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
}

info()  { log "INFO"  "$@"; }
warn()  { log "WARN"  "$@"; }
error() { log "ERROR" "$@"; }

die() {
    error "$*"
    exit 1
}

# Wait for a qm status condition with timeout
# Usage: wait_for_vm_status <vm_id> <expected_status> <max_wait> <poll>
wait_for_vm_status() {
    local vm_id="$1" expected="$2" max_wait="$3" poll="$4"
    local elapsed=0
    while (( elapsed < max_wait )); do
        local status
        status=$(qm status "$vm_id" 2>/dev/null | awk '{print $2}') || true
        if [[ "$status" == "$expected" ]]; then
            return 0
        fi
        sleep "$poll"
        (( elapsed += poll )) || true
    done
    return 1
}

# Wait for the QEMU guest agent to first respond.
# Usage: wait_for_agent <vm_id> <max_wait> <poll_interval>
wait_for_agent() {
    local vm_id="$1" max_wait="$2" poll="$3"
    local elapsed=0
    info "Waiting for QEMU guest agent on VM $vm_id (max ${max_wait}s)..."
    while (( elapsed < max_wait )); do
        if qm guest exec "$vm_id" -- cmd /c echo ping &>/dev/null; then
            info "Guest agent is responsive after ${elapsed}s."
            return 0
        fi
        sleep "$poll"
        (( elapsed += poll )) || true
    done
    return 1
}

# Wait for the guest agent to remain responsive for AGENT_STABLE_WINDOW seconds
# consecutively. Resets the counter on any failure, allowing for agent restarts
# mid-boot (which is what caused the "QEMU guest agent is not running" error).
# Usage: wait_for_stable_agent <vm_id>
wait_for_stable_agent() {
    local vm_id="$1"
    local stable=0
    info "Waiting for agent to be stable for ${AGENT_STABLE_WINDOW}s (poll every ${AGENT_STABLE_POLL}s)..."
    while (( stable < AGENT_STABLE_WINDOW )); do
        if qm guest exec "$vm_id" -- cmd /c echo ping &>/dev/null; then
            (( stable += AGENT_STABLE_POLL )) || true
            info "Agent stable for ${stable}s / ${AGENT_STABLE_WINDOW}s..."
        else
            if (( stable > 0 )); then
                warn "Agent dropped out after ${stable}s — resetting stability counter."
            fi
            stable=0
        fi
        sleep "$AGENT_STABLE_POLL"
    done
    info "Agent is stable. Proceeding with guest configuration."
}

# Run a guest command and check the JSON exit code returned by the agent.
# Automatically retries once if the agent reports it is not running, since the
# agent can briefly disappear during Windows boot even after stability is confirmed.
# Usage: guest_exec <vm_id> <description> <cmd...>
guest_exec() {
    local vm_id="$1" description="$2"
    shift 2
    local result raw_exit exitcode stderr_data

    # One automatic retry on "agent not running" to handle transient drops
    for attempt in 1 2; do
        raw_exit=0
        result=$(qm guest exec "$vm_id" -- "$@" 2>&1) || raw_exit=$?

        if (( raw_exit != 0 )); then
            if [[ "$result" == *"QEMU guest agent is not running"* ]] && (( attempt == 1 )); then
                warn "[$description] Agent not running (attempt $attempt) — waiting ${AGENT_STABLE_POLL}s and retrying..."
                sleep "$AGENT_STABLE_POLL"
                continue
            fi
            die "Guest exec launch failed for: $description — $result"
        fi

        exitcode=$(echo "$result" | jq -r '.exitcode // 1')
        if [[ "$exitcode" != "0" ]]; then
            stderr_data=$(echo "$result" | jq -r '."err-data" // ""')
            error "Guest command failed [$description]: exit=$exitcode — $stderr_data"
            return 1
        fi

        info "$description: OK"
        return 0
    done

    die "Guest exec failed for: $description (agent unavailable after retry)"
}

# Retry a guest command up to GUEST_RETRY_MAX times, sleeping GUEST_RETRY_INTERVAL between attempts.
# Use for WMI-dependent commands that may fail if called too soon after boot.
# Usage: guest_exec_retry <vm_id> <description> <cmd...>
guest_exec_retry() {
    local vm_id="$1" description="$2"
    shift 2
    local attempt=1
    while (( attempt <= GUEST_RETRY_MAX )); do
        if guest_exec "$vm_id" "$description" "$@"; then
            return 0
        fi
        if (( attempt < GUEST_RETRY_MAX )); then
            warn "$description failed (attempt $attempt/$GUEST_RETRY_MAX). Retrying in ${GUEST_RETRY_INTERVAL}s..."
            sleep "$GUEST_RETRY_INTERVAL"
        fi
        (( attempt++ )) || true
    done
    die "$description failed after $GUEST_RETRY_MAX attempts."
}

# ─── Input validation ─────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 <VM_ID> [VM_NAME]"
    echo "  VM_ID   Numeric Proxmox VM ID (must not already exist)"
    echo "  VM_NAME Optional hostname for the cloned VM"
    exit 1
}

[[ $# -lt 1 ]] && usage

NEW_VM_ID="$1"
DEFAULT_VM_NAME="${NEW_VM_ID}-test"
VM_NAME="${2:-$DEFAULT_VM_NAME}"

# Validate VM ID is numeric
if ! [[ "$NEW_VM_ID" =~ ^[0-9]+$ ]]; then
    die "VM_ID must be a positive integer. Got: '$NEW_VM_ID'"
fi

# Validate VM name (alphanumeric + hyphens, no spaces)
if ! [[ "$VM_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?$ ]]; then
    die "VM_NAME must be alphanumeric (hyphens allowed, no spaces). Got: '$VM_NAME'"
fi

# Ensure template VM exists
if ! qm status "$TEMPLATE_VM_ID" &>/dev/null; then
    die "Template VM $TEMPLATE_VM_ID does not exist or is inaccessible."
fi

# Ensure target VM ID is not already in use
if qm status "$NEW_VM_ID" &>/dev/null; then
    die "VM ID $NEW_VM_ID already exists. Choose a different ID or remove it first."
fi

TARGET_IP="${BASE_IP}${NEW_VM_ID}"

info "============================================================"
info "Provisioning VM: ID=$NEW_VM_ID  Name=$VM_NAME  IP=$TARGET_IP"
info "============================================================"

# ─── Step 1: Clone ────────────────────────────────────────────────────────────
info "Cloning template VM $TEMPLATE_VM_ID → $NEW_VM_ID ($VM_NAME)..."
if ! qm clone "$TEMPLATE_VM_ID" "$NEW_VM_ID" --name "$VM_NAME" --full; then
    die "Failed to initiate clone of VM $TEMPLATE_VM_ID."
fi

info "Waiting for VM $NEW_VM_ID to reach 'stopped' state (max ${CLONE_MAX_WAIT}s)..."
if ! wait_for_vm_status "$NEW_VM_ID" "stopped" "$CLONE_MAX_WAIT" "$CLONE_POLL_INTERVAL"; then
    die "Timed out waiting for VM $NEW_VM_ID clone to complete."
fi
info "VM $NEW_VM_ID cloned successfully."

# ─── Step 2: Start ────────────────────────────────────────────────────────────
info "Starting VM $NEW_VM_ID..."
if ! qm start "$NEW_VM_ID"; then
    die "Failed to start VM $NEW_VM_ID."
fi

info "Waiting for VM $NEW_VM_ID to reach 'running' state..."
if ! wait_for_vm_status "$NEW_VM_ID" "running" 60 5; then
    die "VM $NEW_VM_ID did not reach running state in time."
fi

if ! wait_for_agent "$NEW_VM_ID" "$AGENT_MAX_WAIT" "$AGENT_POLL_INTERVAL"; then
    die "QEMU guest agent on VM $NEW_VM_ID did not respond within ${AGENT_MAX_WAIT}s."
fi

wait_for_stable_agent "$NEW_VM_ID"

# ─── Step 3: Network configuration ───────────────────────────────────────────
info "Configuring IP address: $TARGET_IP / $NET_MASK via $GW..."
guest_exec "$NEW_VM_ID" "Set static IP" \
    cmd /c netsh interface ipv4 set address \
    name="$NETWORK_IFACE" static "$TARGET_IP" "$NET_MASK" "$GW"

info "Configuring DNS: $DNS..."
guest_exec "$NEW_VM_ID" "Set DNS" \
    cmd /c netsh interface ipv4 set dns \
    name="$NETWORK_IFACE" static "$DNS"

# ─── Step 4: Rename computer ──────────────────────────────────────────────────
# Uses retry because Rename-Computer depends on WMI which may not be fully
# ready immediately after the guest agent responds.
info "Renaming guest computer to: $VM_NAME..."
guest_exec_retry "$NEW_VM_ID" "Rename computer" \
    powershell.exe -Command "Rename-Computer -NewName '$VM_NAME' -Force"

# ─── Step 5: Reboot ───────────────────────────────────────────────────────────
info "Initiating guest reboot..."
guest_exec "$NEW_VM_ID" "Reboot" \
    cmd /c shutdown -r -f -t 3

info "Waiting ${REBOOT_SETTLE_WAIT}s for reboot to initiate..."
sleep "$REBOOT_SETTLE_WAIT"

info "Waiting for guest agent to come back after reboot (max ${AGENT_MAX_WAIT}s)..."
if ! wait_for_agent "$NEW_VM_ID" "$AGENT_MAX_WAIT" "$AGENT_POLL_INTERVAL"; then
    warn "Guest agent did not respond after reboot. VM may still be starting."
else
    info "VM $NEW_VM_ID is back online after reboot."
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
info "============================================================"
info "Provisioning complete."
info "  VM ID   : $NEW_VM_ID"
info "  VM Name : $VM_NAME"
info "  IP Addr : $TARGET_IP"
info "  DNS     : $DNS"
info "  Log     : $LOG_FILE"
info "============================================================"

exit 0
