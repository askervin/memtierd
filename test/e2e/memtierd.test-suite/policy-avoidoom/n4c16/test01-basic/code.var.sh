memtierd-setup

MEMTIERD_YAML="
policy:
  name: avoid-oom
  config: |
    intervalms: 5000
    startfreeingmemory: 10%
    stopfreeingmemory: 20%
    cgroups:
    - /sys/fs/cgroup/e2e-avoidoom
    mover:
      intervalms: 20
      bandwidth: 100
"
memtierd-start

memtierd-make-cgroup e2e-avoidoom/gu0
memtierd-make-cgroup e2e-avoidoom/gu1
memtierd-make-cgroup e2e-avoidoom/bu/bu0
memtierd-make-cgroup e2e-avoidoom/bu/bu1

MEME_CGROUP=e2e-avoidoom/gu0 MEME_MEMS="0-1" MEME_BS=700M memtierd-meme-start
MEME_CGROUP=e2e-avoidoom/gu1 MEME_MEMS="1-3" MEME_BS=700M memtierd-meme-start
MEME_CGROUP=e2e-avoidoom/bu/bu0 MEME_MEMS="0-5" MEME_BS=700M memtierd-meme-start
MEME_CGROUP=e2e-avoidoom/bu/bu1 MEME_MEMS="" MEME_BS=700M memtierd-meme-start
