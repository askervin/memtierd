nri_plugins_src=${nri_plugins_src:-"https://github.com/containers/nri-plugins"}

if [[ "$distro" != "ubuntu"* ]] && [[ "$distro" != "debian"* ]]; then
    error "only Ubuntu and Debian are supported by this test at the moment"
fi

# Install docker on vm
vm-command "command -v docker" || distro-install-pkg docker.io || \
    command-error "installing docker failed"

# Install go on vm
vm-command "go version" || distro-install-golang

# Enable NRI in containerd
vm-command "sed '/io.containerd.nri.v1.nri/{n; s/disable = true/disable = false/}' -i /etc/containerd/config.toml"
vm-command "grep -A1 io.containerd.nri.v1.nri /etc/containerd/config.toml" || \
    command-error "containerd on vm does not support NRI, version 1.7 or later required"

# Install memtierd NRI plugin
memtierd-nri-install
memtierd-nri-launch

# Create swap
zram-install
zram-swap off
zram-swap 2G

memtierd-nri-meme-pod-install

NAME=meme-lowprio ANN0='class.memtierd.nri: "lowprio"' ANN1='memory.swap.max.memtierd.nri: "max"' memtierd-nri-meme-pod-launch

NAME=meme-normal ANN1='memory.swap.max.memtierd.nri: "max"' ANN2='memory.high.memtierd.nri: "768000000"' memtierd-nri-meme-pod-launch

NAME=meme-higprio memtierd-nri-meme-pod-launch
