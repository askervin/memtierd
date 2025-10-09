min_kernel_version=6.14
vm-command "uname -r"
if [ "$( ( echo $min_kernel_version; echo $COMMAND_OUTPUT ) | sort --version-sort | tail -n 1 )" == "$min_kernel_version" ]; then
    error "quest OS runs too old kernel, hot-plugged CPU node topology may not work. Required: $min_kernel_version"
fi

if [ -z "$k8s" ]; then
    error "k8s required, run with environment variable k8s=latest"
fi

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
vm-command "helm ls | awk /nri-resource-policy/{print $\1}' | xargs -n 1 helm uninstall"
vm-command "kubectl delete pods --all --now"

vm-put-file $(instantiate balloons.conf) balloons.conf

if vm-command "helm ls | grep nri-resource-policy-balloons"; then
    vm-command "helm uninstall nri-resource-policy-balloons"
fi
vm-install-helm-pkg nri-plugins/nri-resource-policy-balloons --values balloons.conf

CPUREQ="500m" CPULIM="" MEMREQ=50M MEMLIM=""
ANN0="balloon.balloons.resource-policy.nri.io/container.pod0c0: pkg0"
ANN1="balloon.balloons.resource-policy.nri.io/container.pod0c1: pkg2"
ANN2="balloon.balloons.resource-policy.nri.io/container.pod0c2: pkg7"
CONTCOUNT=3 create besteffort
report allowed
verify 'cpus["pod0c0"] == {"cpu0511","cpu0002","cpu0000"}' \
       'cpus["pod0c1"] == {"cpu1535"}' \
       'cpus["pod0c2"] == {"cpu4095"}'


# Findings:
#
# Balloons does not make a difference between availableResources out
# of possible CPUs versus actually enabled CPUs. TODO: intersect with
# enabled CPUs. This prevents assigning to CPUs that are not in the
# system.

vm-command "yes | kubeadm --reset; systemctl stop $VM_CRI; systemctl disable $VM_CRI"

vm-command "sed -i 's/.*default_runtime.*/default_runtime = \"crun\"/g' /etc/crio.conf"
VM_CRI=crio
k8scri_sock="unix:/var/run/crio/crio.sock"
vm-create-singlenode-cluster
