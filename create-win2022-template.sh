#!/usr/bin/env bash
# create-win2022-template.sh — Build a Windows Server 2022 Proxmox VM template
#
# What this script does
# ──────────────────────
#   1. Generates a small ISO containing autounattend.xml (with password injected).
#   2. Uploads that ISO to Proxmox storage.
#   3. Creates a new Proxmox VM with hardware appropriate for Windows Server 2022
#      (q35 machine, OVMF/UEFI, VirtIO SCSI disk, VirtIO NIC).
#   4. Attaches the Windows 2022 ISO, VirtIO drivers ISO, and autounattend ISO.
#   5. Starts the VM and waits for unattended installation to complete.
#      Completion is detected when the QEMU guest agent is stable (installed
#      by the autounattend FirstLogonCommands).
#   6. Shuts down the VM, removes the ISOs, and converts it to a Proxmox template.
#
# Prerequisites on the Proxmox host
# ───────────────────────────────────
#   • Windows Server 2022 ISO uploaded to Proxmox ISO storage.
#   • VirtIO Windows drivers ISO (virtio-win.iso) uploaded to Proxmox ISO storage.
#     Download from: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/
#   • genisoimage or xorriso: apt install genisoimage
#   • jq:                     apt install jq
#
# Usage
# ──────
#   ./create-win2022-template.sh [OPTIONS]
#
# Options
# ────────
#   -i, --vm-id        <id>       Template VM ID              (default: 9000)
#   -n, --vm-name      <name>     Template VM name            (default: win2022-template)
#   -s, --storage      <pool>     Proxmox storage for VM disk (default: local-lvm)
#   -I, --iso-storage  <pool>     Proxmox storage for ISOs    (default: local)
#   -w, --win-iso      <file>     Windows 2022 ISO filename   (default: Win2022_English_x64v2.iso)
#   -v, --virtio-iso   <file>     VirtIO drivers ISO filename (default: virtio-win.iso)
#   -d, --disk-size    <GB>       OS disk size in GB          (default: 64)
#   -m, --memory       <MB>       VM RAM in MB                (default: 4096)
#   -c, --cores        <n>        VM vCPU count               (default: 2)
#   -p, --password     <pass>     Windows Administrator password (default: Admin@1234!)
#   -h, --help                    Show this help text and exit
#
# After this script completes, update TEMPLATE_VM_ID in vm-provisioning-v2.sh
# to match the ID used here (default: 9000) and run that script to clone VMs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────
TEMPLATE_VM_ID=9000
TEMPLATE_VM_NAME="win2022-template"
STORAGE="local-lvm"
ISO_STORAGE="local"
WIN_ISO="Win2022_English_x64v2.iso"
VIRTIO_ISO="virtio-win.iso"
DISK_SIZE=64        # GB
MEMORY=4096         # MB
CORES=2
ADMIN_PASSWORD="Admin@1234!"

# Timeout / polling settings
INSTALL_MAX_WAIT=3600   # seconds — Windows install + first-logon can take ~30–60 min
AGENT_POLL_INTERVAL=15  # seconds between guest-agent probes during installation
AGENT_STABLE_WINDOW=30  # seconds of consecutive agent success before declaring stable
AGENT_STABLE_POLL=5     # seconds between probes during stability window
SHUTDOWN_MAX_WAIT=120   # seconds to wait for VM to reach stopped state after shutdown

# ─── Logging ──────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/create_win2022_template_$(date +%Y%m%d_%H%M%S).log"

log() {
    local level="$1"; shift
    printf '[%s] [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE"
}

info()  { log "INFO"  "$@"; }
warn()  { log "WARN"  "$@"; }
error() { log "ERROR" "$@"; }

die() {
    error "$*"
    exit 1
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
usage() {
    sed -n '/^# Usage/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--vm-id)       TEMPLATE_VM_ID="$2";   shift 2 ;;
        -n|--vm-name)     TEMPLATE_VM_NAME="$2"; shift 2 ;;
        -s|--storage)     STORAGE="$2";          shift 2 ;;
        -I|--iso-storage) ISO_STORAGE="$2";      shift 2 ;;
        -w|--win-iso)     WIN_ISO="$2";          shift 2 ;;
        -v|--virtio-iso)  VIRTIO_ISO="$2";       shift 2 ;;
        -d|--disk-size)   DISK_SIZE="${2%G}";    shift 2 ;;  # strip trailing G if present
        -m|--memory)      MEMORY="$2";           shift 2 ;;
        -c|--cores)       CORES="$2";            shift 2 ;;
        -p|--password)    ADMIN_PASSWORD="$2";   shift 2 ;;
        -h|--help)        usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

# Validate VM ID is numeric
if ! [[ "$TEMPLATE_VM_ID" =~ ^[0-9]+$ ]]; then
    die "VM ID must be a positive integer. Got: '$TEMPLATE_VM_ID'"
fi

# ─── Prerequisites check ──────────────────────────────────────────────────────
check_prereqs() {
    local missing=0
    for cmd in qm pvesm jq; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Required command not found: $cmd"
            missing=1
        fi
    done
    if ! command -v genisoimage &>/dev/null && ! command -v xorriso &>/dev/null; then
        error "Either genisoimage or xorriso is required (apt install genisoimage)"
        missing=1
    fi
    (( missing == 0 )) || die "Missing prerequisites. Install them and re-run."
}

# Verify an ISO exists in Proxmox storage before proceeding
check_iso() {
    local storage="$1" iso="$2"
    if ! pvesm list "$storage" --content iso 2>/dev/null | grep -q "$iso"; then
        die "ISO '$iso' not found in storage '$storage'. Upload it first and re-run."
    fi
}

# ─── autounattend ISO creation ────────────────────────────────────────────────
# Writes the ISO path into AUTOUNATTEND_ISO_PATH (avoid subshell / stdout capture).
AUTOUNATTEND_ISO_PATH=""

build_autounattend_iso() {
    local pw="$1"
    local xml_src="${SCRIPT_DIR}/autounattend.xml"

    [[ -f "$xml_src" ]] || die "autounattend.xml not found at $xml_src"

    local tmpdir
    tmpdir=$(mktemp -d /tmp/autounattend.XXXXXX)

    info "Generating autounattend.xml (injecting Administrator password)..."
    # Escape forward-slashes in the password so sed does not mis-parse the
    # substitution delimiter; escape & which sed treats as the matched text.
    local escaped_pw
    escaped_pw=$(printf '%s' "$pw" | sed 's/[\/&]/\\&/g')
    sed "s/__ADMIN_PASSWORD__/${escaped_pw}/g" "$xml_src" > "${tmpdir}/autounattend.xml"

    local iso_path="/tmp/autounattend-${TEMPLATE_VM_ID}.iso"
    info "Creating autounattend ISO: ${iso_path}..."
    if command -v genisoimage &>/dev/null; then
        genisoimage -quiet -o "$iso_path" -J -r "${tmpdir}/" 2>>"$LOG_FILE"
    else
        xorriso -as mkisofs -quiet -o "$iso_path" -J -r "${tmpdir}/" 2>>"$LOG_FILE"
    fi

    rm -rf "$tmpdir"
    AUTOUNATTEND_ISO_PATH="$iso_path"
    info "autounattend ISO ready: ${AUTOUNATTEND_ISO_PATH}"
}

# Upload a local file to Proxmox ISO storage
upload_iso() {
    local src="$1" storage="$2"
    local filename
    filename=$(basename "$src")
    info "Uploading '${filename}' to Proxmox storage '${storage}'..."
    pvesm upload "$storage" "$src" --content iso 2>>"$LOG_FILE" \
        || die "Failed to upload '${filename}' to storage '${storage}'."
    info "Upload complete: ${filename}"
}

# ─── VM status helpers ────────────────────────────────────────────────────────
wait_for_vm_status() {
    local vm_id="$1" expected="$2" max_wait="$3" poll="$4"
    local elapsed=0
    while (( elapsed < max_wait )); do
        local status
        status=$(qm status "$vm_id" 2>/dev/null | awk '{print $2}') || true
        [[ "$status" == "$expected" ]] && return 0
        sleep "$poll"
        (( elapsed += poll )) || true
    done
    return 1
}

# Wait for the QEMU guest agent to remain responsive for AGENT_STABLE_WINDOW
# seconds consecutively, resetting on any failure to handle mid-boot restarts.
wait_for_stable_agent() {
    local vm_id="$1"
    local stable=0
    info "Waiting for guest agent to be stable for ${AGENT_STABLE_WINDOW}s..."
    while (( stable < AGENT_STABLE_WINDOW )); do
        if qm guest exec "$vm_id" -- cmd /c echo ping &>/dev/null 2>&1; then
            (( stable += AGENT_STABLE_POLL )) || true
            info "Agent stable for ${stable}s / ${AGENT_STABLE_WINDOW}s..."
        else
            (( stable > 0 )) && warn "Agent dropped — resetting stability counter."
            stable=0
        fi
        sleep "$AGENT_STABLE_POLL"
    done
    info "Guest agent is stable."
}

# Poll until the guest agent first responds, then confirm it is stable.
wait_for_installation() {
    local vm_id="$1"
    local elapsed=0
    info "Waiting for Windows installation to complete (max ${INSTALL_MAX_WAIT}s)..."
    info "This includes OS setup (~15–30 min) + first-logon VirtIO install + reboot."
    while (( elapsed < INSTALL_MAX_WAIT )); do
        if qm guest exec "$vm_id" -- cmd /c echo ping &>/dev/null 2>&1; then
            info "Guest agent responded after ${elapsed}s. Confirming stability..."
            wait_for_stable_agent "$vm_id"
            return 0
        fi
        sleep "$AGENT_POLL_INTERVAL"
        (( elapsed += AGENT_POLL_INTERVAL )) || true
        # Progress heartbeat every 5 minutes
        if (( elapsed % 300 == 0 )); then
            info "Still waiting for installation... ${elapsed}s / ${INSTALL_MAX_WAIT}s elapsed."
        fi
    done
    die "Installation did not complete within ${INSTALL_MAX_WAIT}s. Check the VM console."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
check_prereqs

if qm status "$TEMPLATE_VM_ID" &>/dev/null; then
    die "VM ID $TEMPLATE_VM_ID already exists. Choose a different ID or remove it first."
fi

check_iso "$ISO_STORAGE" "$WIN_ISO"
check_iso "$ISO_STORAGE" "$VIRTIO_ISO"

WIN_ISO_REF="${ISO_STORAGE}:iso/${WIN_ISO}"
VIRTIO_ISO_REF="${ISO_STORAGE}:iso/${VIRTIO_ISO}"
AUTOUNATTEND_ISO_NAME="autounattend-${TEMPLATE_VM_ID}.iso"
AUTOUNATTEND_ISO_REF="${ISO_STORAGE}:iso/${AUTOUNATTEND_ISO_NAME}"

# Step 1: Build and upload the autounattend ISO
build_autounattend_iso "$ADMIN_PASSWORD"
upload_iso "$AUTOUNATTEND_ISO_PATH" "$ISO_STORAGE"

info "============================================================"
info "Creating Windows Server 2022 template VM"
info "  VM ID       : $TEMPLATE_VM_ID"
info "  VM Name     : $TEMPLATE_VM_NAME"
info "  Storage     : $STORAGE"
info "  Disk        : ${DISK_SIZE} GB"
info "  Memory      : ${MEMORY} MB"
info "  Cores       : $CORES"
info "  Windows ISO : $WIN_ISO"
info "  VirtIO ISO  : $VIRTIO_ISO"
info "  Log         : $LOG_FILE"
info "============================================================"

# Step 2: Create the VM skeleton
info "Creating VM $TEMPLATE_VM_ID ($TEMPLATE_VM_NAME)..."
qm create "$TEMPLATE_VM_ID" \
    --name        "$TEMPLATE_VM_NAME" \
    --memory      "$MEMORY" \
    --cores       "$CORES" \
    --sockets     1 \
    --cpu         cputype=host \
    --bios        ovmf \
    --machine     q35 \
    --ostype      win11 \
    --scsihw      virtio-scsi-single \
    --net0        "virtio,bridge=vmbr0" \
    --agent       "enabled=1,fstrim_cloned_disks=1" \
    --onboot      0 \
    --tablet      1 \
    || die "Failed to create VM $TEMPLATE_VM_ID."

# EFI disk — Proxmox allocates the correct size automatically when size=0
info "Adding EFI disk..."
qm set "$TEMPLATE_VM_ID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1" \
    || die "Failed to add EFI disk."

# OS disk
info "Adding OS disk (${DISK_SIZE} GB)..."
qm set "$TEMPLATE_VM_ID" --scsi0 "${STORAGE}:${DISK_SIZE},discard=on,ssd=1" \
    || die "Failed to add OS disk."

# Attach ISOs
#   ide2: Windows installation ISO  (boot source)
#   ide3: VirtIO drivers ISO         (driver injection during setup + guest tools install)
#   ide0: autounattend ISO           (picked up automatically by Windows Setup)
info "Attaching Windows 2022 ISO (ide2)..."
qm set "$TEMPLATE_VM_ID" --ide2 "${WIN_ISO_REF},media=cdrom"

info "Attaching VirtIO drivers ISO (ide3)..."
qm set "$TEMPLATE_VM_ID" --ide3 "${VIRTIO_ISO_REF},media=cdrom"

info "Attaching autounattend ISO (ide0)..."
qm set "$TEMPLATE_VM_ID" --ide0 "${AUTOUNATTEND_ISO_REF},media=cdrom"

# Boot order: Windows ISO first, then the OS disk (fallback after install)
info "Setting boot order: ide2 → scsi0..."
qm set "$TEMPLATE_VM_ID" --boot "order=ide2;scsi0"

# Step 3: Start the VM
info "Starting VM $TEMPLATE_VM_ID — unattended installation beginning..."
qm start "$TEMPLATE_VM_ID" || die "Failed to start VM $TEMPLATE_VM_ID."

if ! wait_for_vm_status "$TEMPLATE_VM_ID" "running" 60 5; then
    die "VM $TEMPLATE_VM_ID did not reach running state in time."
fi

# Step 4: Wait for installation and first-logon provisioning to complete
wait_for_installation "$TEMPLATE_VM_ID"

# Step 5: Graceful shutdown
info "Shutting down VM $TEMPLATE_VM_ID..."
qm shutdown "$TEMPLATE_VM_ID" --timeout "$SHUTDOWN_MAX_WAIT" 2>>"$LOG_FILE" || {
    warn "Graceful shutdown timed out — forcing stop."
    qm stop "$TEMPLATE_VM_ID"
}

info "Waiting for VM to reach stopped state..."
if ! wait_for_vm_status "$TEMPLATE_VM_ID" "stopped" "$SHUTDOWN_MAX_WAIT" 5; then
    warn "VM did not stop cleanly; forcing stop."
    qm stop "$TEMPLATE_VM_ID" || true
    sleep 10
fi

# Step 6: Detach all ISOs (keep the template clean)
info "Removing ISOs from VM configuration..."
qm set "$TEMPLATE_VM_ID" --delete ide0,ide2,ide3 2>>"$LOG_FILE" || \
    warn "Could not remove all ISO drives — remove them manually if needed."

# Step 7: Convert to Proxmox template
info "Converting VM $TEMPLATE_VM_ID to Proxmox template..."
qm template "$TEMPLATE_VM_ID" || die "Failed to convert VM $TEMPLATE_VM_ID to template."

# Step 8: Clean up temporary autounattend ISO
info "Removing temporary autounattend ISO..."
rm -f "$AUTOUNATTEND_ISO_PATH"

info "============================================================"
info "Template creation complete."
info ""
info "  Template VM ID : $TEMPLATE_VM_ID"
info "  Template Name  : $TEMPLATE_VM_NAME"
info "  Log            : $LOG_FILE"
info ""
info "Next step — provision a VM from this template:"
info "  1. Set TEMPLATE_VM_ID=${TEMPLATE_VM_ID} in vm-provisioning-v2.sh"
info "  2. ./vm-provisioning-v2.sh <NEW_VM_ID> [VM_NAME]"
info "============================================================"

exit 0
