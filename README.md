# NoC Project: Node + Router System Overview
***** PROJECT STILL IN PROGRESS *****

This document explains:
1. What the **Node** does
2. What the **Router** must do (since `Router.sv` is currently empty)
3. How the full project works end-to-end

NOTE: Design drawings can be found in the doc folder. They will be updated as I work through this project

---

## 1) What the Node does

The [`Node`](p3-noc-srikarg2006/Node.sv) is the boundary between a 32-bit testbench interface and an 8-bit network interface.

### TB → Node → Router direction
- Testbench injects a full 32-bit packet (`pkt_in`) when `pkt_in_avail` is asserted.
- Node stores packets in an internal FIFO queue.
- Node advertises backpressure with `cQ_full`.
- Node sends queued packets to the router **byte-by-byte**:
  1. `{src, dest}` (8 bits)
  2. `data[23:16]`
  3. `data[15:8]`
  4. `data[7:0]`
- Node uses handshake:
  - `put_outbound` = valid byte from node
  - `free_outbound` = router ready to accept byte

### Router → Node → TB direction
- Node receives 4 bytes from router on:
  - `put_inbound` + `payload_inbound`
- Node reconstructs the original 32-bit packet.
- Node outputs reconstructed packet on:
  - `pkt_out` + `pkt_out_avail`

---

## 2) What the Router must do

The [`Router`](p3-noc-srikarg2006/Router.sv) currently has only the module header. For the project to work, it must implement **four-port packet reception, routing, arbitration, and transmission**.

### Router interface summary
Each router has 4 ports with identical byte-stream handshakes:

- Inbound from connected neighbor/node:
  - `put_inbound[p]`, `payload_inbound[p]`
- Router backpressure to that sender:
  - `free_inbound[p]`
- Outbound toward connected neighbor/node:
  - `put_outbound[p]`, `payload_outbound[p]`
- Readiness from that receiver:
  - `free_outbound[p]`

### Required internal behavior

#### A) Receive and reassemble per input port
For each input port `p`:
- Watch `put_inbound[p] && free_inbound[p]`.
- Capture 4 incoming bytes in order and reassemble one `pkt_t` packet.
- Maintain per-port state (`byte_count`, partial packet register).

#### B) Compute destination output port
After a full packet is assembled:
- Use `pkt.dest` to determine which output port should carry it.
- Mapping depends on router ID/topology from [`Top`](p3-noc-srikarg2006/Top.sv):
  - Router 0 serves local nodes 0,1,2 and bridge to Router 1
  - Router 1 serves local nodes 3,4,5 and bridge to Router 0
- If destination is not local, forward through bridge port.

#### C) Buffer packets waiting for each output port
- Multiple input ports may target same output simultaneously.
- Router needs output-side buffering or request queues.
- Hold complete packet until selected and transmitted.

#### D) Arbitrate contention fairly
When several inputs request one output:
- Choose one requester per packet transaction.
- Keep fairness (round-robin is typical and usually expected).
- Do not interleave bytes from different packets on one output stream.

#### E) Transmit packet as 4-byte stream
For selected packet on output port `q`:
- Send bytes in required order:
  1. `{src, dest}`
  2. `data[23:16]`
  3. `data[15:8]`
  4. `data[7:0]`
- Assert `put_outbound[q]` only when data is valid.
- Advance only when `free_outbound[q]` indicates receiver ready.
- Keep packet atomic per output stream.

#### F) Correct backpressure behavior
- `free_inbound[p]` should reflect whether router can accept a byte on input `p`.
- Deassert when input reassembly/buffering is full.
- Reassert when space is available.

#### G) Reset correctness
On reset:
- Clear partial-byte assembly state.
- Clear queued packets/requests.
- Reset arbitration state.
- Deassert output valid signals safely.

---

## 3) How the whole project functions

At top level ([`Top`](p3-noc-srikarg2006/Top.sv)):
- 6 nodes connect to 2 routers.
- Router 0 and Router 1 are connected by one port each (bridge).
- Testbench injects packets into source nodes.
- Source node serializes packet to bytes.
- Source router receives bytes, reconstructs packet, selects output port.
- If destination is remote, packet crosses router-to-router bridge.
- Destination router sends bytes to destination node.
- Destination node reconstructs and emits full packet to testbench.

So, the system is a packet-switched network where:
- **Nodes convert width/protocol (32-bit ↔ 8-bit stream).**
- **Routers perform buffering + routing + contention resolution + forwarding.**

---

## 4) Implementation checklist for `Router.sv`

- [ ] Per-input 4-byte packet reassembly FSM
- [ ] Destination decode (local vs bridge)
- [ ] Per-output request tracking
- [ ] Fair arbiter per output (round-robin recommended)
- [ ] Per-output 4-byte transmit FSM
- [ ] Valid/ready handshake correctness (`put_*`/`free_*`)
- [ ] Backpressure handling (`free_inbound`)
- [ ] Clean reset behavior
- [ ] No dropped/corrupted/reordered bytes within a packet

---

## 5) Practical validation flow

- First pass node-level tests using [`nodeTB.sv`](p3-noc-srikarg2006/nodeTB.sv)
- Then run full-router tests using [`RouterTB.sv`](p3-noc-srikarg2006/RouterTB.sv)
- Use stress/fairness modes to catch arbitration and starvation bugs
- Inspect waveforms to verify byte order and handshake timing on each port
