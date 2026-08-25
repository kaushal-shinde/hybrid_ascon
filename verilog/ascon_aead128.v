// Ascon-AEAD128 (NIST SP 800-232), round-based: one permutation round per cycle.
//
// Functional twin of ascon-aead128/aead.c. State is 5 x 64 bits; the rate is
// x0,x1 (128 bits); p^12 initialises and finalises, p^8 runs per data block.
//
// Byte order: all data ports are little-endian byte streams, so din[7:0] is the
// first byte of the block, key[7:0] is key byte 0. This matches LOADBYTES() in
// the reference word.h.
//
// Block protocol, mirroring the C exactly:
//   * pulse start with key/npub held valid; the core runs initialisation
//   * feed associated data blocks (din_ad = 1), then message blocks (din_ad = 0)
//   * every phase that is used must end with a block carrying din_last = 1 and
//     din_bytes in 0..15; full blocks carry din_bytes = 16 and din_last = 0
//   * a phase with no data is simply not fed (matching `if (adlen)` in the C);
//     an empty message is still one last block with din_bytes = 0
//   * decrypt is latched from `decrypt` at start; the core emits the computed
//     tag and the host compares it
//
// Cycles: 12 init + 8 per AD block + 8 per non-final message block + 12 final.

module ascon_aead128 (
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

  // ---------------------------------------------------------------- helpers
  // right rotation; written arithmetically so the amount need not be a
  // constant part-select bound
  function [63:0] ror64;
    input [63:0] x;
    input integer n;
    begin
      ror64 = (x >> n) | (x << (64 - n));
    end
  endfunction

  // one Ascon round on the packed state {x0,x1,x2,x3,x4}
  function [319:0] ascon_round;
    input [319:0] s;
    input [7:0]   c;
    reg [63:0] x0, x1, x2, x3, x4;
    reg [63:0] t0, t1, t2, t3, t4;
    begin
      x0 = s[319:256]; x1 = s[255:192]; x2 = s[191:128];
      x3 = s[127:64];  x4 = s[63:0];

      // addition of round constant
      x2 = x2 ^ {56'd0, c};

      // substitution layer
      x0 = x0 ^ x4;
      x4 = x4 ^ x3;
      x2 = x2 ^ x1;
      t0 = x0 ^ (~x1 & x2);
      t1 = x1 ^ (~x2 & x3);
      t2 = x2 ^ (~x3 & x4);
      t3 = x3 ^ (~x4 & x0);
      t4 = x4 ^ (~x0 & x1);
      t1 = t1 ^ t0;
      t0 = t0 ^ t4;
      t3 = t3 ^ t2;
      t2 = ~t2;

      // linear diffusion layer
      x0 = t0 ^ ror64(t0, 19) ^ ror64(t0, 28);
      x1 = t1 ^ ror64(t1, 61) ^ ror64(t1, 39);
      x2 = t2 ^ ror64(t2,  1) ^ ror64(t2,  6);
      x3 = t3 ^ ror64(t3, 10) ^ ror64(t3, 17);
      x4 = t4 ^ ror64(t4,  7) ^ ror64(t4, 41);

      ascon_round = {x0, x1, x2, x3, x4};
    end
  endfunction

  // Ascon round constants; p^n consumes the last n entries
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

  // IV for Ascon-AEAD128 (ASCON_128A_IV in constants.h)
  localparam [63:0] IV = (64'd1)         // AEAD variant
                       | (64'd12 << 16)  // p^a rounds
                       | (64'd8  << 20)  // p^b rounds
                       | (64'd128 << 24) // tag bits
                       | (64'd16 << 40); // rate bytes

  localparam [2:0] S_IDLE  = 3'd0,
                   S_PERM  = 3'd1,
                   S_INITK = 3'd2,
                   S_WAIT  = 3'd3,
                   S_FINK  = 3'd4,
                   S_DONE  = 3'd5;

  reg [319:0] st;                 // {x0,x1,x2,x3,x4}
  reg [2:0]   fsm, ret;
  reg [3:0]   rc;
  reg [127:0] k_r;
  reg         dec_r, dsep_done;

  wire [63:0] k0 = k_r[63:0];
  wire [63:0] k1 = k_r[127:64];

  assign din_ready = (fsm == S_WAIT);

  // ------------------------------------------------- block padding / rate
  // rate as a 128-bit little-endian byte lane: {x1, x0}
  wire [127:0] rate = {st[255:192], st[319:256]};

  wire        full   = (din_bytes == 5'd16);
  wire [7:0]  shamt  = {din_bytes[3:0], 3'b000};          // 8 * bytes, bytes <= 15
  wire [127:0] mask  = full ? {128{1'b1}} : ((128'd1 << shamt) - 128'd1);
  wire [127:0] padv  = full ? 128'd0      :  (128'd1 << shamt);

  wire [127:0] din_m = din & mask;
  wire [127:0] enc_rate = rate ^ din_m;                    // ciphertext lane
  wire [127:0] dec_rate = (rate & ~mask) | din_m;          // rate after inserting ct

  wire [127:0] new_rate = din_ad ? (rate ^ din_m) ^ padv
                                 : (dec_r ? dec_rate ^ padv
                                          : enc_rate ^ padv);
  wire [127:0] blk_out  = dec_r ? (rate ^ din_m) : enc_rate;

  // domain separation lands on x4 the first time a message block is taken
  wire [63:0] x4_ds = st[63:0] ^ ((!din_ad && !dsep_done) ? (64'h80 << 56) : 64'd0);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fsm        <= S_IDLE;
      st         <= 320'd0;
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
            // x0 = IV, x1 = K0, x2 = K1, x3 = N0, x4 = N1
            st        <= {IV, key[63:0], key[127:64], npub[63:0], npub[127:64]};
            rc        <= 4'd0;          // p^12
            ret       <= S_INITK;
            fsm       <= S_PERM;
          end
        end

        S_PERM: begin
          st <= ascon_round(st, rc_of(rc));
          if (rc == 4'd11) fsm <= ret;
          else             rc  <= rc + 4'd1;
        end

        S_INITK: begin
          // x3 ^= K0, x4 ^= K1
          st  <= {st[319:128], st[127:64] ^ k0, st[63:0] ^ k1};
          fsm <= S_WAIT;
        end

        S_WAIT: begin
          if (din_valid) begin
            st <= {new_rate[63:0], new_rate[127:64], st[191:128], st[127:64], x4_ds};
            if (!din_ad) begin
              dsep_done  <= 1'b1;
              dout       <= blk_out;
              dout_bytes <= din_bytes;
              dout_valid <= 1'b1;
            end
            if (!din_ad && din_last) begin
              fsm <= S_FINK;                 // no permutation before finalisation
            end else begin
              rc  <= 4'd4;                   // p^8
              ret <= S_WAIT;
              fsm <= S_PERM;
            end
          end
        end

        S_FINK: begin
          // x2 ^= K0, x3 ^= K1
          st  <= {st[319:192], st[191:128] ^ k0, st[127:64] ^ k1, st[63:0]};
          rc  <= 4'd0;                       // p^12
          ret <= S_DONE;
          fsm <= S_PERM;
        end

        S_DONE: begin
          // tag = (x3 ^ K0, x4 ^ K1)
          tag  <= {st[63:0] ^ k1, st[127:64] ^ k0};
          done <= 1'b1;
          fsm  <= S_IDLE;
        end

        default: fsm <= S_IDLE;
      endcase
    end
  end

endmodule
