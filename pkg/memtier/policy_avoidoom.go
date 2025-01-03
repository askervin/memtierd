// Copyright 2024 Intel Corporation. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Avoid OOM policy balances memory between NUMA nodes by moving data
// from nodes with memory pressure to nodes with no pressure.
//
// A node has memory pressure if there are processes or containers
// that are allowed to use memory only from that node, and the high
// watermark (startFreeingMemory) is reached. The memory is moved
// until reaching the low watermark (stopFreeingMemory) on the
// node. The same applies to any subset of nodes, too.
//
// Processes whose memory is to be moved are chosen by oom-score
// value: take processes that are most likely to get killed in case of
// out-of-memory in the pressurised nodes. These are considered lowest
// priority processes, so a slightly disruptive operation like moving
// their memory is not considered evil.

package memtier

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	defaultStartFreeingMemory = "8%"
	defaultStopFreeingMemory  = "16%"
	// Do not bother trying to move processes that have less than this
	// amount of memory on high pressure nodes. (Bytes)
	constMinimumPidMoveSize = 16 * 1024 * 1024
)

type PolicyAvoidOomConfig struct {
	// StartFreeingMemory and StopFreeingMemory are the low and
	// high watermarks of available (free + reclaimable) memory on
	// a NUMA node for starting and stopping freeing memory on
	// it. The value can be given as an amount of available
	// memory, for instance "8G", or percentages of total memory
	// on the node, for instance "10%".  Without a unit the value
	// is interpreted as bytes.
	StartFreeingMemory string
	StopFreeingMemory  string
	Cgroups            []string
	// IntervalMs is the length of the period in milliseconds in
	// which new ages are calculated based on gathered tracker
	// values, and page move and swap tasks are triggered.
	IntervalMs int
	Mover      MoverConfig
}

type NodeMask uint64

// PolicyAvoidOom defines empty struct for the scenarios without policy configured.
type PolicyAvoidOom struct {
	config      *PolicyAvoidOomConfig
	nodes       []*memNode
	nodeSets    map[NodeMask]*nodeset
	cgroups     []*cgroup
	prevCands   []*moveCandidate
	mover       *Mover
	cmdLoop     chan chan interface{}
	mutex       sync.Mutex
	lastBalance string
}

type memNode struct {
	id                 int
	mask               NodeMask
	memAvail           int64
	memTotal           int64
	startFreeingMemory int64
	stopFreeingMemory  int64
}

type moveCandidate struct {
	pid                  int
	cgroup               *cgroup
	addr                 uint64 // memory segment start address from numa_maps
	pageSize             int64  // page size in bytes
	segmentSize          int64  // total size of memory segment in bytes
	sizeOnNode           int64  // size of memory segment on fromNode in bytes
	fromNode             int
	preferredTargetMasks []NodeMask
	score                int64
}

var allNumaNodes []int
var allNumaNodesMask NodeMask

func init() {
	PolicyRegister("avoid-oom", NewPolicyAvoidOom)
}

// NewPolicyAvoidOom creates a new instance of PolicyAvoidOom with default configuration.
func NewPolicyAvoidOom() (Policy, error) {
	var err error
	onlineNodesPath := "/sys/devices/system/node/online"
	if len(allNumaNodes) == 0 {
		allNumaNodes, err = procReadIntListFormat(onlineNodesPath, nil)
		if err != nil || len(allNumaNodes) == 0 {
			return nil, fmt.Errorf("failed to read online NUMA nodes from %q: %w", onlineNodesPath, err)
		}
		allNumaNodesMask = nodeIdsToMask(allNumaNodes)
	}
	nodes := []*memNode{}
	for _, nodeId := range allNumaNodes {
		node := &memNode{
			id:   nodeId,
			mask: nodeIdToMask(nodeId),
		}
		nodes = append(nodes, node)
	}
	p := &PolicyAvoidOom{
		nodes:    nodes,
		nodeSets: make(map[NodeMask]*nodeset),
		mover:    NewMover(),
	}
	if err := p.updateNodes(); err != nil {
		return nil, fmt.Errorf("failed to update nodes: %w", err)
	}
	return p, nil
}

// SetConfigJSON is a method of PolicyAvoidOom, returns nil.
func (p *PolicyAvoidOom) SetConfigJSON(configJSON string) error {
	config := &PolicyAvoidOomConfig{}
	if err := unmarshal(configJSON, config); err != nil {
		return err
	}
	return p.SetConfig(config)
}

func (p *PolicyAvoidOom) SetConfig(config *PolicyAvoidOomConfig) error {
	var err error
	if err := p.mover.SetConfig(&config.Mover); err != nil {
		return fmt.Errorf("configuring mover failed: %s", err)
	}
	if config.StartFreeingMemory == "" {
		config.StartFreeingMemory = defaultStartFreeingMemory
	}
	if config.StopFreeingMemory == "" {
		config.StopFreeingMemory = defaultStopFreeingMemory
	}
	for _, node := range p.nodes {
		node.startFreeingMemory, err = parsePercentageOrBytes(config.StartFreeingMemory, node.memTotal)
		if err != nil {
			return fmt.Errorf("failed to parse startFreeingMemory: %w", err)
		}
		node.stopFreeingMemory, err = parsePercentageOrBytes(config.StopFreeingMemory, node.memTotal)
		if err != nil {
			return fmt.Errorf("failed to parse stopFreeingMemory: %w", err)
		}
	}
	p.config = config
	return nil
}

// GetConfigJSON is a method of PolicyAvoidOom, returns "".
func (p *PolicyAvoidOom) GetConfigJSON() string {
	if p.config == nil {
		return ""
	}
	pconfig := *p.config
	if configStr, err := json.Marshal(&pconfig); err == nil {
		return string(configStr)
	}
	return ""
}

// Start is a method of PolicyAvoidOom, returns nil.
func (p *PolicyAvoidOom) Start() error {
	p.mutex.Lock()
	defer p.mutex.Unlock()
	if p.cmdLoop != nil {
		return fmt.Errorf("already started")
	}
	if p.config == nil {
		return fmt.Errorf("unconfigured policy")
	}
	if err := p.mover.Start(); err != nil {
		return fmt.Errorf("mover start error: %w", err)
	}
	p.cmdLoop = make(chan chan interface{})
	go p.loop(p.cmdLoop)
	return nil
}

// Stop is a method of TrackerAvoidOom that doing nothing here.
func (p *PolicyAvoidOom) Stop() {
	p.mutex.Lock()
	defer p.mutex.Unlock()
	if p.cmdLoop == nil {
		return
	}
	cmdResponse := make(chan interface{})
	p.cmdLoop <- cmdResponse
	<-cmdResponse
	close(p.cmdLoop)
	p.cmdLoop = nil
	if p.mover != nil {
		p.mover.Stop()
	}
}

// PidWatcher is a method of PolicyAvoidOom, returns nil.
// AvoidOoom does not have a pid watcher.
func (p *PolicyAvoidOom) PidWatcher() PidWatcher {
	return nil
}

// Mover returns the mover of the policy.
func (p *PolicyAvoidOom) Mover() *Mover {
	return p.mover
}

// Tracker is a method of PolicyAvoidOom, returns nil.
// AvoidOoom does not have a tracker.
func (p *PolicyAvoidOom) Tracker() Tracker {
	return nil
}

func (p *PolicyAvoidOom) updateCgroups() error {
	p.nodeSets = map[NodeMask]*nodeset{}
	p.nodeSets[allNumaNodesMask] = &nodeset{
		nodeMask: allNumaNodesMask,
	}
	p.cgroups = make([]*cgroup, 0)
	cgroupDirs := p.scanCgroupDirs()
	if len(cgroupDirs) == 0 {
		return fmt.Errorf("no cgroups found")
	}
	for _, cgroupDir := range cgroupDirs {
		// Ignore cgroups without processes
		procs, err := procReadInts(filepath.Join(cgroupDir, "cgroup.procs"))
		if err != nil || len(procs) == 0 {
			continue
		}
		// Ignore cgroups without cpuset.mems
		mems, err := procReadIntListFormat(filepath.Join(cgroupDir, "cpuset.mems.effective"), allNumaNodes)
		if err != nil {
			continue
		}
		// Add cgroup to the policy
		nodeMask := nodeIdsToMask(mems)
		if nodeMask == 0 {
			continue
		}
		nset, ok := p.nodeSets[nodeMask]
		if !ok {
			nset = &nodeset{
				nodeMask: nodeMask,
			}
			p.nodeSets[nodeMask] = nset
		}
		cgroup := &cgroup{
			fullPath: cgroupDir,
			procs:    procs,
			nodeset:  nset,
		}
		p.cgroups = append(p.cgroups, cgroup)
		nset.cgroups = append(nset.cgroups, cgroup)
	}
	for nodeMask, nset := range p.nodeSets {
		for _, node := range p.nodes {
			if nodeMask&node.mask != 0 {
				nset.memAvail += node.memAvail
				nset.memTotal += node.memTotal
				nset.startFreeingMemory += node.startFreeingMemory
				nset.stopFreeingMemory += node.stopFreeingMemory
			}
		}
	}
	return nil
}

// scanCgroupDirs returns a list of cgroup paths under user-defined cgroups.
func (p *PolicyAvoidOom) scanCgroupDirs() []string {
	cgroupDirs := []string{}
	for _, cgroupParents := range p.config.Cgroups {
		filepath.WalkDir(cgroupParents,
			func(path string, d fs.DirEntry, err error) error {
				if err != nil {
					return err
				}
				if d.IsDir() {
					cgroupDirs = append(cgroupDirs, path)
				}
				return nil
			})
	}
	return cgroupDirs
}

func (p *PolicyAvoidOom) updateNodes() error {
	stats.Store(StatsHeartbeat{"PolicyAvoidOom.updateNodes"})
	for _, node := range p.nodes {
		if err := updateMeminfo(node); err != nil {
			return fmt.Errorf("failed to get memory info from node %d: %w", node.id, err)
		}
	}
	return nil
}

type nodeset struct {
	nodeMask           NodeMask
	cgroups            []*cgroup
	memAvail           int64
	memTotal           int64
	startFreeingMemory int64
	stopFreeingMemory  int64
}

func (nset *nodeset) NodeIds() []int {
	return nodeMaskToIds(nset.nodeMask)
}

func nodeMaskToIds(nodeMask NodeMask) []int {
	nodeIds := []int{}
	for _, nodeId := range allNumaNodes {
		if nodeMask&(1<<nodeId) != 0 {
			nodeIds = append(nodeIds, nodeId)
		}
	}
	return nodeIds
}

func nodeIdsToMask(nodeIds []int) NodeMask {
	nodeMask := NodeMask(0)
	for _, nodeId := range nodeIds {
		nodeMask |= 1 << nodeId
	}
	return nodeMask
}

func nodeIdToMask(nodeId int) NodeMask {
	return 1 << nodeId
}

type cgroup struct {
	fullPath string
	procs    []int
	nodeset  *nodeset
}

func updateMeminfo(node *memNode) error {
	meminfoFilename := fmt.Sprintf("/sys/devices/system/node/node%d/meminfo", node.id)
	meminfo, err := procRead(meminfoFilename)
	if err != nil {
		return fmt.Errorf("failed to read %q: %w", meminfoFilename, err)
	}
	node.memTotal = parseValueAfter(meminfo, "MemTotal:") * 1024
	node.memAvail = (parseValueAfter(meminfo, "MemFree:") + parseValueAfter(meminfo, "SReclaimable:") + parseValueAfter(meminfo, "Inactive(file):")*80/100) * 1024
	return nil
}

func parseValueAfter(data, key string) int64 {
	for _, line := range strings.Split(data, "\n") {
		halfs := strings.SplitN(line, key, 2)
		if len(halfs) < 2 {
			continue
		}
		nextFields := strings.Fields(halfs[1])
		v, _ := strconv.ParseInt(nextFields[0], 10, 64)
		return v
	}
	return -1
}

func parsePercentageOrBytes(watermark string, total int64) (int64, error) {
	if strings.HasSuffix(watermark, "%") {
		percentage, err := strconv.ParseInt(strings.TrimSuffix(watermark, "%"), 10, 64)
		if err != nil {
			return 0, fmt.Errorf("failed to parse percentage %q: %w", watermark, err)
		}
		return total * percentage / 100, nil
	}
	return parseBytes(watermark)
}

var bytesSuffixMultiplier map[string]int64 = map[string]int64{
	"K":  1 << 10,
	"KB": 1 << 10,
	"M":  1 << 20,
	"MB": 1 << 20,
	"G":  1 << 30,
	"GB": 1 << 30,
	"T":  1 << 40,
	"TB": 1 << 40,
}

func parseBytes(bytes string) (int64, error) {
	if len(bytes) == 0 {
		return 0, fmt.Errorf("empty string")
	}
	for suffix, multiplier := range bytesSuffixMultiplier {
		if strings.HasSuffix(strings.ToUpper(bytes), suffix) {
			value, err := strconv.ParseInt(strings.TrimSuffix(bytes, suffix), 10, 64)
			return value * multiplier, err
		}
	}
	return strconv.ParseInt(bytes, 10, 64)
}

func (p *PolicyAvoidOom) loop(cmd chan chan interface{}) {
	log.Debugf("PolicyAvoidOom: online\n")
	defer log.Debugf("PolicyAvoidOom: offline\n")
	ticker := time.NewTicker(time.Duration(p.config.IntervalMs) * time.Millisecond)
	defer ticker.Stop()
	for {
		stats.Store(StatsHeartbeat{"PolicyAvoidOom.loop"})
		select {
		case res := <-cmd:
			res <- struct{}{}
			return
		case <-ticker.C:
			if err := p.updateNodes(); err != nil {
				log.Errorf("failed to update nodes: %v", err)
			}
			if err := p.updateCgroups(); err != nil {
				log.Errorf("failed to update cgroups: %v", err)
			}
			if err := p.balance(); err != nil {
				log.Errorf("failed to balance: %v", err)
			}
		}
	}
}

func (p *PolicyAvoidOom) setBalanceStatus(status string) error {
	p.lastBalance = status
	stats.Store(StatsHeartbeat{"PolicyAvoidOom.balance: " + p.lastBalance})
	return nil
}

func (p *PolicyAvoidOom) balance() error {
	if p.mover.TaskCount() > 0 {
		return p.setBalanceStatus("mover busy")
	}
	mostPressureNodesets, highPressureNodeMask, medPressureNodeMask, noPressureNodeMask := p.pressureNodesets()
	if highPressureNodeMask == 0 {
		return p.setBalanceStatus("no pressure")
	}
	if highPressureNodeMask == allNumaNodesMask {
		return p.setBalanceStatus("high pressure on all nodes")
	}
	if noPressureNodeMask == 0 {
		return p.setBalanceStatus("no low pressure nodes")
	}
	p.setBalanceStatus("pressure on some nodes")
	cands := []*moveCandidate{}
	for _, nset := range mostPressureNodesets {
		// Look for cgroups that have memory on both high and no pressure nodes
		if nset.nodeMask&highPressureNodeMask == 0 || nset.nodeMask&noPressureNodeMask == 0 || len(nset.cgroups) == 0 {
			continue
		}
		for _, cgroup := range nset.cgroups {
			// find processes in cgroup that have memory on high pressure nodes
			for _, pid := range cgroup.procs {
				nodeAddrSize := map[int]map[uint64]int64{}
				addrSegmentSize := map[uint64]int64{}
				addrPageSize := map[uint64]int64{}
				sizeOnPressure := int64(0)
				pidNodeMask := NodeMask(0)
				procNumaMaps(pid, func(addr uint64, nodePagecount map[int]int64, pagesize int64, attrs map[string]string) {
					if _, ok := attrs["anon"]; !ok {
						return
					}
					addrPageSize[addr] = pagesize
					for node, pagecount := range nodePagecount {
						sizeOnNode := pagecount * pagesize
						addrSegmentSize[addr] += sizeOnNode
						pidNodeMask |= nodeIdToMask(node)
						if highPressureNodeMask&nodeIdToMask(node) != 0 {
							sizeOnPressure += sizeOnNode
							if _, ok := nodeAddrSize[node]; !ok {
								nodeAddrSize[node] = map[uint64]int64{}
							}
							nodeAddrSize[node][addr] += sizeOnNode
						}
					}
				})
				if sizeOnPressure < constMinimumPidMoveSize {
					continue
				}
				oomScore, err := procReadInt(fmt.Sprintf("/proc/%d/oom_score", pid))
				if err != nil {
					continue
				}
				for node, addrSize := range nodeAddrSize {
					for addr, size := range addrSize {
						cand := &moveCandidate{
							pid:         pid,
							cgroup:      cgroup,
							addr:        addr,
							pageSize:    addrPageSize[addr],
							segmentSize: addrSegmentSize[addr],
							sizeOnNode:  size,
							fromNode:    node,
							preferredTargetMasks: []NodeMask{
								pidNodeMask & noPressureNodeMask,
								nset.nodeMask & noPressureNodeMask,
								pidNodeMask & (noPressureNodeMask | medPressureNodeMask),
								nset.nodeMask & (noPressureNodeMask | medPressureNodeMask)},
							score: size * (10000 + int64(oomScore)) / 10000,
						}
						cands = append(cands, cand)
					}
				}
				log.Debugf("  pid: %d oom_score: %d sizeOnPressure: %d\n", pid, oomScore, sizeOnPressure)
			}
		}
		if len(cands) == 0 {
			continue
		}
		sort.Slice(cands, func(i, j int) bool {
			return cands[i].score > cands[j].score
		})
		bytesToMoveFromNode := map[int]int64{}
		for _, node := range nodeMaskToIds(highPressureNodeMask) {
			bytesToMoveFromNode[node] = p.nodes[node].stopFreeingMemory - p.nodes[node].memAvail
		}
		bytesAvailOnNode := map[int]int64{}
		for _, node := range nodeMaskToIds(noPressureNodeMask) {
			bytesAvailOnNode[node] = p.nodes[node].memAvail - p.nodes[node].stopFreeingMemory
		}
		p.prevCands = cands
		for _, cand := range cands {
			pid := cand.pid
			targetNodeMask := NodeMask(0)
			// find a preferred target node that has most memory available
			for _, targetMask := range cand.preferredTargetMasks {
				if targetMask == 0 {
					continue
				}
				for _, targetNode := range nodeMaskToIds(targetMask) {
					if bytesAvailOnNode[targetNode] >= cand.sizeOnNode {
						targetNodeMask = nodeIdToMask(targetNode)
						break
					}
				}
				if targetNodeMask != 0 {
					break
				}
			}
			if targetNodeMask == 0 {
				// Cannot fit pages of this memory segment on any target node.
				// Currently we do not try to split the memory segment.
				// Continue to look smaller segments in next candidates.
				continue
			}
			log.Debugf("move candidate score %d: pid=%d targets=%b\n", cand.score, cand.pid, targetNodeMask)
			targetNodes := nodeMaskToIds(targetNodeMask)
			// sort targetNodes by memory available
			sort.Slice(targetNodes, func(i, j int) bool {
				return p.nodes[targetNodes[i]].memAvail > p.nodes[targetNodes[j]].memAvail
			})
			for _, nodeId := range targetNodes {
				log.Debugf("- target node %d avail %.3fG/%.3fG %.1f %%\n", nodeId, float32(p.nodes[nodeId].memAvail)/(1<<30), float32(p.nodes[nodeId].memTotal)/(1<<30), 100*float32(p.nodes[nodeId].memAvail)/float32(p.nodes[nodeId].memTotal))
			}

			log.Debugf("move pid %d addr %x from %d to node %d\n", pid, cand.addr, cand.fromNode, targetNodes[0])
			// Now we have a candidate to move.
			// As we calculated total memory segment size from numa_maps,
			// we can skip scanning /proc/pid/maps for start/end addresses.
			// In other words, no need to go through
			// NewProcess().AddressRanges().PagesMatching(),
			// but we can create Pages object directly.
			pp := &Pages{
				pid:   pid,
				pages: make([]Page, 0, cand.segmentSize/cand.pageSize),
			}
			for addr := cand.addr; addr < cand.addr+uint64(cand.segmentSize); addr += uint64(cand.pageSize) {
				pp.pages = append(pp.pages, Page{addr: addr})
			}
			pageLocations, err := pp.status()
			if err != nil {
				log.Debugf("failed to get page status for pid %d %x-%x (%d pages): %v", pid, cand.addr, cand.addr+uint64(cand.segmentSize), cand.segmentSize/cand.pageSize, err)
				continue
			}
			pagesOnHPNodes := &Pages{pid: pid, pages: make([]Page, 0)}
			for pageIndex, node := range pageLocations {
				if node < 0 {
					// error reading page location
					continue
				}
				if highPressureNodeMask&(1<<node) != 0 && bytesToMoveFromNode[node] > 0 {
					pagesOnHPNodes.pages = append(pagesOnHPNodes.pages, pp.pages[pageIndex])
					bytesToMoveFromNode[node] -= cand.pageSize
					bytesAvailOnNode[targetNodes[0]] -= cand.pageSize
				}
			}
			if len(pagesOnHPNodes.pages) == 0 {
				log.Debugf("no pages to move from pid %d %x-%x to node %d\n", pid, cand.addr, cand.addr+uint64(cand.segmentSize), targetNodes[0])
				continue
			}
			log.Debugf("schedule move task of %d MB (%d pages) of pid %d memory to node %d",
				(int64(len(pagesOnHPNodes.pages))*cand.pageSize)>>20,
				len(pagesOnHPNodes.pages),
				pid,
				targetNodes[0])
			p.mover.AddTask(NewMoverTask(pagesOnHPNodes, Node(targetNodes[0])))

			// Calculate if we have still need to move memory from any node
			bytesToMove := int64(0)
			for _, node := range nodeMaskToIds(highPressureNodeMask) {
				if bytesToMoveFromNode[node] > 0 {
					bytesToMove += bytesToMoveFromNode[node]
				}
			}
			if bytesToMove == 0 {
				log.Debugf("move tasks created for all necessary data from high pressure nodes")
				break
			}
			log.Debugf("still need to find %d MB to move from high pressure nodes", bytesToMove>>20)
		}
	}
	return nil
}

func (p *PolicyAvoidOom) pressureNodesets() ([]*nodeset, NodeMask, NodeMask, NodeMask) {
	mostPressureNodesets := make([]*nodeset, 0, len(p.nodeSets))
	for _, nset := range p.nodeSets {
		mostPressureNodesets = append(mostPressureNodesets, nset)
	}
	sort.Slice(mostPressureNodesets, func(i, j int) bool {
		return mostPressureNodesets[i].memAvail < mostPressureNodesets[j].memAvail
	})
	for order, nset := range mostPressureNodesets {
		procs := []int{}
		for _, cgroup := range nset.cgroups {
			procs = append(procs, cgroup.procs...)
		}
		log.Debugf("order %d in nodes %v: avail %.3fG/%.3fG %.1f %% cgroups: %d %v\n", order, nset.NodeIds(), float32(nset.memAvail)/(1<<30), float32(nset.memTotal)/(1<<30), 100*float32(nset.memAvail)/float32(nset.memTotal), len(nset.cgroups), procs)
	}
	highPressureNodeMask := NodeMask(0)
	medPressureNodeMask := NodeMask(0)
	for _, nset := range mostPressureNodesets {
		if nset.memAvail < nset.startFreeingMemory {
			log.Debugf("high pressure on nodes %v, avail: %.3fG startFreeing: %.3fG\n", nset.NodeIds(), float32(nset.memAvail)/(1<<30), float32(nset.startFreeingMemory)/(1<<30))
			highPressureNodeMask |= nset.nodeMask
		} else if nset.memAvail < nset.stopFreeingMemory {
			log.Debugf("med pressure on nodes %v, avail: %.3fG stopFreeing: %.3fG\n", nset.NodeIds(), float32(nset.memAvail)/(1<<30), float32(nset.stopFreeingMemory)/(1<<30))
			medPressureNodeMask |= nset.nodeMask
		}
	}
	return mostPressureNodesets, highPressureNodeMask, medPressureNodeMask, allNumaNodesMask &^ highPressureNodeMask &^ medPressureNodeMask
}

// Dump generates a string representation of the policy based on specified arguments
func (p *PolicyAvoidOom) Dump(args []string) string {
	p.mutex.Lock()
	defer p.mutex.Unlock()
	dumpHelp := `dump <config|nodes|status|balance|cands>`
	if len(args) == 0 {
		return dumpHelp
	}
	switch args[0] {
	case "config":
		return p.GetConfigJSON()
	case "nodes":
		var buf strings.Builder
		for _, node := range p.nodes {
			fmt.Fprintf(&buf, "Node %d: avail %.3fG/%.3fG %.1f %%\n", node.id, float32(node.memAvail)/(1<<30), float32(node.memTotal)/(1<<30), 100*float32(node.memAvail)/float32(node.memTotal))
		}
		return buf.String()
	case "status":
		if p.cmdLoop == nil {
			return "offline"
		}
		return "online"
	case "balance":
		return p.lastBalance
	case "cands":
		var buf strings.Builder
		for _, cand := range p.prevCands {
			fmt.Fprintf(&buf, "pid: %d %x size: %d MB (in %d kB pages) fromNode: %d score: %d\n",
				cand.pid,
				cand.addr,
				cand.sizeOnNode>>20,
				cand.pageSize/1024,
				cand.fromNode,
				cand.score)
		}
		return buf.String()
	}
	return "unknown argument, " + dumpHelp
}
