// Xoodyak AEAD, implementing the CryptoCore-facing protocol of the NIST
// Lightweight Cryptography Hardware API (see tinyjambu_lwc.v's header for the
// full API citation; the same port set, opcodes and segment-header format
// apply here unchanged).
//
// WARNING: Xoodyak did NOT win the NIST LWC competition -- Ascon did. This
// core exists for hardware comparison against ascon_aead128.v (this directory),
// not as a recommendation.
//
// Algorithm: transliterated from the official reference C,
// ../lwc-finalists/xoodyak/{Xoodoo-reference.c,Xoodoo.h,Cyclist.inc,
// Xoodyak.h,encrypt.c}, which is itself the NIST final-round submission.
// Xoodyak = the Cyclist duplex mode driving the Xoodoo permutation (12
// rounds, a 3x4 array of 32-bit lanes, Theta/Rho-west/Iota/Chi/Rho-east).
//
// PORTS/PROTOCOL: identical to tinyjambu_lwc.v -- w=32, sw=32, real PDI/SDI/DO
// with the real instruction opcodes and 32-bit segment headers. Key and Npub
// are both 16 bytes here (Xoodyak_Rkin's ID field), tag is 16 bytes.
//
// CYCLIST MODE, traced exactly from Cyclist.inc/Xoodyak.c for KLen=16,
// counterLen=0 (the only case the NIST AEAD entry point ever uses):
//
//   state    384 bits (12 x 32-bit lanes), reset to 0
//   Down(K||Npub||0x10, 33 bytes, Cd=0x02)   -- state[0:33]^=K||Npub||0x10,
//                                                state[33]^=0x01 (pad),
//                                                state[47]^=Cd
//   -- AD phase, rate Rkin=44 bytes (11 lanes), ALWAYS at least one chunk
//      (Cyclist's absorb loops are do-while: an empty AD still gets one
//      padding-only chunk), Cd=0x03 on the first chunk only, 0x00 after:
//   for each AD chunk (44 bytes, or fewer on the last one):
//     Up(Cu=0x00): permute (12 rounds)
//     Down(chunk, len, Cd): state[0:len]^=chunk, state[len]^=0x01, state[47]^=Cd
//   -- PT/CT phase, rate Rkout=24 bytes (6 lanes), ALWAYS at least one chunk,
//      Cu=0x80 on the first chunk only, plaintext (not ciphertext) is what
//      gets absorbed back in either direction, and output is released before
//      the tag check (API Sec. 2.8) -- this is also why the mode always needs
//      the two buses running concurrently, same as TinyJAMBU's decrypt path:
//   for each PT/CT chunk (24 bytes, or fewer on the last one):
//     Up(Cu): permute (12 rounds)                 [Cu=0x80 first chunk, else 0]
//     out_chunk = in_chunk XOR state[0:len]        (keystream XOR)
//     Down(plaintext_chunk, len, Cd=0x00): state[0:len]^=plaintext, pad, Cd
//   -- tag, exactly one squeeze (16 bytes fits in one 24-byte rate block):
//   Up(Cu=0x40): permute (12 rounds); tag = state[0:16]
//
// IMPORTANT PADDING DETAIL: when a chunk exactly fills its rate (44 or 24
// bytes = a whole number of lanes), the 0x01 pad byte still lands -- one lane
// PAST the last data lane, inside what is otherwise capacity. This is
// ordinary sponge padding (the pad bit always needs room, even when data
// fills the block exactly), not a special case, but it means AD chunks can
// touch lane 11 and PT/CT chunks can touch lane 6, one past their nominal
// 11-lane/6-lane full-chunk width. The state is therefore held as a proper
// indexable array (not 12 separately-named registers), so that boundary
// lane is reached by the same dynamic-index logic as every other lane rather
// than needing its own hand-written case arm -- the earlier draft of this
// file got exactly that boundary wrong with per-lane case statements.

module xoodyak_lwc (
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

  localparam [3:0] OP_DEC = 4'b0011;
  localparam [3:0] ST_SUCCESS = 4'b1110, ST_FAILURE = 4'b1111;
  localparam [3:0] SEGT_PT = 4'h4, SEGT_CT = 4'h5, SEGT_TAG = 4'h8;

  // -------------------------------------------------------- Xoodoo state --
  // a[index(x,y)], index(x,y)=y*4+x: a[0..3]=row y0, a[4..7]=row y1,
  // a[8..11]=row y2.
  reg [31:0] a [0:11];

  function [31:0] rotl32;
    input [31:0] x; input integer n;
    begin rotl32 = (x << n) | (x >> (32-n)); end
  endfunction

  function [31:0] rc_of;
    input [3:0] i;   // round index 0..11, matching RC[0]=_rc12 .. RC[11]=_rc1
    begin
      case (i)
        4'd0: rc_of=32'h00000058; 4'd1: rc_of=32'h00000038;
        4'd2: rc_of=32'h000003C0; 4'd3: rc_of=32'h000000D0;
        4'd4: rc_of=32'h00000120; 4'd5: rc_of=32'h00000014;
        4'd6: rc_of=32'h00000060; 4'd7: rc_of=32'h0000002C;
        4'd8: rc_of=32'h00000380; 4'd9: rc_of=32'h000000F0;
        4'd10: rc_of=32'h000001A0; default: rc_of=32'h00000012;
      endcase
    end
  endfunction

  // One Xoodoo round: Theta, Rho-west, Iota, Chi, Rho-east, transliterated
  // directly from Xoodoo_Round in Xoodoo-reference.c. Pure function of the
  // 12 input lanes and the round constant -> 12 output lanes.
  reg [31:0] p [0:3];
  reg [31:0] e [0:3];
  reg [31:0] t [0:11];   // post-theta
  reg [31:0] rw [0:11];  // post-rho-west (+iota folded into rw[0])
  reg [31:0] c [0:11];   // post-chi
  reg [31:0] nx [0:11];  // round output (post-rho-east)
  integer ri;
  reg [31:0] rot5, rot14; // see note below

  task xoodoo_round;
    input [31:0] rc;
    integer x;
    begin
      // Theta
      for (x = 0; x < 4; x = x + 1)
        p[x] = a[x] ^ a[x+4] ^ a[x+8];
      // rot5/rot14 hold each rotl32() call's result before combining, rather
      // than writing `rotl32(...,5) ^ rotl32(...,14)` inline: calling the
      // same function twice in one expression, inside a for loop, produced
      // silently wrong results under this Vivado xsim build -- the second
      // call's result leaking into other loop iterations (e.g. e[2] and
      // e[3] both came out equal to e[0]'s second call, 0x80, instead of
      // their own correct value of 0) -- found only by comparing every
      // intermediate lane against the C reference word by word, not by lint
      // or by any single-call test of rotl32 in isolation, which is why
      // this is spelled out here rather than left as a one-line diff.
      for (x = 0; x < 4; x = x + 1) begin
        rot5  = rotl32(p[(x+3)%4], 5);
        rot14 = rotl32(p[(x+3)%4], 14);
        e[x]  = rot5 ^ rot14;  // (x-1)%4
      end
      for (x = 0; x < 4; x = x + 1) begin
        t[x]   = a[x]   ^ e[x];
        t[x+4] = a[x+4] ^ e[x];
        t[x+8] = a[x+8] ^ e[x];
      end

      // Rho-west: row0 unchanged; row1 shifted x-1 (with wrap); row2
      // rotated 11 bits, no x-shift.
      for (x = 0; x < 4; x = x + 1) begin
        rw[x]   = t[x];
        rw[x+4] = t[((x+3)%4)+4];
        rw[x+8] = rotl32(t[x+8], 11);
      end

      // Iota
      rw[0] = rw[0] ^ rc;

      // Chi: c[x,y] = rw[x,y] ^ (~rw[x,y+1] & rw[x,y+2]), y mod 3
      for (x = 0; x < 4; x = x + 1) begin
        c[x]   = rw[x]   ^ (~rw[x+4]  & rw[x+8]);
        c[x+4] = rw[x+4] ^ (~rw[x+8]  & rw[x]);
        c[x+8] = rw[x+8] ^ (~rw[x]    & rw[x+4]);
      end

      // Rho-east: row0 unchanged; row1 rotated 1 bit, no x-shift; row2
      // shifted x+2 then rotated 8 bits.
      for (x = 0; x < 4; x = x + 1) begin
        nx[x]   = c[x];
        nx[x+4] = rotl32(c[x+4], 1);
        nx[x+8] = rotl32(c[((x+2)%4)+8], 8);
      end
    end
  endtask

  reg [31:0] k0,k1,k2,k3, npub0,npub1,npub2,npub3;
  reg [31:0] mac0,mac1,mac2,mac3;

  reg [3:0] round_idx;     // 0..11 within the current permute
  reg [3:0] lane_idx;      // lane position within the current AD/PT chunk

  // Bytes remaining in the current phase (AD or PT/CT); chunk size is capped
  // to the phase's rate (44 or 24) each time a new chunk starts.
  reg [15:0] ad_len, pt_len;
  reg [5:0]  chunk_len;     // bytes in THIS chunk (<=44 or <=24), set once
  reg        first_ad_chunk;
  reg        first_pt_chunk;
  reg        decrypt_r;

  localparam [5:0] AD_RATE = 6'd44, PT_RATE = 6'd24;

  // XOR `n` low bytes of `data` into `base`, leaving the rest unchanged --
  // used for the trailing partial word of a chunk (n=1..3).
  function [31:0] xor_n;
    input [31:0] base; input [31:0] data; input [1:0] n;
    begin
      xor_n = base;
      if (n > 0) xor_n[7:0]   = base[7:0]   ^ data[7:0];
      if (n > 1) xor_n[15:8]  = base[15:8]  ^ data[15:8];
      if (n > 2) xor_n[23:16] = base[23:16] ^ data[23:16];
    end
  endfunction
  // Keep only the low `n` bytes of `data`, zeroing the rest -- for the
  // partial-word ciphertext/plaintext output (API Sec. 2.7: unused portions
  // of the last output block must be cleared).
  function [31:0] keep_n;
    input [31:0] data; input [1:0] n;
    begin
      keep_n = 32'd0;
      if (n > 0) keep_n[7:0]   = data[7:0];
      if (n > 1) keep_n[15:8]  = data[15:8];
      if (n > 2) keep_n[23:16] = data[23:16];
    end
  endfunction
  // Single byte `v` XORed at byte position `pos` (0..3) within a lane.
  function [31:0] xor_byte_at;
    input [31:0] base; input [7:0] v; input [1:0] pos;
    begin
      xor_byte_at = base;
      case (pos)
        2'd0: xor_byte_at[7:0]   = base[7:0]   ^ v;
        2'd1: xor_byte_at[15:8]  = base[15:8]  ^ v;
        2'd2: xor_byte_at[23:16] = base[23:16] ^ v;
        default: xor_byte_at[31:24] = base[31:24] ^ v;
      endcase
    end
  endfunction

  reg [31:0] out_word;      // PT/CT word en route to/from DO
  reg [15:0] byte_off;      // running byte offset within the CURRENT chunk
  reg        tag_ok;

  // ------------------------------------------------------------------ FSM -
  localparam [5:0]
    S_IDLE     = 6'd0,
    S_SDI_HDR  = 6'd1,  S_SDI_KEY  = 6'd2,
    S_PDI_OP   = 6'd3,
    S_PDI_NHDR = 6'd4,  S_PDI_NDATA= 6'd5,
    S_LOAD     = 6'd6,
    S_PDI_AHDR = 6'd7,
    S_AD_PERM  = 6'd8,
    S_AD_WORD  = 6'd9,  S_AD_XOR   = 6'd10,
    S_AD_PAD   = 6'd11,
    S_PDI_PHDR = 6'd12, S_DO_PTHDR = 6'd13,
    S_PT_PERM  = 6'd14,
    S_PT_WORD  = 6'd15, S_PT_XOR   = 6'd16, S_PT_OUT = 6'd17,
    S_PT_PAD   = 6'd18,
    S_TAG_PERM = 6'd19,
    S_DO_TAGHDR= 6'd20, S_OUT_TAG  = 6'd21,
    S_PDI_THDR = 6'd22, S_TAG_WORD = 6'd23,
    S_OUT_STATUS = 6'd24,
    S_PERM_RUN = 6'd25; // shared 12-round permute engine, returns via `ret`

  reg [5:0] fsm, ret;
  reg [3:0] tag_wcnt;

  wire full_word = (byte_off + 16'd4 <= {10'd0,chunk_len});
  wire [1:0] rem_bytes = chunk_len[1:0];
  wire pad_fresh_lane = (chunk_len[1:0]==2'd0);  // full-rate or exact-4x chunk
  wire [15:0] ad_next_len = ad_len - {10'd0,AD_RATE};
  wire [15:0] pt_next_len = pt_len - {10'd0,PT_RATE};

  // S_AD_WORD/S_PT_WORD only assert ready when they will actually consume a
  // word (byte_off < chunk_len): both states fall straight through to their
  // *_PAD state without touching pdi_data once the chunk is exhausted --
  // most visibly on an empty (adlen=0) AD phase, where chunk_len is already
  // 0 the instant S_AD_WORD is entered. Asserting ready unconditionally
  // there let a well-formed sender's *next* PDI word (the following
  // segment's header) get silently consumed and discarded during that
  // single cycle, desynchronizing the rest of the stream by one word --
  // found via KAT simulation, not visible from lint or from any AD/PT
  // length that actually needs multiple words.
  assign pdi_ready = (fsm == S_IDLE)     || (fsm == S_PDI_OP)   ||
                     (fsm == S_PDI_NHDR)|| (fsm == S_PDI_NDATA)||
                     (fsm == S_PDI_AHDR)||
                     (fsm == S_AD_WORD && byte_off < {10'd0,chunk_len}) ||
                     (fsm == S_PDI_PHDR)||
                     (fsm == S_PT_WORD && byte_off < {10'd0,chunk_len}) ||
                     (fsm == S_PDI_THDR)|| (fsm == S_TAG_WORD);
  assign sdi_ready = (fsm == S_IDLE) || (fsm == S_SDI_HDR) || (fsm == S_SDI_KEY);

  // S_DO_TAGHDR/S_OUT_TAG run for BOTH directions -- the tag always has to
  // be computed (mac0..mac3 captured) so decrypt can compare it -- but only
  // encrypt actually puts that tag on the DO bus; the API never re-sends a
  // tag on a decrypt. Without the !decrypt_r guard here, decrypt silently
  // emitted 5 extra DO words (a tag header + 4 tag words) every single
  // transaction that a normal encrypt/decrypt pair would never trigger a
  // functional mismatch on early -- it only showed up as a growing
  // word-count drift once transactions were chained back-to-back, exactly
  // matching 1089 decrypts x 5 extra words against the KAT grid.
  assign do_valid = (fsm == S_DO_PTHDR) || (fsm == S_PT_OUT) ||
                    ((fsm == S_DO_TAGHDR) && !decrypt_r) ||
                    ((fsm == S_OUT_TAG) && !decrypt_r) ||
                    (fsm == S_OUT_STATUS);
  assign do_last  = (fsm == S_OUT_STATUS);
  assign do_data  =
      (fsm == S_DO_PTHDR)  ? {(decrypt_r ? SEGT_PT : SEGT_CT), 1'b0, 1'b0,
                              1'b1, decrypt_r, 8'd0, pt_len} :
      (fsm == S_PT_OUT)    ? out_word :
      (fsm == S_DO_TAGHDR) ? {SEGT_TAG, 1'b0, 1'b0, 1'b1, 1'b1, 8'd0, 16'd16} :
      (fsm == S_OUT_TAG)   ? (tag_wcnt==4'd0 ? mac0 : tag_wcnt==4'd1 ? mac1 :
                              tag_wcnt==4'd2 ? mac2 : mac3) :
      (fsm == S_OUT_STATUS)? {(decrypt_r ? (tag_ok?ST_SUCCESS:ST_FAILURE)
                                          : ST_SUCCESS), 28'd0} :
      32'd0;

  integer zi;
  always @(posedge clk) begin
    if (rst) begin
      fsm<=S_IDLE; ret<=S_IDLE; round_idx<=4'd0; lane_idx<=4'd0;
      for (zi = 0; zi < 12; zi = zi + 1) a[zi] <= 32'd0;
      k0<=0;k1<=0;k2<=0;k3<=0; npub0<=0;npub1<=0;npub2<=0;npub3<=0;
      mac0<=0;mac1<=0;mac2<=0;mac3<=0;
      ad_len<=0; pt_len<=0; chunk_len<=0; first_ad_chunk<=1;
      decrypt_r<=0; out_word<=0; byte_off<=0; tag_ok<=0; tag_wcnt<=0;
    end else begin
      case (fsm)
        // ------------------------------------------------------ key load --
        S_IDLE: begin
          if (sdi_valid) fsm <= S_SDI_HDR;      // LDKEY consumed
          else if (pdi_valid) fsm <= S_PDI_OP;  // ACTKEY consumed
        end
        S_SDI_HDR: if (sdi_valid) begin lane_idx<=4'd0; fsm<=S_SDI_KEY; end
        S_SDI_KEY: if (sdi_valid) begin
          case (lane_idx)
            4'd0: k0<=sdi_data; 4'd1: k1<=sdi_data;
            4'd2: k2<=sdi_data; default: k3<=sdi_data;
          endcase
          if (lane_idx==4'd3) fsm<=S_IDLE; else lane_idx<=lane_idx+4'd1;
        end

        // --------------------------------------------- instr + npub -------
        S_PDI_OP: if (pdi_valid) begin
          decrypt_r <= (pdi_data[31:28]==OP_DEC);
          fsm <= S_PDI_NHDR;
        end
        S_PDI_NHDR: if (pdi_valid) begin lane_idx<=4'd0; fsm<=S_PDI_NDATA; end
        S_PDI_NDATA: if (pdi_valid) begin
          case (lane_idx)
            4'd0: npub0<=pdi_data; 4'd1: npub1<=pdi_data;
            4'd2: npub2<=pdi_data; default: npub3<=pdi_data;
          endcase
          if (lane_idx==4'd3) fsm<=S_LOAD; else lane_idx<=lane_idx+4'd1;
        end

        // Down(K||Npub||0x10, 33, Cd=0x02): computed in one shot since K and
        // Npub are already fully buffered. Byte 32 (=0x10, IDLen) and byte 33
        // (=0x01 padding) both fall in lane 8; byte 47 (Cd) is the top byte
        // of lane 11.
        S_LOAD: begin
          a[0]<=k0; a[1]<=k1; a[2]<=k2; a[3]<=k3;
          a[4]<=npub0; a[5]<=npub1; a[6]<=npub2; a[7]<=npub3;
          a[8]<=32'h0000_0110;   // byte32=0x10 (IDLen), byte33=0x01 (pad)
          a[9]<=0; a[10]<=0;
          a[11]<=32'h0200_0000;  // byte47 (top byte of lane11) = Cd=0x02
          first_ad_chunk<=1'b1;
          first_pt_chunk<=1'b1;
          fsm <= S_PDI_AHDR;
        end

        // --------------------------------------------- associated data ----
        S_PDI_AHDR: if (pdi_valid) begin
          ad_len <= pdi_data[15:0];
          chunk_len <= (pdi_data[15:0] > {10'd0,AD_RATE}) ? AD_RATE
                                                          : pdi_data[5:0];
          fsm <= S_AD_PERM;
        end
        // Up(Cu=0x00): permute, then process this chunk's data.
        S_AD_PERM: begin
          round_idx<=4'd0; ret<=S_AD_WORD; lane_idx<=4'd0; byte_off<=16'd0;
          fsm<=S_PERM_RUN;
        end
        S_AD_WORD: begin
          if (byte_off < {10'd0,chunk_len}) begin
            if (pdi_valid) begin out_word<=pdi_data; fsm<=S_AD_XOR; end
          end else fsm <= S_AD_PAD;
        end
        S_AD_XOR: begin
          if (full_word) begin
            a[lane_idx] <= a[lane_idx] ^ out_word;
            lane_idx<=lane_idx+4'd1; byte_off<=byte_off+16'd4;
            fsm<=S_AD_WORD;
          end else begin
            a[lane_idx] <= xor_n(a[lane_idx], out_word, rem_bytes);
            fsm <= S_AD_PAD;
          end
        end
        // Pad (0x01) lands right after the last real byte -- a fresh lane
        // at lane_idx if the chunk was an exact multiple of 4 bytes
        // (including the boundary case where lane_idx=11, one past AD's
        // nominal 11-lane width), otherwise mid-lane at rem_bytes. Cd is
        // XORed into the top byte of lane 11 separately (it can coincide
        // with the pad write above when lane_idx=11, in which case this is
        // a second, independent XOR into the SAME register -- safe here
        // because it targets a disjoint byte range, byte 3 vs bytes 0-2/all,
        // and only one of the two `a[...]` writes below ever targets lane 11
        // through the case/pad path while the Cd write is unconditional on
        // lane index, so both edits are folded into one lane-11 value by
        // computing the pad step first and only then XORing Cd on top).
        S_AD_PAD: begin
          if (pad_fresh_lane)
            a[lane_idx] <= (lane_idx==4'd11)
                          ? (a[lane_idx] ^ 32'h0000_0001
                             ^ (first_ad_chunk ? 32'h0300_0000 : 32'd0))
                          : a[lane_idx] ^ 32'h0000_0001;
          else
            a[lane_idx] <= xor_byte_at(a[lane_idx], 8'h01, rem_bytes);
          if (lane_idx != 4'd11)
            a[11] <= a[11] ^ (first_ad_chunk ? 32'h0300_0000 : 32'd0);
          first_ad_chunk <= 1'b0;
          if (ad_len > {10'd0,AD_RATE}) begin
            ad_len <= ad_next_len;
            chunk_len <= (ad_next_len > {10'd0,AD_RATE}) ? AD_RATE
                                                          : ad_next_len[5:0];
            fsm <= S_AD_PERM;
          end else begin
            fsm <= S_PDI_PHDR;
          end
        end

        // ---------------------------------------------- plaintext/ct ------
        S_PDI_PHDR: if (pdi_valid) begin
          pt_len <= pdi_data[15:0];
          chunk_len <= (pdi_data[15:0] > {10'd0,PT_RATE}) ? PT_RATE
                                                          : pdi_data[5:0];
          fsm <= S_DO_PTHDR;
        end
        S_DO_PTHDR: if (do_ready) fsm <= S_PT_PERM;
        // Up(Cu): Cu=0x80 on the PT/CT phase's first chunk only, else 0 --
        // applied to byte 47 (a[11]'s top byte) *before* the permute, unlike
        // AD's Cd which the C reference applies via Down() *after* its
        // permute. Missing entirely until KAT simulation caught it: every
        // other domain-separation byte in this core (the two Cd's) was
        // implemented, but this one -- the only Cu that isn't a no-op 0 --
        // was documented in this file's own header and never wired up.
        S_PT_PERM: begin
          if (first_pt_chunk) a[11] <= a[11] ^ 32'h8000_0000;
          round_idx<=4'd0; ret<=S_PT_WORD; lane_idx<=4'd0; byte_off<=16'd0;
          fsm<=S_PERM_RUN;
        end
        S_PT_WORD: begin
          if (byte_off < {10'd0,chunk_len}) begin
            if (pdi_valid) begin out_word<=pdi_data; fsm<=S_PT_XOR; end
          end else fsm <= S_PT_PAD;
        end
        // Keystream XOR: out = lane ^ in_word. For encrypt in_word=plaintext
        // so out=ciphertext (out_word = S^plaintext); for decrypt
        // in_word=ciphertext so out=plaintext (out_word = S^ciphertext).
        // Cyclist_Crypt's C.inc always absorbs the *plaintext* back into the
        // state via a genuine XOR-into-state (Cyclist_Down -> SnP_AddBytes),
        // i.e. newS = S ^ plaintext -- not an overwrite. For decrypt
        // plaintext = out_word directly, so newS = S ^ out_word, which is
        // what S_PT_OUT below computes. For encrypt, though, out_word
        // *already equals* S ^ plaintext (that's the definition of
        // ciphertext here) -- so newS = S ^ plaintext = out_word itself; a
        // *second* XOR with S (S ^ out_word = S ^ (S^plaintext) = plaintext)
        // cancels the state term and silently absorbs the bare plaintext
        // instead, which only agreed with the correct answer by coincidence
        // on every all-empty KAT record (S=0 there, so S^out_word and
        // out_word were the same value) -- found only once a KAT record
        // with real plaintext (mlen=1) exercised this path.
        S_PT_XOR: begin
          if (full_word) out_word <= a[lane_idx] ^ out_word;
          else            out_word <= keep_n(a[lane_idx] ^ out_word, rem_bytes);
          fsm <= S_PT_OUT;
        end
        S_PT_OUT: if (do_ready) begin
          if (full_word) begin
            a[lane_idx] <= decrypt_r ? (a[lane_idx] ^ out_word) : out_word;
            lane_idx<=lane_idx+4'd1; byte_off<=byte_off+16'd4;
            fsm<=S_PT_WORD;
          end else begin
            a[lane_idx] <= decrypt_r
                          ? xor_n(a[lane_idx], out_word, rem_bytes)
                          : xor_n(a[lane_idx], out_word ^ a[lane_idx], rem_bytes);
            fsm <= S_PT_PAD;
          end
        end
        // Cd=0x00 always for Crypt's Down -- nothing else to XOR beyond pad.
        S_PT_PAD: begin
          if (pad_fresh_lane) a[lane_idx] <= a[lane_idx] ^ 32'h0000_0001;
          else a[lane_idx] <= xor_byte_at(a[lane_idx], 8'h01, rem_bytes);
          first_pt_chunk <= 1'b0;
          if (pt_len > {10'd0,PT_RATE}) begin
            pt_len <= pt_next_len;
            chunk_len <= (pt_next_len > {10'd0,PT_RATE}) ? PT_RATE
                                                          : pt_next_len[5:0];
            fsm <= S_PT_PERM;
          end else begin
            fsm <= S_TAG_PERM;
          end
        end

        // ------------------------------------------------------- squeeze --
        // Up(Cu=0x40): the tag squeeze's own domain-separation byte, applied
        // to byte 47 before the permute -- unconditional (there's exactly
        // one tag squeeze per transaction, no "first chunk" gating needed,
        // unlike PT's Cu=0x80). Same class of bug as S_PT_PERM above: this
        // Cu was documented in the header and never wired up.
        S_TAG_PERM: begin
          a[11] <= a[11] ^ 32'h4000_0000;
          round_idx<=4'd0; ret<=S_DO_TAGHDR; lane_idx<=4'd0;
          fsm<=S_PERM_RUN;
        end

        // -------------------------------------------------------- output --
        S_DO_TAGHDR: begin
          mac0<=a[0]; mac1<=a[1]; mac2<=a[2]; mac3<=a[3];
          if (do_ready) begin tag_wcnt<=4'd0; fsm<=S_OUT_TAG; end
        end
        S_OUT_TAG: if (do_ready) begin
          if (tag_wcnt==4'd3) fsm <= decrypt_r ? S_PDI_THDR : S_OUT_STATUS;
          else tag_wcnt <= tag_wcnt + 4'd1;
        end

        S_PDI_THDR: if (pdi_valid) begin tag_wcnt<=4'd0; fsm<=S_TAG_WORD; end
        S_TAG_WORD: if (pdi_valid) begin
          case (tag_wcnt)
            4'd0: tag_ok <= (pdi_data==mac0);
            4'd1: tag_ok <= tag_ok & (pdi_data==mac1);
            4'd2: tag_ok <= tag_ok & (pdi_data==mac2);
            default: begin
              tag_ok <= tag_ok & (pdi_data==mac3);
              fsm <= S_OUT_STATUS;
            end
          endcase
          if (tag_wcnt!=4'd3) tag_wcnt<=tag_wcnt+4'd1;
        end
        S_OUT_STATUS: if (do_ready) fsm <= S_IDLE;

        // -------------------------------------------- shared permute core -
        // 12 rounds, one per cycle, folded into the same cycle as the
        // round-counter check (no separate registered "go" signal --
        // tinyjambu_lwc.v's fix applied from the start here).
        S_PERM_RUN: begin
          xoodoo_round(rc_of(round_idx));
          for (ri = 0; ri < 12; ri = ri + 1) a[ri] <= nx[ri];
          if (round_idx==4'd11) fsm<=ret; else round_idx<=round_idx+4'd1;
        end

        default: fsm <= S_IDLE;
      endcase
    end
  end

endmodule
