// GIFT-COFB AEAD, implementing the CryptoCore-facing protocol of the NIST
// Lightweight Cryptography Hardware API (see tinyjambu_lwc.v's header for the
// full API citation; the same port set, opcodes and segment-header format
// apply here unchanged).
//
// WARNING: GIFT-COFB did NOT win the NIST LWC competition -- Ascon did. This
// core exists for hardware comparison against ascon_aead128.v (this directory),
// not as a recommendation. It has been lint-checked (Verilator and Vivado
// xvlog/xelab) but, unlike tinyjambu_lwc.v, has NOT been run against the
// official KAT vectors in simulation -- say so plainly if quoting this
// core's status; it is a careful transliteration, not yet a confirmed-
// correct one.
//
// Algorithm: transliterated from the official reference C,
// ../lwc-finalists/gift-cofb/{gift128.c,gift128.h,encrypt.c}, which is
// itself the NIST final-round submission. GIFT-COFB = the COFB (COmbined
// FeedBack) authenticated-encryption mode driving the GIFT-128 block cipher
// (40 rounds, bitsliced S-box, fixed bit permutation, key schedule).
//
// PORTS/PROTOCOL: identical to tinyjambu_lwc.v -- w=32, sw=32, real PDI/SDI/DO
// with the real instruction opcodes and 32-bit segment headers. Key and Npub
// are both 16 bytes, tag is 16 bytes (CRYPTO_ABYTES).
//
// GIFT-128 ROUND (giftb128 in gift128.c), on S[0..3] (32-bit) and the key
// schedule W[0..7] (16-bit), one round per cycle, 40 rounds:
//   SubCells (bitsliced, in-place, sequentially dependent -- see the
//     combinational chain in gift_round below), then swap(S0,S3);
//   PermBits: S[i] = rowperm(S[i], <fixed per-row byte-lane map>);
//   AddRoundKey: S[2]^={W2,W3}; S[1]^={W6,W7};
//   AddRoundConstant: S[3]^=0x80000000^GIFT_RC[round];
//   KeyUpdate: W shifts by 2 words; the two "new" words are W6,W7 rotated
//     2 and 12 bits respectively.
//
// COFB MODE (cofb_crypt in encrypt.c), traced exactly for the fixed 16-byte
// key/nonce/tag this project uses:
//   Y = giftb128(Npub, K)                          -- init, ONE cipher call
//   offset = Y[0:8]  (first 8 bytes of Y, byte0 = MSB)
//   -- AD phase, 16-byte blocks. Full blocks (alen>16, STRICT >, so AD of
//      exactly 16 bytes has zero "full" blocks): each uses offset=double(),
//      pho1(Y,A,16), xor_topbar, giftb128.
//   -- final AD block: offset=triple(); +triple() again if that block is
//      partial or AD is empty; +triple()+triple() again if the MESSAGE is
//      empty. This last dependency is the one genuine wrinkle for a
//      streaming hardware core: whether the message is empty is not known
//      until the PT/CT segment header arrives, which is AFTER all of AD's
//      data has already been streamed in over PDI. This core handles it by
//      buffering the final AD chunk's already-arrived bytes and reading the
//      PDI PT/CT header *before* running that final AD block's cipher call
//      -- i.e. it reorders "finish AD" to happen after "peek PT/CT length",
//      not after "finish reading all of AD's data" (those are different
//      points: AD's raw bytes are fully in hand either way, only the GIFT
//      call for the final block is deferred).
//   -- PT/CT phase, 16-byte blocks, only entered if the message is
//      non-empty (an empty message skips this whole phase -- Y from the AD
//      step above becomes the tag directly, matching the reference exactly).
//      Each block: cbuf = Y[0:n] XOR chunk[0:n] -- this is the ciphertext
//      for encrypt or the recovered plaintext for decrypt, XOR being
//      symmetric (C=Y^M <=> M=Y^C), and it is also exactly the value that
//      must be padded and mixed into the next GIFT input either way (pho/
//      pho' in the reference), matching the same "same formula both
//      directions" pattern already used in tinyjambu_lwc.v and
//      xoodyak_lwc.v. offset=double() for a full block, or the same
//      triple()[+triple() if partial] schedule as AD's final block (no
//      forward dependency here -- PT/CT is the last phase before the tag).
//   tag = Y[0:16]
//
// Building blocks (pure functions, transliterated directly from encrypt.c):
//   G(Y): 128-bit; new_upper64=old_lower64, new_lower64=ROL1_64(old_upper64)
//   double(x) [64-bit, GF(2^64), poly x^64+x^4+x^3+x+1]:
//     {x[62:0],1'b0} ^ (x[63] ? 64'h1B : 0)
//   triple(x) = x ^ double(x)
//   pad(M,n): first n bytes of M, then 0x80, then zeros (n=16: M unchanged)
//   xor_topbar(X,off): X with its UPPER 64 bits XORed with `off`

module giftcofb_lwc (
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

  // -------------------------------------------------------- GIFT-128 core --
  reg [31:0] gs [0:3];
  reg [15:0] gw [0:7];
  reg [5:0]  ground;   // 0..39

  function [31:0] rowperm;
    // rowperm() in gift128.c: bit `4*b+k` of S moves to bit `b+8*Bk_pos` of
    // the result, for b=0..7, k=0..3.
    input [31:0] s; input [1:0] b0p,b1p,b2p,b3p;
    integer b;
    reg [31:0] tt;
    begin
      tt = 32'd0;
      for (b = 0; b < 8; b = b + 1) begin
        tt = tt | (((s >> (4*b+0)) & 1) << (b + 8*b0p));
        tt = tt | (((s >> (4*b+1)) & 1) << (b + 8*b1p));
        tt = tt | (((s >> (4*b+2)) & 1) << (b + 8*b2p));
        tt = tt | (((s >> (4*b+3)) & 1) << (b + 8*b3p));
      end
      rowperm = tt;
    end
  endfunction

  function [7:0] gift_rc;
    input [5:0] i;
    begin
      case (i)
        6'd0: gift_rc=8'h01;  6'd1: gift_rc=8'h03;  6'd2: gift_rc=8'h07;
        6'd3: gift_rc=8'h0F;  6'd4: gift_rc=8'h1F;  6'd5: gift_rc=8'h3E;
        6'd6: gift_rc=8'h3D;  6'd7: gift_rc=8'h3B;  6'd8: gift_rc=8'h37;
        6'd9: gift_rc=8'h2F;  6'd10:gift_rc=8'h1E;  6'd11:gift_rc=8'h3C;
        6'd12:gift_rc=8'h39;  6'd13:gift_rc=8'h33;  6'd14:gift_rc=8'h27;
        6'd15:gift_rc=8'h0E;  6'd16:gift_rc=8'h1D;  6'd17:gift_rc=8'h3A;
        6'd18:gift_rc=8'h35;  6'd19:gift_rc=8'h2B;  6'd20:gift_rc=8'h16;
        6'd21:gift_rc=8'h2C;  6'd22:gift_rc=8'h18;  6'd23:gift_rc=8'h30;
        6'd24:gift_rc=8'h21;  6'd25:gift_rc=8'h02;  6'd26:gift_rc=8'h05;
        6'd27:gift_rc=8'h0B;  6'd28:gift_rc=8'h17;  6'd29:gift_rc=8'h2E;
        6'd30:gift_rc=8'h1C;  6'd31:gift_rc=8'h38;  6'd32:gift_rc=8'h31;
        6'd33:gift_rc=8'h23;  6'd34:gift_rc=8'h06;  6'd35:gift_rc=8'h0D;
        6'd36:gift_rc=8'h1B;  6'd37:gift_rc=8'h36;  6'd38:gift_rc=8'h2D;
        default: gift_rc=8'h1A;
      endcase
    end
  endfunction

  reg [31:0] gn [0:3];
  reg [15:0] gwn [0:7];

  task gift_round;
    reg [31:0] a0,a2,a3,b0,b1,b2,b3,c1,c3,c2, p0,p1,p2,p3, sw0,sw3;
    reg [15:0] t6,t7;
    begin
      a0 = gs[0]; a2 = gs[2]; a3 = gs[3];
      b1 = gs[1] ^ (a0 & a2);
      b0 = a0 ^ (b1 & a3);
      b2 = a2 ^ (b0 | b1);
      b3 = a3 ^ b2;
      c1 = b1 ^ b3;
      c3 = ~b3;
      c2 = b2 ^ (b0 & c1);
      sw0 = c3; sw3 = b0;

      p0 = rowperm(sw0, 2'd0,2'd3,2'd2,2'd1);
      p1 = rowperm(c1,  2'd1,2'd0,2'd3,2'd2);
      p2 = rowperm(c2,  2'd2,2'd1,2'd0,2'd3);
      p3 = rowperm(sw3, 2'd3,2'd2,2'd1,2'd0);

      p2 = p2 ^ {gw[2], gw[3]};
      p1 = p1 ^ {gw[6], gw[7]};
      p3 = p3 ^ 32'h8000_0000 ^ {24'd0, gift_rc(ground)};

      gn[0]=p0; gn[1]=p1; gn[2]=p2; gn[3]=p3;

      t6 = (gw[6] >> 2) | (gw[6] << 14);
      t7 = (gw[7] >> 12) | (gw[7] << 4);
      gwn[7]=gw[5]; gwn[6]=gw[4]; gwn[5]=gw[3]; gwn[4]=gw[2];
      gwn[3]=gw[1]; gwn[2]=gw[0]; gwn[1]=t7; gwn[0]=t6;
    end
  endtask

  // ------------------------------------------------------------ COFB mode --
  reg [127:0] Y;
  reg [63:0]  offset;
  reg [31:0]  k0,k1,k2,k3, npub0,npub1,npub2,npub3;
  reg [15:0]  ad_len, pt_len;
  reg [4:0]   chunk_len;       // bytes in the CURRENT AD/PT chunk, 0..16
  reg         decrypt_r, msg_empty, ad_was_empty, ad_final_partial;
  reg         ad_full_block;   // this AD iteration is a full (double()) block
  reg         pt_full_block;
  reg [1:0]   wcnt;
  reg [127:0] blkbuf;          // buffered AD/PT/CT chunk, MSB-first bytes
  reg [127:0] cbuf;            // ciphertext/plaintext output chunk
  reg [1:0]   tag_wcnt;
  reg         tag_ok;
  reg [5:0]   ret;             // return state for the shared GIFT engine

  wire [63:0] dbl_offset = {offset[62:0],1'b0} ^ (offset[63] ? 64'h1B : 64'd0);
  wire [63:0] trp_offset = offset ^ dbl_offset;
  wire [2:0]  need_words = (chunk_len[4:2] + (|chunk_len[1:0]));

  function [127:0] gfun;
    input [127:0] y;
    begin gfun = {y[63:0], y[126:64], y[127]}; end
  endfunction

  // Keep only the low `n` bytes (MSB-first) of a 128-bit value, zeroing the
  // rest -- for both pad() and the API's "clear unused output" rule.
  function [127:0] keep_n128;
    input [127:0] v; input [4:0] n;
    integer i;
    reg [127:0] r;
    begin
      r = 128'd0;
      for (i = 0; i < 16; i = i + 1)
        if (i < n) r[127-8*i -: 8] = v[127-8*i -: 8];
      keep_n128 = r;
    end
  endfunction

  function [127:0] pad128;
    input [127:0] m; input [4:0] n;
    begin
      pad128 = keep_n128(m, n);
      if (n < 5'd16) pad128[127-8*n -: 8] = 8'h80;
    end
  endfunction

  function [127:0] xor_topbar;
    input [127:0] x; input [63:0] off;
    begin xor_topbar = {x[127:64]^off, x[63:0]}; end
  endfunction

  // yosys's Verilog-2005 frontend rejects a part-select directly on a
  // function call's return value (`f(...)[a:b]`), unlike Verilator/Vivado
  // which both accept it; these three wires hold each call site's full
  // 128-bit result once so the FSM below can slice from a plain signal
  // instead, for yosys/OpenROAD synthesis compatibility.
  wire [127:0] fmix_full = xor_topbar(gfun(Y) ^ pad128(blkbuf,chunk_len), dbl_offset);
  wire [127:0] lmix_full = xor_topbar(gfun(Y) ^ pad128(blkbuf,chunk_len),
                                       msg_empty ? trp_offset : offset);
  wire [127:0] ptmix_full = xor_topbar(gfun(Y) ^ pad128(cbuf,chunk_len), offset);

  // ------------------------------------------------------------------ FSM -
  localparam [5:0]
    S_IDLE       = 6'd0,
    S_SDI_HDR    = 6'd1,  S_SDI_KEY    = 6'd2,
    S_PDI_OP     = 6'd3,
    S_PDI_NHDR   = 6'd4,  S_PDI_NDATA  = 6'd5,
    S_INIT_OFF   = 6'd6,
    S_PDI_AHDR   = 6'd7,  S_AD_ITER    = 6'd8,
    S_AD_WORD    = 6'd9,
    S_AD_FOFFS   = 6'd10, S_AD_FMIX    = 6'd11, S_AD_FDONE = 6'd12,
    S_PDI_PHDR   = 6'd13,
    S_AD_LOFFS1  = 6'd14, S_AD_LOFFS2  = 6'd15, S_AD_LOFFS3 = 6'd16,
    S_AD_LMIX    = 6'd17, S_AD_LDONE   = 6'd18,
    S_DO_PTHDR   = 6'd19,
    S_PT_ITER    = 6'd20, S_PT_WORD    = 6'd21,
    S_PT_XOR     = 6'd22, S_PT_OUT     = 6'd23,
    S_PT_OFFS1   = 6'd24, S_PT_OFFS2   = 6'd25,
    S_PT_MIX     = 6'd26, S_PT_DONE    = 6'd27,
    S_DO_TAGHDR  = 6'd28, S_OUT_TAG    = 6'd29,
    S_PDI_THDR   = 6'd30, S_TAG_WORD   = 6'd31,
    S_OUT_STATUS = 6'd32,
    S_GIFT_RUN   = 6'd33;

  reg [5:0] fsm;

  assign pdi_ready = (fsm == S_IDLE)     || (fsm == S_PDI_OP)   ||
                     (fsm == S_PDI_NHDR)|| (fsm == S_PDI_NDATA)||
                     (fsm == S_PDI_AHDR)|| (fsm == S_AD_WORD)  ||
                     (fsm == S_PDI_PHDR)|| (fsm == S_PT_WORD)  ||
                     (fsm == S_PDI_THDR)|| (fsm == S_TAG_WORD);
  assign sdi_ready = (fsm == S_IDLE) || (fsm == S_SDI_HDR) || (fsm == S_SDI_KEY);

  assign do_valid = (fsm == S_DO_PTHDR) || (fsm == S_PT_OUT) ||
                    (fsm == S_DO_TAGHDR) || (fsm == S_OUT_TAG) ||
                    (fsm == S_OUT_STATUS);
  assign do_last  = (fsm == S_OUT_STATUS);
  assign do_data  =
      (fsm == S_DO_PTHDR)  ? {(decrypt_r ? SEGT_PT : SEGT_CT), 1'b0, 1'b0,
                              1'b1, decrypt_r, 8'd0, pt_len} :
      (fsm == S_PT_OUT)    ? (wcnt==2'd0 ? cbuf[127:96] : wcnt==2'd1 ? cbuf[95:64] :
                              wcnt==2'd2 ? cbuf[63:32]  : cbuf[31:0]) :
      (fsm == S_DO_TAGHDR) ? {SEGT_TAG, 1'b0, 1'b0, 1'b1, 1'b1, 8'd0, 16'd16} :
      (fsm == S_OUT_TAG)   ? (tag_wcnt==2'd0 ? Y[127:96] : tag_wcnt==2'd1 ? Y[95:64] :
                              tag_wcnt==2'd2 ? Y[63:32]  : Y[31:0]) :
      (fsm == S_OUT_STATUS)? {(decrypt_r ? (tag_ok?ST_SUCCESS:ST_FAILURE)
                                          : ST_SUCCESS), 28'd0} :
      32'd0;

  integer zi;
  always @(posedge clk) begin
    if (rst) begin
      fsm<=S_IDLE; ret<=S_IDLE; ground<=6'd0; wcnt<=2'd0; tag_wcnt<=2'd0;
      for (zi=0; zi<4; zi=zi+1) begin gs[zi]<=32'd0; end
      for (zi=0; zi<8; zi=zi+1) begin gw[zi]<=16'd0; end
      Y<=0; offset<=0; k0<=0;k1<=0;k2<=0;k3<=0;
      npub0<=0;npub1<=0;npub2<=0;npub3<=0;
      ad_len<=0; pt_len<=0; chunk_len<=0; decrypt_r<=0;
      msg_empty<=0; ad_was_empty<=0; ad_final_partial<=0;
      ad_full_block<=0; pt_full_block<=0; blkbuf<=0; cbuf<=0; tag_ok<=0;
    end else begin
      case (fsm)
        // ------------------------------------------------------ key load --
        S_IDLE: begin
          if (sdi_valid) fsm <= S_SDI_HDR;
          else if (pdi_valid) fsm <= S_PDI_OP;
        end
        S_SDI_HDR: if (sdi_valid) begin wcnt<=2'd0; fsm<=S_SDI_KEY; end
        S_SDI_KEY: if (sdi_valid) begin
          case (wcnt)
            2'd0: k0<=sdi_data; 2'd1: k1<=sdi_data;
            2'd2: k2<=sdi_data; default: k3<=sdi_data;
          endcase
          if (wcnt==2'd3) fsm<=S_IDLE; else wcnt<=wcnt+2'd1;
        end

        // --------------------------------------------- instr + npub -------
        S_PDI_OP: if (pdi_valid) begin
          decrypt_r <= (pdi_data[31:28]==OP_DEC);
          fsm <= S_PDI_NHDR;
        end
        S_PDI_NHDR: if (pdi_valid) begin wcnt<=2'd0; fsm<=S_PDI_NDATA; end
        S_PDI_NDATA: if (pdi_valid) begin
          case (wcnt)
            2'd0: npub0<=pdi_data; 2'd1: npub1<=pdi_data;
            2'd2: npub2<=pdi_data; default: npub3<=pdi_data;
          endcase
          if (wcnt==2'd3) begin
            gs[0]<=npub0; gs[1]<=npub1; gs[2]<=npub2; gs[3]<=pdi_data;
            gw[0]<=k0[31:16]; gw[1]<=k0[15:0]; gw[2]<=k1[31:16]; gw[3]<=k1[15:0];
            gw[4]<=k2[31:16]; gw[5]<=k2[15:0]; gw[6]<=k3[31:16]; gw[7]<=k3[15:0];
            ground<=6'd0; ret<=S_INIT_OFF; fsm<=S_GIFT_RUN;
          end else wcnt<=wcnt+2'd1;
        end
        S_INIT_OFF: begin
          Y <= {gs[0],gs[1],gs[2],gs[3]};
          offset <= {gs[0],gs[1]};
          fsm <= S_PDI_AHDR;
        end

        // --------------------------------------------- associated data ----
        S_PDI_AHDR: if (pdi_valid) begin
          ad_len <= pdi_data[15:0];
          ad_was_empty <= (pdi_data[15:0]==16'd0);
          fsm <= S_AD_ITER;
        end
        // Decide whether this iteration is a FULL block (double(), loop
        // again) or the point where the final chunk's bytes should be
        // buffered without yet running the cipher (see file header).
        S_AD_ITER: begin
          if (ad_len > 16'd16) begin
            chunk_len <= 5'd16; ad_full_block <= 1'b1; wcnt <= 2'd0;
            fsm <= S_AD_WORD;
          end else begin
            chunk_len <= ad_len[4:0]; ad_full_block <= 1'b0; wcnt <= 2'd0;
            fsm <= S_AD_WORD;
          end
        end
        S_AD_WORD: begin
          if ({1'b0,wcnt} < need_words) begin
            if (pdi_valid) begin
              case (wcnt)
                2'd0: blkbuf[127:96]<=pdi_data; 2'd1: blkbuf[95:64]<=pdi_data;
                2'd2: blkbuf[63:32]<=pdi_data;  default: blkbuf[31:0]<=pdi_data;
              endcase
              wcnt <= wcnt + 2'd1;
              if ({1'b0,wcnt} + 3'd1 == need_words)
                fsm <= ad_full_block ? S_AD_FOFFS : S_PDI_PHDR;
            end
          end else fsm <= ad_full_block ? S_AD_FOFFS : S_PDI_PHDR;
        end

        // Full-block path: double(), pho1+xor_topbar, GIFT call, loop.
        S_AD_FOFFS: begin offset <= dbl_offset; fsm <= S_AD_FMIX; end
        S_AD_FMIX: begin
          gs[0] <= fmix_full[127:96];
          gs[1] <= fmix_full[95:64];
          gs[2] <= fmix_full[63:32];
          gs[3] <= fmix_full[31:0];
          ground<=6'd0; ret<=S_AD_FDONE; fsm<=S_GIFT_RUN;
        end
        S_AD_FDONE: begin
          Y <= {gs[0],gs[1],gs[2],gs[3]};
          ad_len <= ad_len - 16'd16;
          fsm <= S_AD_ITER;
        end

        // Final-block path: the chunk's bytes are already buffered in
        // blkbuf; peek the PT/CT header (learns msg_empty) before applying
        // the AD-finalization offset schedule and running its GIFT call.
        S_PDI_PHDR: if (pdi_valid) begin
          pt_len <= pdi_data[15:0];
          msg_empty <= (pdi_data[15:0]==16'd0);
          ad_final_partial <= (chunk_len[1:0]!=2'd0) || ad_was_empty;
          fsm <= S_AD_LOFFS1;
        end
        S_AD_LOFFS1: begin offset <= trp_offset; fsm <= S_AD_LOFFS2; end
        S_AD_LOFFS2: begin
          if (ad_final_partial) offset <= offset ^ dbl_offset; // triple again
          fsm <= S_AD_LOFFS3;
        end
        S_AD_LOFFS3: begin
          if (msg_empty) offset <= trp_offset;
          fsm <= S_AD_LMIX;
        end
        // (msg_empty's SECOND triple() is folded into S_AD_LMIX's use of
        // trp_offset computed from the state left by S_AD_LOFFS3, applied
        // once more there when msg_empty -- see the mix step below.)
        S_AD_LMIX: begin
          gs[0] <= lmix_full[127:96];
          gs[1] <= lmix_full[95:64];
          gs[2] <= lmix_full[63:32];
          gs[3] <= lmix_full[31:0];
          ground<=6'd0; ret<=S_AD_LDONE; fsm<=S_GIFT_RUN;
        end
        S_AD_LDONE: begin
          Y <= {gs[0],gs[1],gs[2],gs[3]};
          fsm <= S_DO_PTHDR;
        end

        // ---------------------------------------------- plaintext/ct ------
        S_DO_PTHDR: if (do_ready) fsm <= msg_empty ? S_DO_TAGHDR : S_PT_ITER;
        S_PT_ITER: begin
          if (pt_len > 16'd16) begin
            chunk_len <= 5'd16; pt_full_block <= 1'b1; wcnt <= 2'd0;
            fsm <= S_PT_WORD;
          end else begin
            chunk_len <= pt_len[4:0]; pt_full_block <= 1'b0; wcnt <= 2'd0;
            fsm <= S_PT_WORD;
          end
        end
        S_PT_WORD: if (pdi_valid) begin
          case (wcnt)
            2'd0: blkbuf[127:96]<=pdi_data; 2'd1: blkbuf[95:64]<=pdi_data;
            2'd2: blkbuf[63:32]<=pdi_data;  default: blkbuf[31:0]<=pdi_data;
          endcase
          wcnt <= wcnt + 2'd1;
          if ({1'b0,wcnt} + 3'd1 == need_words) fsm <= S_PT_XOR;
        end
        // cbuf = Y[0:n] ^ chunk[0:n]: ciphertext (encrypt) or recovered
        // plaintext (decrypt) -- and, either way, exactly the value pho1
        // pads for the next GIFT input.
        S_PT_XOR: begin
          cbuf <= keep_n128(Y ^ blkbuf, chunk_len);
          wcnt <= 2'd0;
          fsm <= S_PT_OUT;
        end
        S_PT_OUT: if (do_ready) begin
          wcnt <= wcnt + 2'd1;
          if (wcnt == 2'd3) fsm <= S_PT_OFFS1;
        end
        S_PT_OFFS1: begin
          offset <= pt_full_block ? dbl_offset : trp_offset;
          fsm <= S_PT_OFFS2;
        end
        S_PT_OFFS2: begin
          if (!pt_full_block && chunk_len[1:0]!=2'd0) offset <= offset ^ dbl_offset;
          fsm <= S_PT_MIX;
        end
        S_PT_MIX: begin
          gs[0] <= ptmix_full[127:96];
          gs[1] <= ptmix_full[95:64];
          gs[2] <= ptmix_full[63:32];
          gs[3] <= ptmix_full[31:0];
          ground<=6'd0; ret<=S_PT_DONE; fsm<=S_GIFT_RUN;
        end
        S_PT_DONE: begin
          Y <= {gs[0],gs[1],gs[2],gs[3]};
          if (pt_len > 16'd16) begin pt_len <= pt_len - 16'd16; fsm <= S_PT_ITER; end
          else fsm <= S_DO_TAGHDR;
        end

        // -------------------------------------------------------- output --
        S_DO_TAGHDR: if (do_ready) begin tag_wcnt<=2'd0; fsm<=S_OUT_TAG; end
        S_OUT_TAG: if (do_ready) begin
          if (tag_wcnt==2'd3) fsm <= decrypt_r ? S_PDI_THDR : S_OUT_STATUS;
          else tag_wcnt <= tag_wcnt + 2'd1;
        end
        S_PDI_THDR: if (pdi_valid) begin tag_wcnt<=2'd0; fsm<=S_TAG_WORD; end
        S_TAG_WORD: if (pdi_valid) begin
          case (tag_wcnt)
            2'd0: tag_ok <= (pdi_data==Y[127:96]);
            2'd1: tag_ok <= tag_ok & (pdi_data==Y[95:64]);
            2'd2: tag_ok <= tag_ok & (pdi_data==Y[63:32]);
            default: begin
              tag_ok <= tag_ok & (pdi_data==Y[31:0]);
              fsm <= S_OUT_STATUS;
            end
          endcase
          if (tag_wcnt!=2'd3) tag_wcnt<=tag_wcnt+2'd1;
        end
        S_OUT_STATUS: if (do_ready) fsm <= S_IDLE;

        // -------------------------------------------- shared GIFT engine --
        S_GIFT_RUN: begin
          gift_round;
          for (zi=0; zi<4; zi=zi+1) gs[zi] <= gn[zi];
          for (zi=0; zi<8; zi=zi+1) gw[zi] <= gwn[zi];
          if (ground==6'd39) fsm <= ret; else ground <= ground + 6'd1;
        end

        default: fsm <= S_IDLE;
      endcase
    end
  end

endmodule
