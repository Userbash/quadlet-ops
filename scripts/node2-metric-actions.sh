#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

metrics_url=http://127.0.0.1:8428/api/v1/query
loki_url=http://127.0.0.1:3100/loki/api/v1/query
state_dir="${HOME:?}/.local/state/node2-metric-actions"
state_file="$state_dir/state.tsv"
maintenance_file="$state_dir/MAINTENANCE"
install -d -m 0700 "$state_dir"
exec 9>"$state_dir/lock"
flock -n 9 || exit 0

now=$(date +%s)
xhttp_context_cache=
nextcloud_context_cache=
declare -A consecutive active clear_count last_event last_action
if [[ -r $state_file ]]; then
  while IFS=$'\t' read -r key samples is_active clear last_seen last_recovery; do
    [[ -n $key ]] || continue
    consecutive[$key]=${samples:-0}
    active[$key]=${is_active:-0}
    clear_count[$key]=${clear:-0}
    last_event[$key]=${last_seen:-0}
    last_action[$key]=${last_recovery:-0}
  done < "$state_file"
fi

log_event() {
  local event=$1 rule=$2 severity=$3 value=${4:-unknown} detail=${5:-none} context traffic_context='{}' system_context='[]'
  context=$(fail2ban_context)
  case $rule in
    xhttp_conn_rejections|xhttp_rate_surge) traffic_context=$(cached_xhttp_summary) ;;
    nextcloud_5xx_sustained) traffic_context=$(cached_nextcloud_summary) ;;
    nginx_status_unavailable|nginx_connection_pressure|nginx_backlog_pressure|nginx_connection_surge|nginx_reading_surge|tcp_conntrack_pressure|host_iowait_sustained)
      traffic_context=$(mixed_loki_summary)
      system_context=$(metric_context)
      ;;
    host_cpu_sustained|host_memory_low|nextcloud_storage_low|root_storage_low)
      traffic_context=$(jq -cn \
        --argjson nextcloud "$(nextcloud_loki_summary)" \
        --argjson xhttp "$(xhttp_loki_summary)" \
        '{nextcloud:$nextcloud,xhttp:$xhttp}')
      system_context=$(metric_context)
      ;;
  esac
  jq -cn \
    --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$event" \
    --arg rule "$rule" \
    --arg severity "$severity" \
    --arg value "$value" \
    --arg detail "$detail" \
    --argjson fail2ban_activity "$context" \
    --argjson traffic_context "$traffic_context" \
    --argjson system_context "$system_context" \
    '{time:$time,event:$event,rule:$rule,severity:$severity,value:$value,detail:$detail,fail2ban_activity:$fail2ban_activity,traffic_context:$traffic_context,system_context:$system_context}' \
    | systemd-cat --identifier=node2-metric-actions --priority=notice
}

fail2ban_context() {
  local response
  response=$(curl --fail --silent --show-error --max-time 3 --get \
    --data-urlencode 'query=sum by (jail) (increase(node2_fail2ban_jail_events_total{event="Ban"}[10m]))' \
    "$metrics_url" 2>/dev/null) || { printf '[]'; return; }
  jq -c '[.data.result[]? | {jail:.metric.jail,events:(.value[1]|tonumber)} | select(.events > 0)]' <<< "$response" 2>/dev/null || printf '[]'
}

metric_context() {
  local expression response
  expression=$(cat <<'PROMQL'
label_replace(node2_nginx_status_up, "signal", "nginx_status_up", "__name__", ".*") or
label_replace(node2_nginx_active_connections, "signal", "nginx_active", "__name__", ".*") or
label_replace(node2_nginx_reading_connections, "signal", "nginx_reading", "__name__", ".*") or
label_replace(node2_nginx_writing_connections, "signal", "nginx_writing", "__name__", ".*") or
label_replace(node2_nginx_waiting_connections, "signal", "nginx_waiting", "__name__", ".*") or
label_replace(node2_nginx_connection_capacity, "signal", "nginx_capacity", "__name__", ".*") or
label_replace(node2_nginx_established_443_connections, "signal", "https_established", "__name__", ".*") or
label_replace(node2_nginx_syn_recv_443_connections, "signal", "https_syn_recv", "__name__", ".*") or
label_replace(node2_tcp_listen_overflows_total, "signal", "listen_overflows_total", "__name__", ".*") or
label_replace(node2_tcp_listen_drops_total, "signal", "listen_drops_total", "__name__", ".*") or
label_replace(node2_tcp_syncookies_sent_total, "signal", "syncookies_sent_total", "__name__", ".*") or
label_replace(node2_tcp_backlog_drops_total, "signal", "backlog_drops_total", "__name__", ".*") or
label_replace(node2_conntrack_entries, "signal", "conntrack_entries", "__name__", ".*") or
label_replace(node2_conntrack_limit, "signal", "conntrack_limit", "__name__", ".*") or
label_replace(node2_cpu_busy_ratio, "signal", "cpu_busy_ratio", "__name__", ".*") or
label_replace(node2_cpu_iowait_ratio, "signal", "cpu_iowait_ratio", "__name__", ".*") or
label_replace(node2_memory_available_bytes, "signal", "memory_available_bytes", "__name__", ".*") or
label_replace(node2_load1, "signal", "load1", "__name__", ".*") or
label_replace(node2_root_filesystem_available_bytes, "signal", "root_disk_available_bytes", "__name__", ".*") or
label_replace(node2_nextcloud_filesystem_available_bytes, "signal", "nextcloud_disk_available_bytes", "__name__", ".*") or
label_replace(node2_nextcloud_application_container_cpu_ratio, "signal", "nextcloud_container_cpu", "__name__", ".*") or
label_replace(node2_nextcloud_application_container_memory_bytes, "signal", "nextcloud_container_memory_bytes", "__name__", ".*") or
label_replace(node2_xui_container_cpu_ratio, "signal", "xui_container_cpu", "__name__", ".*") or
label_replace(node2_xui_container_memory_bytes, "signal", "xui_container_memory_bytes", "__name__", ".*")
PROMQL
  )
  response=$(curl --fail --silent --show-error --max-time 4 --get \
    --data-urlencode "query=$expression" "$metrics_url" 2>/dev/null) || { printf '[]'; return; }
  jq -c '[.data.result[]? | {signal:.metric.signal,value:(.value[1]|tonumber)}]' <<< "$response" 2>/dev/null || printf '[]'
}

loki_peer_summary() {
  local expression=$1 response
  response=$(curl --fail --silent --show-error --max-time 6 --get \
    --data-urlencode "query=$expression" "$loki_url" 2>/dev/null) || {
    printf '{"available":false,"total":0,"sources":0,"top":0,"top_share":0}'
    return 0
  }
  jq -c '
    if .status != "success" then
      {available:false,total:0,sources:0,top:0,top_share:0}
    else
      [.data.result[]? | (.value[1] | tonumber)] as $counts
      | ($counts | add // 0) as $total
      | ($counts | max // 0) as $top
      | {available:true,total:$total,sources:($counts|length),top:$top,
         top_share:(if $total > 0 then $top / $total else 0 end)}
    end' <<< "$response" 2>/dev/null || printf '{"available":false,"total":0,"sources":0,"top":0,"top_share":0}'
}

cached_xhttp_summary() {
  if [[ -z $xhttp_context_cache ]]; then xhttp_context_cache=$(xhttp_loki_summary); fi
  printf '%s' "$xhttp_context_cache"
}

cached_nextcloud_summary() {
  if [[ -z $nextcloud_context_cache ]]; then nextcloud_context_cache=$(nextcloud_loki_summary); fi
  printf '%s' "$nextcloud_context_cache"
}

xhttp_loki_summary() {
  local all_requests rejected_requests request_bytes response_bytes
  all_requests=$(loki_peer_summary \
    'sum by (peer) (count_over_time({job="nginx",filename="/var/log/nginx/xhttp_access.log"} | regexp "^(?P<peer>[^ ]+) " [5m]))')
  rejected_requests=$(loki_peer_summary \
    'sum by (peer) (count_over_time({job="nginx",filename="/var/log/nginx/xhttp_access.log"} |= "limit_conn=REJECTED" | regexp "^(?P<peer>[^ ]+) " [5m]))')
  request_bytes=$(loki_peer_summary \
    'sum by (peer) (sum_over_time({job="nginx",filename="/var/log/nginx/xhttp_access.log"} | regexp "^(?P<peer>[^ ]+).*request_length=(?P<request_length>[0-9]+)" | unwrap request_length [5m]))')
  response_bytes=$(loki_peer_summary \
    'sum by (peer) (sum_over_time({job="nginx",filename="/var/log/nginx/xhttp_access.log"} | regexp "^(?P<peer>[^ ]+).*bytes=(?P<bytes>[0-9]+)" | unwrap bytes [5m]))')
  jq -cn --argjson requests "$all_requests" --argjson rejected "$rejected_requests" --argjson request_bytes "$request_bytes" --argjson response_bytes "$response_bytes" \
    '{available:($requests.available and $rejected.available and $request_bytes.available and $response_bytes.available),requests:$requests,rejected:$rejected,request_bytes:$request_bytes,response_bytes:$response_bytes}'
}

nextcloud_loki_summary() {
  local all_requests server_errors upstream_errors request_bytes response_bytes
  all_requests=$(loki_peer_summary \
    'sum by (peer) (count_over_time({job="nginx_incident",service="nextcloud"} | json peer="peer", status="status" [5m]))')
  server_errors=$(loki_peer_summary \
    'sum by (peer) (count_over_time({job="nginx_incident",service="nextcloud"} | json peer="peer", status="status" | status=~"5.." [5m]))')
  upstream_errors=$(loki_peer_summary \
    'sum by (peer) (count_over_time({job="nginx_incident",service="nextcloud"} | json peer="peer", upstream_status="upstream_status" | upstream_status=~".*(500|502|503|504).*" [5m]))')
  request_bytes=$(loki_peer_summary \
    'sum by (peer) (sum_over_time({job="nginx_incident",service="nextcloud"} | json peer="peer", request_length="request_length" | unwrap request_length [5m]))')
  response_bytes=$(loki_peer_summary \
    'sum by (peer) (sum_over_time({job="nginx_incident",service="nextcloud"} | json peer="peer", bytes_sent="bytes_sent" | unwrap bytes_sent [5m]))')
  jq -cn --argjson requests "$all_requests" --argjson errors "$server_errors" --argjson upstream_errors "$upstream_errors" --argjson request_bytes "$request_bytes" --argjson response_bytes "$response_bytes" \
    '{available:($requests.available and $errors.available and $upstream_errors.available and $request_bytes.available and $response_bytes.available),requests:$requests,errors:$errors,upstream_errors:$upstream_errors,request_bytes:$request_bytes,response_bytes:$response_bytes}'
}

mixed_loki_summary() {
  local nextcloud xhttp
  nextcloud=$(cached_nextcloud_summary)
  xhttp=$(cached_xhttp_summary)
  jq -cn --argjson nextcloud "$nextcloud" --argjson xhttp "$xhttp" \
    '{available:($nextcloud.available and $xhttp.available),nextcloud:$nextcloud,xhttp:$xhttp}'
}

start_incident_feedback() {
  local rule=$1 summary file="$state_dir/$1-feedback.json" tmp="$state_dir/$1-feedback.json.$$"
  case $rule in
    xhttp_conn_rejections|xhttp_rate_surge) summary=$(cached_xhttp_summary) ;;
    nextcloud_5xx_sustained) summary=$(cached_nextcloud_summary) ;;
    nginx_status_unavailable|nginx_connection_pressure|nginx_backlog_pressure|nginx_connection_surge|nginx_reading_surge|tcp_conntrack_pressure|host_iowait_sustained|host_cpu_sustained|host_memory_low|nextcloud_storage_low|root_storage_low) summary=$(mixed_loki_summary) ;;
    *) return 0 ;;
  esac
  jq -cn --argjson time "$now" --argjson summary "$summary" \
    '{started_at:$time,last_checked_at:$time,baseline:$summary}' > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

check_incident_feedback() {
  local rule=$1 field=$2 file="$state_dir/$1-feedback.json" previous summary \
    checked_at baseline current sources top_share bans outcome detail tmp cloud_before cloud_now xhttp_before xhttp_now cloud_bytes_before cloud_bytes_now xhttp_bytes_before xhttp_bytes_now cloud_share xhttp_share
  [[ -r $file ]] || { start_incident_feedback "$rule"; return 0; }
  previous=$(<"$file")
  checked_at=$(jq -r '.last_checked_at // 0' <<< "$previous")
  (( now - checked_at >= 300 )) || return 0

  case $rule in
    xhttp_conn_rejections|xhttp_rate_surge) summary=$(cached_xhttp_summary) ;;
    nextcloud_5xx_sustained) summary=$(cached_nextcloud_summary) ;;
    nginx_status_unavailable|nginx_connection_pressure|nginx_backlog_pressure|nginx_connection_surge|nginx_reading_surge|tcp_conntrack_pressure|host_iowait_sustained|host_cpu_sustained|host_memory_low|nextcloud_storage_low|root_storage_low) summary=$(mixed_loki_summary) ;;
  esac
  if [[ $field == traffic ]]; then
    cloud_before=$(jq -r '.baseline.nextcloud.requests.total // 0' <<< "$previous")
    cloud_now=$(jq -r '.nextcloud.requests.total // 0' <<< "$summary")
    xhttp_before=$(jq -r '.baseline.xhttp.requests.total // 0' <<< "$previous")
    xhttp_now=$(jq -r '.xhttp.requests.total // 0' <<< "$summary")
    cloud_share=$(jq -r '.nextcloud.requests.top_share // 0' <<< "$summary")
    xhttp_share=$(jq -r '.xhttp.requests.top_share // 0' <<< "$summary")
    cloud_bytes_before=$(jq -r '(.baseline.nextcloud.request_bytes.total // 0) + (.baseline.nextcloud.response_bytes.total // 0)' <<< "$previous")
    cloud_bytes_now=$(jq -r '(.nextcloud.request_bytes.total // 0) + (.nextcloud.response_bytes.total // 0)' <<< "$summary")
    xhttp_bytes_before=$(jq -r '(.baseline.xhttp.request_bytes.total // 0) + (.baseline.xhttp.response_bytes.total // 0)' <<< "$previous")
    xhttp_bytes_now=$(jq -r '(.xhttp.request_bytes.total // 0) + (.xhttp.response_bytes.total // 0)' <<< "$summary")
    sources=$(jq -r '(.nextcloud.requests.sources // 0) + (.xhttp.requests.sources // 0)' <<< "$summary")
    if [[ $(jq -r '.available' <<< "$summary") != true ]]; then
      outcome=loki_unavailable
    elif awk -v cb="$cloud_before" -v cn="$cloud_now" -v xb="$xhttp_before" -v xn="$xhttp_now" \
      -v cbytes="$cloud_bytes_before" -v cnbytes="$cloud_bytes_now" -v xbytes="$xhttp_bytes_before" -v xnbytes="$xhttp_bytes_now" \
      'BEGIN {exit !((cb > 0 || xb > 0 || cbytes > 0 || xbytes > 0) && (cb == 0 ? cn == 0 : cn <= cb * 0.70) && (xb == 0 ? xn == 0 : xn <= xb * 0.70) && (cbytes == 0 ? cnbytes == 0 : cnbytes <= cbytes * 0.70) && (xbytes == 0 ? xnbytes == 0 : xnbytes <= xbytes * 0.70))}'; then
      outcome=load_reduced
    elif awk -v cb="$cloud_before" -v xb="$xhttp_before" -v cbytes="$cloud_bytes_before" -v xbytes="$xhttp_bytes_before" 'BEGIN {exit !((cb == 0) && (xb == 0) && (cbytes == 0) && (xbytes == 0))}'; then
      outcome=no_traffic_baseline
    else
      outcome=load_not_reduced
    fi
    bans=$(fail2ban_context | jq -r '[.[] | .events] | add // 0')
    detail="nextcloud_requests=$cloud_before->$cloud_now nextcloud_total_bytes=$cloud_bytes_before->$cloud_bytes_now nextcloud_top_share=$cloud_share xhttp_requests=$xhttp_before->$xhttp_now xhttp_total_bytes=$xhttp_bytes_before->$xhttp_bytes_now xhttp_top_share=$xhttp_share sources=$sources recent_bans_10m=$bans outcome=$outcome"
    log_event metric_response_check "$rule" info "$sources" "$detail"
    tmp="$file.$$"
    jq -cn --argjson time "$now" --argjson summary "$summary" \
      '{last_checked_at:$time,baseline:$summary}' > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$file"
    return 0
  fi
  baseline=$(jq -r ".baseline.$field.total // 0" <<< "$previous")
  current=$(jq -r ".$field.total // 0" <<< "$summary")
  sources=$(jq -r ".$field.sources // 0" <<< "$summary")
  top_share=$(jq -r ".$field.top_share // 0" <<< "$summary")
  bans=$(fail2ban_context | jq -r '[.[] | .events] | add // 0')

  if [[ $(jq -r '.available' <<< "$summary") != true ]]; then
    outcome=loki_unavailable
  elif awk -v before="$baseline" 'BEGIN {exit !(before > 0)}'; then
    if awk -v before="$baseline" -v after="$current" 'BEGIN {exit !(after <= before * 0.70)}'; then
      outcome=load_reduced
    else
      outcome=load_not_reduced
    fi
  else
    outcome=no_source_baseline
  fi
  detail="metric=$field previous=$baseline current=$current sources=$sources top_share=$top_share recent_bans_10m=$bans outcome=$outcome"
  log_event metric_response_check "$rule" info "$current" "$detail"

  tmp="$file.$$"
  jq -cn --argjson time "$now" --argjson summary "$summary" \
    '{last_checked_at:$time,baseline:$summary}' > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

query_bool() {
  local expression=$1 response row sample_time age value
  query_code=0
  query_value=0
  response=$(curl --fail --silent --show-error --max-time 4 --get \
    --data-urlencode "query=$expression" "$metrics_url" 2>/dev/null) || { query_code=1; return; }
  [[ $(jq -r '.status // "error"' <<< "$response" 2>/dev/null) == success ]] || { query_code=1; return; }
  row=$(jq -c '.data.result[0] // empty' <<< "$response")
  [[ -n $row ]] || { query_code=2; return; }
  sample_time=$(jq -r '.value[0] // empty' <<< "$row")
  value=$(jq -r '.value[1] // empty' <<< "$row")
  [[ $sample_time =~ ^[0-9]+([.][0-9]+)?$ && $value =~ ^[0-9]+([.][0-9]+)?$ ]] || { query_code=1; return; }
  age=$(awk -v now="$now" -v sample="$sample_time" 'BEGIN {printf "%d", now-sample}')
  (( age >= 0 && age <= 180 )) || { query_code=3; return; }
  if awk -v value="$value" 'BEGIN {exit !(value > 0.5)}'; then
    query_value=1
  fi
  return 0
}

persist_state() {
  local tmp="$state_file.$$" key
  : > "$tmp"
  for key in "${!consecutive[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$key" "${consecutive[$key]:-0}" "${active[$key]:-0}" \
      "${clear_count[$key]:-0}" "${last_event[$key]:-0}" "${last_action[$key]:-0}" >> "$tmp"
  done
  chmod 0600 "$tmp"
  mv -f "$tmp" "$state_file"
}

run_recovery() {
  local rule=$1 unit=$2 service_uid state
  if [[ -e $maintenance_file ]]; then
    log_event action_suppressed "$rule" warning 0 maintenance_hold
    return
  fi
  if ! systemctl --user is-enabled --quiet "$unit" || ! systemctl --user is-failed --quiet "$unit"; then
    log_event action_skipped "$rule" warning 0 unit_not_failed
    return
  fi
  if (( now - ${last_action[$rule]:-0} < 1800 )); then
    log_event action_suppressed "$rule" warning 0 cooldown
    return
  fi
  last_action[$rule]=$now
  if systemctl --user restart "$unit"; then
    for _ in {1..20}; do
      state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
      [[ $state == active ]] && { log_event recovery_requested "$rule" warning 1 "$unit active"; return; }
      sleep 1
    done
    log_event recovery_failed "$rule" critical 0 "$unit did not become active"
  else
    log_event recovery_failed "$rule" critical 0 "restart $unit failed"
  fi
}

update_rule() {
  local rule=$1 expression=$2 required=$3 severity=$4 action=$5 label=$6
  query_bool "$expression"
  if (( query_code == 1 || query_code == 3 )); then
    consecutive[$rule]=0
    return
  fi
  if (( query_code == 2 )); then
    consecutive[$rule]=0
    return
  fi

  if (( query_value )); then
    consecutive[$rule]=$(( ${consecutive[$rule]:-0} + 1 ))
    clear_count[$rule]=0
    if (( consecutive[$rule] >= required )); then
      if (( ${active[$rule]:-0} == 0 )); then
        active[$rule]=1
        last_event[$rule]=$now
        case $rule in
          xhttp_conn_rejections|xhttp_rate_surge|nextcloud_5xx_sustained|nginx_status_unavailable|nginx_connection_pressure|nginx_backlog_pressure|nginx_connection_surge|nginx_reading_surge|tcp_conntrack_pressure|host_iowait_sustained|host_cpu_sustained|host_memory_low|nextcloud_storage_low|root_storage_low) start_incident_feedback "$rule" ;;
        esac
        log_event incident_started "$rule" "$severity" 1 "$label after $required consecutive samples"
        case $action in
          restart-nextcloud) run_recovery "$rule" nextcloud-app.service ;;
          restart-xui) run_recovery "$rule" 3xui.service ;;
          alert) ;;
        esac
      else
        case $rule in
          xhttp_conn_rejections) check_incident_feedback "$rule" rejected ;;
          xhttp_rate_surge) check_incident_feedback "$rule" requests ;;
          nextcloud_5xx_sustained) check_incident_feedback "$rule" errors ;;
          nginx_status_unavailable|nginx_connection_pressure|nginx_backlog_pressure|nginx_connection_surge|nginx_reading_surge|tcp_conntrack_pressure|host_iowait_sustained) check_incident_feedback "$rule" traffic ;;
          host_cpu_sustained|host_memory_low|nextcloud_storage_low|root_storage_low) check_incident_feedback "$rule" traffic ;;
        esac
        if (( now - ${last_event[$rule]:-0} >= 900 )); then
          last_event[$rule]=$now
          log_event incident_still_active "$rule" "$severity" 1 "$label"
        fi
      fi
    fi
  else
    consecutive[$rule]=0
    if (( ${active[$rule]:-0} == 1 )); then
      clear_count[$rule]=$(( ${clear_count[$rule]:-0} + 1 ))
      if (( clear_count[$rule] >= 3 )); then
        active[$rule]=0
        clear_count[$rule]=0
        log_event incident_recovered "$rule" info 0 "$label cleared for 3 consecutive samples"
        case $rule in
          xhttp_conn_rejections|xhttp_rate_surge|nextcloud_5xx_sustained|nginx_status_unavailable|nginx_connection_pressure|nginx_backlog_pressure|nginx_connection_surge|nginx_reading_surge|tcp_conntrack_pressure|host_iowait_sustained|host_cpu_sustained|host_memory_low|nextcloud_storage_low|root_storage_low) rm -f "$state_dir/$rule-feedback.json" ;;
        esac
      fi
    fi
  fi
}

# Anchor the policy to a fresh collector sample. A stale or missing series must
# never be interpreted as a healthy service or as a reason to restart one.
query_bool 'node2_cpu_sample_valid >= bool 0'
if (( query_code == 1 || query_code == 2 || query_code == 3 )); then
  consecutive[metrics_pipeline]=$(( ${consecutive[metrics_pipeline]:-0} + 1 ))
  clear_count[metrics_pipeline]=0
  if (( consecutive[metrics_pipeline] >= 2 )); then
    if (( ${active[metrics_pipeline]:-0} == 0 )); then
      active[metrics_pipeline]=1
      last_event[metrics_pipeline]=$now
      log_event incident_started metrics_pipeline critical 1 'no fresh collector sample for 2 checks'
    elif (( now - ${last_event[metrics_pipeline]:-0} >= 900 )); then
      last_event[metrics_pipeline]=$now
      log_event incident_still_active metrics_pipeline critical 1 'no fresh collector sample'
    fi
  fi
  persist_state
  exit 0
fi
consecutive[metrics_pipeline]=0
if (( ${active[metrics_pipeline]:-0} == 1 )); then
  clear_count[metrics_pipeline]=$(( ${clear_count[metrics_pipeline]:-0} + 1 ))
  if (( clear_count[metrics_pipeline] >= 3 )); then
    active[metrics_pipeline]=0
    clear_count[metrics_pipeline]=0
    log_event incident_recovered metrics_pipeline info 0 'collector fresh for 3 consecutive checks'
  fi
fi

update_rule nextcloud_http_unavailable 'min(node2_nextcloud_http_status_up) == bool 0' 3 critical alert 'Nextcloud HTTP readiness is down'
update_rule nextcloud_container_stopped 'min(node2_nextcloud_application_container_running) == bool 0' 3 critical restart-nextcloud 'Nextcloud container is stopped'
update_rule xui_container_stopped 'min(node2_xui_container_running) == bool 0' 2 critical restart-xui '3X-UI/Xray container is stopped'
update_rule nginx_status_unavailable 'min(node2_nginx_status_up) == bool 0' 3 critical alert 'Nginx loopback stub_status is unavailable'
update_rule nginx_connection_pressure '((min(node2_nginx_status_up) == bool 1) * (max(node2_nginx_active_connections) / clamp_min(max(node2_nginx_connection_capacity), 1) > bool 0.70))' 3 warning alert 'Nginx active connections exceed 70% of worker capacity'
update_rule nginx_connection_surge '((count_over_time(node2_nginx_active_connections[24h]) > bool 2500) * (node2_nginx_active_connections > bool (5 * avg_over_time(node2_nginx_active_connections[24h]) + 100)))' 3 warning alert 'Nginx active connections exceed the established 24h baseline'
update_rule nginx_reading_surge '((min(node2_nginx_status_up) == bool 1) * (max(node2_nginx_reading_connections) / clamp_min(max(node2_nginx_connection_capacity), 1) > bool 0.02))' 5 warning alert 'Nginx reading connections exceed 2% of worker capacity'
update_rule nginx_backlog_pressure '(((sum(increase(node2_tcp_listen_overflows_total[5m])) or vector(0)) > bool 3) + ((sum(increase(node2_tcp_listen_drops_total[5m])) or vector(0)) > bool 10) + (max(node2_nginx_syn_recv_443_connections) > bool 100) > bool 0)' 3 critical alert 'TCP listen backlog drops or sustained SYN-RECV pressure'
update_rule tcp_conntrack_pressure '((max(node2_conntrack_entries) / clamp_min(max(node2_conntrack_limit), 1)) > bool 0.80)' 3 warning alert 'conntrack table exceeds 80% capacity'
update_rule host_iowait_sustained 'avg(node2_cpu_iowait_ratio) > bool 0.20' 5 warning alert 'host I/O wait exceeds 20%'
update_rule host_cpu_sustained 'avg(node2_cpu_busy_ratio) > bool 0.90' 5 warning alert 'host CPU busy ratio exceeds 90%'
update_rule host_memory_low '(avg(node2_memory_available_bytes) / clamp_min(avg(node2_memory_total_bytes), 1)) < bool 0.08' 5 critical alert 'host available memory below 8%'
update_rule nextcloud_storage_low '((min(node2_nextcloud_storage_scrape_success) == bool 1) * ((min(node2_nextcloud_filesystem_available_bytes) / clamp_min(min(node2_nextcloud_filesystem_size_bytes), 1)) < bool 0.10))' 10 warning alert 'Nextcloud data filesystem below 10% free'
update_rule root_storage_low '(min(node2_root_filesystem_available_bytes) / clamp_min(min(node2_root_filesystem_size_bytes), 1)) < bool 0.10' 10 warning alert 'root filesystem below 10% free'
update_rule nextcloud_5xx_sustained '((sum(increase(node2_nginx_http_requests_total{service="nextcloud",status=~"5.."}[5m])) or vector(0)) / clamp_min((sum(increase(node2_nginx_http_requests_total{service="nextcloud"}[5m])) or vector(0)), 1) > bool 0.20) * ((sum(increase(node2_nginx_http_requests_total{service="nextcloud"}[5m])) or vector(0)) > bool 20)' 3 critical alert 'Nextcloud 5xx exceeds 20% with at least 20 requests in 5m'
update_rule xhttp_conn_rejections '((sum(rate(node2_nginx_http_requests_total{service="xhttp",limit_conn=~"REJECTED.*"}[5m])) or vector(0)) / clamp_min((sum(rate(node2_nginx_http_requests_total{service="xhttp"}[5m])) or vector(0)), 0.01) > bool 0.05) * ((sum(rate(node2_nginx_http_requests_total{service="xhttp"}[5m])) or vector(0)) > bool 0.10)' 3 warning alert 'more than 5% XHTTP requests rejected by connection limit'
update_rule xhttp_rate_surge '(sum(rate(node2_nginx_http_requests_total{service="xhttp"}[5m])) > bool (5 * avg_over_time((sum(rate(node2_nginx_http_requests_total{service="xhttp"}[5m])))[24h:5m]) + 1))' 3 warning alert 'XHTTP completed-request rate exceeds its 24h baseline'

persist_state
