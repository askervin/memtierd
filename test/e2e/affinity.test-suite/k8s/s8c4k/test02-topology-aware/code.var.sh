vm-command 'grep 511,1535,4095 /sys/devices/system/cpu/enabled' || {
    vm-cpu-hotplug 0 511 0
    vm-cpu-hotplug 2 511 0
    vm-cpu-hotplug 7 511 0
}

vm-command 'for cpuX in /sys/devices/system/cpu/cpu[1-9][0-9][0-9]*; do
    echo onlining $cpuX
    echo 1 > $cpuX/online
done
grep . /sys/devices/system/cpu/cpu[1-9][0-9][0-9]*/online'

if ! vm-command "type -p kubelet"; then
    vm-install-k8s
fi

if ! vm-command "[ -f /var/lib/kubelet/config.yaml ]"; then
    vm-create-singlenode-cluster
fi

if ! vm-command "type -p helm"; then
    vm-install-helm
fi

# MOVE TO: cleanup-pods()
vm-command "helm ls -n kube-system | awk '/nri-resource-policy/{print \$1}' | xargs -n 1 helm uninstall -n kube-system"
vm-command "kubectl delete pods --all --now"

AVAILABLE_CPU="cpuset:0-4095"
RESERVED_CPU="cpuset:0-2"
vm-put-file $(instantiate topology-aware.conf) topology-aware.conf

vm-install-helm-pkg nri-plugins/nri-resource-policy-topology-aware --values topology-aware.conf -n kube-system

CPUREQ=1 MEMREQ=50M CPULIM=1 MEMLIM=50M
CONTCOUNT=3 create besteffort
report allowed
verify 'disjoint_sets(cpus["pod0c0"], cpus["pod0c1"], cpus["pod0c2"])' \
       'len(cpus["pod0c0"]) == 1' \
       'len(cpus["pod0c1"]) == 1' \
       'len(cpus["pod0c2"]) == 1'

# Possible issue: suggests slicing where not enough CPUs is available.
# - Could it be that there simply is not enough CPUs, but then it should not be "internal error"?
# - No. The problem persists even if moved the t-a container to the kube-system ns. no containers
#   should use cpus 511, 1535 or 4096.
# failed to get NRI adjustment for container: rpc error: code = Unknown desc = failed to allocate resources: topology-aware: failed to allocate resources for default/pod0/pod0c2: topology-aware: failed to allocate <none CPU request default/pod0/pod0c2: exclusive: 1> <Memory request: limit: 47.68M, req: 47.68M> from <socket #2 allocatable: MemLimit: 10.73G>: topology-aware: internal error: socket #2: can't slice 1 exclusive CPUs from , 0m available
