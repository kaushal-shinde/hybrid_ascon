// SCHWAEMM256-128 (the SPARKLE submission's primary AEAD member), implementing
// the CryptoCore-facing protocol of the NIST Lightweight Cryptography Hardware
// API (see tinyjambu_lwc.v's header for the full API citation; same ports,
// opcodes and segment-header format).
//
// WARNING: SPARKLE did NOT win the NIST LWC competition -- Ascon did. This
// core exists for hardware comparison against the Ascon cores in verilog/,
// not as a recommendation. Lint-checked (Verilator + Vivado) but NOT run
// against the official KAT vectors in simulation -- unlike tinyjambu_lwc.v.
// It is a careful transliteration, not a confirmed-correct one.
//
// Algorithm: transliterated from the official reference C in
// ../lwc-finalists/sparkle/ (encrypt.c + sparkle_ref.c, version 1.1.2,
// NIST final-round submission, GPLv3, (C) University of Luxembourg).
//
// PARAMETERS (schwaemm_cfg.h, SCHWAEMM256_128):
//   SPARKLE384 permutation: 6 branches, each branch a 32-bit (x,y) pair
//   rate     = 256 bits = 4 branches = 8 words = 32 bytes
//   capacity = 128 bits = 2 branches (x4,y4,x5,y5)
//   key = 16 B, Npub = 32 B (note: 32, not 16 -- SCHWAEMM256_128 takes a
//   256-bit nonce), tag = 16 B
//   slim permutation = 7 steps, big permutation = 11 steps
//
// ENDIANNESS: the reference memcpy's byte strings straight into uint32_t
// arrays, so its state words are LITTLE-endian views of the byte stream. The
// LWC API delivers bytes big-endian-packed in each 32-bit bus word (byte 0 in
// bits [31:24]). Every word crossing the bus is therefore byte-swapped, on
// input and on output alike; internally this core works in the reference's
// little-endian word domain so that the arithmetic matches the C exactly.
//
// RATE WORD ORDER: the rate occupies branches 0..3, and the reference's
// word-indexed rate buffer maps as in0->x0, in1->y0, in2->x1, in3->y1,
// in4->x2, in5->y2, in6->x3, in7->y3 (interleaved x/y, not all-x-then-all-y).
//
// RHO / WHITENING (rho_whi_*): three stages, in this order --
//   1. Feistel swap on the rate, pairing branch i with branch i+4 within the
//      SAME x or y half. STATE_WORD(s,i) selects x[i/2] for even i and y[i/2]
//      for odd i, so the four pairs are (x0,x2), (y0,y2), (x1,x3), (y1,y3):
//      left := right, right := right ^ old_left.
//   2. XOR the (padded) rate block in.
//   3. Whiten: x[i] ^= x[4 + (i&1)], y[i] ^= y[4 + (i&1)] -- capacity words
//      folded back into the rate.
//   For encryption the output block is computed from the rate BEFORE stage 1.
//
// DECRYPT ABSORPTION: rho_whi_dec has two visibly different branches for the
// partial and full final block, but they compute the same thing -- the state
// absorbs the PADDED PLAINTEXT in both cases. (Full block: it XORs
// statebuf ^ inbuf, and out = inbuf ^ statebuf, so that IS the plaintext, and
// a full block needs no pad.) This core therefore uses one uniform rule:
// absorb = encrypt ? padded_input : padded_recovered_plaintext.
//
// PADDING: a block shorter than 32 bytes gets a single 0x80 byte at byte
// index nb, with everything above it zero. Because bytes sit little-endian
// inside words, that is word nb>>2, bit position 8*(nb&3) -- computed
// directly as a variable part-select rather than a per-word case ladder.
//
// FINAL-BLOCK CONSTANT: the reference XORs a domain constant into y[5] (the
// last capacity word) BEFORE calling rho on the final block, and rho's
// whitening stage then READS y[5]. The order matters, so this core computes
// the constant-modified y5 as a wire and uses it for both the whitening and
// the y5 register update.
//
// BLOCK SPLIT: the reference loops "while (inlen > RATE_BYTES)" -- strictly
// greater -- so a length that is an exact multiple of 32 ends with a FULL
// 32-byte final block (constant A1/M3, no padding), not an empty one. Also,
// ProcessAssocData / ProcessPlainText are skipped entirely for a zero-length
// AD / message; this core skips them the same way.
//
// COST: one SPARKLE *step* per clock cycle. A step is six parallel ARX-boxes,
// each four chained 32-bit adds, plus the linear layer -- a long critical
// path, deliberately kept as the natural round unit so the mapping to the C
// stays one-to-one and comparable with the other cores here. Splitting the
// ARX-box into its four sub-rounds would shorten it roughly 4x at 4x the
// cycles; that is a fair optimisation but not a transliteration.

module sparkle_lwc (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] pdi_data,
    input  wire        pdi_valid,
    output wire        pdi_ready,

    input  wire [31:0] sdi_data,
    input  wire        sdi_valid,
    output wire        sdi_ready,

    output wire [31:0] do_data,
    output wire        do_valid,
    input  wire        do_ready,
    output wire        do_last
);

  localparam [3:0] OP_DEC     = 4'b0011;
  localparam [3:0] ST_SUCCESS = 4'b1110, ST_FAILURE = 4'b1111;
  localparam [3:0] SEGT_PT    = 4'h4,    SEGT_CT    = 4'h5, SEGT_TAG = 4'h8;

  // CONST_Ax / CONST_Mx with CAP_BRANS = 2: (v ^ (1<<2)) << 24
  localparam [31:0] CONST_A0 = 32'h04000000;   // (0^4)<<24, partial AD
  localparam [31:0] CONST_A1 = 32'h05000000;   // (1^4)<<24, full AD
  localparam [31:0] CONST_M2 = 32'h06000000;   // (2^4)<<24, partial msg
  localparam [31:0] CONST_M3 = 32'h07000000;   // (3^4)<<24, full msg

  // ---------------------------------------------------------------- helpers
  function [31:0] bswap;
    input [31:0] v;
    begin bswap = {v[7:0], v[15:8], v[23:16], v[31:24]}; end
  endfunction

  // ELL(x) = ROT(x ^ (x<<16), 16), where ROT is a rotate RIGHT.
  function [31:0] ell;
    input [31:0] v;
    reg [31:0] t;
    begin
      t = v ^ {v[15:0], 16'b0};
      ell = {t[15:0], t[31:16]};
    end
  endfunction

  // 4-round ARX-box. ROT(v,n) = rotate right by n = {v[n-1:0], v[31:n]}.
  // Returns the (x,y) pair packed as {x, y}.
  function [63:0] arxbox;
    input [31:0] xi;
    input [31:0] yi;
    input [31:0] c;
    reg [31:0] xa, ya;
    begin
      xa = xi; ya = yi;
      xa = xa + {ya[30:0], ya[31]};      // x += ROT(y,31)
      ya = ya ^ {xa[23:0], xa[31:24]};   // y ^= ROT(x,24)
      xa = xa ^ c;
      xa = xa + {ya[16:0], ya[31:17]};   // x += ROT(y,17)
      ya = ya ^ {xa[16:0], xa[31:17]};   // y ^= ROT(x,17)
      xa = xa ^ c;
      xa = xa + ya;                      // x += y
      ya = ya ^ {xa[30:0], xa[31]};      // y ^= ROT(x,31)
      xa = xa ^ c;
      xa = xa + {ya[23:0], ya[31:24]};   // x += ROT(y,24)
      ya = ya ^ {xa[15:0], xa[31:16]};   // y ^= ROT(x,16)
      xa = xa ^ c;
      arxbox = {xa, ya};
    end
  endfunction

  function [31:0] rcon;
    input [2:0] i;
    begin
      case (i)
        3'd0: rcon = 32'hB7E15162;  3'd1: rcon = 32'hBF715880;
        3'd2: rcon = 32'h38B4DA56;  3'd3: rcon = 32'h324E7738;
        3'd4: rcon = 32'hBB1185EB;  3'd5: rcon = 32'h4F7C7B57;
        3'd6: rcon = 32'hCFBFA1C8;  default: rcon = 32'hC2B3293D;
      endcase
    end
  endfunction

  // ------------------------------------------------------------ state regs
  reg [31:0] x0, x1, x2, x3, x4, x5;
  reg [31:0] y0, y1, y2, y3, y4, y5;

  reg [31:0] k0, k1, k2, k3;      // key, in the reference's word domain
  reg [15:0] ad_len, pt_len, rem;
  reg [255:0] ib;                 // collected input block (little-endian words)
  reg [255:0] ob;                 // output block awaiting DO
  reg [2:0]  wc3;                 // word counter within a block
  reg [2:0]  owc;                 // output word counter
  reg [2:0]  lastw_r;             // registered index of last word of this block
  reg [1:0]  wcnt;                // key/tag word counter
  reg [2:0]  ncnt;                // nonce word counter (0..7)
  reg [3:0]  pi;                  // permutation step index
  reg [3:0]  steps_m1;            // 6 for slim (7 steps), 10 for big (11)
  reg [4:0]  nxt;                 // state to enter when the permutation ends
  reg        decrypt_r, key_loaded, tag_ok;

  // ------------------------------------------------------- one SPARKLE step
  // y0 ^= RCON[i%8]; y1 ^= i; six ARX-boxes; linear layer.
  wire [31:0] sy0 = y0 ^ rcon(pi[2:0]);
  wire [31:0] sy1 = y1 ^ {28'd0, pi};

  wire [63:0] p0 = arxbox(x0, sy0, rcon(3'd0));
  wire [63:0] p1 = arxbox(x1, sy1, rcon(3'd1));
  wire [63:0] p2 = arxbox(x2, y2,  rcon(3'd2));
  wire [63:0] p3 = arxbox(x3, y3,  rcon(3'd3));
  wire [63:0] p4 = arxbox(x4, y4,  rcon(3'd4));
  wire [63:0] p5 = arxbox(x5, y5,  rcon(3'd5));

  wire [31:0] a0 = p0[63:32], b0 = p0[31:0];
  wire [31:0] a1 = p1[63:32], b1 = p1[31:0];
  wire [31:0] a2 = p2[63:32], b2 = p2[31:0];
  wire [31:0] a3 = p3[63:32], b3 = p3[31:0];
  wire [31:0] a4 = p4[63:32], b4 = p4[31:0];
  wire [31:0] a5 = p5[63:32], b5 = p5[31:0];

  // Feistel halves of the linear layer (b = 3 branches per half).
  wire [31:0] tx = ell(a0 ^ a1 ^ a2);
  wire [31:0] fb3 = b3 ^ tx ^ b0;
  wire [31:0] fb4 = b4 ^ tx ^ b1;
  wire [31:0] fb5 = b5 ^ tx ^ b2;
  wire [31:0] ty = ell(b0 ^ b1 ^ b2);   // uses the ORIGINAL y-half, per the C
  wire [31:0] fa3 = a3 ^ ty ^ a0;
  wire [31:0] fa4 = a4 ^ ty ^ a1;
  wire [31:0] fa5 = a5 ^ ty ^ a2;

  // Branch swap with 1-branch left-rotation of the right side:
  // new = [4, 5, 3, 0, 1, 2] (indices into the post-Feistel array).
  wire [31:0] nx0 = fa4, nx1 = fa5, nx2 = fa3, nx3 = a0, nx4 = a1, nx5 = a2;
  wire [31:0] ny0 = fb4, ny1 = fb5, ny2 = fb3, ny3 = b0, ny4 = b1, ny5 = b2;

  // ------------------------------------------------- block sizing / padding
  wire        fin  = (rem <= 16'd32);            // this is the final block
  wire [5:0]  nb   = fin ? rem[5:0] : 6'd32;     // bytes in this block, 1..32
  wire [4:0]  nbm1 = nb[4:0] - 5'd1;
  wire [2:0]  lastw = nbm1[4:2];                 // index of last word of block

  // Per-word byte mask for a block of nb bytes.
  reg [255:0] mskv;
  integer mi;
  always @* begin
    mskv = 256'd0;
    for (mi = 0; mi < 8; mi = mi + 1) begin
      if      ({26'd0, nb} >= mi*4 + 4) mskv[32*mi +: 32] = 32'hFFFFFFFF;
      else if ({26'd0, nb} == mi*4 + 3) mskv[32*mi +: 32] = 32'h00FFFFFF;
      else if ({26'd0, nb} == mi*4 + 2) mskv[32*mi +: 32] = 32'h0000FFFF;
      else if ({26'd0, nb} == mi*4 + 1) mskv[32*mi +: 32] = 32'h000000FF;
      else                              mskv[32*mi +: 32] = 32'd0;
    end
  end

  // 0x80 pad byte at byte index nb, only when the block is short of the rate.
  reg [255:0] padv;
  always @* begin
    padv = 256'd0;
    if (nb < 6'd32)
      padv[{nb[4:2], 5'b0} +: 32] = 32'h80 << {nb[1:0], 3'b0};
  end

  // -------------------------------------------------------- rho / whitening
  localparam [4:0]
    S_IDLE     = 5'd0,  S_SDI_INSTR = 5'd1,  S_SDI_HDR   = 5'd2,
    S_SDI_KEY  = 5'd3,  S_PDI_OP    = 5'd4,  S_PDI_NHDR  = 5'd5,
    S_PDI_NDATA= 5'd6,  S_PERM      = 5'd7,  S_PDI_AHDR  = 5'd8,
    S_AD_COLL  = 5'd9,  S_AD_ABS    = 5'd10, S_PDI_PHDR  = 5'd11,
    S_DO_PTHDR = 5'd12, S_PT_COLL   = 5'd13, S_PT_ABS    = 5'd14,
    S_PT_OUT   = 5'd15, S_FINAL     = 5'd16, S_DO_TAGHDR = 5'd17,
    S_TAG_OUT  = 5'd18, S_PDI_THDR  = 5'd19, S_TAG_IN    = 5'd20,
    S_OUT_STATUS = 5'd21;

  reg [4:0] fsm;

  wire msgph = (fsm == S_PT_ABS);
  wire [31:0] cval = msgph ? (nb < 6'd32 ? CONST_M2 : CONST_M3)
                           : (nb < 6'd32 ? CONST_A0 : CONST_A1);
  wire [31:0] y5c  = fin ? (y5 ^ cval) : y5;    // domain-separated y[5]

  wire [255:0] rate_orig = {y3, x3, y2, x2, y1, x1, y0, x0};
  wire [255:0] ibm  = ib & mskv;                       // truncated input
  wire [255:0] outv = (ibm ^ rate_orig) & mskv;        // CT (enc) or PT (dec)
  wire [255:0] absv = (msgph & decrypt_r) ? (outv ^ padv) : (ibm ^ padv);

  // stage 1: Feistel swap   stage 2: absorb   stage 3: whiten
  wire [31:0] rx0 = x2         ^ absv[ 31:  0] ^ x4;
  wire [31:0] ry0 = y2         ^ absv[ 63: 32] ^ y4;
  wire [31:0] rx1 = x3         ^ absv[ 95: 64] ^ x5;
  wire [31:0] ry1 = y3         ^ absv[127: 96] ^ y5c;
  wire [31:0] rx2 = (x2 ^ x0)  ^ absv[159:128] ^ x4;
  wire [31:0] ry2 = (y2 ^ y0)  ^ absv[191:160] ^ y4;
  wire [31:0] rx3 = (x3 ^ x1)  ^ absv[223:192] ^ x5;
  wire [31:0] ry3 = (y3 ^ y1)  ^ absv[255:224] ^ y5c;

  // ------------------------------------------------------------- handshakes
  assign pdi_ready = (fsm == S_IDLE)     || (fsm == S_SDI_INSTR) ||
                     (fsm == S_PDI_OP)   || (fsm == S_PDI_NHDR)  ||
                     (fsm == S_PDI_NDATA)|| (fsm == S_PDI_AHDR)  ||
                     (fsm == S_AD_COLL)  || (fsm == S_PDI_PHDR)  ||
                     (fsm == S_PT_COLL)  || (fsm == S_PDI_THDR)  ||
                     (fsm == S_TAG_IN);
  assign sdi_ready = (fsm == S_IDLE)   || (fsm == S_SDI_INSTR) ||
                     (fsm == S_SDI_HDR)|| (fsm == S_SDI_KEY);

  assign do_valid = (fsm == S_DO_PTHDR) || (fsm == S_PT_OUT) ||
                    (fsm == S_DO_TAGHDR)|| (fsm == S_TAG_OUT) ||
                    (fsm == S_OUT_STATUS);
  assign do_last  = (fsm == S_OUT_STATUS);

  wire [31:0] tagw = (wcnt == 2'd0) ? x4 : (wcnt == 2'd1) ? y4
                   : (wcnt == 2'd2) ? x5 : y5;

  assign do_data =
      (fsm == S_DO_PTHDR)  ? {(decrypt_r ? SEGT_PT : SEGT_CT), 1'b0, 1'b0,
                              1'b1, decrypt_r, 8'd0, pt_len} :
      (fsm == S_PT_OUT)    ? bswap(ob[{owc, 5'b0} +: 32]) :
      (fsm == S_DO_TAGHDR) ? {SEGT_TAG, 1'b0, 1'b0, 1'b1, 1'b1, 8'd0, 16'd16} :
      (fsm == S_TAG_OUT)   ? bswap(tagw) :
      (fsm == S_OUT_STATUS)? {(decrypt_r ? (tag_ok ? ST_SUCCESS : ST_FAILURE)
                                         : ST_SUCCESS), 28'd0} :
      32'd0;

  // ------------------------------------------------------------------- FSM
  always @(posedge clk) begin
    if (rst) begin
      fsm <= S_IDLE; key_loaded <= 1'b0; decrypt_r <= 1'b0; tag_ok <= 1'b1;
      wcnt <= 2'd0; ncnt <= 3'd0; wc3 <= 3'd0; owc <= 3'd0; pi <= 4'd0;
      steps_m1 <= 4'd0; nxt <= S_IDLE; rem <= 16'd0; lastw_r <= 3'd0;
      ad_len <= 16'd0; pt_len <= 16'd0;
      x0 <= 32'd0; x1 <= 32'd0; x2 <= 32'd0;
      x3 <= 32'd0; x4 <= 32'd0; x5 <= 32'd0;
      y0 <= 32'd0; y1 <= 32'd0; y2 <= 32'd0;
      y3 <= 32'd0; y4 <= 32'd0; y5 <= 32'd0;
      k0 <= 32'd0; k1 <= 32'd0; k2 <= 32'd0; k3 <= 32'd0;
      ib <= 256'd0; ob <= 256'd0;
    end else begin
      case (fsm)
        // An SDI word starts a key load (LDKEY); a PDI word starts a
        // transaction (ACTKEY). Either instruction word is consumed here.
        S_IDLE, S_SDI_INSTR: begin
          if (sdi_valid)      fsm <= S_SDI_HDR;
          else if (pdi_valid) fsm <= S_PDI_OP;
        end
        S_SDI_HDR: if (sdi_valid) begin wcnt <= 2'd0; fsm <= S_SDI_KEY; end
        S_SDI_KEY: if (sdi_valid) begin
          case (wcnt)
            2'd0: k0 <= bswap(sdi_data);
            2'd1: k1 <= bswap(sdi_data);
            2'd2: k2 <= bswap(sdi_data);
            default: k3 <= bswap(sdi_data);
          endcase
          wcnt <= wcnt + 2'd1;
          if (wcnt == 2'd3) begin key_loaded <= 1'b1; fsm <= S_IDLE; end
        end

        S_PDI_OP: if (pdi_valid) begin
          decrypt_r <= (pdi_data[31:28] == OP_DEC);
          tag_ok    <= 1'b1;
          fsm       <= S_PDI_NHDR;
        end
        S_PDI_NHDR: if (pdi_valid) begin ncnt <= 3'd0; fsm <= S_PDI_NDATA; end

        // Nonce is 8 words: noncebuf[2i] -> x[i], noncebuf[2i+1] -> y[i].
        // Key goes straight into the capacity branches 4 and 5.
        S_PDI_NDATA: if (pdi_valid) begin
          case (ncnt)
            3'd0: x0 <= bswap(pdi_data);  3'd1: y0 <= bswap(pdi_data);
            3'd2: x1 <= bswap(pdi_data);  3'd3: y1 <= bswap(pdi_data);
            3'd4: x2 <= bswap(pdi_data);  3'd5: y2 <= bswap(pdi_data);
            3'd6: x3 <= bswap(pdi_data);  default: y3 <= bswap(pdi_data);
          endcase
          ncnt <= ncnt + 3'd1;
          if (ncnt == 3'd7) begin
            x4 <= k0; y4 <= k1; x5 <= k2; y5 <= k3;
            pi <= 4'd0; steps_m1 <= 4'd10;      // big permutation, 11 steps
            nxt <= S_PDI_AHDR;
            fsm <= S_PERM;
          end
        end

        S_PERM: begin
          x0 <= nx0; x1 <= nx1; x2 <= nx2; x3 <= nx3; x4 <= nx4; x5 <= nx5;
          y0 <= ny0; y1 <= ny1; y2 <= ny2; y3 <= ny3; y4 <= ny4; y5 <= ny5;
          if (pi == steps_m1) fsm <= nxt;
          else                pi  <= pi + 4'd1;
        end

        // Zero-length AD is skipped entirely (the C guards with "if (adsize)").
        S_PDI_AHDR: if (pdi_valid) begin
          ad_len <= pdi_data[15:0];
          rem    <= pdi_data[15:0];
          wc3    <= 3'd0;
          fsm    <= (pdi_data[15:0] == 16'd0) ? S_PDI_PHDR : S_AD_COLL;
        end
        S_AD_COLL: if (pdi_valid) begin
          ib[{wc3, 5'b0} +: 32] <= bswap(pdi_data);
          if (wc3 == lastw) fsm <= S_AD_ABS;
          else              wc3 <= wc3 + 3'd1;
        end
        S_AD_ABS: begin
          x0 <= rx0; y0 <= ry0; x1 <= rx1; y1 <= ry1;
          x2 <= rx2; y2 <= ry2; x3 <= rx3; y3 <= ry3;
          y5 <= y5c;
          rem <= rem - {10'd0, nb};
          wc3 <= 3'd0;
          pi  <= 4'd0;
          steps_m1 <= fin ? 4'd10 : 4'd6;
          nxt <= fin ? S_PDI_PHDR : S_AD_COLL;
          fsm <= S_PERM;
        end

        S_PDI_PHDR: if (pdi_valid) begin
          pt_len <= pdi_data[15:0];
          rem    <= pdi_data[15:0];
          wc3    <= 3'd0;
          fsm    <= S_DO_PTHDR;
        end
        S_DO_PTHDR: if (do_ready)
          fsm <= (pt_len == 16'd0) ? S_FINAL : S_PT_COLL;

        S_PT_COLL: if (pdi_valid) begin
          ib[{wc3, 5'b0} +: 32] <= bswap(pdi_data);
          if (wc3 == lastw) fsm <= S_PT_ABS;
          else              wc3 <= wc3 + 3'd1;
        end
        S_PT_ABS: begin
          x0 <= rx0; y0 <= ry0; x1 <= rx1; y1 <= ry1;
          x2 <= rx2; y2 <= ry2; x3 <= rx3; y3 <= ry3;
          y5 <= y5c;
          ob  <= outv;
          owc <= 3'd0;
          lastw_r <= lastw;              // nb changes when rem updates below
          rem <= rem - {10'd0, nb};
          wc3 <= 3'd0;
          pi  <= 4'd0;
          steps_m1 <= fin ? 4'd10 : 4'd6;
          nxt <= fin ? S_FINAL : S_PT_COLL;
          fsm <= S_PT_OUT;
        end
        S_PT_OUT: if (do_ready) begin
          if (owc == lastw_r) fsm <= S_PERM;
          else                owc <= owc + 3'd1;
        end

        // Finalize: fold the key back into the capacity; the tag is then the
        // capacity itself (x4, y4, x5, y5).
        S_FINAL: begin
          x4 <= x4 ^ k0; y4 <= y4 ^ k1; x5 <= x5 ^ k2; y5 <= y5 ^ k3;
          wcnt <= 2'd0;
          fsm  <= decrypt_r ? S_PDI_THDR : S_DO_TAGHDR;
        end

        S_DO_TAGHDR: if (do_ready) begin wcnt <= 2'd0; fsm <= S_TAG_OUT; end
        S_TAG_OUT: if (do_ready) begin
          wcnt <= wcnt + 2'd1;
          if (wcnt == 2'd3) fsm <= S_OUT_STATUS;
        end

        S_PDI_THDR: if (pdi_valid) begin wcnt <= 2'd0; fsm <= S_TAG_IN; end
        S_TAG_IN: if (pdi_valid) begin
          tag_ok <= tag_ok & (bswap(pdi_data) == tagw);
          wcnt   <= wcnt + 2'd1;
          if (wcnt == 2'd3) fsm <= S_OUT_STATUS;
        end

        S_OUT_STATUS: if (do_ready) fsm <= S_IDLE;
        default: fsm <= S_IDLE;
      endcase
    end
  end
endmodule
