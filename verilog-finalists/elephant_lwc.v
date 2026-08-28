// Elephant (Dumbo variant: Spongent-π[160]), implementing the CryptoCore-facing
// protocol of the NIST Lightweight Cryptography Hardware API (see
// tinyjambu_lwc.v's header for the full API citation; same ports, opcodes and
// segment-header format).
//
// WARNING: Elephant did NOT win the NIST LWC competition -- Ascon did. This
// core exists for hardware comparison against the Ascon cores in verilog/,
// not as a recommendation. Lint-checked (Verilator + Vivado) but NOT run
// against the official KAT vectors in simulation -- unlike tinyjambu_lwc.v.
// It is a careful transliteration, not a confirmed-correct one, and it is
// the most structurally involved of the finalist cores in this directory
// (see CAPACITY LIMIT below).
//
// Algorithm: transliterated from the official reference C in
// ../lwc-finalists/elephant/ (encrypt.c + spongent.c, NIST final-round
// "Dumbo" submission, permutation = Spongent-pi[160], BLOCK_SIZE=20 bytes).
// Key = 16 B, Npub = 12 B, tag = 8 B (CRYPTO_ABYTES=8, like Grain -- not 16).
//
// PERMUTATION (spongent.c): 160-bit state, 80 rounds, one round = counter-XOR
// + 8-bit S-box on each of 20 bytes + a full 160-bit wire permutation
// (pLayer). Internal byte/bit numbering: this core represents the state as a
// flat 160-bit vector where byte i occupies bits [8*i +: 8] and bit j of that
// byte is vector bit (8*i+j) -- exactly the reference's GET_BIT(state[i],j)
// addressing, so pLayer's bit-index formula Pi() ports over unchanged.
// pLayer is a fixed (data-independent) bit permutation, i.e. pure wiring; it
// is computed here by the same nested-index arithmetic as the reference
// (Pi(k) = (k!=159) ? (k*160/4)%159 : 159) inside a combinational function,
// rather than by hand-transcribing 160 wire assignments.
// The S-box table (sbox_tab, 256 entries) is transcribed verbatim from
// spongent.c's sBoxLayer[]. One round is applied per clock (matching the
// "one step per cycle" style used for SPARKLE in this directory); a full
// permutation() call therefore costs 80 cycles, and this core calls it up to
// three times per main-loop iteration plus twice more for key expansion and
// finalization.
//
// AEAD STRUCTURE (crypto_aead_impl in encrypt.c): three interleaved streams,
// each stepping by one 20-byte block per iteration of a single loop of
// nb_it = max(nblocks_c+1, nblocks_ad-1) iterations:
//   - message encryption/decryption at block index i (i < nblocks_m), using
//     an LFSR-mask pair (current_mask, next_mask) framing a keystream
//     permutation call on {Npub, zero-pad};
//   - a running tag accumulator, updated at index i from the CIPHERTEXT (or,
//     when decrypting, the just-recovered PLAINTEXT) of the PREVIOUS block
//     i-1 (get_c_block), using the mask pair (previous_mask, next_mask);
//   - the same tag accumulator, updated at index i from the AD block ONE
//     AHEAD, i+1 (get_ad_block), using next_mask alone.
//   The three 32-bit mask registers rotate every iteration
//   (previous<-current, current<-next). get_ad_block(0) (nonce-prefixed AD
//   block) seeds the tag accumulator before the loop starts; the key,
//   permuted once into "expanded_key", both seeds current_mask and is XORed
//   in twice (Finalize-equivalent) around one last permutation call to
//   produce the tag.
//
// UNIFIED KEYSTREAM XOR: message encryption and decryption use the identical
// formula (out = keystream ^ in), so this core computes one "out_block" per
// message-block iteration regardless of direction -- ciphertext when
// encrypting, recovered plaintext when decrypting -- and that is exactly the
// value get_c_block's lookback needs from out_mem, matching the reference's
// own "encrypt ? c : m" selection without a separate code path.
//
// get_ad_block / get_c_block: rather than transcribe the reference's
// several branching special cases (exact-multiple-of-block-size padding,
// nonce-prefix-only first block, etc.), this core observes that every case
// reduces to ONE per-byte rule -- for absolute source-stream byte offset
// "off" less than the stream's total length, emit that byte; when off equals
// the length exactly, emit the single pad marker (0x01); otherwise 0 -- and
// implements get_ad_block/get_c_block as that uniform per-byte formula over
// ad_mem/out_mem. This was checked by hand against every branch of the C
// (including the "block_offset==length" early-return case, which the
// uniform rule reproduces automatically at the first byte of that block).
//
// CAPACITY LIMIT (the one real simplification here): get_ad_block does true
// random-offset lookahead into the AD stream, one block ahead of the main
// loop, and get_c_block looks one block behind into the OUTPUT stream --
// both need buffered random access, not pure streaming. This core buffers
// the full (raw) AD stream into ad_mem and the full produced output stream
// into out_mem, each sized MAX_BYTES = 64 bytes. AD and message/ciphertext
// length are therefore assumed <= 64 bytes; a fully general core would need
// a genuinely windowed (2-block-deep) AD prefetch instead of whole-message
// buffering, which is a materially larger design left out of scope for a
// transliteration exercise. The 16-bit PDI length header is still read in
// full (so a too-long input is detected as an addressing bound, not
// silently misread), but only lengths within MAX_BYTES produce a value
// matching the reference.

module elephant_lwc (
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

  localparam MAX_BYTES = 64;

  // -------------------------------------------------------------- S-box ROM
  reg [7:0] sbox_tab [0:255];
  initial begin
    sbox_tab[0] = 8'hee;
    sbox_tab[1] = 8'hed;
    sbox_tab[2] = 8'heb;
    sbox_tab[3] = 8'he0;
    sbox_tab[4] = 8'he2;
    sbox_tab[5] = 8'he1;
    sbox_tab[6] = 8'he4;
    sbox_tab[7] = 8'hef;
    sbox_tab[8] = 8'he7;
    sbox_tab[9] = 8'hea;
    sbox_tab[10] = 8'he8;
    sbox_tab[11] = 8'he5;
    sbox_tab[12] = 8'he9;
    sbox_tab[13] = 8'hec;
    sbox_tab[14] = 8'he3;
    sbox_tab[15] = 8'he6;
    sbox_tab[16] = 8'hde;
    sbox_tab[17] = 8'hdd;
    sbox_tab[18] = 8'hdb;
    sbox_tab[19] = 8'hd0;
    sbox_tab[20] = 8'hd2;
    sbox_tab[21] = 8'hd1;
    sbox_tab[22] = 8'hd4;
    sbox_tab[23] = 8'hdf;
    sbox_tab[24] = 8'hd7;
    sbox_tab[25] = 8'hda;
    sbox_tab[26] = 8'hd8;
    sbox_tab[27] = 8'hd5;
    sbox_tab[28] = 8'hd9;
    sbox_tab[29] = 8'hdc;
    sbox_tab[30] = 8'hd3;
    sbox_tab[31] = 8'hd6;
    sbox_tab[32] = 8'hbe;
    sbox_tab[33] = 8'hbd;
    sbox_tab[34] = 8'hbb;
    sbox_tab[35] = 8'hb0;
    sbox_tab[36] = 8'hb2;
    sbox_tab[37] = 8'hb1;
    sbox_tab[38] = 8'hb4;
    sbox_tab[39] = 8'hbf;
    sbox_tab[40] = 8'hb7;
    sbox_tab[41] = 8'hba;
    sbox_tab[42] = 8'hb8;
    sbox_tab[43] = 8'hb5;
    sbox_tab[44] = 8'hb9;
    sbox_tab[45] = 8'hbc;
    sbox_tab[46] = 8'hb3;
    sbox_tab[47] = 8'hb6;
    sbox_tab[48] = 8'h0e;
    sbox_tab[49] = 8'h0d;
    sbox_tab[50] = 8'h0b;
    sbox_tab[51] = 8'h00;
    sbox_tab[52] = 8'h02;
    sbox_tab[53] = 8'h01;
    sbox_tab[54] = 8'h04;
    sbox_tab[55] = 8'h0f;
    sbox_tab[56] = 8'h07;
    sbox_tab[57] = 8'h0a;
    sbox_tab[58] = 8'h08;
    sbox_tab[59] = 8'h05;
    sbox_tab[60] = 8'h09;
    sbox_tab[61] = 8'h0c;
    sbox_tab[62] = 8'h03;
    sbox_tab[63] = 8'h06;
    sbox_tab[64] = 8'h2e;
    sbox_tab[65] = 8'h2d;
    sbox_tab[66] = 8'h2b;
    sbox_tab[67] = 8'h20;
    sbox_tab[68] = 8'h22;
    sbox_tab[69] = 8'h21;
    sbox_tab[70] = 8'h24;
    sbox_tab[71] = 8'h2f;
    sbox_tab[72] = 8'h27;
    sbox_tab[73] = 8'h2a;
    sbox_tab[74] = 8'h28;
    sbox_tab[75] = 8'h25;
    sbox_tab[76] = 8'h29;
    sbox_tab[77] = 8'h2c;
    sbox_tab[78] = 8'h23;
    sbox_tab[79] = 8'h26;
    sbox_tab[80] = 8'h1e;
    sbox_tab[81] = 8'h1d;
    sbox_tab[82] = 8'h1b;
    sbox_tab[83] = 8'h10;
    sbox_tab[84] = 8'h12;
    sbox_tab[85] = 8'h11;
    sbox_tab[86] = 8'h14;
    sbox_tab[87] = 8'h1f;
    sbox_tab[88] = 8'h17;
    sbox_tab[89] = 8'h1a;
    sbox_tab[90] = 8'h18;
    sbox_tab[91] = 8'h15;
    sbox_tab[92] = 8'h19;
    sbox_tab[93] = 8'h1c;
    sbox_tab[94] = 8'h13;
    sbox_tab[95] = 8'h16;
    sbox_tab[96] = 8'h4e;
    sbox_tab[97] = 8'h4d;
    sbox_tab[98] = 8'h4b;
    sbox_tab[99] = 8'h40;
    sbox_tab[100] = 8'h42;
    sbox_tab[101] = 8'h41;
    sbox_tab[102] = 8'h44;
    sbox_tab[103] = 8'h4f;
    sbox_tab[104] = 8'h47;
    sbox_tab[105] = 8'h4a;
    sbox_tab[106] = 8'h48;
    sbox_tab[107] = 8'h45;
    sbox_tab[108] = 8'h49;
    sbox_tab[109] = 8'h4c;
    sbox_tab[110] = 8'h43;
    sbox_tab[111] = 8'h46;
    sbox_tab[112] = 8'hfe;
    sbox_tab[113] = 8'hfd;
    sbox_tab[114] = 8'hfb;
    sbox_tab[115] = 8'hf0;
    sbox_tab[116] = 8'hf2;
    sbox_tab[117] = 8'hf1;
    sbox_tab[118] = 8'hf4;
    sbox_tab[119] = 8'hff;
    sbox_tab[120] = 8'hf7;
    sbox_tab[121] = 8'hfa;
    sbox_tab[122] = 8'hf8;
    sbox_tab[123] = 8'hf5;
    sbox_tab[124] = 8'hf9;
    sbox_tab[125] = 8'hfc;
    sbox_tab[126] = 8'hf3;
    sbox_tab[127] = 8'hf6;
    sbox_tab[128] = 8'h7e;
    sbox_tab[129] = 8'h7d;
    sbox_tab[130] = 8'h7b;
    sbox_tab[131] = 8'h70;
    sbox_tab[132] = 8'h72;
    sbox_tab[133] = 8'h71;
    sbox_tab[134] = 8'h74;
    sbox_tab[135] = 8'h7f;
    sbox_tab[136] = 8'h77;
    sbox_tab[137] = 8'h7a;
    sbox_tab[138] = 8'h78;
    sbox_tab[139] = 8'h75;
    sbox_tab[140] = 8'h79;
    sbox_tab[141] = 8'h7c;
    sbox_tab[142] = 8'h73;
    sbox_tab[143] = 8'h76;
    sbox_tab[144] = 8'hae;
    sbox_tab[145] = 8'had;
    sbox_tab[146] = 8'hab;
    sbox_tab[147] = 8'ha0;
    sbox_tab[148] = 8'ha2;
    sbox_tab[149] = 8'ha1;
    sbox_tab[150] = 8'ha4;
    sbox_tab[151] = 8'haf;
    sbox_tab[152] = 8'ha7;
    sbox_tab[153] = 8'haa;
    sbox_tab[154] = 8'ha8;
    sbox_tab[155] = 8'ha5;
    sbox_tab[156] = 8'ha9;
    sbox_tab[157] = 8'hac;
    sbox_tab[158] = 8'ha3;
    sbox_tab[159] = 8'ha6;
    sbox_tab[160] = 8'h8e;
    sbox_tab[161] = 8'h8d;
    sbox_tab[162] = 8'h8b;
    sbox_tab[163] = 8'h80;
    sbox_tab[164] = 8'h82;
    sbox_tab[165] = 8'h81;
    sbox_tab[166] = 8'h84;
    sbox_tab[167] = 8'h8f;
    sbox_tab[168] = 8'h87;
    sbox_tab[169] = 8'h8a;
    sbox_tab[170] = 8'h88;
    sbox_tab[171] = 8'h85;
    sbox_tab[172] = 8'h89;
    sbox_tab[173] = 8'h8c;
    sbox_tab[174] = 8'h83;
    sbox_tab[175] = 8'h86;
    sbox_tab[176] = 8'h5e;
    sbox_tab[177] = 8'h5d;
    sbox_tab[178] = 8'h5b;
    sbox_tab[179] = 8'h50;
    sbox_tab[180] = 8'h52;
    sbox_tab[181] = 8'h51;
    sbox_tab[182] = 8'h54;
    sbox_tab[183] = 8'h5f;
    sbox_tab[184] = 8'h57;
    sbox_tab[185] = 8'h5a;
    sbox_tab[186] = 8'h58;
    sbox_tab[187] = 8'h55;
    sbox_tab[188] = 8'h59;
    sbox_tab[189] = 8'h5c;
    sbox_tab[190] = 8'h53;
    sbox_tab[191] = 8'h56;
    sbox_tab[192] = 8'h9e;
    sbox_tab[193] = 8'h9d;
    sbox_tab[194] = 8'h9b;
    sbox_tab[195] = 8'h90;
    sbox_tab[196] = 8'h92;
    sbox_tab[197] = 8'h91;
    sbox_tab[198] = 8'h94;
    sbox_tab[199] = 8'h9f;
    sbox_tab[200] = 8'h97;
    sbox_tab[201] = 8'h9a;
    sbox_tab[202] = 8'h98;
    sbox_tab[203] = 8'h95;
    sbox_tab[204] = 8'h99;
    sbox_tab[205] = 8'h9c;
    sbox_tab[206] = 8'h93;
    sbox_tab[207] = 8'h96;
    sbox_tab[208] = 8'hce;
    sbox_tab[209] = 8'hcd;
    sbox_tab[210] = 8'hcb;
    sbox_tab[211] = 8'hc0;
    sbox_tab[212] = 8'hc2;
    sbox_tab[213] = 8'hc1;
    sbox_tab[214] = 8'hc4;
    sbox_tab[215] = 8'hcf;
    sbox_tab[216] = 8'hc7;
    sbox_tab[217] = 8'hca;
    sbox_tab[218] = 8'hc8;
    sbox_tab[219] = 8'hc5;
    sbox_tab[220] = 8'hc9;
    sbox_tab[221] = 8'hcc;
    sbox_tab[222] = 8'hc3;
    sbox_tab[223] = 8'hc6;
    sbox_tab[224] = 8'h3e;
    sbox_tab[225] = 8'h3d;
    sbox_tab[226] = 8'h3b;
    sbox_tab[227] = 8'h30;
    sbox_tab[228] = 8'h32;
    sbox_tab[229] = 8'h31;
    sbox_tab[230] = 8'h34;
    sbox_tab[231] = 8'h3f;
    sbox_tab[232] = 8'h37;
    sbox_tab[233] = 8'h3a;
    sbox_tab[234] = 8'h38;
    sbox_tab[235] = 8'h35;
    sbox_tab[236] = 8'h39;
    sbox_tab[237] = 8'h3c;
    sbox_tab[238] = 8'h33;
    sbox_tab[239] = 8'h36;
    sbox_tab[240] = 8'h6e;
    sbox_tab[241] = 8'h6d;
    sbox_tab[242] = 8'h6b;
    sbox_tab[243] = 8'h60;
    sbox_tab[244] = 8'h62;
    sbox_tab[245] = 8'h61;
    sbox_tab[246] = 8'h64;
    sbox_tab[247] = 8'h6f;
    sbox_tab[248] = 8'h67;
    sbox_tab[249] = 8'h6a;
    sbox_tab[250] = 8'h68;
    sbox_tab[251] = 8'h65;
    sbox_tab[252] = 8'h69;
    sbox_tab[253] = 8'h6c;
    sbox_tab[254] = 8'h63;
    sbox_tab[255] = 8'h66;
  end

  // Declared ahead of the helper functions below, which reference them
  // directly (Vivado requires module-scope signals be declared before a
  // function that reads them; Verilator does not enforce the ordering, but
  // this layout works for both).
  reg [127:0] key_r;
  reg [95:0]  npub_r;
  reg [15:0]  ad_len, pt_len;
  reg [7:0]   ad_mem  [0:MAX_BYTES-1];
  reg [7:0]   out_mem [0:MAX_BYTES-1];

  // ---------------------------------------------------------------- helpers
  function [7:0] retnuoCl;
    input [7:0] lfsr;
    begin
      retnuoCl = {lfsr[0], lfsr[1], lfsr[2], lfsr[3],
                  lfsr[4], lfsr[5], lfsr[6], 1'b0};
    end
  endfunction

  function [7:0] lcounter;
    input [7:0] lfsr;
    reg [7:0] shifted;
    begin
      shifted  = {lfsr[6:0], 1'b0};
      lcounter = (shifted | {6'b0, lfsr[6] ^ lfsr[5], 1'b0}) & 8'h7f;
    end
  endfunction

  function [159:0] sbox_all;
    input [159:0] s;
    integer i;
    reg [159:0] o;
    begin
      o = 160'd0;
      for (i = 0; i < 20; i = i + 1)
        o[8*i +: 8] = sbox_tab[s[8*i +: 8]];
      sbox_all = o;
    end
  endfunction

  function [159:0] player;
    input [159:0] s;
    integer k, pb;
    reg [159:0] o;
    begin
      o = 160'd0;
      for (k = 0; k < 160; k = k + 1) begin
        pb = (k != 159) ? ((k*160/4) % 159) : 159;
        o[pb] = s[k];
      end
      player = o;
    end
  endfunction

  function [159:0] lfsr_step;
    input [159:0] inp;
    reg [7:0] b0, b3, b13, temp;
    begin
      b0   = inp[7:0];
      b3   = inp[31:24];
      b13  = inp[111:104];
      temp = {b0[4:0], b0[7:5]} ^ {b3[0], 7'b0} ^ {7'b0, b13[7]};
      lfsr_step = {temp, inp[159:8]};
    end
  endfunction

  // get_ad_block(bi): bi==0 is the nonce-prefixed first AD block; bi>=1
  // reads pure AD bytes at (bi*20 - 12). Uniform per-byte pad rule (see file
  // header). ad_len/npub_r/ad_mem are module-scope regs read directly.
  function [159:0] get_ad_block;
    input [7:0] bi;
    integer j;
    reg [15:0] pfx, boff, off;
    reg [159:0] o;
    begin
      o    = 160'd0;
      pfx  = (bi == 8'd0) ? 16'd12 : 16'd0;
      boff = (bi == 8'd0) ? 16'd0 : (({8'd0, bi} * 16'd20) - 16'd12);
      for (j = 0; j < 20; j = j + 1) begin
        if (bi == 8'd0 && j < 12)
          o[8*j +: 8] = npub_r[8*j +: 8];
        else begin
          off = boff + ({11'd0, j[4:0]} - pfx);
          if (off < ad_len)       o[8*j +: 8] = ad_mem[off[5:0]];
          else if (off == ad_len) o[8*j +: 8] = 8'h01;
          else                    o[8*j +: 8] = 8'h00;
        end
      end
      get_ad_block = o;
    end
  endfunction

  // get_c_block(bi): reads the OUTPUT stream (ciphertext when encrypting,
  // recovered plaintext when decrypting) already written into out_mem.
  function [159:0] get_c_block;
    input [7:0] bi;
    integer j;
    reg [15:0] off;
    reg [159:0] o;
    begin
      o = 160'd0;
      for (j = 0; j < 20; j = j + 1) begin
        off = ({8'd0, bi} * 16'd20) + {11'd0, j[4:0]};
        if (off < pt_len)       o[8*j +: 8] = out_mem[off[5:0]];
        else if (off == pt_len) o[8*j +: 8] = 8'h01;
        else                    o[8*j +: 8] = 8'h00;
      end
      get_c_block = o;
    end
  endfunction

  // ------------------------------------------------------------ state regs
  // (key_r, npub_r, ad_len, pt_len, ad_mem, out_mem declared above, ahead of
  // the helper functions that reference them)
  reg [159:0] expanded_key;
  reg [159:0] previous_mask, current_mask;
  reg [159:0] tag_buffer;
  reg [7:0]   it;                 // main-loop iteration index

  reg [159:0] perm_state;
  reg [7:0]   perm_iv;
  reg [6:0]   perm_rnd;
  reg [5:0]   perm_ret;

  reg [159:0] inblk;              // collected PT/CT bytes for this block
  reg [159:0] out_block;          // computed output block for this iteration
  reg [4:0]   coll_idx;           // word index while collecting AD or PT/CT
  reg [4:0]   coll_words;         // total words to collect this block
  reg [7:0]   coll_base;          // byte offset in ad_mem/out_mem/PDI stream
  reg [4:0]   coll_nbytes;        // valid byte count in this block (r_size)
  reg [3:0]   owc;                // output word counter
  reg [1:0]   wcnt;               // small word counter (key/npub/tag)
  reg         decrypt_r, key_loaded, tag_ok;

  wire [159:0] next_mask = lfsr_step(current_mask);

  wire [15:0] nblocks_c_16 = 16'd1 + pt_len / 16'd20;
  wire [7:0] nblocks_c  = nblocks_c_16[7:0];
  wire [7:0] nblocks_m  = ((pt_len % 16'd20) != 16'd0) ? nblocks_c
                                                        : (nblocks_c - 8'd1);
  wire [15:0] nblocks_ad_16 = 16'd1 + (16'd12 + ad_len) / 16'd20;
  wire [7:0] nblocks_ad = nblocks_ad_16[7:0];
  wire [7:0] nb_it = ((nblocks_c + 8'd1) > (nblocks_ad - 8'd1))
                    ? (nblocks_c + 8'd1) : (nblocks_ad - 8'd1);

  // Byte offset / valid-byte-count of the message block at index "it".
  wire [15:0] msg_off      = {8'd0, it} * 16'd20;
  wire [15:0] msg_rsize_16 = pt_len - msg_off;
  wire [7:0]  msg_rsize = (it == nblocks_m - 8'd1) ? msg_rsize_16[7:0]
                                                    : 8'd20;
  wire [7:0]  msg_words_8 = (msg_rsize + 8'd3) >> 2;
  wire [4:0]  msg_words = msg_words_8[4:0];

  wire [7:0]  ad_words  = (ad_len[7:0] + 8'd3) >> 2;

  // Round update (shared by every permutation() call site).
  wire [7:0]   inv_iv       = retnuoCl(perm_iv);
  wire [159:0] round_ivxor  = perm_state ^ {inv_iv, 144'b0, perm_iv};
  wire [159:0] round_sbox   = sbox_all(round_ivxor);
  wire [159:0] round_next   = player(round_sbox);
  wire [7:0]   iv_next      = lcounter(perm_iv);

  // Byte mask for the message block's valid bytes.
  reg [159:0] msg_mask;
  integer mmi;
  always @* begin
    msg_mask = 160'd0;
    for (mmi = 0; mmi < 20; mmi = mmi + 1)
      msg_mask[8*mmi +: 8] = (mmi < msg_rsize) ? 8'hff : 8'h00;
  end

  wire [159:0] tagc_input  = get_c_block(it - 8'd1) ^ previous_mask ^ next_mask;
  wire [159:0] tagad_input = get_ad_block(it + 8'd1) ^ next_mask;

  localparam [5:0]
    S_IDLE        = 6'd0,  S_SDI_HDR     = 6'd1,  S_SDI_KEY    = 6'd2,
    S_PDI_OP      = 6'd3,  S_PDI_NHDR    = 6'd4,  S_PDI_NDATA  = 6'd5,
    S_EK_LOAD     = 6'd6,  S_PERM_RUN    = 6'd7,  S_EK_DONE    = 6'd8,
    S_PDI_AHDR    = 6'd9,  S_AD_COLL     = 6'd10,
    S_PDI_PHDR    = 6'd11, S_DO_PTHDR    = 6'd12, S_TAG0_INIT  = 6'd13,
    S_IT_MSG_CHK  = 6'd14, S_IT_MSG_LOAD = 6'd15, S_IT_MSG_XOR = 6'd16,
    S_IT_MSG_COLL = 6'd17, S_IT_MSG_CMB  = 6'd18, S_IT_MSG_OUT = 6'd19,
    S_IT_TAGC_CHK = 6'd20, S_IT_TAGC_LOAD= 6'd21, S_IT_TAGC_XOR= 6'd22,
    S_IT_TAGAD_CHK= 6'd23, S_IT_TAGAD_LD = 6'd24, S_IT_TAGAD_XOR=6'd25,
    S_IT_NEXT     = 6'd26,
    S_FIN_LOAD    = 6'd27, S_FIN_XOR     = 6'd28,
    S_DO_TAGHDR   = 6'd29, S_TAG_OUT     = 6'd30,
    S_PDI_THDR    = 6'd31, S_TAG_IN      = 6'd32,
    S_OUT_STATUS  = 6'd33;

  reg [5:0] fsm;

  // ------------------------------------------------------------- handshakes
  assign pdi_ready = (fsm == S_IDLE)      || (fsm == S_PDI_OP)   ||
                     (fsm == S_PDI_NHDR) || (fsm == S_PDI_NDATA)||
                     (fsm == S_PDI_AHDR) || (fsm == S_AD_COLL)  ||
                     (fsm == S_PDI_PHDR) || (fsm == S_IT_MSG_COLL) ||
                     (fsm == S_PDI_THDR) || (fsm == S_TAG_IN);
  assign sdi_ready = (fsm == S_IDLE) || (fsm == S_SDI_HDR) || (fsm == S_SDI_KEY);

  assign do_valid = (fsm == S_DO_PTHDR) || (fsm == S_IT_MSG_OUT) ||
                    (fsm == S_DO_TAGHDR)|| (fsm == S_TAG_OUT)   ||
                    (fsm == S_OUT_STATUS);
  assign do_last  = (fsm == S_OUT_STATUS);

  wire [7:0] obit = {4'd0, owc}  << 5;   // owc*32, owc<=4 so fits in 8 bits
  wire [7:0] tbit = {6'd0, wcnt} << 5;   // wcnt*32, wcnt<=1
  wire [7:0] ibit = {5'd0, coll_idx[2:0]} << 5;  // coll_idx*32 during msg coll (<=4)
  wire [5:0] adbase = {coll_idx[3:0], 2'b00};    // coll_idx*4 during AD coll (<=15)
  wire [5:0] obase  = msg_off[5:0] + {1'b0, owc[2:0], 2'b00};

  wire [31:0] out_word = {out_block[obit+:8],  out_block[(obit+8'd8)+:8],
                          out_block[(obit+8'd16)+:8], out_block[(obit+8'd24)+:8]};
  wire [31:0] tag_word = {tag_buffer[tbit+:8],  tag_buffer[(tbit+8'd8)+:8],
                          tag_buffer[(tbit+8'd16)+:8], tag_buffer[(tbit+8'd24)+:8]};

  assign do_data =
      (fsm == S_DO_PTHDR)  ? {(decrypt_r ? SEGT_PT : SEGT_CT), 1'b0, 1'b0,
                              1'b1, decrypt_r, 8'd0, pt_len} :
      (fsm == S_IT_MSG_OUT)? out_word :
      (fsm == S_DO_TAGHDR) ? {SEGT_TAG, 1'b0, 1'b0, 1'b1, 1'b1, 8'd0, 16'd8} :
      (fsm == S_TAG_OUT)   ? tag_word :
      (fsm == S_OUT_STATUS)? {(decrypt_r ? (tag_ok ? ST_SUCCESS : ST_FAILURE)
                                         : ST_SUCCESS), 28'd0} :
      32'd0;

  // ------------------------------------------------------------------- FSM
  always @(posedge clk) begin
    if (rst) begin
      fsm <= S_IDLE; key_loaded <= 1'b0; decrypt_r <= 1'b0; tag_ok <= 1'b1;
      wcnt <= 2'd0; owc <= 4'd0; it <= 8'd0;
      coll_idx <= 5'd0; coll_words <= 5'd0; coll_base <= 8'd0; coll_nbytes <= 5'd0;
      key_r <= 128'd0; npub_r <= 96'd0; ad_len <= 16'd0; pt_len <= 16'd0;
      expanded_key <= 160'd0; previous_mask <= 160'd0; current_mask <= 160'd0;
      tag_buffer <= 160'd0; inblk <= 160'd0; out_block <= 160'd0;
      perm_state <= 160'd0; perm_iv <= 8'd0; perm_rnd <= 7'd0; perm_ret <= 6'd0;
    end else begin
      case (fsm)
        S_IDLE: begin
          if (sdi_valid)      fsm <= S_SDI_HDR;
          else if (pdi_valid) fsm <= S_PDI_OP;
        end
        S_SDI_HDR: if (sdi_valid) begin wcnt <= 2'd0; fsm <= S_SDI_KEY; end
        // Words are byte-swapped on arrival so key_r ends up flatvec-ordered
        // (byte 0 of the key, i.e. the FIRST byte on the bus, lands at
        // key_r[7:0] -- the same "byte i at bits[8*i +: 8]" convention used
        // for ad_mem/out_mem/get_ad_block/get_c_block throughout this file).
        S_SDI_KEY: if (sdi_valid) begin
          case (wcnt)
            2'd0: key_r[31:0]   <= {sdi_data[7:0], sdi_data[15:8], sdi_data[23:16], sdi_data[31:24]};
            2'd1: key_r[63:32]  <= {sdi_data[7:0], sdi_data[15:8], sdi_data[23:16], sdi_data[31:24]};
            2'd2: key_r[95:64]  <= {sdi_data[7:0], sdi_data[15:8], sdi_data[23:16], sdi_data[31:24]};
            default: key_r[127:96] <= {sdi_data[7:0], sdi_data[15:8], sdi_data[23:16], sdi_data[31:24]};
          endcase
          wcnt  <= wcnt + 2'd1;
          if (wcnt == 2'd3) begin key_loaded <= 1'b1; fsm <= S_IDLE; end
        end

        S_PDI_OP: if (pdi_valid) begin
          decrypt_r <= (pdi_data[31:28] == OP_DEC);
          tag_ok    <= 1'b1;
          fsm       <= S_PDI_NHDR;
        end
        S_PDI_NHDR: if (pdi_valid) begin wcnt <= 2'd0; fsm <= S_PDI_NDATA; end
        // Same byte-swap-on-arrival rule as key_r above (flatvec-ordered,
        // byte 0 -> npub_r[7:0]).
        S_PDI_NDATA: if (pdi_valid) begin
          case (wcnt)
            2'd0: npub_r[31:0]  <= {pdi_data[7:0], pdi_data[15:8], pdi_data[23:16], pdi_data[31:24]};
            2'd1: npub_r[63:32] <= {pdi_data[7:0], pdi_data[15:8], pdi_data[23:16], pdi_data[31:24]};
            default: npub_r[95:64] <= {pdi_data[7:0], pdi_data[15:8], pdi_data[23:16], pdi_data[31:24]};
          endcase
          wcnt   <= wcnt + 2'd1;
          if (wcnt == 2'd2) begin
            // expanded_key input: key (bytes 0..15, LOW) || 0-pad (bytes
            // 16..19, HIGH) -- matches memcpy(expanded_key,k,16) into a
            // zero-initialized 20-byte buffer.
            perm_state <= {32'd0, key_r};
            perm_iv    <= 8'h75; perm_rnd <= 7'd0; perm_ret <= S_EK_DONE;
            fsm <= S_PERM_RUN;
          end
        end

        // Shared permutation engine: 80 rounds, one per cycle.
        S_PERM_RUN: begin
          perm_state <= round_next;
          perm_iv    <= iv_next;
          if (perm_rnd == 7'd79) fsm <= perm_ret;
          else                   perm_rnd <= perm_rnd + 7'd1;
        end

        S_EK_DONE: begin
          expanded_key  <= perm_state;
          current_mask  <= perm_state;
          fsm <= S_PDI_AHDR;
        end

        S_PDI_AHDR: if (pdi_valid) begin
          ad_len   <= pdi_data[15:0];
          coll_idx <= 5'd0;
          fsm <= (pdi_data[15:0] == 16'd0) ? S_PDI_PHDR : S_AD_COLL;
        end
        S_AD_COLL: if (pdi_valid) begin
          ad_mem[adbase]      <= pdi_data[31:24];
          ad_mem[adbase+6'd1] <= pdi_data[23:16];
          ad_mem[adbase+6'd2] <= pdi_data[15:8];
          ad_mem[adbase+6'd3] <= pdi_data[7:0];
          if (coll_idx == ad_words[4:0] - 5'd1) fsm <= S_PDI_PHDR;
          else                                   coll_idx <= coll_idx + 5'd1;
        end

        S_PDI_PHDR: if (pdi_valid) begin
          pt_len <= pdi_data[15:0];
          fsm    <= S_DO_PTHDR;
        end
        S_DO_PTHDR: if (do_ready) begin
          // get_ad_block(0) needs ad_len/npub_r, both already latched.
          tag_buffer <= get_ad_block(8'd0);
          it <= 8'd0;
          fsm <= S_TAG0_INIT;
        end
        S_TAG0_INIT: fsm <= S_IT_MSG_CHK;   // one cycle for tag_buffer to land

        // ---------------------------------------------------- main loop
        S_IT_MSG_CHK: if (it < nblocks_m) begin
          // {Npub (bytes 0..11, LOW), 0-pad (bytes 12..19, HIGH)} ^ masks.
          perm_state <= ({64'd0, npub_r} ^ current_mask ^ next_mask);
          perm_iv <= 8'h75; perm_rnd <= 7'd0; perm_ret <= S_IT_MSG_XOR;
          fsm <= S_PERM_RUN;
        end else fsm <= S_IT_TAGC_CHK;

        S_IT_MSG_XOR: begin
          out_block <= (perm_state ^ current_mask ^ next_mask);
          inblk    <= 160'd0;
          coll_idx <= 5'd0;
          fsm <= S_IT_MSG_COLL;
        end
        S_IT_MSG_COLL: if (pdi_valid) begin
          inblk[ibit+:32] <=
              {pdi_data[7:0], pdi_data[15:8], pdi_data[23:16], pdi_data[31:24]};
          if (coll_idx == msg_words - 5'd1) fsm <= S_IT_MSG_CMB;
          else                              coll_idx <= coll_idx + 5'd1;
        end
        S_IT_MSG_CMB: begin
          out_block <= (out_block ^ inblk) & msg_mask;
          owc <= 4'd0;
          fsm <= S_IT_MSG_OUT;
        end
        S_IT_MSG_OUT: if (do_ready) begin
          // Also commit this word's bytes into out_mem for later get_c_block
          // lookback (written unconditionally; only bytes < msg_rsize are
          // ever read back, so writing the full masked word is safe).
          out_mem[obase]      <= out_block[obit+:8];
          out_mem[obase+6'd1] <= out_block[(obit+8'd8)+:8];
          out_mem[obase+6'd2] <= out_block[(obit+8'd16)+:8];
          out_mem[obase+6'd3] <= out_block[(obit+8'd24)+:8];
          if (owc == msg_words[3:0] - 4'd1)   // msg_words <= 5, fits in 4 bits
            fsm <= S_IT_TAGC_CHK;
          else
            owc <= owc + 4'd1;
        end

        S_IT_TAGC_CHK: if (it > 8'd0 && it <= nblocks_c) begin
          perm_state <= tagc_input;
          perm_iv <= 8'h75; perm_rnd <= 7'd0; perm_ret <= S_IT_TAGC_XOR;
          fsm <= S_PERM_RUN;
        end else fsm <= S_IT_TAGAD_CHK;
        S_IT_TAGC_XOR: begin
          tag_buffer <= tag_buffer ^ (perm_state ^ previous_mask ^ next_mask);
          fsm <= S_IT_TAGAD_CHK;
        end

        S_IT_TAGAD_CHK: if ((it + 8'd1) < nblocks_ad) begin
          perm_state <= tagad_input;
          perm_iv <= 8'h75; perm_rnd <= 7'd0; perm_ret <= S_IT_TAGAD_XOR;
          fsm <= S_PERM_RUN;
        end else fsm <= S_IT_NEXT;
        S_IT_TAGAD_XOR: begin
          tag_buffer <= tag_buffer ^ (perm_state ^ next_mask);
          fsm <= S_IT_NEXT;
        end

        S_IT_NEXT: begin
          previous_mask <= current_mask;
          current_mask  <= next_mask;
          if (it == nb_it - 8'd1) begin
            perm_state <= tag_buffer ^ expanded_key;
            perm_iv <= 8'h75; perm_rnd <= 7'd0; perm_ret <= S_FIN_XOR;
            fsm <= S_PERM_RUN;
          end else begin
            it  <= it + 8'd1;
            fsm <= S_IT_MSG_CHK;
          end
        end

        S_FIN_XOR: begin
          tag_buffer <= perm_state ^ expanded_key;
          wcnt <= 2'd0;
          fsm  <= decrypt_r ? S_PDI_THDR : S_DO_TAGHDR;
        end

        S_DO_TAGHDR: if (do_ready) begin wcnt <= 2'd0; fsm <= S_TAG_OUT; end
        S_TAG_OUT: if (do_ready) begin
          wcnt <= wcnt + 2'd1;
          if (wcnt == 2'd1) fsm <= S_OUT_STATUS;   // 8-byte tag = 2 words
        end

        S_PDI_THDR: if (pdi_valid) begin wcnt <= 2'd0; fsm <= S_TAG_IN; end
        S_TAG_IN: if (pdi_valid) begin
          tag_ok <= tag_ok & ({pdi_data[7:0],pdi_data[15:8],pdi_data[23:16],pdi_data[31:24]}
                               == tag_buffer[tbit+:32]);
          wcnt   <= wcnt + 2'd1;
          if (wcnt == 2'd1) fsm <= S_OUT_STATUS;
        end

        S_OUT_STATUS: if (do_ready) fsm <= S_IDLE;
        default: fsm <= S_IDLE;
      endcase
    end
  end
endmodule
