`default_nettype none
`include "Router.svh"
`include "RouterPkg.pkg"

//////
////// Network on Chip (NoC) 18-341
////// Node module
//////
module Node #(parameter NODEID = 0) (
  input logic clock, reset_n,

  //Interface to testbench: the blue arrows
  input  pkt_t pkt_in,        // Data packet from the TB
  input  logic pkt_in_avail,  // The packet from TB is available
  output logic cQ_full,       // The queue is full

  output pkt_t pkt_out,       // Outbound packet from node to TB
  output logic pkt_out_avail, // The outbound packet is available

  //Interface with the router: black arrows
  input  logic       free_outbound,    // Router is free
  output logic       put_outbound,     // Node is transferring to router
  output logic [7:0] payload_outbound, // Data sent from node to router

  output logic       free_inbound,     // Node is free
  input  logic       put_inbound,      // Router is transferring to node
  input  logic [7:0] payload_inbound); // Data sent from router to node

  logic [31:0] fifo_out;
  logic fifo_empty, read_in, packet_avail;

  assign packet_avail = ~fifo_empty;

  FIFO q(
    .clock(clock),
    .reset_n(reset_n),
    .data_in(pkt_in),
    .we(pkt_in_avail),
    .re(read_in),
    .data_out(fifo_out),
    .full(cQ_full),
    .empty(fifo_empty));
  
  Packet_decomp node_to_router(
    .clock(clock),
    .reset_n(reset_n),
    .packet(fifo_out),
    .packet_avail(packet_avail),
    .payload_out(payload_outbound),
    .payload_avail(put_outbound),
    .read_in(read_in),
    .requested(free_outbound));
  
  Packet_reconstruct router_to_node(
    .clock(clock),
    .reset_n(reset_n),
    .payload(payload_inbound),
    .put_inbound(put_inbound),
    .packet(pkt_out),
    .packet_avail(pkt_out_avail),
    .free_inbound(free_inbound));

endmodule: Node

/*
This packet decomposes a 32-bit packet into 4 8-bit payloads,
sending one such payload out every clock cycle. It is implemmented
using just an FSM, with one register being used to store the state
value, and one register being used to store the inputted packet
in a buffer. The FSM breaks down the 32-bit packet and sends 
the payload_avail signal out at each clock cycle where a payload
is prepared and sent.
*/
module Packet_decomp(
  input logic clock, reset_n,
  input logic [31:0] packet,
  input logic packet_avail,
  input logic requested,
  output logic payload_avail,
  output logic [7:0] payload_out,
  output logic read_in);

  enum logic [2:0] {IDLE, WAIT, SEND0, SEND1, SEND2, SEND3} 
                    curr_state, next_state;
  logic [31:0] buffer, buffer_next;

  // Next State Logic
  always_comb begin
    next_state = curr_state;
    case(curr_state)
      IDLE: next_state = (packet_avail) ? WAIT : IDLE;
      WAIT: next_state = SEND0;
      SEND0: next_state = (requested) ? SEND1 : SEND0;
      SEND1: next_state = SEND2;
      SEND2: next_state = SEND3;
      SEND3: next_state = (packet_avail) ? WAIT : IDLE;
    endcase
  end

  // Output Generation Logic
  always_comb begin
    // default values
    buffer_next = buffer;
    payload_avail = 1'b0;
    payload_out = 8'd0;
    read_in = 1'b0;
    
    case(curr_state)
      IDLE: begin
        if (packet_avail) begin
          read_in = 1'b1;
          buffer_next = packet;
        end
      end
      WAIT: /* no outputs in this state */;
      SEND0: begin
        if (requested) begin
          payload_out = buffer[31:24];
          payload_avail = 1'b1;
        end
      end
      SEND1: payload_out = buffer[23:16];
      SEND2: payload_out = buffer[15:8];
      SEND3: begin
        payload_out = buffer[7:0];
        if (packet_avail) begin
          buffer_next = packet;
          read_in = 1'b1;
        end
      end
    endcase
  end

  // Flip Flops for state transition
  always_ff @(posedge clock, negedge reset_n) begin
    if (~reset_n) begin
      curr_state <= IDLE;
      buffer <= 32'd0;
    end
    else begin
      curr_state <= next_state;
      buffer <= buffer_next;
    end
  end

endmodule: Packet_decomp


/*
This module reconstructs 4 8-bit payloads into the complete 32-bit packet.
It accepts the payloads sequentially and uses an FSM to reconstruct
the packet, only asserting the packet_avail flag when the packet is
ready to be sent. The only components that are used are two registers,
one to store the state and one to store the intermediate values of 
the packet while it is being reconstructed.
*/
module Packet_reconstruct(
  input logic clock, reset_n,
  input logic [7:0] payload,
  input logic put_inbound,
  output logic [31:0] packet,
  output logic packet_avail,
  output logic free_inbound);

  enum logic [1:0] {IDLE, BYTE1, BYTE2, BYTE3} curr_state, next_state;
  logic [31:0] buffer, buffer_next;

  // Next State Logic
  always_comb begin
    case(curr_state) 
      IDLE: next_state = put_inbound ? BYTE1 : IDLE;
      BYTE1: next_state = put_inbound ? BYTE2 : BYTE1;
      BYTE2: next_state = put_inbound ? BYTE3 : BYTE2;
      BYTE3: next_state = put_inbound ? IDLE : BYTE3;
    endcase
  end

  // Output Generation Logic
  always_comb begin
    // default values
    free_inbound = 1'b1;
    buffer_next = buffer;
    packet_avail = 1'b0;
    packet = 32'd0;
    
    case(curr_state)
      IDLE: begin
        if (put_inbound) begin
          free_inbound = 1'b0;
          buffer_next = {payload, 24'd0};
        end
      end
      BYTE1: begin
        if (put_inbound) begin
          buffer_next = {buffer_next[31:24], payload, 16'd0};
          free_inbound = 1'b0;
        end
      end
      BYTE2: begin
        if (put_inbound) begin
          buffer_next = {buffer[31:16], payload, 8'd0};
        end
        free_inbound = 1'b0;
      end
      BYTE3: begin
        if (put_inbound) begin
          packet = {buffer[31:8], payload};
          packet_avail = 1'b1;
        end
        free_inbound = 1'b0;
      end
    endcase
  end

  // always_ff for state transitions
  always_ff @(posedge clock, negedge reset_n) begin
    if (~reset_n) begin
      buffer <= 32'd0;
      curr_state <= IDLE;
    end
    else begin
      buffer <= buffer_next;
      curr_state <= next_state;
    end
  end
  
endmodule: Packet_reconstruct

/*
 *  Create a FIFO (First In First Out) buffer with depth 4 using the given
 *  interface and constraints
 *    - The buffer is initally empty
 *    - Reads are combinational, so data_out is valid unless empty is asserted
 *    - Removal from the queue is processed on the clock edge.
 *    - Writes are processed on the clock edge
 *    - If a write is pending while the buffer is full, do nothing
 *    - If a read is pending while the buffer is empty, do nothing
 */
module FIFO #(parameter WIDTH=32) (
  input logic              clock, reset_n,
  input logic [WIDTH-1:0]  data_in,
  input logic              we, re,
  output logic [WIDTH-1:0] data_out,
  output logic             full, empty);

  logic [3:0][WIDTH - 1:0] buffer;
  logic [1:0] read_ptr, write_ptr;
  logic [2:0] counter;
  logic [1:0] counter_state;
  assign counter_state = {we & ~full, re & ~empty};

  assign data_out = buffer[read_ptr];
  assign full = (counter == 3'd4);
  assign empty = (counter == '0);

  always_ff @(posedge clock, negedge reset_n) begin
    if (~reset_n) begin
      counter   <= 3'd0;
      read_ptr  <= 2'd0;
      write_ptr <= 2'd0;
    end
    else begin
      if (we && !full) begin
        buffer[write_ptr] <= data_in;
        write_ptr <= write_ptr + 2'd1;
      end
      if (re && !empty)
        read_ptr <= read_ptr + 2'd1;
      case (counter_state)
        2'b10:   counter <= counter + 3'd1;
        2'b01:   counter <= counter - 3'd1;
        default: counter <= counter;
      endcase
    end
  end

endmodule: FIFO