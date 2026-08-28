// ISAP-A-128A, implementing the CryptoCore-facing protocol of the NIST
// Lightweight Cryptography Hardware API (see tinyjambu_lwc.v's header for the
// full API citation; same ports, opcodes and segment-header format).
//
// WARNING: ISAP did NOT win the NIST LWC competition -- Ascon did. This core
// exists for hardware comparison against the Ascon cores in verilog/, not as
// a recommendation. Lint-checked (Verilator + Vivado) but NOT run against the
// official KAT vectors in simulation -- unlike tinyjambu_lwc.v. It is a
// careful transliteration, not a confirmed-correct one.
//
// Algorithm: transliterated from the official reference C in
// ../lwc-finalists/isap/ (isap.c + Ascon-reference.c + crypto_aead.c, ISAP-A
// variant: the permutation is plain Ascon-p, reused unmodified from the
// verilog/ascon_aead128.v round function -- see below). Key = 16 B,
// Npub = 16 B, tag = 16 B (CRYPTO_ABYTES=16, unlike Grain/Elephant).
//
// STATE / PERMUTATION: ISAP's state is 40 bytes = 320 bits = Ascon's own
// 5x64-bit state, and Ascon-reference.c's round transform (substitution +
// linear layer, same round constants) is bit-for-bit identical to
// ascon_aead128.v's ascon_round()/rc_of() -- ISAP just calls it with
// different round counts at different points: sH=12 (AD/ciphertext
// absorption and MAC finalisation), sK=12 (IsapRk's init and final step),
// sB=1 (IsapRk's per-BIT rekeying step -- see below), sE=6 (keystream
// squeeze). This core reuses that same round function and round-constant
// table verbatim rather than re-deriving them.
//
// BYTE ORDER: Ascon-reference.c's load64/store64 pack bytes MSB-first
// (S[0] lands in the TOP byte of the 64-bit word) -- the opposite convention
// from ascon_aead128.v's own "little-endian" comment, because that is a
// different, self-contained reference file with its own loader, not the
// official NIST aead.c. Conveniently, MSB-first-per-byte is also exactly how
// the LWC PDI bus delivers a word (pdi_data[31:24] = first byte), so building
// each internal 64-bit lane by straight concatenation of arriving PDI bytes
// (no byte-swap!) already produces the right bit pattern -- unlike every
// other finalist core in this directory, which needed an explicit bswap.
//
// IsapRk (the bit-serial re-keying primitive) is the one genuinely unusual
// part of ISAP: to derive a sub-key it Init()s+p^sK once, then absorbs the
// input ONE BIT at a time (XOR into the state's single top bit, p^sB=1 round
// each time) for all but the last bit, then absorbs the final bit with a
// full p^sK=12 round call, then squeezes. Both call sites in this AEAD
// instantiation (deriving Ke* from Npub, and Ka* from a 16-byte digest y)
// happen to absorb exactly 16 bytes = 128 bits, so this core hardcodes that
// bit count rather than building a general variable-length absorber: 127
// single-round steps plus one final 12-round step, ~151 cycles per call,
// unconditionally run twice per transaction (once for Ke*, once for Ka*) --
// deliberately expensive, by ISAP's own design, not an artifact of this
// transliteration. Both calls share one small sub-FSM (S_RK_*), selected by
// `rk_mode`, since their structure is otherwise identical.
//
// STRUCTURE (crypto_aead_encrypt/decrypt, isap_mac, isap_enc): this core
// restructures the reference's two orderings (encrypt: derive Ke*, encrypt,
// then MAC over the ciphertext; decrypt: MAC first, then decrypt) into one
// uniform hardware pipeline, matching the "release plaintext before tag
// verification" convention (API Sec 2.8) already used by every other core in
// this directory: MAC-initialise and absorb AD (state = mac_state); derive
// Ke* (state = enc_state, independent of mac_state); then, for each
// message/ciphertext byte as it streams in, extract a keystream byte from
// enc_state (re-permuting enc_state with p^sE every 8th byte, EXACTLY at
// byte index %8==0 -- the reference's own "key_bytes_avail" starts at 0,
// which forces this same immediate refresh before byte 0), XOR to produce
// the output byte, and absorb into mac_state the CIPHERTEXT value specifically
// -- which is the just-computed output byte when encrypting, but the raw
// input byte unchanged when decrypting (isap_mac is always over ciphertext,
// never plaintext; see the mac_c_byte mux below) -- re-permuting mac_state
// with p^sH every 8th byte, at index%8==7 (i.e. AFTER a full rate block,
// the reference's own "avail==0" post-check). Both triggers reduce to the
// same simple mod-8 byte counter; no special-casing was needed to reconcile
// the reference's differing avail-bookkeeping styles between its AD loop,
// its ciphertext loop and IsapEnc's keystream loop, since they are all
// standard rate-8 duplex sponge steps once expressed this way. After the
// message stream: pad+permute mac_state's C-phase, derive Ka* from
// mac_state's top 16 bytes, overwrite them with Ka*, permute once more
// (p^sH), and the top 16 bytes are the tag.
//
// SIMPLIFICATION: Ke* is always derived, even for an empty message (the
// reference only calls isap_enc, and therefore only derives Ke*, "if
// (mlen>0)"); the ~151 wasted cycles for an empty message are harmless since
// the keystream is simply never consumed.

module isap_lwc (
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

  // ---------------------------------------------------------- Ascon round
  // Verbatim from ascon_aead128.v: same state packing {x0,x1,x2,x3,x4} in
  // s[319:0], same substitution/diffusion layers, same round-constant table
  // (p^n consumes the LAST n entries, i.e. start index = 12-n).
  function [63:0] ror64;
    input [63:0] x;
    input integer n;
    begin
      ror64 = (x >> n) | (x << (64 - n));
    end
  endfunction

  function [319:0] ascon_round;
    input [319:0] s;
    input [7:0]   c;
    reg [63:0] x0, x1, x2, x3, x4;
    reg [63:0] t0, t1, t2, t3, t4;
    begin
      x0 = s[319:256]; x1 = s[255:192]; x2 = s[191:128];
      x3 = s[127:64];  x4 = s[63:0];

      x2 = x2 ^ {56'd0, c};

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

      x0 = t0 ^ ror64(t0, 19) ^ ror64(t0, 28);
      x1 = t1 ^ ror64(t1, 61) ^ ror64(t1, 39);
      x2 = t2 ^ ror64(t2,  1) ^ ror64(t2,  6);
      x3 = t3 ^ ror64(t3, 10) ^ ror64(t3, 17);
      x4 = t4 ^ ror64(t4,  7) ^ ror64(t4, 41);

      ascon_round = {x0, x1, x2, x3, x4};
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

  // ISAP_IV_A/_KA/_KE = {tag, K=128, rH=64, rB=1, sH=12, sB=1, sE=6, sK=12}
  localparam [63:0] IV_A  = {8'h01,8'h80,8'h40,8'h01,8'h0c,8'h01,8'h06,8'h0c};
  localparam [63:0] IV_KA = {8'h02,8'h80,8'h40,8'h01,8'h0c,8'h01,8'h06,8'h0c};
  localparam [63:0] IV_KE = {8'h03,8'h80,8'h40,8'h01,8'h0c,8'h01,8'h06,8'h0c};

  // ------------------------------------------------------------ state regs
  reg [127:0] key_r;
  reg [127:0] npub_r;
  reg [15:0]  ad_len, pt_len;

  reg [319:0] mac_state;
  reg [319:0] enc_state;
  reg [127:0] ka_star;

  reg [319:0] perm_state;      // shared round-transform scratch
  reg [3:0]   rc_idx;
  reg [4:0]   rounds_left;
  reg [5:0]   perm_ret;

  reg         rk_mode;         // 0 = deriving Ke*, 1 = deriving Ka*
  reg [63:0]  rk_iv;
  reg [127:0] rk_in;
  reg [6:0]   bitctr;          // 0..126 during IsapRk's bit-serial absorb

  reg [2:0]   bcnt;            // mac_state rate-byte counter, 0..7
  reg [15:0]  ad_i, pt_i;      // absolute byte index within AD / message
  reg [31:0]  cur_word;
  reg [1:0]   byte_sel;

  reg [31:0]  outword;
  reg [1:0]   owsel;

  reg [1:0]   wcnt;            // small word counter (key/npub/tag)
  reg         decrypt_r, tag_ok;
  reg [5:0]   ad_resume, pt_resume;   // where to go after an AD/PT-phase permute

  // current byte from the word register, MSB-first (matches PDI convention)
  wire [7:0] cur_byte = (byte_sel == 2'd0) ? cur_word[31:24] :
                        (byte_sel == 2'd1) ? cur_word[23:16] :
                        (byte_sel == 2'd2) ? cur_word[15:8]  : cur_word[7:0];

  // byte-in-state XOR mask, positioned at mac_state's rate byte `bcnt`
  wire [319:0] ad_byte_mask = {cur_byte, 312'd0} >> (bcnt * 8);
  wire [319:0] mac_after_ad = mac_state ^ ad_byte_mask;

  // keystream byte for the current message byte, from enc_state's rate word
  wire [2:0]  ks_pos = pt_i[2:0];
  wire [7:0]  ks_byte = enc_state[319 - 8*ks_pos -: 8];
  wire [7:0]  dout_byte = cur_byte ^ ks_byte;
  wire [7:0]  mac_c_byte = decrypt_r ? cur_byte : dout_byte;
  wire [319:0] c_byte_mask = {mac_c_byte, 312'd0} >> (bcnt * 8);
  wire [319:0] mac_after_c = mac_state ^ c_byte_mask;

  // IsapRk's per-bit absorption: XOR one bit into the state's top bit.
  wire        rk_bit_loop = rk_in[127 - bitctr];     // bits 0..126
  wire        rk_bit_last = rk_in[0];                // bit 127 (final)
  wire [319:0] rk_xor_loop = perm_state ^ {rk_bit_loop, 319'd0};
  wire [319:0] rk_xor_last = perm_state ^ {rk_bit_last, 319'd0};

  localparam [5:0]
    S_IDLE        = 6'd0,  S_SDI_HDR     = 6'd1,  S_SDI_KEY    = 6'd2,
    S_PDI_OP      = 6'd3,  S_PDI_NHDR    = 6'd4,  S_PDI_NDATA  = 6'd5,
    S_MACINIT_LD  = 6'd6,  S_PERM_RUN    = 6'd7,  S_MACINIT_DN = 6'd8,
    S_PDI_AHDR    = 6'd9,  S_AD_WORD     = 6'd10, S_AD_BYTE    = 6'd11,
    S_AD_COMMIT   = 6'd12, S_AD_PAD      = 6'd13, S_AD_PAD_DONE= 6'd14,
    S_DOMSEP      = 6'd15,
    S_PDI_PHDR    = 6'd16, S_DO_PTHDR    = 6'd17,
    S_RK_INIT     = 6'd18, S_RK_INIT_DN  = 6'd19,
    S_RK_ABSORB   = 6'd20, S_RK_FINAL    = 6'd21, S_RK_FIN_DN  = 6'd22,
    S_RK_DONE     = 6'd23,
    S_PT_WORD     = 6'd24, S_PT_KSPERM   = 6'd25, S_PT_KS_DONE = 6'd26,
    S_PT_BYTE     = 6'd27, S_PT_COMMIT   = 6'd28, S_PT_OUT     = 6'd29,
    S_C_PAD       = 6'd30, S_C_PAD_DONE  = 6'd31,
    S_TAG_OVW     = 6'd32, S_TAG_PERM_DN = 6'd33,
    S_DO_TAGHDR   = 6'd34, S_TAG_OUT     = 6'd35,
    S_PDI_THDR    = 6'd36, S_TAG_IN      = 6'd37,
    S_OUT_STATUS  = 6'd38;

  reg [5:0] fsm;

  // Word/byte accounting for the "next action" after processing one AD or
  // message byte: fold into the state constant used both as a direct next
  // state (no permute this cycle) and as the resume target stashed ahead of
  // a permute detour (ad_resume / pt_resume).
  wire [15:0] ad_i_next = ad_i + 16'd1;
  wire [5:0]  ad_next = (ad_i_next == ad_len) ? S_AD_PAD :
                        (byte_sel == 2'd3)    ? S_AD_WORD : S_AD_BYTE;

  wire [15:0] pt_i_next = pt_i + 16'd1;
  // Route through S_PT_OUT (a DO flush) whenever this byte completes a
  // 4-byte output word OR is the last message byte (a partial final word,
  // already zero-padded by the outword-clear rule below); S_PT_OUT itself
  // then decides whether to fetch another PDI word or move on to the
  // ciphertext-phase padding.
  // Every byte -- not just the first of a word -- must pass through the
  // keystream-refresh check (S_PT_KSPERM), since pt_i%8==0 can land on any
  // byte_sel position depending on how pt_len lines up with word boundaries.
  wire        pt_flush = (byte_sel == 2'd3) || (pt_i_next == pt_len);
  wire [5:0]  pt_next  = pt_flush ? S_PT_OUT : S_PT_KSPERM;

  // ------------------------------------------------------------- handshakes
  assign pdi_ready = (fsm == S_IDLE)      || (fsm == S_PDI_OP)   ||
                     (fsm == S_PDI_NHDR) || (fsm == S_PDI_NDATA)||
                     (fsm == S_PDI_AHDR) || (fsm == S_AD_WORD)  ||
                     (fsm == S_PDI_PHDR) || (fsm == S_PT_WORD)  ||
                     (fsm == S_PDI_THDR) || (fsm == S_TAG_IN);
  assign sdi_ready = (fsm == S_IDLE) || (fsm == S_SDI_HDR) || (fsm == S_SDI_KEY);

  assign do_valid = (fsm == S_DO_PTHDR) || (fsm == S_PT_OUT) ||
                    (fsm == S_DO_TAGHDR)|| (fsm == S_TAG_OUT) ||
                    (fsm == S_OUT_STATUS);
  assign do_last  = (fsm == S_OUT_STATUS);

  wire [7:0] tag_off = {4'b0, wcnt, 2'b00};   // wcnt*4: 0,4,8,12
  wire [7:0] tag_byte_hi = mac_state[319 - 8*(tag_off)         -: 8];
  wire [7:0] tag_byte_1  = mac_state[319 - 8*(tag_off + 8'd1)  -: 8];
  wire [7:0] tag_byte_2  = mac_state[319 - 8*(tag_off + 8'd2)  -: 8];
  wire [7:0] tag_byte_3  = mac_state[319 - 8*(tag_off + 8'd3)  -: 8];
  wire [31:0] tag_word = {tag_byte_hi, tag_byte_1, tag_byte_2, tag_byte_3};

  assign do_data =
      (fsm == S_DO_PTHDR)  ? {(decrypt_r ? SEGT_PT : SEGT_CT), 1'b0, 1'b0,
                              1'b1, decrypt_r, 8'd0, pt_len} :
      (fsm == S_PT_OUT)    ? outword :
      (fsm == S_DO_TAGHDR) ? {SEGT_TAG, 1'b0, 1'b0, 1'b1, 1'b1, 8'd0, 16'd16} :
      (fsm == S_TAG_OUT)   ? tag_word :
      (fsm == S_OUT_STATUS)? {(decrypt_r ? (tag_ok ? ST_SUCCESS : ST_FAILURE)
                                         : ST_SUCCESS), 28'd0} :
      32'd0;

  // ------------------------------------------------------------------- FSM
  always @(posedge clk) begin
    if (rst) begin
      fsm <= S_IDLE; decrypt_r <= 1'b0; tag_ok <= 1'b1;
      wcnt <= 2'd0; owsel <= 2'd0; byte_sel <= 2'd0;
      ad_i <= 16'd0; pt_i <= 16'd0; bcnt <= 3'd0; bitctr <= 7'd0;
      key_r <= 128'd0; npub_r <= 128'd0; ad_len <= 16'd0; pt_len <= 16'd0;
      mac_state <= 320'd0; enc_state <= 320'd0; ka_star <= 128'd0;
      perm_state <= 320'd0; rc_idx <= 4'd0; rounds_left <= 5'd0; perm_ret <= 6'd0;
      rk_mode <= 1'b0; rk_iv <= 64'd0; rk_in <= 128'd0;
      cur_word <= 32'd0; outword <= 32'd0; ad_resume <= 6'd0; pt_resume <= 6'd0;
    end else begin
      case (fsm)
        S_IDLE: begin
          if (sdi_valid)      fsm <= S_SDI_HDR;
          else if (pdi_valid) fsm <= S_PDI_OP;
        end
        S_SDI_HDR: if (sdi_valid) begin wcnt <= 2'd0; fsm <= S_SDI_KEY; end
        S_SDI_KEY: if (sdi_valid) begin
          key_r <= {key_r[95:0], sdi_data};      // straight concat, MSB-first
          wcnt  <= wcnt + 2'd1;
          if (wcnt == 2'd3) fsm <= S_IDLE;
        end

        S_PDI_OP: if (pdi_valid) begin
          decrypt_r <= (pdi_data[31:28] == OP_DEC);
          tag_ok    <= 1'b1;
          fsm       <= S_PDI_NHDR;
        end
        S_PDI_NHDR: if (pdi_valid) begin wcnt <= 2'd0; fsm <= S_PDI_NDATA; end
        S_PDI_NDATA: if (pdi_valid) begin
          npub_r <= {npub_r[95:0], pdi_data};
          wcnt   <= wcnt + 2'd1;
          if (wcnt == 2'd3) begin
            // mac_state init: {Npub(16B), IV_A(8B), 0-pad(16B)}, then p^12.
            perm_state <= {npub_r, IV_A, 128'd0};
            rc_idx <= 4'd0; rounds_left <= 5'd12; perm_ret <= S_MACINIT_DN;
            fsm <= S_PERM_RUN;
          end
        end

        // Shared round-transform engine: `rounds_left` rounds starting at
        // round-constant index `rc_idx`, one round per cycle.
        S_PERM_RUN: begin
          perm_state <= ascon_round(perm_state, rc_of(rc_idx));
          rc_idx     <= rc_idx + 4'd1;
          if (rounds_left == 5'd1) fsm <= perm_ret;
          else                     rounds_left <= rounds_left - 5'd1;
        end

        S_MACINIT_DN: begin
          mac_state <= perm_state;
          fsm <= S_PDI_AHDR;
        end

        S_PDI_AHDR: if (pdi_valid) begin
          ad_len   <= pdi_data[15:0];
          ad_i     <= 16'd0;
          byte_sel <= 2'd0;
          fsm <= (pdi_data[15:0] == 16'd0) ? S_AD_PAD : S_AD_WORD;
        end
        S_AD_WORD: if (pdi_valid) begin
          cur_word <= pdi_data;
          byte_sel <= 2'd0;
          fsm <= S_AD_BYTE;
        end
        S_AD_BYTE: begin
          if (bcnt == 3'd7) begin
            perm_state <= mac_after_ad;
            rc_idx <= 4'd0; rounds_left <= 5'd12; perm_ret <= S_AD_COMMIT;
            ad_resume <= ad_next;
            bcnt <= 3'd0;
            ad_i <= ad_i_next; byte_sel <= byte_sel + 2'd1;
            fsm <= S_PERM_RUN;
          end else begin
            mac_state <= mac_after_ad;
            bcnt <= bcnt + 3'd1;
            ad_i <= ad_i_next; byte_sel <= byte_sel + 2'd1;
            fsm <= ad_next;
          end
        end
        S_AD_COMMIT: begin
          mac_state <= perm_state;
          fsm <= ad_resume;
        end

        S_AD_PAD: begin
          // pad 0x80 at the current rate position (bcnt), then p^12 always.
          perm_state <= mac_state ^ ({8'h80, 312'd0} >> (bcnt * 8));
          rc_idx <= 4'd0; rounds_left <= 5'd12; perm_ret <= S_AD_PAD_DONE;
          fsm <= S_PERM_RUN;
        end
        S_AD_PAD_DONE: begin
          mac_state <= perm_state;
          bcnt <= 3'd0;
          fsm <= S_DOMSEP;
        end
        S_DOMSEP: begin
          // domain separation: XOR 0x01 into the state's very last byte
          // (x4's LSB), no permute.
          mac_state[7:0] <= mac_state[7:0] ^ 8'h01;
          fsm <= S_PDI_PHDR;
        end

        S_PDI_PHDR: if (pdi_valid) begin
          pt_len <= pdi_data[15:0];
          fsm    <= S_DO_PTHDR;
        end
        S_DO_PTHDR: if (do_ready) begin
          // Derive Ke*: IsapRk(k, IV_KE, Npub, 16 -> enc_state in place).
          rk_mode <= 1'b0; rk_iv <= IV_KE; rk_in <= npub_r;
          fsm <= S_RK_INIT;
        end

        // ------------------------------------------------ IsapRk (shared)
        S_RK_INIT: begin
          perm_state <= {key_r, rk_iv, 128'd0};
          rc_idx <= 4'd0; rounds_left <= 5'd12; perm_ret <= S_RK_INIT_DN;
          fsm <= S_PERM_RUN;
        end
        S_RK_INIT_DN: begin
          bitctr <= 7'd0;
          fsm <= S_RK_ABSORB;
        end
        // 127 single-round steps, bit i XORed into the state's top bit then
        // one p-round -- combined in the same cycle to avoid an extra state.
        S_RK_ABSORB: begin
          perm_state <= ascon_round(rk_xor_loop, rc_of(4'd11));   // p^1
          if (bitctr == 7'd126) fsm <= S_RK_FINAL;
          else                  bitctr <= bitctr + 7'd1;
        end
        // Final (128th) bit, then p^12: round 0 combined with the bit-XOR,
        // rounds 1..11 via the shared engine.
        S_RK_FINAL: begin
          perm_state <= ascon_round(rk_xor_last, rc_of(4'd0));
          rc_idx <= 4'd1; rounds_left <= 5'd11; perm_ret <= S_RK_FIN_DN;
          fsm <= S_PERM_RUN;
        end
        S_RK_FIN_DN: fsm <= S_RK_DONE;
        S_RK_DONE: begin
          if (rk_mode == 1'b0) begin
            // Ke*: squeeze becomes the enc_state in place; overwrite its
            // last 16 bytes (x3||x4) with Npub.
            enc_state <= {perm_state[319:128], npub_r};
            pt_i <= 16'd0; byte_sel <= 2'd0; bcnt <= 3'd0;
            fsm <= S_PT_WORD;
          end else begin
            // Ka*: squeeze the top 16 bytes only; mac_state is untouched.
            ka_star <= perm_state[319:192];
            fsm <= S_TAG_OVW;
          end
        end

        // -------------------------------------------------- message loop
        S_PT_WORD: if (pdi_valid) begin
          cur_word <= pdi_data;
          byte_sel <= 2'd0;
          fsm <= S_PT_KSPERM;
        end
        S_PT_KSPERM: begin
          if (ks_pos == 3'd0) begin
            perm_state <= enc_state;
            rc_idx <= 4'd6; rounds_left <= 5'd6; perm_ret <= S_PT_KS_DONE; // p^6
            fsm <= S_PERM_RUN;
          end else fsm <= S_PT_BYTE;
        end
        S_PT_KS_DONE: begin
          enc_state <= perm_state;
          fsm <= S_PT_BYTE;
        end
        S_PT_BYTE: begin
          // assemble the output word; cleared at the start of each word so
          // an unfilled tail (partial final word) reads back as zero.
          if (byte_sel == 2'd0) outword <= {dout_byte, 24'd0};
          else                  outword[{(2'd3-byte_sel),3'b000} +: 8] <= dout_byte;

          if (bcnt == 3'd7) begin
            perm_state <= mac_after_c;
            rc_idx <= 4'd0; rounds_left <= 5'd12; perm_ret <= S_PT_COMMIT;
            pt_resume <= pt_next;
            bcnt <= 3'd0;
            pt_i <= pt_i_next; byte_sel <= byte_sel + 2'd1;
            fsm <= S_PERM_RUN;
          end else begin
            mac_state <= mac_after_c;
            bcnt <= bcnt + 3'd1;
            pt_i <= pt_i_next; byte_sel <= byte_sel + 2'd1;
            fsm <= pt_next;
          end
        end
        S_PT_COMMIT: begin
          mac_state <= perm_state;
          fsm <= pt_resume;
        end
        S_PT_OUT: if (do_ready) begin
          fsm <= (pt_i == pt_len) ? S_C_PAD : S_PT_WORD;
        end

        S_C_PAD: begin
          perm_state <= mac_state ^ ({8'h80, 312'd0} >> (bcnt * 8));
          rc_idx <= 4'd0; rounds_left <= 5'd12; perm_ret <= S_C_PAD_DONE;
          fsm <= S_PERM_RUN;
        end
        S_C_PAD_DONE: begin
          mac_state <= perm_state;
          // Derive Ka*: IsapRk(k, IV_KA, y=mac_state[319:192], 16 -> ka_star).
          rk_mode <= 1'b1; rk_iv <= IV_KA; rk_in <= perm_state[319:192];
          fsm <= S_RK_INIT;
        end

        S_TAG_OVW: begin
          mac_state[319:192] <= ka_star;
          perm_state <= {ka_star, mac_state[191:0]};
          rc_idx <= 4'd0; rounds_left <= 5'd12; perm_ret <= S_TAG_PERM_DN;
          fsm <= S_PERM_RUN;
        end
        S_TAG_PERM_DN: begin
          mac_state <= perm_state;
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
          tag_ok <= tag_ok & (pdi_data == tag_word);
          wcnt   <= wcnt + 2'd1;
          if (wcnt == 2'd3) fsm <= S_OUT_STATUS;
        end

        S_OUT_STATUS: if (do_ready) fsm <= S_IDLE;
        default: fsm <= S_IDLE;
      endcase
    end
  end
endmodule
