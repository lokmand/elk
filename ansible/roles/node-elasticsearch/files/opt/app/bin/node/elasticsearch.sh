EC_HTTP_ERROR=130
EC_STATUS_ERROR=131
EC_SCLIN_NO_HEALTH=132
EC_SCLIN_UNHEALTHY=133
EC_SCLIN_PORT_OPEN=134
EC_UPG_UP_NODES=135       # wrong number of running nodes
EC_UPG_NOT_JOINED=136     # upgraded node not joined the cluster
EC_DATA_LOAD_TIMEOUT=137   # shards not fully loaded
EC_UPG_ONE_NEW=138
EC_UPDATE_FAILURE=139
EC_SCLIN_EXCIP_NOACK=140
EC_SCLIN_LACK_NODES=141   # Be careful to avoid overlap with cURL
EC_SCLIN_ERR_COUNTING=142 # the leaving nodes are still holding data
EC_SCLIN_HOLDING_DATA=143 # the leaving nodes are still holding data
EC_SCLIN_BELOW_MIN_COUNT=144
EC_SCLIN_CLOSED_INDICES=145
EC_SCLIN_NO_LEAVING_NODES=146

parseJsonField() {
  local field=$1 json=${@:2}
  echo $json | jq -r '."'$field'"'
}

prepareEsDirs() {
  local dataDirs; dataDirs="$(egrep -o " /data[23]? " /proc/mounts)"

  local esDir=${1:-elasticsearch}
  mkdir -p /data/$esDir/{analysis,dump,logs,repo}

  for dataDir in $dataDirs; do
    rm -rf $dataDir/lost+found
    mkdir -p $dataDir/$esDir/data
    chown -R elasticsearch.svc /$dataDir/$esDir
  done
}

initNode() {
  _initNode
  prepareEsDirs
  local htmlPath=/data/elasticsearch/index.html
  [ -e $htmlPath ] || ln -s /opt/app/conf/caddy/index.html $htmlPath
}

start() {
  _start

  if [[ " $JOINING_MASTER_NODES$JOINING_DATA_NODES " == *" $MY_IP "* ]]; then
    retry 120 1 0 checkNodeJoined $MY_IP ${STABLE_DATA_NODES%% *}
  fi
}

restart() {
  if [ -z "$1" ]; then _restart && return 0; fi

  if [ "$1" = "role" ]; then
    local earliest="$(($(date +%s%3N) - 5000))"
    local nodes; nodes=$(parseJsonField node.ip ${@:2})
    if [[ ",${nodes:=${ROLE_NODES// /,}}," != *",$MY_IP,"* ]]; then return 0; fi
    local opTimeout; opTimeout=$(parseJsonField timeout "${@:2}")
    timeout --preserver-status ${opTimeout:-600} appctl restartInOrder $nodes $earliest $IS_MASTER || {
      log "WARN: failed to restart nodes '$nodes' in order ($?)"
      return 0
    }
  fi
}

updateSettings() {
  local url="${ES_HOST:-$MY_IP}:9200/_cluster/settings" key="$1" value="$2" ack
  ack="$(curl -s -m 60 -H "$jsonHeader" -XPUT "$url" -d@- <<- SETTINGS_EOF |
    {
      "transient": {
        "$key": $value
      }
    }
SETTINGS_EOF
    jq -r '.acknowledged')" || return $EC_UPDATE_FAILURE
  [ "$ack" = "true" ] || {
    log "Failed to update cluster settings '$key' to '$value' with ack '$ack'."
    return $EC_UPDATE_FAILURE
  }
}

restartInOrder() {
  local nodes="$1" earliest=$2 isMaster=${3:-false}
  local node; for node in ${nodes//,/ }; do
    if [ "$node" = "$MY_IP" ]; then _restart; fi

    retry 600 1 0 execute check && retry 60 2 0 checkNodeRestarted $earliest $node || log "WARN: Node '$node' seems not restarted."
    $isMaster || retry 21600 2 0 checkNodeShardsLoaded $node || log "WARN: Node '$node' seems not loaded within 12 hours."

    if [ "$node" = "$MY_IP" ]; then return 0; fi
  done
}

checkNodeRestarted() {
  local earliest=$1 node=${2:-$MY_IP} startTime
  startTime="$(curl -s -m 3 $node:9200/_nodes/$node/jvm | jq -r '.nodes | to_entries[] | .value | .jvm | .start_time_in_millis')"
  [ -n "$startTime" ] && [ $startTime -ge $earliest ]
}

checkNodeShardsLoaded() {
  local node=${1:-$MY_IP} shards
  shards="$(curl -s -m 3 $node:9200/_cluster/health | jq -r '.initializing_shards + .unassigned_shards')"
  [ -n "$shards" ] && [ "$shards" -eq 0 ] || return $EC_DATA_LOAD_TIMEOUT
}

jsonHeader='Content-Type: application/json'

preScaleIn() {
  # only process this check on the first stable data node and only when there are ES nodes leaving
  [ "$MY_IP" = "${STABLE_DATA_NODES%% *}" -a -n "$LEAVING_DATA_NODES" ] || return 0

  [[ "$STABLE_DATA_NODES" = *\ * ]] || return $EC_SCLIN_BELOW_MIN_COUNT

  retry 10 1 0 checkClusterHealthy
  retry 10 1 0 checkNoClosed

  local excludingNodes="${LEAVING_DATA_NODES// /,}" excludedNodes
  setExcludeIp "\"$excludingNodes\""
  excludedNodes="$(getExcludeIp)"
  [ "$excludingNodes" = "$excludedNodes" ] && retry 8640 1 $EC_SCLIN_LACK_NODES checkClusterScaled && retry 30 1 0 checkShardsMovedAway || {
    local retCode=$?
    log "Failed to relocate shards with exit code '$retCode'. Reverting cluster settings."
    setExcludeIp null
    return $retCode
  }
}

checkClusterHealthy() {
  local status; status="$(curl -s -m 5 $MY_IP:9200/_cat/health?h=status)" || return $EC_SCLIN_NO_HEALTH
  [ "${status}" = "green" ] || return $EC_SCLIN_UNHEALTHY
}

checkNoClosed() {
  local numClosed
  numClosed="$(curl -s -m 30 $MY_IP:9200/_cat/indices?h=status | awk '$1=="close"' | wc -l)" || return $EC_HTTP_ERROR
  [ "$numClosed" -eq 0 ] || return $EC_SCLIN_CLOSED_INDICES
}

scale() {
  local inout=${1:?in/out should be specified}

  if [ "$inout" = "in" -a -n "$LEAVING_MASTER_NODES" ]; then
    execute restart
  fi
}

destroy() {
  # In case the user is trying to remove all ES nodes, when preScaleIn will never be called.
  if [ -n "$LEAVING_DATA_NODES" ]; then
    [[ "$STABLE_DATA_NODES" = *\ * ]] || return $EC_SCLIN_BELOW_MIN_COUNT
  fi

  # This is the 2nd step to remove a data node (shards are assumed to be already moved away in the 1st step).
  # Assumed stopping this node will not bring the cluster unhealthy because it has no data now.
  if [[ " $LEAVING_DATA_NODES " == *" $MY_IP "* ]]; then
    execute stop
    retry 10 1 0 checkPortClosed
    checkClusterScaled 10 || {
      local retCode=$?
      log "Reverting scale-in as the cluster is not healthy or my shards were not relocated/assigned ..."
      execute start
      setExcludeIp null
      return $retCode
    }
  fi
}

setExcludeIp() {
  local ip=${1:-null}
  ES_HOST="${STABLE_DATA_NODES%% *}" updateSettings "cluster.routing.allocation.exclude._ip" "$ip" || return $EC_SCLIN_EXCIP_NOACK
}

getExcludeIp() {
  curl -s -m 30 $MY_IP:9200/_cluster/settings | jq -r '.transient.cluster.routing.allocation.exclude._ip' || return $EC_SCLIN_EXCIP_NOACK
}

checkClusterScaled() {
  local opTimeout=${1:-10}
  local url="${STABLE_DATA_NODES%% *}:9200/_cat/health?h=status,relo,init,unassign" \
        health status relocating initializing unassigned
  health="$(curl -s -m $opTimeout -H "$jsonHeader" "$url")"
  [ -n "$health" ] || return $EC_SCLIN_NO_HEALTH
  status="$(echo $health | awk '{print $1}')"
  relocating="$(echo $health | awk '{print $2}')"
  initializing="$(echo $health | awk '{print $3}')"
  unassigned="$(echo $health | awk '{print $4}')"
  [ -n "$unassigned" ] || return $EC_SCLIN_NO_HEALTH

  if [[ "$status" =~ ^(red|yellow)$ ]] && [ "$relocating$initializing" = "00" ] && [ "$unassigned" -gt 0 ]; then
    log "Insufficient nodes to assign shards: '$health'."
    return $EC_SCLIN_LACK_NODES
  fi

  [ "$status" = "green" -a "$relocating" = "0" ] || {
    log "Not fully scaled yet: '$health'."
    return $EC_SCLIN_UNHEALTHY
  }
}

checkShardsMovedAway() {
  local url="${STABLE_DATA_NODES%% *}:9200/_nodes/${LEAVING_DATA_NODES// /,}/stats/indices/docs"
  local expr='.nodes | to_entries | map(.value.indices.docs.count) | @csv'
  local docsCount
  docsCount=$(curl -s -m 10 "$url" | jq -r "$expr") || {
    log "Failed to sum up docs count on the leaving nodes '$LEAVING_DATA_NODES' from '$url': $docsCount."
    return $EC_SCLIN_ERR_COUNTING
  }

  [[ "$docsCount" =~ ^0(,0)*$ ]] || {
    log "Still holding data on leaving nodes '$LEAVING_DATA_NODES': docs='$docsCount'."
    return $EC_SCLIN_HOLDING_DATA
  }
}

checkPortClosed() {
  checkEndpoint tcp:${2:-9200} ${1:-$MY_IP} && return $EC_SCLIN_PORT_OPEN || return 0
}

checkEsOutput() {
  [ "$(curl -s -m 5 $MY_IP:9200 | jq -r '.version.number')" = "$ELK_VERSION" ]
}

checkSvc() {
  _checkSvc $@ || return $?
  if [ "$1" == "elasticsearch" ]; then checkEsOutput; fi
}

measure() {
  if [ "$MY_SID" != "$ES_SID_1" ]; then return 0; fi

  local stats health
  stats=$(curl -s -m 3 $MY_IP:9200/_cluster/stats | jq -c "{
    cluster_docs_count: .indices.docs.count,
    cluster_docs_deleted_count: .indices.docs.deleted,
    cluster_indices_count: .indices.count,
    cluster_jvm_heap_used_in_percent: (10000 * (.nodes.jvm.mem.heap_used_in_bytes / .nodes.jvm.mem.heap_max_in_bytes)),
    cluster_jvm_threads_count: .nodes.jvm.threads,
    cluster_shards_primaries_count: .indices.shards.primaries,
    cluster_shards_replication_count: (.indices.shards.total - .indices.shards.primaries),
    cluster_status: .status
  }")
  health=$(curl -s -m 2 $MY_IP:9200/_cluster/health | jq -c "{
    active_shards_percent_as_number: (100 * .active_shards_percent_as_number),
    initializing_shards,
    number_of_in_flight_fetch,
    number_of_nodes,
    number_of_pending_tasks,
    relocating_shards,
    task_max_waiting_in_queue_millis,
    unassigned_shards
  }")

  [ -n "$stats" -a -n "$health" ] && echo $stats $health | jq -cs add
}

upgrade() {
  execute start && retry 600 1 0 execute check && retry 600 1 0 checkNodeJoined || log "WARN: still not joined the cluster."
  [ "$IS_MASTER" == "true" ] || retry 10800 2 $EC_UPG_ONE_NEW checkNodeLoaded || log "WARN: not fully loaded with exit code '$?'. Moving to next node."
}

checkNodeJoined() {
  local result node=${1:-$MY_IP}
  local knownNode=${2:-$node}
  result="$(curl -s -m 3 $knownNode:9200/_cat/nodes?h=ip,node.role | awk '$1 == "'$node'" && $2 ~ /^(m|m?di)$/ {print $1}')"
  [ "$result" = "$node" ] || return $EC_UPG_NOT_JOINED
}

checkNodeLoaded() {
  local url="$MY_IP:9200/_cluster/health"
  local query=".status, .initializing_shards, .unassigned_shards"
  local health status init unassign
  health="$(curl -s -m 3 "$url" | jq -r "$query" | xargs)" || return $EC_HTTP_ERROR
  status="$(echo $health | awk '{print $1}')"
  init="$(echo $health | awk '{print $2}')"
  unassign="$(echo $health | awk '{print $3}')"

  [ -n "$status" -a -n "$init" -a -n "$unassign" ] || return $EC_STATUS_ERROR

  # if this is the first upgraded node, it will fail to allocate shards for newly created indices to other old-version nodes. Need to move on then.
  if [ "$init" -eq 0 -a "$unassign" -gt 0 ]; then
    local nodes expectedCount="$(echo "$STABLE_DATA_NODES" | tr -cd ' ' | wc -c)"
    url="$MY_IP:9200/_cat/nodes?h=v"
    nodes="$(curl -s -m 5 "$url" | awk 'BEGIN{n=0;o=0} {if($1=="'$ELK_VERSION'")n++;else if($1=="5.5.1")o++;} END{print n,o}')" || return $EC_HTTP_ERROR
    if [ "$nodes" = "1 $expectedCount" ]; then
      log "This is the first upgraded node: '$nodes'."
      return $EC_UPG_ONE_NEW
    fi
  fi

  [ "$status" = "green" ] || return $EC_DATA_LOAD_TIMEOUT
}

dump() {
  local node; node=$(parseJsonField node.ip $@)
  local opTimeout; opTimeout=$(parseJsonField timeout $@)
  if [ "${node:=$MY_IP}" != "$MY_IP" ]; then return 0; fi

  local path="$HEAP_DUMP_PATH"
  if [ -d "$path" ]; then path="$path/dump.hprof"; fi
  timeout ${opTimeout:-1800}s jmap -dump:file="$path" -F $(cat /var/run/elasticsearch/elasticsearch.pid) || return 0
}

clearDump() {
  local node; node=$(parseJsonField node.ip $@)
  if [ "${node:=$MY_IP}" != "$MY_IP" ]; then return 0; fi
  local files="$(findDumpFiles)"
  if [ -n "$files" ]; then rm -rf $files; fi
}

findDumpFiles() {
  if [ -d "$HEAP_DUMP_PATH" ]; then
    find $HEAP_DUMP_PATH -name '*.hprof'
  elif [ -f "$HEAP_DUMP_PATH" ]; then
    echo $HEAP_DUMP_PATH
  fi
}
