#!/usr/bin/env bash
set -Eeuo pipefail

# Helper functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

trap 'error "Status $? while: $BASH_COMMAND (line $LINENO/$BASH_LINENO)"' ERR
[[ "${TRACE:-}" == [Yy1]* ]] && set -o functrace && trap 'echo "# $BASH_COMMAND" >&2' DEBUG

# Check environment

[ ! -f "/run/entrypoint.sh" ] && error "Script must be run inside the container!" && exit 11
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 12

# Docker environment variables

: "${USERNAME:="root"}"
: "${PASSWORD:="root"}"

# Helper variables

ROOTLESS="N"
PRIVILEGED="N"
ENGINE="Docker"

if [ -f "/run/.containerenv" ]; then
  ENGINE="${container:-}"
  if [[ "${ENGINE,,}" == *"podman"* ]]; then
    ROOTLESS="Y"
    ENGINE="Podman"
  else
    [ -z "$ENGINE" ] && ENGINE="Kubernetes"
  fi
fi

echo "❯ Starting Proxmox for $ENGINE v$(</run/version)..."
echo "❯ For support visit https://github.com/dockur/proxmox"

# Get the capability bounding set
CAP_BND=$(grep '^CapBnd:' /proc/$$/status | awk '{print $2}')
CAP_BND=$(printf "%d" "0x${CAP_BND}")

# Get the last capability number
LAST_CAP=$(cat /proc/sys/kernel/cap_last_cap)

# Calculate the maximum capability value
MAX_CAP=$(((1 << (LAST_CAP + 1)) - 1))

if [ "${CAP_BND}" -eq "${MAX_CAP}" ]; then
  ROOTLESS="N"
  PRIVILEGED="Y"
fi

if [[ "$PRIVILEGED" != [Yy1]* ]]; then
  error "Please start the container with the --privileged flag!"
  [[ "${DEBUG:-}" != [Yy1]* ]] && exit 14
fi

cpu() {
  local ret
  local cpu=""

  ret=$(lscpu)

  if grep -qi "model name" <<< "$ret"; then
    cpu=$(echo "$ret" | grep -m 1 -i 'model name' | cut -f 2 -d ":" | awk '{$1=$1}1' | sed 's# @.*##g' | sed s/"(R)"//g | sed 's/[^[:alnum:] ]\+/ /g' | sed 's/  */ /g')
  fi

  if [ -z "${cpu// /}" ] && grep -qi "model:" <<< "$ret"; then
    cpu=$(echo "$ret" | grep -m 1 -i 'model:' | cut -f 2 -d ":" | awk '{$1=$1}1' | sed 's# @.*##g' | sed s/"(R)"//g | sed 's/[^[:alnum:] ]\+/ /g' | sed 's/  */ /g')
  fi

  cpu="${cpu// CPU/}"
  cpu="${cpu// [0-9][0-9][0-9] Core}"
  cpu="${cpu// [0-9][0-9] Core}"
  cpu="${cpu// [0-9] Core}"
  cpu="${cpu//[0-9][0-9]th Gen }"
  cpu="${cpu//[0-9]th Gen }"
  cpu="${cpu// Processor/}"
  cpu="${cpu// Quad core/}"
  cpu="${cpu// Dual core/}"
  cpu="${cpu// Octa core/}"
  cpu="${cpu// Hexa core/}"
  cpu="${cpu// Core TM/ Core}"
  cpu="${cpu// with Radeon Graphics/}"
  cpu="${cpu// with Radeon Vega Graphics/}"
  cpu="${cpu// with Radeon Vega Mobile Gfx/}"
  cpu="${cpu// w Radeon [0-9][0-9][0-9]M Graphics/}"

  [ -z "${cpu// /}" ] && cpu="Unknown"

  echo "$cpu"
  return 0
}

CPU=$(cpu)
SYS=$(uname -r)
HOST=$(hostname -s)
KERNEL=$(echo "$SYS" | cut -b 1)
MINOR=$(echo "$SYS" | cut -d '.' -f2)
ARCH=$(dpkg --print-architecture)
CORES=$(grep -c '^processor' /proc/cpuinfo)

# Read memory
RAM_AVAIL=$(free -b | grep -m 1 Mem: | awk '{print $7}')
RAM_TOTAL=$(free -b | grep -m 1 Mem: | awk '{print $2}')

# Print system info
SYS="${SYS/-generic/}"
FS=$(stat -f -c %T "$STORAGE")
FS="${FS/UNKNOWN //}"
FS="${FS/ext2\/ext3/ext4}"
FS=$(echo "$FS" | sed 's/[)(]//g')
SPACE=$(df --output=avail -B 1 "$STORAGE" | tail -n 1)

formatBytes() {
  local result
  result=$(numfmt --to=iec --suffix=B "$1" | sed -r 's/([A-Z])/ \1/' | sed 's/ B/ bytes/g;')
  local unit="${result//[0-9. ]}"
  result="${result//[a-zA-Z ]/}"
  if [[ "${2:-}" == "up" ]]; then
    if [[ "$result" == *"."* ]]; then
      result="${result%%.*}"
      result=$((result+1))
    fi
  else
    if [[ "${2:-}" == "down" ]]; then
      result="${result%%.*}"
    fi
  fi
  echo "$result $unit"
  return 0
}

SPACE_GB=$(formatBytes "$SPACE" "down")
AVAIL_MEM=$(formatBytes "$RAM_AVAIL" "down")
TOTAL_MEM=$(formatBytes "$RAM_TOTAL" "up")

echo "❯ CPU: ${CPU} | RAM: ${AVAIL_MEM/ GB/}/$TOTAL_MEM | DISK: $SPACE_GB (${FS}) | KERNEL: ${SYS}..."
echo

# Check if /dev/fuse is available

if [ ! -c /dev/fuse ]; then
  error "Could not access /dev/fuse, make sure this kernel module is loaded!"
  [[ "${DEBUG:-}" != [Yy1]* ]] && exit 16
fi

# Check KVM support

KVM_ERR=""

if [ ! -e /dev/kvm ]; then
  KVM_ERR="(/dev/kvm is missing)"
else
  if ! sh -c 'echo -n > /dev/kvm' &> /dev/null; then
    KVM_ERR="(/dev/kvm is unwriteable)"
  else
    flags=$(sed -ne '/^flags/s/^.*: //p' /proc/cpuinfo)
    if ! grep -qw "vmx\|svm" <<< "$flags"; then
      KVM_ERR="(not enabled in BIOS)"
    fi
  fi
fi

if [ -n "$KVM_ERR" ]; then
  error "KVM acceleration is not available $KVM_ERR, see the FAQ for possible causes."
  [[ "${DEBUG:-}" != [Yy1]* ]] && exit 19
fi

# Update username and password
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd

exec /sbin/init
