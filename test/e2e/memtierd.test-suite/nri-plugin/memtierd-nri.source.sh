# memtierd-nri-install installs memtierd nri plugin from nri_plugins_src.
# Supported nri_plugins_src syntax:
# - https://github.com/<ORG>/nri-plugins [-b branch]
#   clone NRI plugins from github to vm, and build and install
#   memtierd-nri:latest image.
memtierd-nri-install() {
    if [[ "$reinstall_memtierd_nri" != "1" ]] && vm-command "ctr -n k8s.io images ls | grep memtierd-nri"; then
        echo "memtierd-nri-install: memtierd-nri already installed, use reinstall_memtierd_nri=1 to force reinstalling."
        return 0
    fi
    vm-command "rm -rf nri-plugins; kubectl delete -n kube-system daemonset memtierd-nri"
    if [[ "$nri_plugins_src" == "https://github.com/"* ]]; then
        vm-command "git clone --depth=1 $nri_plugins_src" || \
            command-error "failed to fetch NRI plugins"
    elif [[ -f "$nri_plugins_src/cmd/memtierd/Dockerfile" ]]; then
        vm-command "su $VM_SSH_USER -c 'mkdir nri-plugins'"
        host-command "cd \"$nri_plugins_src/..\" && rsync -avz $(basename "$nri_plugins_src")/* --exclude 'build/*' --exclude 'test/e2e/*' $VM_SSH_USER@$VM_IP:nri-plugins/" ||
            command-error "failed to copy NRI plugins from host to vm"
    fi
    if ! vm-command-q "[[ -f nri-plugins/cmd/memtierd/Dockerfile ]]"; then
        error "don't know how to install NRI plugins from nri_plugins_src=\"$nri_plugins_src\" to vm"
    fi
    vm-command "cd nri-plugins && (set -x; docker rmi memtierd-nri:latest 2>/dev/null; ctr -n k8s.io images rm docker.io/library/memtierd-nri:latest 2>/dev/null; ); docker build cmd/memtierd -t memtierd-nri:latest" || \
        command-error "building memtierd-nri image failed"
    vm-command "docker save memtierd-nri | ctr -n k8s.io images import -" || \
        command-error "importing memtierd-nri image to k8s failed"
}

# memtierd-nri-launch launches memtierd-nri plugin that connects to
# container runtime's NRI server.
memtierd-nri-launch() {
    # Launch the plugin by deploying from memtierd-nri.daemonset.yaml.in
    wait_for="jsonpath={'.status.numberReady'}=1"
    vm-command "kubectl wait --timeout=0 -n kube-system --for=$wait_for daemonsets/memtierd-nri" && {
        if [[ "$reinstall_memtierd_nri" != "1" ]]; then
            echo "memtierd-nri-launch: memtierd-nri plugin is already running"
            return 0
        fi
        vm-command "kubectl delete -n kube-system daemonset memtierd-nri"
    }
    NAME=memtierd-nri namespace=kube-system wait="$wait_for" create memtierd-nri.daemonset
}

memtierd-nri-meme-pod-install() {
    if vm-command "ctr -n k8s.io images ls | grep meme"; then
        echo "mmtierd-nri-meme-pod-install: meme image already available"
        return 0
    fi
    vm-command "command -v meme" || memtierd-install || \
        command-error "failed to install meme to vm, needed for building meme image in vm"
    vm-command "mkdir -p meme-image; cp \$(command -v meme) meme-image/" || \
        command-error "failed to find meme from system"
    cat <<EOF | vm-pipe-to-file meme-image/Dockerfile
FROM busybox:latest
COPY meme /usr/local/bin/meme
EOF
    vm-command "cd meme-image; docker build . -t meme:latest" || \
        command-error "failed to build meme image"
    vm-command "docker save meme:latest | ctr -n k8s.io images import -" || \
        command-error "importing meme:latest image to k8s failed"
}

memtierd-nri-meme-pod-launch() {
    local NAME=${NAME:-meme}
    vm-command "kubectl wait --timeout=0 --for=condition=Ready pods/$NAME" && {
        echo "memtierd-nri-mem-pod-launch: meme pod $NAME is already running"
        return 0
    }
    NAME=${NAME} ANN0=${ANN0} BS=1G BWC=1 BWS=256M BWO=128M BWOD=1M BWI=1s create meme.pod
}
