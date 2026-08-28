// TinyJAMBU-128 AEAD, implementing the CryptoCore-facing protocol of the
// NIST Lightweight Cryptography Hardware API -- the actual interface GMU's
// CERG group used to benchmark every submitted finalist, including this one
// and Ascon (Kaps, Diehl, Tempelmeier, Homsirikamol, Gaj, "Hardware API for
// Lightweight Cryptography", https://cryptography.gmu.edu/athena/LWC/LWC_HW_API.pdf).
//
// WARNING: TinyJAMBU did NOT win the NIST LWC competition -- Ascon did. This
// core exists for hardware comparison against the Ascon cores in verilog/,
// not as a recommendation.
//
// Algorithm: transliterated from the official reference C,
// ../lwc-finalists/tinyjambu/encrypt.c (TinyJAMBU-128, 128-bit key, 96-bit
// nonce, 64-bit tag), which is itself the NIST final-round submission. Every
// cycle count and constant below (NROUND1=640, NROUND2=1024, the four
// FrameBits values, the tap positions 15/6+26/21+11/27+5) is that file's, not
// re-derived.
//
// PORTS -- w = 32, sw = 32, matching the API's permitted external bus widths.
//   PDI (Public Data Input):  pdi_data[31:0], pdi_valid, pdi_ready
//   SDI (Secret Data Input):  sdi_data[31:0], sdi_valid, sdi_ready
//   DO  (Data Output):        do_data[31:0], do_valid, do_ready, do_last
// One clock, synchronous active-high reset, single data stream -- exactly the
// API's minimum compliance profile (Sec. 2 of the spec above).
//
// PROTOCOL -- the real Instruction/Segment-Header wire format, not a
// simplified stand-in:
//   Instruction/status word: opcode in bits [31:28] (LDKEY=0100, ACTKEY=0111,
//     ENC=0010, DEC=0011; status SUCCESS=1110/FAILURE=1111), rest unused.
//   Segment header (always 32 bits): type[31:28] | partial[27] | eoi[26] |
//     eot[25] | last[24] | reserved[23:16] | length_bytes[15:0].
//   Segment types used here: Key=1100, Npub=1101, AD=0001, Plaintext=0100,
//     Ciphertext=0101, Tag=1000 -- Table 1 of the spec.
//
// SDI:  LDKEY, then one Key segment header, then 4 words of key.
// PDI encrypt: ACTKEY, ENC, then Npub segment (3 words), AD segment (0 or
//   more words -- the header is still sent with length=0 when AD is empty,
//   per the spec's rule that empty segments still get a header), Plaintext
//   segment (0 or more words).
// PDI decrypt: ACTKEY, DEC, then Npub, AD, Ciphertext, and a Tag segment
//   (2 words, 8 bytes).
// DO encrypt: Ciphertext segment, Tag segment (2 words), then a status word.
// DO decrypt: Plaintext segment, then a status word (no output at all, and
//   FAILURE status, if the tag does not verify -- API Sec. 2.8/2.9).
//
// EOI/EOT/Last on the segments this core sends are set for the case the spec
// calls "typical" (Fig./Table in Sec. 4): every type is sent as exactly one
// segment (EOT=1 always -- the spec permits, but does not require, splitting
// a type across multiple segments), and EOI marks the last segment that
// carries real input data (Plaintext if non-empty, else AD if non-empty,
// else Npub), while Last marks the last segment physically sent for the
// instruction (always Plaintext/Ciphertext here, since this core always
// sends Npub/AD/PT in that fixed order even when a part is empty). This core
// does not implement multi-segment splitting, the Length segment (only
// required for "offline" algorithms -- TinyJAMBU is online), or the
// side-channel RDI port -- none apply to a plain functional comparison.
//
// This core owns the full PDI/SDI/DO boundary directly; it does not sit
// behind GMU's generic VHDL PreProcessor/PostProcessor (that component is
// identical infrastructure across every LWC submission, not part of what any
// team's algorithm-specific hardware contributes, and porting it to Verilog
// would add nothing to the comparison this project is making).

module tinyjambu_lwc (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] pdi_data,
    input  wire        pdi_valid,
    output wire        pdi_ready,

    input  wire [31:0] sdi_data,
    input  wire        sdi_valid,
    output wire        sdi_ready,

    output wire [31:0] do_data,
    output wire         do_valid,
    input  wire         do_ready,
    output wire          do_last
);

  // ------------------------------------------------------------- opcodes --
  localparam [3:0] OP_ENC = 4'b0010, OP_DEC = 4'b0011, OP_LDKEY = 4'b0100,
                   OP_ACTKEY = 4'b0111;
  localparam [3:0] ST_SUCCESS = 4'b1110, ST_FAILURE = 4'b1111;
  localparam [3:0] SEGT_AD = 4'h1, SEGT_PT = 4'h4, SEGT_CT = 4'h5,
                   SEGT_TAG = 4'h8, SEGT_KEY = 4'hC, SEGT_NPUB = 4'hD;

  // -------------------------------------------------------- TinyJAMBU core -
  localparam FB_IV = 32'h10, FB_AD = 32'h30, FB_PC = 32'h50, FB_FIN = 32'h70;
  localparam [9:0] STEPS_20 = 10'd20, STEPS_32 = 10'd32;  // NROUND1/32, NROUND2/32

  reg [31:0] s0, s1, s2, s3;                 // state[0..3] in the reference
  reg [31:0] k0, k1, k2, k3;                 // key words
  reg [31:0] npub0, npub1, npub2;
  reg [31:0] mac_lo, mac_hi;

  wire [31:0] t1 = {s2[14:0], s1[31:15]};
  wire [31:0] t2 = {s3[5:0],  s2[31:6]};
  wire [31:0] t3 = {s3[20:0], s2[31:21]};
  wire [31:0] t4 = {s3[26:0], s2[31:27]};
  reg  [1:0]  key_idx;
  wire [31:0] key_word = (key_idx == 2'd0) ? k0 : (key_idx == 2'd1) ? k1 :
                         (key_idx == 2'd2) ? k2 : k3;
  wire [31:0] feedback = s0 ^ t1 ^ ~(t2 & t3) ^ t4 ^ key_word;

  reg [9:0] steps_left;
  // The word-iteration shift is performed directly inside each *_STEPS case
  // body below, in the same cycle as the steps_left check -- not through a
  // separate registered "stepping" signal read by an independent always
  // block. That two-block form has a one-cycle latency between "FSM decides
  // to step" and "step happens", which silently drops the LAST shift of
  // every state_update() phase (the *_XOR/*_CAP state ends up reading s2/s3
  // one shift too early). Folding it into one block removes the extra
  // register stage and gives exactly N shifts for N cycles in steps_left.

  // -------------------------------------------------- byte-count bookkeeping
  reg  [15:0] ad_len, pt_len;      // bytes remaining in the current segment
  wire        ad_full  = (ad_len >= 16'd4);
  wire        pt_full  = (pt_len >= 16'd4);
  wire [1:0]  ad_rem   = ad_len[1:0];   // 1..3 on the final partial block
  wire [1:0]  pt_rem   = pt_len[1:0];

  // byte-selective feedback into s3 (partial-block case): the C code XORs
  // individual bytes at state offset 12+j, i.e. into s3.
  function [31:0] xor_bytes;
    input [31:0] base;
    input [31:0] data;
    input [1:0]  n;     // number of low bytes of `data` to XOR in
    begin
      xor_bytes = base;
      if (n > 0) xor_bytes[7:0]   = base[7:0]   ^ data[7:0];
      if (n > 1) xor_bytes[15:8]  = base[15:8]  ^ data[15:8];
      if (n > 2) xor_bytes[23:16] = base[23:16] ^ data[23:16];
    end
  endfunction

  // Partial-block PT/CT output: s2 ^ in_word, keeping only the low `n` bytes
  // and zeroing the rest -- the API requires any unused portion of the last
  // output block to be cleared (Sec. 2.7), not left as leftover keystream.
  function [31:0] pc_out_partial;
    input [31:0] s2v;
    input [31:0] inw;
    input [1:0]  n;
    reg [31:0] full;
    begin
      full = s2v ^ inw;
      pc_out_partial = 32'd0;
      if (n > 0) pc_out_partial[7:0]   = full[7:0];
      if (n > 1) pc_out_partial[15:8]  = full[15:8];
      if (n > 2) pc_out_partial[23:16] = full[23:16];
    end
  endfunction

  // --------------------------------------------------------------- the FSM -
  localparam [5:0]
    S_IDLE       = 6'd0,  S_SDI_INSTR  = 6'd1,  S_SDI_HDR    = 6'd2,
    S_SDI_KEY    = 6'd3,
    S_PDI_ACT    = 6'd4,  S_PDI_OP     = 6'd5,
    S_PDI_NHDR   = 6'd6,  S_PDI_NDATA  = 6'd7,
    S_KEYMIX     = 6'd8,
    S_IV_FRAME   = 6'd9,  S_IV_STEPS   = 6'd10, S_IV_XOR     = 6'd11,
    S_PDI_AHDR   = 6'd12,
    S_AD_WORD    = 6'd13, S_AD_FRAME   = 6'd14, S_AD_STEPS   = 6'd15,
    S_AD_XOR     = 6'd16,
    S_PDI_PHDR   = 6'd17, S_DO_PTHDR   = 6'd35,
    S_PT_WORD    = 6'd18, S_PT_FRAME   = 6'd19, S_PT_STEPS   = 6'd20,
    S_PT_XOR     = 6'd21, S_PT_OUT     = 6'd22,
    S_F1_FRAME   = 6'd23, S_F1_STEPS   = 6'd24, S_F1_CAP     = 6'd25,
    S_F2_FRAME   = 6'd26, S_F2_STEPS   = 6'd27, S_F2_CAP     = 6'd28,
    S_PDI_THDR   = 6'd29, S_TAG_WORD   = 6'd30,
    S_DO_TAGHDR  = 6'd36, S_OUT_TAG_LO = 6'd31, S_OUT_TAG_HI = 6'd32,
    S_OUT_STATUS = 6'd34;

  reg [5:0]  fsm;
  reg [2:0]  iv_round;       // 0,1,2 across the three IV-mixing rounds
  reg        decrypt_r;
  reg        key_loaded;
  reg [1:0]  wcnt;           // generic small word counter (npub/tag words)
  reg [31:0] out_word;       // ciphertext/plaintext word en route to DO
  reg        tag_ok;

  assign pdi_ready = (fsm == S_IDLE)     || (fsm == S_PDI_OP)   ||
                     (fsm == S_PDI_NHDR)|| (fsm == S_PDI_NDATA)||
                     (fsm == S_PDI_AHDR)|| (fsm == S_AD_WORD)  ||
                     (fsm == S_PDI_PHDR)|| (fsm == S_PT_WORD)  ||
                     (fsm == S_PDI_THDR)|| (fsm == S_TAG_WORD);
  assign sdi_ready = (fsm == S_IDLE) || (fsm == S_SDI_INSTR) ||
                     (fsm == S_SDI_HDR) || (fsm == S_SDI_KEY);

  // do_valid is a pure function of "are we currently sitting in a state that
  // has data to present", not a registered pulse -- avoids the classic
  // off-by-one where a registered valid is gated on a ready sample from the
  // *previous* cycle. The transfer happens exactly when do_valid and
  // do_ready are both high in the same cycle, matching the API's stated rule
  // (Sec. 4: "read and acknowledged when *_valid and *_ready are both
  // asserted"), and holds for real backpressure, not just an always-ready
  // consumer.
  assign do_valid = (fsm == S_DO_PTHDR) || (fsm == S_PT_OUT) ||
                    (fsm == S_DO_TAGHDR) || (fsm == S_OUT_TAG_LO) ||
                    (fsm == S_OUT_TAG_HI) || (fsm == S_OUT_STATUS);
  assign do_last  = (fsm == S_OUT_STATUS);
  assign do_data  =
      (fsm == S_DO_PTHDR)  ? {(decrypt_r ? SEGT_PT : SEGT_CT), 1'b0, 1'b0,
                              1'b1, decrypt_r, 8'd0, pt_len} :
      (fsm == S_PT_OUT)    ? out_word :
      (fsm == S_DO_TAGHDR) ? {SEGT_TAG, 1'b0, 1'b0, 1'b1, 1'b1, 8'd0, 16'd8} :
      (fsm == S_OUT_TAG_LO)? mac_lo :
      (fsm == S_OUT_TAG_HI)? mac_hi :
      (fsm == S_OUT_STATUS)? {(decrypt_r ? (tag_ok ? ST_SUCCESS : ST_FAILURE)
                                          : ST_SUCCESS), 28'd0} :
      32'd0;

  always @(posedge clk) begin
    if (rst) begin
      fsm <= S_IDLE; steps_left <= 10'd0; key_idx <= 2'd0;
      s0<=0; s1<=0; s2<=0; s3<=0; k0<=0; k1<=0; k2<=0; k3<=0;
      npub0<=0; npub1<=0; npub2<=0; mac_lo<=0; mac_hi<=0;
      ad_len<=0; pt_len<=0; iv_round<=0; decrypt_r<=0; key_loaded<=0;
      wcnt<=0; out_word<=0; tag_ok<=0;
    end else begin
      case (fsm)
        // ------------------------------------------------------ key load --
        // S_IDLE accepts either bus: an SDI word starts a key load (LDKEY,
        // consumed here), a PDI word starts a transaction (ACTKEY, likewise
        // consumed here -- there is nothing to capture from either
        // instruction's value, so no separate pass-through state is needed;
        // S_PDI_OP is the first state that actually reads a field).
        S_IDLE, S_SDI_INSTR: begin
          if (sdi_valid) fsm <= S_SDI_HDR;      // LDKEY consumed
          else if (pdi_valid) fsm <= S_PDI_OP;  // ACTKEY consumed
        end
        S_SDI_HDR: if (sdi_valid) begin wcnt <= 2'd0; fsm <= S_SDI_KEY; end
        S_SDI_KEY: if (sdi_valid) begin
          case (wcnt)
            2'd0: k0 <= sdi_data; 2'd1: k1 <= sdi_data;
            2'd2: k2 <= sdi_data; default: k3 <= sdi_data;
          endcase
          if (wcnt == 2'd3) begin key_loaded <= 1'b1; fsm <= S_IDLE; end
          else wcnt <= wcnt + 2'd1;
        end

        // ---------------------------------------------- PDI: instructions --
        S_PDI_OP:  if (pdi_valid) begin
          decrypt_r <= (pdi_data[31:28] == OP_DEC);
          fsm <= S_PDI_NHDR;
        end
        S_PDI_NHDR: if (pdi_valid) begin wcnt <= 2'd0; fsm <= S_PDI_NDATA; end
        S_PDI_NDATA: if (pdi_valid) begin
          case (wcnt)
            2'd0: npub0 <= pdi_data; 2'd1: npub1 <= pdi_data;
            default: npub2 <= pdi_data;
          endcase
          if (wcnt == 2'd2) begin
            s0<=0; s1<=0; s2<=0; s3<=0; key_idx <= 2'd0;
            steps_left <= STEPS_32; fsm <= S_KEYMIX;
          end else wcnt <= wcnt + 2'd1;
        end

        // --------------------------------------------- initialization -----
        S_KEYMIX: begin
          s0 <= s1; s1 <= s2; s2 <= s3; s3 <= feedback;
          key_idx <= key_idx + 2'd1;
          if (steps_left == 10'd1) begin iv_round <= 3'd0; fsm <= S_IV_FRAME; end
          else steps_left <= steps_left - 10'd1;
        end
        S_IV_FRAME: begin
          s1 <= s1 ^ FB_IV;
          key_idx <= 2'd0; steps_left <= STEPS_20; fsm <= S_IV_STEPS;
        end
        S_IV_STEPS: begin
          s0 <= s1; s1 <= s2; s2 <= s3; s3 <= feedback;
          key_idx <= key_idx + 2'd1;
          if (steps_left == 10'd1) fsm <= S_IV_XOR;
          else steps_left <= steps_left - 10'd1;
        end
        S_IV_XOR: begin
          s3 <= s3 ^ (iv_round == 3'd0 ? npub0 : iv_round == 3'd1 ? npub1 : npub2);
          if (iv_round == 3'd2) fsm <= S_PDI_AHDR;
          else begin iv_round <= iv_round + 3'd1; fsm <= S_IV_FRAME; end
        end

        // --------------------------------------------- associated data ----
        S_PDI_AHDR: if (pdi_valid) begin
          ad_len <= pdi_data[15:0];
          fsm <= (pdi_data[15:0] == 16'd0) ? S_PDI_PHDR : S_AD_WORD;
        end
        S_AD_WORD: if (pdi_valid) begin
          out_word <= pdi_data;                 // stash the AD word
          fsm <= S_AD_FRAME;
        end
        S_AD_FRAME: begin
          s1 <= s1 ^ FB_AD;
          key_idx <= 2'd0; steps_left <= STEPS_20; fsm <= S_AD_STEPS;
        end
        S_AD_STEPS: begin
          s0 <= s1; s1 <= s2; s2 <= s3; s3 <= feedback;
          key_idx <= key_idx + 2'd1;
          if (steps_left == 10'd1) fsm <= S_AD_XOR;
          else steps_left <= steps_left - 10'd1;
        end
        S_AD_XOR: begin
          if (ad_full) begin
            s3 <= s3 ^ out_word;
            ad_len <= ad_len - 16'd4;
            fsm <= ((ad_len - 16'd4) == 16'd0) ? S_PDI_PHDR : S_AD_WORD;
          end else begin
            s3 <= xor_bytes(s3, out_word, ad_rem);
            s1 <= s1 ^ {30'd0, ad_rem};
            ad_len <= 16'd0;
            fsm <= S_PDI_PHDR;
          end
        end

        // ---------------------------------------------- plaintext/ct ------
        S_PDI_PHDR: if (pdi_valid) begin
          pt_len <= pdi_data[15:0];
          fsm <= S_DO_PTHDR;
        end
        // DO segment header for the Ciphertext (encrypt) / Plaintext
        // (decrypt) segment. EOI is always 0 on DO (API Sec. 4: "EOI is set
        // to 0 for segments leaving the cipher"). EOT=1 (one segment per
        // type). Last=1 only for decrypt, whose only DO segment before
        // Status is Plaintext (Fig. 12b); encrypt still has Tag to send.
        S_DO_PTHDR: if (do_ready)
          fsm <= (pt_len == 16'd0) ? S_F1_FRAME : S_PT_WORD;
        S_PT_WORD: if (pdi_valid) begin
          out_word <= pdi_data;
          fsm <= S_PT_FRAME;
        end
        S_PT_FRAME: begin
          s1 <= s1 ^ FB_PC;
          key_idx <= 2'd0; steps_left <= STEPS_32; fsm <= S_PT_STEPS;
        end
        S_PT_STEPS: begin
          s0 <= s1; s1 <= s2; s2 <= s3; s3 <= feedback;
          key_idx <= key_idx + 2'd1;
          if (steps_left == 10'd1) fsm <= S_PT_XOR;
          else steps_left <= steps_left - 10'd1;
        end
        // encrypt: ct = s2^pt, s3 ^= pt.  decrypt: pt = s2^ct, s3 ^= pt (the
        // *computed* plaintext, not the ciphertext) -- both directions XOR
        // the plaintext value into s3; since pt = s2^ct on decrypt, that is
        // s3 ^= (s2 ^ in_word) there. out_word = s2^in_word either way.
        S_PT_XOR: begin
          if (pt_full) begin
            s3 <= s3 ^ (decrypt_r ? (s2 ^ out_word) : out_word);
            out_word <= s2 ^ out_word;
            pt_len <= pt_len - 16'd4;
            fsm <= S_PT_OUT;
          end else begin
            s3 <= xor_bytes(s3, decrypt_r ? (s2 ^ out_word) : out_word, pt_rem);
            s1 <= s1 ^ {30'd0, pt_rem};
            out_word <= pc_out_partial(s2, out_word, pt_rem);
            pt_len <= 16'd0;
            fsm <= S_PT_OUT;
          end
        end
        S_PT_OUT: if (do_ready)
          fsm <= (pt_len == 16'd0) ? S_F1_FRAME : S_PT_WORD;

        // ----------------------------------------------- finalization -----
        S_F1_FRAME: begin
          s1 <= s1 ^ FB_FIN;
          key_idx <= 2'd0; steps_left <= STEPS_32; fsm <= S_F1_STEPS;
        end
        S_F1_STEPS: begin
          s0 <= s1; s1 <= s2; s2 <= s3; s3 <= feedback;
          key_idx <= key_idx + 2'd1;
          if (steps_left == 10'd1) fsm <= S_F1_CAP;
          else steps_left <= steps_left - 10'd1;
        end
        S_F1_CAP: begin mac_lo <= s2; fsm <= S_F2_FRAME; end
        S_F2_FRAME: begin
          s1 <= s1 ^ FB_FIN;
          key_idx <= 2'd0; steps_left <= STEPS_20; fsm <= S_F2_STEPS;
        end
        S_F2_STEPS: begin
          s0 <= s1; s1 <= s2; s2 <= s3; s3 <= feedback;
          key_idx <= key_idx + 2'd1;
          if (steps_left == 10'd1) fsm <= S_F2_CAP;
          else steps_left <= steps_left - 10'd1;
        end
        S_F2_CAP: begin
          mac_hi <= s2;
          fsm <= decrypt_r ? S_PDI_THDR : S_DO_TAGHDR;
        end

        // ---------------------------------------------------- tag check ---
        S_PDI_THDR: if (pdi_valid) begin wcnt <= 2'd0; fsm <= S_TAG_WORD; end
        S_TAG_WORD: if (pdi_valid) begin
          if (wcnt == 2'd0) begin tag_ok <= (pdi_data == mac_lo); wcnt <= 2'd1; end
          else begin tag_ok <= tag_ok & (pdi_data == mac_hi); fsm <= S_OUT_STATUS; end
        end

        // -------------------------------------------------------- output --
        // Tag segment header (encrypt only; length is always 8 bytes).
        S_DO_TAGHDR:  if (do_ready) fsm <= S_OUT_TAG_LO;
        S_OUT_TAG_LO: if (do_ready) fsm <= S_OUT_TAG_HI;
        S_OUT_TAG_HI: if (do_ready) fsm <= S_OUT_STATUS;
        S_OUT_STATUS: if (do_ready) fsm <= S_IDLE;

        default: fsm <= S_IDLE;
      endcase
    end
  end

endmodule
