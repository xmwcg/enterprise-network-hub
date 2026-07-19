#!/bin/bash
# 金网通 · Linux 硬件与系统扫描 V2
# 用法: bash scan-linux.sh [--json] [--output /path/to/result.json]

OUTPUT=""
JSON_MODE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_MODE=true; shift ;;
    --output) OUTPUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# 辅助函数
cmd_exists() { command -v "$1" &>/dev/null; }
get_val() { echo "$1" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

HOSTNAME=$(hostname)
OS_NAME=$(cat /etc/os-release 2>/dev/null | grep "^PRETTY_NAME=" | cut -d= -f2 | tr -d '"')
[ -z "$OS_NAME" ] && OS_NAME=$(uname -sr)
KERNEL=$(uname -r)
ARCH=$(uname -m)
UPTIME=$(uptime -p 2>/dev/null | sed 's/^up //')
[ -z "$UPTIME" ] && UPTIME=$(cat /proc/uptime | awk '{printf "%.0f minutes", $1/60}')

# CPU
CPU_NAME=$(cat /proc/cpuinfo | grep "model name" | head -1 | cut -d: -f2 | xargs)
CPU_CORES=$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo)
CPU_SOCKETS=$(grep "physical id" /proc/cpuinfo 2>/dev/null | sort -u | wc -l)
CPU_MHZ=$(cat /proc/cpuinfo | grep "cpu MHz" | head -1 | awk '{print $4}')
[ -z "$CPU_MHZ" ] && CPU_MHZ="0"

# 内存 (KB)
MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_FREE=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_TOTAL_MB=$((MEM_TOTAL / 1024))
MEM_FREE_MB=$((MEM_FREE / 1024))
MEM_USED_MB=$((MEM_TOTAL_MB - MEM_FREE_MB))

# 硬盘
DISKS=""
if cmd_exists lsblk; then
  while IFS= read -r line; do
    NAME=$(echo "$line" | awk '{print $1}')
    SIZE=$(echo "$line" | awk '{print $4}')
    TYPE=$(echo "$line" | awk '{print $6}')
    [ "$TYPE" = "disk" ] && DISKS="$DISKS{\"name\":\"$NAME\",\"size\":\"$SIZE\"},"
  done < <(lsblk -ndo NAME,SIZE,TYPE 2>/dev/null)
else
  for d in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
    [ -e "$d" ] || continue
    NAME=$(basename "$d")
    SIZE=$(cat "$d/size" 2>/dev/null | awk '{printf "%.1fG", $1*512/1024/1024/1024}')
    DISKS="$DISKS{\"name\":\"$NAME\",\"size\":\"$SIZE\"},"
  done
fi
DISKS="[${DISKS%,}]"

# 分区
PARTITIONS=""
if cmd_exists df; then
  while IFS= read -r line; do
    DEV=$(echo "$line" | awk '{print $1}')
    SIZE=$(echo "$line" | awk '{print $2}')
    USED=$(echo "$line" | awk '{print $3}')
    PUSE=$(echo "$line" | awk '{print $5}' | tr -d '%')
    MOUNT=$(echo "$line" | awk '{print $6}')
    # 只取真实设备
    [[ "$DEV" =~ ^/dev/ ]] || continue
    PARTITIONS="$PARTITIONS{\"dev\":\"$DEV\",\"size\":\"$SIZE\",\"used\":\"$USED\",\"usePct\":$PUSE,\"mount\":\"$MOUNT\"},"
  done < <(df -h 2>/dev/null | tail -n +2)
fi
PARTITIONS="[${PARTITIONS%,}]"

# GPU
GPU="[]"
if cmd_exists lspci; then
  GPU_LIST=$(lspci | grep -iE "VGA|3D|Display" | while read -r line; do
    NAME=$(echo "$line" | cut -d: -f3- | xargs)
    echo "{\"name\":\"$NAME\"},"
  done)
  GPU="[${GPU_LIST%,}]"
elif cmd_exists nvidia-smi; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  GPU="[{\"name\":\"$GPU_NAME\"}]"
fi

# 网卡
NET=""
if cmd_exists ip; then
  while IFS= read -r iface; do
    MAC=$(cat /sys/class/net/$iface/address 2>/dev/null)
    IP=$(ip -4 addr show $iface 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
    [ -z "$IP" ] && continue
    NET="$NET{\"name\":\"$iface\",\"mac\":\"$MAC\",\"ip\":\"$IP\"},"
  done < <(ls /sys/class/net/ | grep -v lo)
elif cmd_exists ifconfig; then
  for iface in $(ifconfig -s | tail -n +2 | awk '{print $1}'); do
    [ "$iface" = "lo" ] && continue
    MAC=$(cat /sys/class/net/$iface/address 2>/dev/null)
    IP=$(ifconfig $iface 2>/dev/null | grep "inet " | awk '{print $2}')
    NET="$NET{\"name\":\"$iface\",\"mac\":\"$MAC\",\"ip\":\"$IP\"},"
  done
fi
NET="[${NET%,}]"

# Docker / 虚拟化
DOCKER=false
cmd_exists docker && DOCKER=true
VIRT_TYPE=""
[ -d /proc/vz ] && VIRT_TYPE="openvz"
grep -qi hypervisor /proc/cpuinfo 2>/dev/null && VIRT_TYPE="${VIRT_TYPE:-kvm}"

# 已安装服务
SERVICES=""
for svc in ssh nginx apache2 docker mysql postgresql redis smbd nmbd nfs-kernel-server; do
  if systemctl is-active --quiet $svc 2>/dev/null; then
    SERVICES="$SERVICES\"$svc\","
  fi
done
SERVICES="[${SERVICES%,}]"

TIMESTAMP=$(date -Iseconds)

if $JSON_MODE || [ -n "$OUTPUT" ]; then
  JSON=$(cat <<JSONEND
{
  "scanTime": "$TIMESTAMP",
  "hostname": "$HOSTNAME",
  "osName": "$OS_NAME",
  "kernel": "$KERNEL",
  "arch": "$ARCH",
  "uptime": "$UPTIME",
  "cpu": {"name": "$CPU_NAME", "cores": $CPU_CORES, "sockets": $CPU_SOCKETS, "mhz": "$CPU_MHZ"},
  "memory": {"totalMB": $MEM_TOTAL_MB, "freeMB": $MEM_FREE_MB, "usedMB": $MEM_USED_MB},
  "disk": {"physical": $DISKS, "partitions": $PARTITIONS},
  "gpu": $GPU,
  "network": $NET,
  "docker": $DOCKER,
  "virtType": "$VIRT_TYPE",
  "services": $SERVICES
}
JSONEND
)

  if [ -n "$OUTPUT" ]; then
    echo "$JSON" > "$OUTPUT"
    echo "OK: $OUTPUT"
  else
    echo "$JSON"
  fi
else
  echo "=== $HOSTNAME ==="
  echo "OS:     $OS_NAME ($KERNEL $ARCH)"
  echo "Uptime: $UPTIME"
  echo "CPU:    $CPU_NAME ($CPU_CORES cores, $CPU_SOCKETS socket(s))"
  echo "Memory: ${MEM_USED_MB}MB / ${MEM_TOTAL_MB}MB"
  echo "Disks:  $(echo $DISKS | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//' | tr '\n' ' ')"
  echo "GPU:    $(echo $GPU | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//' | tr '\n' ' ')"
  echo "Docker: $DOCKER  Virt: ${VIRT_TYPE:-none}"
  echo "Services: $(echo $SERVICES | tr -d '[]"' | tr ',' ' ')"
fi