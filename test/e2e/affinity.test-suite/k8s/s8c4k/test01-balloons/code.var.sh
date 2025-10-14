min_kernel_version=6.14
vm-command "uname -r"
if [ "$( ( echo $min_kernel_version; echo $COMMAND_OUTPUT ) | sort --version-sort | tail -n 1 )" == "$min_kernel_version" ]; then
    error "quest OS runs too old kernel, hot-plugged CPU node topology may not work. Required: $min_kernel_version"
fi

# Hot-plug CPUs.
vm-command 'grep 511,1535,4095 /sys/devices/system/cpu/enabled' || {
    vm-cpu-hotplug 0 511 0
    vm-cpu-hotplug 2 511 0
    vm-cpu-hotplug 7 511 0

    # Wait for the kernel to expose all hot-plugged CPUs in sysfs.
    vm-run-until '[ -d /sys/devices/system/cpu/cpu511 ] && [ -d /sys/devices/system/cpu/cpu1535 ] && [ -d /sys/devices/system/cpu/cpu4095 ]'

    # Online all CPUs.
    vm-command 'for cpuX in /sys/devices/system/cpu/cpu[1-9]*; do
            echo onlining $cpuX
            ( echo 1 > $cpuX/online && echo Successful: write 1 to $cpuX/online ) || echo Failed: write 1 to $cpuX/online
        done
       grep . /sys/devices/system/cpu/cpu[1-9]*/online'
}

# Sometimes the kernel (seen at least Debian Linux 6.16.9) does not
# expose cpuX/topology directory but situation may improve by
# offlininging and re-onlining the CPU.
# NOTE: could be a false alarm due and caused by race condition:
# kernel had not exposed hot-plugged CPUs yet in sysfs when this
# loop was executed for the first time.
vm-command 'recheck=1; while [ $recheck == "1" ]; do
    recheck=0
    for cpuX in /sys/devices/system/cpu/cpu[1-9]*; do
        [ -d $cpuX/topology ] || {
            echo "INTERESTING: onlined CPU without $cpuX/topology"
            exit 1
            echo "cannot find $cpuX/topology, offline-online the CPU"
            echo 0 > $cpuX/online; sleep 0.1; echo 1 > $cpuX/online
            recheck=1
        }
    done
done' || command-error 'continue debugging manually'

switch-k8s-containerd-runc() {
    vm-command "yes | kubeadm reset && systemctl stop $VM_CRI && systemctl disable $VM_CRI"

    k8s_version=1.34
    VM_CRI=containerd
    k8scri=containerd
    k8scri_sock="/var/run/containerd/containerd.sock"

    vm-command 'command -v runc.disabled-by-e2e && mv $(command -v runc.disabled-by-e2e) /usr/bin/runc'
    vm-command 'command -v crun && mv $(command -v crun) $(command -v crun).disabled-by-e2e'

    vm-command 'command -v containerd' || vm-install-cri
    vm-command 'systemctl enable containerd; systemctl start containerd'

    if ! vm-command "type -p kubelet"; then
        vm-install-k8s
    fi

    if ! vm-command "[ -f /var/lib/kubelet/config.yaml ]"; then
        vm-create-singlenode-cluster
    fi
}

switch-k8s-crio-crun() {
    vm-command "yes | kubeadm reset && systemctl stop $VM_CRI && systemctl disable $VM_CRI"

    k8s_version=1.34
    VM_CRI=crio
    k8scri=crio
    k8scri_sock="/var/run/crio/crio.sock"

    vm-command 'command -v crun.disabled-by-e2e && mv $(command -v crun.disabled-by-e2e) /usr/bin/crun'
    vm-command 'command -v runc && mv $(command -v runc) $(command -v runc).disabled-by-e2e'

    vm-command 'command -v crio' || vm-install-cri
    vm-command "sed -i 's/# default_runtime = .*/default_runtime = \\\"crun\\\"/1' /etc/crio/crio.conf"
    # Prevent using runc instead of crun by misconfig.
    vm-command "systemctl restart crio"
    # Wait for crio to respond before running kubeadm
    sleep 2
    vm-command "while ! fuser -v /var/run/crio/crio.sock; do sleep 1; done"

    if ! vm-command "type -p kubelet"; then
        vm-install-k8s
    fi

    vm-create-singlenode-cluster
}

test-balloons() {
    # containerd:  kubepods/cpuset.cpus
    # cri-o: kubepods.slice/cpuset.cpus
    vm-command "grep . /sys/fs/cgroup/kubepods*/cpuset.cpus"
    if ! ( grep -q 511 <<< $COMMAND_OUTPUT &&
           grep -q 1535 <<< $COMMAND_OUTPUT &&
           grep -q 4095 <<< $COMMAND_OUTPUT ); then
        command-error "kubepods cpuset.cpus does not include expected CPUs"
    fi

    if ! vm-command "type -p helm"; then
        vm-install-helm
    fi

    vm-command "helm ls -n kube-system | awk '/nri-resource-policy/{print \$1}' | xargs -n 1 helm uninstall -n kube-system"
    vm-command "kubectl delete pods --all --now"

    vm-put-file $(instantiate balloons.conf) balloons.conf

    local patch_config_args=""
    if [ "$VM_CRI" == "containerd" ] && vm-command 'containerd --version | grep 1.7'; then
        patch_config_args="--set nri.runtime.patchConfig=true"
    fi
    vm-install-helm-pkg nri-plugins/nri-resource-policy-balloons --values balloons.conf $patch_config_args -n kube-system
    vm-command "kubectl wait -n kube-system ds/nri-resource-policy-balloons --timeout=120s --for=jsonpath='{.status.numberAvailable}'=1"

    # keep creating pod0 every time
    reset counters
    rm -f "$OUTPUT_DIR"/topology_dump.*
    CPUREQ="500m" CPULIM="" MEMREQ=50M MEMLIM=""
    ANN0="balloon.balloons.resource-policy.nri.io/container.pod0c0: pkg0"
    ANN1="balloon.balloons.resource-policy.nri.io/container.pod0c1: pkg2"
    ANN2="balloon.balloons.resource-policy.nri.io/container.pod0c2: pkg7"
    CONTCOUNT=3 create besteffort
    report allowed
    verify 'cpus["pod0c0"] == {"cpu0511","cpu0002","cpu0000"}' \
           'cpus["pod0c1"] == {"cpu1535"}' \
           'cpus["pod0c2"] == {"cpu4095"}'
}

switch-k8s-crio-crun

test-balloons

switch-k8s-containerd-runc

test-balloons

# Findings:
#
# Balloons does not make a difference between availableResources out
# of possible CPUs versus actually enabled CPUs. TODO: intersect with
# enabled CPUs. This prevents assigning to CPUs that are not in the
# system.
