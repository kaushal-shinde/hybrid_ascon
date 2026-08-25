// Ascon-SipHash hybrid AEAD, round-based: one permutation round per cycle.
//
// Functional twin of ascon-siphash/asconsip.c. 4 x 64-bit state (256 bits),
// rate = x0,x1 (128 bits), capacity = x2,x3 (128 bits), Ascon's duplex mode
// with Ascon's round constant followed by SipHash's SIPROUND in place of the
// S-box and linear layer. p^12 initialises and finalises, p^8 per data block.
//
// WARNING: experimental, unanalysed construction. See ascon-siphash/asconsip.h.
//
// Byte order and block protocol are identical to ascon_aead128.v: little-endian
// data ports, associated data blocks first, every used phase terminated by a
// block with din_last = 1 and din_bytes in 0..15, an empty message still sent
// as one last block with din_bytes = 0.
//
// Cycles: 12 init + 8 per AD block + 8 per non-final message block + 12 final.

module asconsip_aead (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,       // 1-cycle pulse
    input  wire         decrypt,     // latched with start: 0 = encrypt, 1 = decrypt
    input  wire [127:0] key,
    input  wire [127:0] npub,

    output wire         din_ready,
    input  wire         din_valid,
    input  wire [127:0] din,
    input  wire [4:0]   din_bytes,   // 16 = full block, 0..15 = last block
    input  wire         din_ad,      // 1 = associated data, 0 = message/ciphertext
    input  wire         din_last,

    output reg          dout_valid,
    output reg  [127:0] dout,
    output reg  [4:0]   dout_bytes,

    output reg          done,
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

  // Ascon's constant schedule; p^n consumes the last n entries
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

  // parameter encoding, with 0x53 marking the SipHash round core
  localparam [63:0] IV = (64'd1)
                       | (64'd12  << 16)
                       | (64'd8   << 20)
                       | (64'd128 << 24)
                       | (64'd16  << 40)
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

  // rate as a 128-bit little-endian byte lane: {x1, x0}
  wire [127:0] rate = {st[191:128], st[255:192]};

  wire         full  = (din_bytes == 5'd16);
  wire [7:0]   shamt = {din_bytes[3:0], 3'b000};
  wire [127:0] mask  = full ? {128{1'b1}} : ((128'd1 << shamt) - 128'd1);
  wire [127:0] padv  = full ? 128'd0      :  (128'd1 << shamt);

  wire [127:0] din_m    = din & mask;
  wire [127:0] enc_rate = rate ^ din_m;
  wire [127:0] dec_rate = (rate & ~mask) | din_m;

  wire [127:0] new_rate = din_ad ? (rate ^ din_m) ^ padv
                                 : (dec_r ? dec_rate ^ padv
                                          : enc_rate ^ padv);
  wire [127:0] blk_out  = dec_r ? (rate ^ din_m) : enc_rate;

  // domain separation lands on x3, the last capacity word
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
      dout       <= 128'd0;
      dout_bytes <= 5'd0;
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
            rc        <= 4'd0;          // p^12
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
            st <= {new_rate[63:0], new_rate[127:64], st[127:64], x3_ds};
            if (!din_ad) begin
              dsep_done  <= 1'b1;
              dout       <= blk_out;
              dout_bytes <= din_bytes;
              dout_valid <= 1'b1;
            end
            if (!din_ad && din_last) begin
              fsm <= S_FINK;
            end else begin
              rc  <= 4'd4;              // p^8
              ret <= S_WAIT;
              fsm <= S_PERM;
            end
          end
        end

        S_FINK: begin
          // x2 ^= K0, x3 ^= K1
          st  <= {st[255:128], st[127:64] ^ k0, st[63:0] ^ k1};
          rc  <= 4'd0;                  // p^12
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
