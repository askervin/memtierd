memtierd-setup

vm-command "dmesg -c"

MEMTIERD_YAML="
policy:
  name: avoid-oom
  config: |
    intervalms: 5000
    startfreeingmemory: 25%
    stopfreeingmemory: 35%
    cgroups:
    - /sys/fs/cgroup/non-existing-cgroup/is/ignored
    - /sys/fs/cgroup/e2e-avoidoom
    mover:
      intervalms: 100
      bandwidth: 100
"
memtierd-start

py3-alloc-mb() {
    echo "l.append(\"x\"*(1024*1024*$1))"
}

verify-node-avail() {
    # Usage: verify-node-avail NODE OP REFVALUE
    # Example: verify-node-avail 3 ">=" 33
    # requires that node 3 has at least 33 % available
    local node="$1"
    local op="$2"
    local refval="$3"
    local node_avail
    memtierd-command 'policy -dump nodes'
    node_avail=$(awk "/Node $node:/{print int(\$5)}" <<< "$COMMAND_OUTPUT")
    if [[ -z "$node_avail" ]]; then
        command-error "verify-node-avail: failed to read Node $node available memory percentage"
    fi
    if ! (( $node_avail $op $refval )); then
        echo "verify-node-avail: unexpected node $node avail: $node_avail $op $refval"
        return 1
    fi
    echo "verify-node-avail: ok: node $node avail: $node_avail $op $refval"
    return 0
}

memtierd-make-cgroup e2e-avoidoom/bu/bu0
memtierd-make-cgroup e2e-avoidoom/bu/bu1
memtierd-make-cgroup e2e-avoidoom/gu0
memtierd-make-cgroup e2e-avoidoom/gu1

PYTHON3_CGROUP=e2e-avoidoom/bu/bu0
memtierd-python3-start
memtierd-python3-command "l=[]"
vm-command "echo 0-5 > /sys/fs/cgroup/$PYTHON3_CGROUP/cpuset.mems"
vm-command "echo 6-7 > /sys/fs/cgroup/$PYTHON3_CGROUP/cpuset.cpus" # prefer mem from node3

PYTHON3_CGROUP=e2e-avoidoom/bu/bu1
memtierd-python3-start
memtierd-python3-command "l=[]"
vm-command "echo 0-3 > /sys/fs/cgroup/$PYTHON3_CGROUP/cpuset.mems"
vm-command "echo 6-7 > /sys/fs/cgroup/$PYTHON3_CGROUP/cpuset.cpus" # prefer mem from node3

sleep 1

# Allocate 1 GB, most likely consume all of node3.
# However, this is not a memory pressure situation, because all processes
# can get memory from elsewhere, too.
PYTHON3_ID=0 memtierd-python3-command "$(py3-alloc-mb 640)"
PYTHON3_ID=1 memtierd-python3-command "$(py3-alloc-mb 384)"

sleep 6

memtierd-command 'stats -t events'

verify-node-avail 3 "<=" 25

memtierd-command "policy -dump balance"
grep -v "no pressure" <<< "$COMMAND_OUTPUT" || {
    command-error "expected balance: no pressure"
}

# Create a container with memory pinned to node3. Yet the process in
# the container does not consume memory yet, there is now a set of
# nodes ({3}) where total available memory is below the
# startfreeingmemory threshold. Memtierd is expected to free memory
# until node3 has 33 % memory available.

PYTHON3_CGROUP=e2e-avoidoom/gu0
memtierd-make-cgroup "$PYTHON3_CGROUP"
vm-command "echo 3 > /sys/fs/cgroup/$PYTHON3_CGROUP/cpuset.mems"
memtierd-python3-start
memtierd-python3-command "l=[]"

run-until --timeout 15 --poll 3 verify-node-avail 3 ">=" 33

# With >= 33% free on node3, we can make a 256 MB allocation
# without the fear of oom kicking in.
memtierd-python3-command "$(py3-alloc-mb 256)"

run-until --timeout 15 --poll 3 verify-node-avail 3 ">=" 33

# Create yet another cgroup, this time with nodes 2-3.
PYTHON3_CGROUP=e2e-avoidoom/gu1
memtierd-make-cgroup "$PYTHON3_CGROUP"
vm-command "echo 2-3 > /sys/fs/cgroup/$PYTHON3_CGROUP/cpuset.mems"
memtierd-python3-start
memtierd-python3-command "l=[]"

# As a result, there should be roughly 33 % free in node3 as before,
# but now also node2+node3 should have 33 % free in total. Because
# node3 is expected to be pretty close to 33 % avail, expect roughly
# the same from node2, too.

run-until --timeout 15 --poll 3 verify-node-avail 2 ">=" 30
verify-node-avail 3 ">=" 33

# Finally, test a situation where cgroups and processes already exist
# in the vm, and memory consumption is inbalanced. Verify that
# memtierd brings the balance.

memtierd-stop

# Free memory from Python processes
PYTHON3_ID=0 memtierd-python3-command "l=[]"
PYTHON3_ID=1 memtierd-python3-command "l=[]"
PYTHON3_ID=2 memtierd-python3-command "l=[]"
PYTHON3_ID=3 memtierd-python3-command "l=[]"

# Saturate nodes 2-3 with processes that are allowed to use memory
# from any node.
PYTHON3_ID=0 memtierd-python3-command "$(py3-alloc-mb 1000)"
PYTHON3_ID=1 memtierd-python3-command "$(py3-alloc-mb 1000)"

MEMTIERD_YAML="
policy:
  name: avoid-oom
  config: |
    intervalms: 1000
    startfreeingmemory: 25%
    stopfreeingmemory: 25%
    cgroups:
    - /sys/fs/cgroup/e2e-avoidoom
    mover:
      intervalms: 100
      bandwidth: 100
"

# Balance the situation so that node2 and node3 will have enough
# memory for 200 MB allocations
memtierd-start
verify-node-avail 3 "<=" 24
verify-node-avail 2 "<=" 24

run-until --timeout 15 --poll 3 verify-node-avail 3 ">=" 24
run-until --timeout 15 --poll 3 verify-node-avail 2 ">=" 24
memtierd-command "stats"

PYTHON3_ID=2 memtierd-python3-command "$(py3-alloc-mb 256)"
PYTHON3_ID=3 memtierd-python3-command "$(py3-alloc-mb 256)"

run-until --timeout 15 --poll 3 verify-node-avail 3 ">=" 24
run-until --timeout 15 --poll 3 verify-node-avail 2 ">=" 24

vm-command "dmesg | grep oom-kill" &&
    error "OOM killer was triggered"

memtierd-stop

# Suggestion for following memory per node on each python3 process during the test:
# while true; do clear; for pid in $(pidof python3); do echo $pid; awk -v pid=$pid 'BEGIN{RS=" ";FS="="}/N[0-9]+/{mem[$1]+=$2}END{for(node in mem){print pid" "node" "int(mem[node]*4/1024)" M"}}' < /proc/$pid/numa_maps; done | sort -n; sleep 2; done
