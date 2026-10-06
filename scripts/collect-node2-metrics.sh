#!/usr/bin/env bash
set -Eeuo pipefail
NODE2_DOMAIN=${NODE2_DOMAIN:?NODE2_DOMAIN is required in observability/node2.env}
export LC_ALL=C

state_dir="${HOME:?}/.local/state/node2-metrics"
install -d -m 0700 "$state_dir"

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
cpu_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
cpu_idle=$((idle + iowait))
cpu_busy_ratio=0
cpu_iowait_ratio=0
cpu_sample_valid=0
state_file="$state_dir/cpu.state"

if [[ -r $state_file ]]; then
  read -r previous_total previous_idle previous_iowait < "$state_file"
  total_delta=$((cpu_total - previous_total))
  idle_delta=$((cpu_idle - previous_idle))
  iowait_delta=$((iowait - ${previous_iowait:-0}))
  if (( total_delta > 0 && idle_delta >= 0 && idle_delta <= total_delta && iowait_delta >= 0 && iowait_delta <= total_delta )); then
    cpu_busy_ratio=$(awk -v total="$total_delta" -v idle="$idle_delta" 'BEGIN { printf "%.6f", (total-idle)/total }')
    cpu_iowait_ratio=$(awk -v total="$total_delta" -v iowait="$iowait_delta" 'BEGIN { printf "%.6f", iowait/total }')
    cpu_sample_valid=1
  fi
fi

state_tmp="$state_file.$$"
printf '%s %s %s\n' "$cpu_total" "$cpu_idle" "$iowait" > "$state_tmp"
chmod 0600 "$state_tmp"
mv -f "$state_tmp" "$state_file"

read_fs() {
  df -B1 --output=size,used,avail -- "$1" | awk 'NR == 2 {print $1, $2, $3}'
}

read -r root_size root_used root_available < <(read_fs /)
read -r memory_total memory_available < <(
  awk '/^MemTotal:/ {total=$2*1024} /^MemAvailable:/ {available=$2*1024} END {print total, available}' /proc/meminfo
)
load_1=$(awk '{print $1}' /proc/loadavg)

nextcloud_up=0
nextcloud_size=0
nextcloud_used=0
nextcloud_available=0
if nextcloud_fs=$(podman exec nextcloud-app df -B1 --output=size,used,avail /var/www/html/data 2>/dev/null | awk 'NR == 2 {print $1, $2, $3}') && [[ $nextcloud_fs =~ ^([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
  nextcloud_size=${BASH_REMATCH[1]}
  nextcloud_used=${BASH_REMATCH[2]}
  nextcloud_available=${BASH_REMATCH[3]}
  nextcloud_up=1
fi

container_running() {
  local state
  state=$(podman inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)
  [[ $state == true ]] && printf '1\n' || printf '0\n'
}

read_container_stats() {
  local name=$1 stats cpu memory_pair memory_used
  stats=$(podman stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' "$name" 2>/dev/null || true)
  if [[ $stats == *'|'* ]]; then
    IFS='|' read -r _ cpu memory_pair <<< "$stats"
    cpu=${cpu%%%}
    memory_used=${memory_pair%%/*}
    memory_used=$(xargs <<< "$memory_used")
    memory_used=${memory_used%B}
    if [[ $cpu =~ ^[0-9]+([.][0-9]+)?$ ]] && {
      memory_bytes=$(numfmt --from=auto "$memory_used" 2>/dev/null) || memory_bytes=$(numfmt --from=iec-i "$memory_used" 2>/dev/null)
    } && [[ $memory_bytes =~ ^[0-9]+$ ]]; then
      awk -v cpu="$cpu" -v memory="$memory_bytes" 'BEGIN {printf "%.6f %d 1\n", cpu/100, memory}'
      return
    fi
  fi
  printf '0 0 0\n'
}

read -r nextcloud_cpu_ratio nextcloud_memory_bytes nextcloud_stats_up < <(read_container_stats nextcloud-app)
read -r xui_cpu_ratio xui_memory_bytes xui_stats_up < <(read_container_stats 3xui_app)
nextcloud_container_running=$(container_running nextcloud-app)
xui_container_running=$(container_running 3xui_app)

nextcloud_http=0
http_code=$(curl -k -sS -o /dev/null --connect-timeout 3 --max-time 10 \
  --resolve "cloud.$NODE2_DOMAIN:443:127.0.0.1" \
  -w '%{http_code}' "https://cloud.$NODE2_DOMAIN/status.php" 2>/dev/null || true)
[[ $http_code == 200 ]] && nextcloud_http=1

nginx_status_up=0
nginx_active_connections=0
nginx_reading_connections=0
nginx_writing_connections=0
nginx_waiting_connections=0
nginx_accepted_connections=0
nginx_handled_connections=0
nginx_total_requests=0
nginx_connection_capacity=0
nginx_established_443=0
nginx_syn_recv_443=0
if status=$(curl --fail --silent --show-error --connect-timeout 1 --max-time 2 http://127.0.0.1:9913/nginx_status 2>/dev/null); then
  read -r nginx_active_connections nginx_accepted_connections nginx_handled_connections nginx_total_requests < <(
    awk '/^Active connections:/ {active=$3} /^server accepts handled requests$/ {getline; accepted=$1; handled=$2; requests=$3} END {if (active ~ /^[0-9]+$/ && accepted ~ /^[0-9]+$/ && handled ~ /^[0-9]+$/ && requests ~ /^[0-9]+$/) print active, accepted, handled, requests}' <<< "$status"
  )
  read -r nginx_reading_connections nginx_writing_connections nginx_waiting_connections < <(
    awk '/^Reading:/ {print $2, $4, $6}' <<< "$status"
  )
  if [[ $nginx_active_connections =~ ^[0-9]+$ && $nginx_reading_connections =~ ^[0-9]+$ && $nginx_writing_connections =~ ^[0-9]+$ && $nginx_waiting_connections =~ ^[0-9]+$ && $nginx_accepted_connections =~ ^[0-9]+$ && $nginx_handled_connections =~ ^[0-9]+$ && $nginx_total_requests =~ ^[0-9]+$ ]]; then
    nginx_status_up=1
    worker_count=$(ps -eo args= | awk '$1 == "nginx:" && $2 == "worker" && $3 == "process" {n++} END {print n+0}')
    nginx_connection_capacity=$((worker_count * 8192))
  fi
fi

nginx_established_443=$(ss -Htan state established '( sport = :443 )' | wc -l | xargs)
nginx_syn_recv_443=$(ss -Htan state syn-recv '( sport = :443 )' | wc -l | xargs)

read_tcp_ext() {
  awk -v wanted="$1" '
    $1 == "TcpExt:" && !names {for (i=2; i<=NF; i++) index_of[$i]=i; names=1; next}
    $1 == "TcpExt:" && names {i=index_of[wanted]; if (i > 0) print $i; else print 0; exit}
  ' /proc/net/netstat
}

tcp_listen_overflows=$(read_tcp_ext ListenOverflows)
tcp_listen_drops=$(read_tcp_ext ListenDrops)
tcp_syncookies_sent=$(read_tcp_ext SyncookiesSent)
tcp_backlog_drops=$(read_tcp_ext TCPBacklogDrop)
conntrack_count=0
conntrack_max=0
[[ ! -r /proc/sys/net/netfilter/nf_conntrack_count ]] || read -r conntrack_count < /proc/sys/net/netfilter/nf_conntrack_count
[[ ! -r /proc/sys/net/netfilter/nf_conntrack_max ]] || read -r conntrack_max < /proc/sys/net/netfilter/nf_conntrack_max

printf '{"cpu_busy_ratio":%s,"cpu_iowait_ratio":%s,"cpu_sample_valid":%s,"memory_total_bytes":%s,"memory_available_bytes":%s,"load1":%s,"root_size_bytes":%s,"root_used_bytes":%s,"root_available_bytes":%s,"nextcloud_storage_up":%s,"nextcloud_size_bytes":%s,"nextcloud_used_bytes":%s,"nextcloud_available_bytes":%s,"nextcloud_http_up":%s,"nextcloud_container_running":%s,"nextcloud_container_stats_up":%s,"nextcloud_container_cpu_ratio":%s,"nextcloud_container_memory_bytes":%s,"xui_container_running":%s,"xui_container_stats_up":%s,"xui_container_cpu_ratio":%s,"xui_container_memory_bytes":%s,"nginx_status_up":%s,"nginx_active_connections":%s,"nginx_reading_connections":%s,"nginx_writing_connections":%s,"nginx_waiting_connections":%s,"nginx_accepted_connections":%s,"nginx_handled_connections":%s,"nginx_total_requests":%s,"nginx_connection_capacity":%s,"nginx_established_443":%s,"nginx_syn_recv_443":%s,"tcp_listen_overflows_total":%s,"tcp_listen_drops_total":%s,"tcp_syncookies_sent_total":%s,"tcp_backlog_drops_total":%s,"conntrack_entries":%s,"conntrack_limit":%s}\n' \
  "$cpu_busy_ratio" "$cpu_iowait_ratio" "$cpu_sample_valid" "$memory_total" "$memory_available" "$load_1" \
  "$root_size" "$root_used" "$root_available" "$nextcloud_up" "$nextcloud_size" \
  "$nextcloud_used" "$nextcloud_available" "$nextcloud_http" "$nextcloud_container_running" \
  "$nextcloud_stats_up" "$nextcloud_cpu_ratio" "$nextcloud_memory_bytes" "$xui_container_running" \
  "$xui_stats_up" "$xui_cpu_ratio" "$xui_memory_bytes" "$nginx_status_up" "$nginx_active_connections" \
  "$nginx_reading_connections" "$nginx_writing_connections" "$nginx_waiting_connections" \
  "$nginx_accepted_connections" "$nginx_handled_connections" "$nginx_total_requests" \
  "$nginx_connection_capacity" "$nginx_established_443" "$nginx_syn_recv_443" \
  "$tcp_listen_overflows" "$tcp_listen_drops" "$tcp_syncookies_sent" "$tcp_backlog_drops" \
  "$conntrack_count" "$conntrack_max"
