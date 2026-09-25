// SipCon64 hybrid AEAD: 64-bit rate, 192-bit capacity.
// Round-based, one permutation round per cycle.
//
// Functional twin of sipcon64/sipcon64.c. 256-bit state (x0..x3, 64
// bits each); rate is x0 alone (64 bits), capacity is x1,x2,x3 (192 bits),
// data port is 64 bits wide, throughput is 64/6 = 10.67 bits/cycle.
//
// The 192-bit capacity is the point: it matches Ascon-AEAD128's own capacity
// in a 256-bit state.
//
// WARNING: experimental, unanalysed construction. See sipcon64/sipcon64.h.
//
// Byte order is little-endian, din[7:0] is the first byte of the block.
//
// Block protocol, mirroring the C exactly:
//   * pulse start with key/npub valid; the core runs initialisation
//   * feed associated data blocks (din_ad = 1), then message blocks (din_ad = 0)
//   * every phase that is used must end with a block carrying din_last = 1 and
//     din_bytes in 0..7; full blocks carry din_bytes = 8 and din_last = 0
//   * a phase with no data is simply not fed; an empty message is still one
//     last block with din_bytes = 0
//   * decrypt is latched from `decrypt` at start; the core emits the computed
//     tag and the host compares it
//
// Cycles: 10 init + 6 per AD block + 6 per non-final message block + 10 final.

module sipcon64_aead (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,       // 1-cycle pulse
    input  wire        decrypt,     // latched with start: 0 = encrypt, 1 = decrypt
    input  wire [127:0] key,
    input  wire [127:0] npub,

    output wire        din_ready,
    input  wire        din_valid,
    input  wire [63:0] din,
    input  wire [3:0]  din_bytes,   // 8 = full block, 0..7 = last block
    input  wire        din_ad,      // 1 = associated data, 0 = message/ciphertext
    input  wire        din_last,

    output reg         dout_valid,
    output reg  [63:0] dout,
    output reg  [3:0]  dout_bytes,

    output reg         done,
    output reg  [127:0] tag
);

  function [63:0] rotl64;
    input [63:0] x;
    input integer b;
    begin
      rotl64 = (x << b) | (x >> (64 - b));
    end
  endfunction

  // Ascon round constant into the capacity word x2, then SIPROUND verbatim
  function [255:0] hybrid_round;
    input [255:0] s;
    input [7:0]   c;
    reg [63:0] v0, v1, v2, v3;
    begin
      v0 = s[255:192]; v1 = s[191:128]; v2 = s[127:64]; v3 = s[63:0];

      v2 = v2 ^ {56'd0, c};

      v0 = v0 + v1;
      v1 = rotl64(v1, 13);
      v1 = v1 ^ v0;
      v0 = rotl64(v0, 32);
      v2 = v2 + v3;
      v3 = rotl64(v3, 16);
      v3 = v3 ^ v2;
      v0 = v0 + v3;
      v3 = rotl64(v3, 21);
      v3 = v3 ^ v0;
      v2 = v2 + v1;
      v1 = rotl64(v1, 17);
      v1 = v1 ^ v2;
      v2 = rotl64(v2, 32);

      hybrid_round = {v0, v1, v2, v3};
    end
  endfunction

  function [7:0] rc_of;
    input [3:0] i;
    begin
      case (i)
        4'd0: rc_of = 8'hf0;  4'd1: rc_of = 8'he1;
        4'd2: rc_of = 8'hd2;  4'd3: rc_of = 8'hc3;
        4'd4: rc_of = 8'hb4;  4'd5: rc_of = 8'ha5;
        4'd6: rc_of = 8'h96;  4'd7: rc_of = 8'h87;
        4'd8: rc_of = 8'h78;  4'd9: rc_of = 8'h69;
        4'd10: rc_of = 8'h5a; default: rc_of = 8'h4b;
      endcase
    end
  endfunction

  // same IV encoding as Ascon-AEAD128, with the rate field holding 8 and the
  // round fields 10/6 rather than Ascon's 12/8 -- so a state of this variant
  // cannot collide with Ascon's, nor with the earlier 12/8 version of itself
  localparam [63:0] IV = (64'd1)
                       | (64'd10  << 16)
                       | (64'd6   << 20)
                       | (64'd128 << 24)
                       | (64'd8   << 40)
                       | (64'h53  << 48);

  localparam [2:0] S_IDLE  = 3'd0,
                   S_PERM  = 3'd1,
                   S_INITK = 3'd2,
                   S_WAIT  = 3'd3,
                   S_FINK  = 3'd4,
                   S_DONE  = 3'd5;

  reg [255:0] st;                 // {x0,x1,x2,x3}
  reg [2:0]   fsm, ret;
  reg [3:0]   rc;
  reg [127:0] k_r;
  reg         dec_r, dsep_done;

  wire [63:0] k0 = k_r[63:0];
  wire [63:0] k1 = k_r[127:64];

  assign din_ready = (fsm == S_WAIT);

  // the rate is x0 alone
  wire [63:0] rate = st[255:192];

  wire        full  = (din_bytes == 4'd8);
  wire [5:0]  shamt = {din_bytes[2:0], 3'b000};
  wire [63:0] mask  = full ? {64{1'b1}} : ((64'd1 << shamt) - 64'd1);
  wire [63:0] padv  = full ? 64'd0      :  (64'd1 << shamt);

  wire [63:0] din_m    = din & mask;
  wire [63:0] enc_rate = rate ^ din_m;
  wire [63:0] dec_rate = (rate & ~mask) | din_m;

  wire [63:0] new_rate = din_ad ? (rate ^ din_m) ^ padv
                                : (dec_r ? dec_rate ^ padv
                                         : enc_rate ^ padv);
  // ciphertext on encrypt, plaintext on decrypt: the same XOR either way, so
  // only the state update below forks (xor vs. masked replace)
  wire [63:0] blk_out  = rate ^ din_m;

  // domain separation lands on x3, the last capacity word, the first time a
  // message block is taken -- 0x80 in byte 7, the same DSEP as Ascon-AEAD128
  wire [63:0] x3_ds = st[63:0] ^ ((!din_ad && !dsep_done) ? (64'h80 << 56) : 64'd0);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fsm        <= S_IDLE;
      st         <= 256'd0;
      rc         <= 4'd0;
      ret        <= S_IDLE;
      k_r        <= 128'd0;
      dec_r      <= 1'b0;
      dsep_done  <= 1'b0;
      dout_valid <= 1'b0;
      dout       <= 64'd0;
      dout_bytes <= 4'd0;
      done       <= 1'b0;
      tag        <= 128'd0;
    end else begin
      dout_valid <= 1'b0;
      done       <= 1'b0;

      case (fsm)
        S_IDLE: begin
          if (start) begin
            k_r       <= key;
            dec_r     <= decrypt;
            dsep_done <= 1'b0;
            // x0 = N0, x1 = N1, x2 = K0, x3 = K1 ^ IV
            st        <= {npub[63:0], npub[127:64], key[63:0], key[127:64] ^ IV};
            rc        <= 4'd2;          // p^10
            ret       <= S_INITK;
            fsm       <= S_PERM;
          end
        end

        S_PERM: begin
          st <= hybrid_round(st, rc_of(rc));
          if (rc == 4'd11) fsm <= ret;
          else             rc  <= rc + 4'd1;
        end

        S_INITK: begin
          // x2 ^= K0, x3 ^= K1
          st  <= {st[255:128], st[127:64] ^ k0, st[63:0] ^ k1};
          fsm <= S_WAIT;
        end

        S_WAIT: begin
          if (din_valid) begin
            st <= {new_rate, st[191:128], st[127:64], x3_ds};
            if (!din_ad) begin
              dsep_done  <= 1'b1;
              dout       <= blk_out;
              dout_bytes <= din_bytes;
              dout_valid <= 1'b1;
            end
            if (!din_ad && din_last) begin
              fsm <= S_FINK;
            end else begin
              rc  <= 4'd6;              // p^6
              ret <= S_WAIT;
              fsm <= S_PERM;
            end
          end
        end

        S_FINK: begin
          st  <= {st[255:128], st[127:64] ^ k0, st[63:0] ^ k1};
          rc  <= 4'd2;                  // p^10
          ret <= S_DONE;
          fsm <= S_PERM;
        end

        S_DONE: begin
          // tag = (x2 ^ K0, x3 ^ K1)
          tag  <= {st[63:0] ^ k1, st[127:64] ^ k0};
          done <= 1'b1;
          fsm  <= S_IDLE;
        end

        default: fsm <= S_IDLE;
      endcase
    end
  end

endmodule
