// PHOTON-Beetle-AEAD-ENC-128 (rate 128), implementing the CryptoCore-facing
// protocol of the NIST Lightweight Cryptography Hardware API (see
// tinyjambu_lwc.v's header for the full API citation; same ports, opcodes
// and segment-header format).
//
// WARNING: PHOTON-Beetle did NOT win the NIST LWC competition -- Ascon did.
// This core exists for hardware comparison against the Ascon cores in
// verilog/, not as a recommendation. Lint-checked (Verilator + Vivado) but
// NOT run against the official KAT vectors in simulation -- unlike
// tinyjambu_lwc.v. It is a careful transliteration, not a confirmed-correct
// one.
//
// Algorithm: transliterated from the official reference C in
// ../lwc-finalists/photon-beetle/ (encrypt.c, the Beetle-mode AEAD wrapper,
// + photon.c, the PHOTON256 permutation). Key = 16 B, Npub = 16 B, tag = 16 B.
// Rate = capacity = 128 bits (32-byte state), 12-round permutation.
//
// PHOTON256: an 8x8 grid of 4-bit nibbles (64 cells, 256 bits), not a
// word-oriented ARX design like the other cores here -- each round is
// AddKey (XOR a round constant into column 0), SubCell (4-bit S-box on
// every cell), ShiftRow (row i rotated LEFT by i), MixColumn (an 8x8 GF(2^4)
// matrix multiply per column, modulus x^4+x+1). This core represents the
// state as a flat 256-bit vector with byte k at bits [255-8k -: 8] (matching
// the reference's plain byte array -- see BYTE ORDER below) and extracts
// nibble n (row n/8, col n%8, matching PHOTON_Permutation's own unpacking)
// as the low nibble of byte n/2 when n is even, the high nibble when n is
// odd. field_mult() is a direct line-by-line transliteration of the
// reference's FieldMult(), including its habit of not masking the
// intermediate value to 4 bits after every shift-reduce step (the byte-wide
// `x`/`ret` there is deliberate: GF(2^4)-arithmetic garbage above bit 3
// never affects the low 4 bits and is discarded by the final `&0xF`,
// exactly as in the C) -- narrowing those intermediates to 4 bits would
// silently change the result on some inputs, so this core keeps them 8 bits
// wide too. One round runs per clock cycle, like every other multi-round
// permutation in this directory.
//
// BYTE ORDER: outside PHOTON_Permutation, the reference treats the 32-byte
// state as a plain byte array (memcpy/XOR by index, e.g. concatenate(State,
// Npub,16,Key,16)), with no bit-level reinterpretation -- so, as with
// isap_lwc.v, building each byte by straight concatenation of arriving PDI
// bytes (no bswap) already produces the right array, since the PDI bus's
// own "first byte in bits[31:24]" convention matches "array index order"
// directly.
//
// BEETLE MODE STRUCTURE (crypto_aead_encrypt/decrypt): state = Npub || Key
// (no initial permutation). A rare genuine special case: if AD and message
// are BOTH empty, the reference skips HASH/ENCorDEC entirely and instead
// XORs domain constant 1 into the state's last byte (top 3 bits, per
// XOR_const/LAST_THREE_BITS_OFFSET) before the final tag permutation --
// this is NOT equivalent to "just skip both phases", since the normal path
// would then apply no domain separation at all before TAG, so this core
// implements it as an explicit branch (S_EMPTY_CONST) rather than letting
// it fall out of the general per-phase logic. Otherwise: HASH(AD) if AD is
// non-empty (permute-then-absorb per 16-byte block, standard sponge, ending
// with ozs padding on a partial last block and an XOR_const(c0)); rho-based
// ENCorDEC(message) if the message is non-empty; then TAG (one more
// permute, top 16 bytes). c0/c1 select one of several domain constants
// based on which phases are used and whether AD/message length is an exact
// multiple of the rate (selectConst in the reference); this core computes
// them combinationally from ad_len/pt_len once both are known.
//
// RHO (rhoohr/ShuffleXOR): Beetle's distinguishing mixing step. Splits the
// state's rate half into two 8-byte halves (part1, part2); output bytes
// 0..7 = part2 XOR input, output bytes 8..15 = ROTR1(part1) XOR input,
// where ROTR1 is a 1-BIT rotate-right across the whole 8-byte half (bit 0
// of byte 0 wraps into bit 7 of byte 7) -- implemented here exactly as the
// reference's per-byte formula, not as a same-width scalar rotate (the two
// are NOT equivalent for a byte-array laid out MSB-first, since the carry
// direction differs; this was checked by hand). Critically, the STATE
// absorbs the PLAINTEXT value in both directions -- the raw input when
// encrypting, the just-computed output (recovered plaintext) when
// decrypting -- unlike the ciphertext-absorbing convention used by
// isap_lwc.v/elephant_lwc.v; this core computes plaintext_byte = encrypt ?
// in_byte : out_byte and XORs that into the state's rate.

module photonbeetle_lwc (
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

  // ------------------------------------------------------------- constants
  function [3:0] rc_tab;
    input [6:0] idx;   // row*12 + round
    case (idx)
        7'd0: rc_tab = 4'd1;
        7'd1: rc_tab = 4'd3;
        7'd2: rc_tab = 4'd7;
        7'd3: rc_tab = 4'd14;
        7'd4: rc_tab = 4'd13;
        7'd5: rc_tab = 4'd11;
        7'd6: rc_tab = 4'd6;
        7'd7: rc_tab = 4'd12;
        7'd8: rc_tab = 4'd9;
        7'd9: rc_tab = 4'd2;
        7'd10: rc_tab = 4'd5;
        7'd11: rc_tab = 4'd10;
        7'd12: rc_tab = 4'd0;
        7'd13: rc_tab = 4'd2;
        7'd14: rc_tab = 4'd6;
        7'd15: rc_tab = 4'd15;
        7'd16: rc_tab = 4'd12;
        7'd17: rc_tab = 4'd10;
        7'd18: rc_tab = 4'd7;
        7'd19: rc_tab = 4'd13;
        7'd20: rc_tab = 4'd8;
        7'd21: rc_tab = 4'd3;
        7'd22: rc_tab = 4'd4;
        7'd23: rc_tab = 4'd11;
        7'd24: rc_tab = 4'd2;
        7'd25: rc_tab = 4'd0;
        7'd26: rc_tab = 4'd4;
        7'd27: rc_tab = 4'd13;
        7'd28: rc_tab = 4'd14;
        7'd29: rc_tab = 4'd8;
        7'd30: rc_tab = 4'd5;
        7'd31: rc_tab = 4'd15;
        7'd32: rc_tab = 4'd10;
        7'd33: rc_tab = 4'd1;
        7'd34: rc_tab = 4'd6;
        7'd35: rc_tab = 4'd9;
        7'd36: rc_tab = 4'd6;
        7'd37: rc_tab = 4'd4;
        7'd38: rc_tab = 4'd0;
        7'd39: rc_tab = 4'd9;
        7'd40: rc_tab = 4'd10;
        7'd41: rc_tab = 4'd12;
        7'd42: rc_tab = 4'd1;
        7'd43: rc_tab = 4'd11;
        7'd44: rc_tab = 4'd14;
        7'd45: rc_tab = 4'd5;
        7'd46: rc_tab = 4'd2;
        7'd47: rc_tab = 4'd13;
        7'd48: rc_tab = 4'd14;
        7'd49: rc_tab = 4'd12;
        7'd50: rc_tab = 4'd8;
        7'd51: rc_tab = 4'd1;
        7'd52: rc_tab = 4'd2;
        7'd53: rc_tab = 4'd4;
        7'd54: rc_tab = 4'd9;
        7'd55: rc_tab = 4'd3;
        7'd56: rc_tab = 4'd6;
        7'd57: rc_tab = 4'd13;
        7'd58: rc_tab = 4'd10;
        7'd59: rc_tab = 4'd5;
        7'd60: rc_tab = 4'd15;
        7'd61: rc_tab = 4'd13;
        7'd62: rc_tab = 4'd9;
        7'd63: rc_tab = 4'd0;
        7'd64: rc_tab = 4'd3;
        7'd65: rc_tab = 4'd5;
        7'd66: rc_tab = 4'd8;
        7'd67: rc_tab = 4'd2;
        7'd68: rc_tab = 4'd7;
        7'd69: rc_tab = 4'd12;
        7'd70: rc_tab = 4'd11;
        7'd71: rc_tab = 4'd4;
        7'd72: rc_tab = 4'd13;
        7'd73: rc_tab = 4'd15;
        7'd74: rc_tab = 4'd11;
        7'd75: rc_tab = 4'd2;
        7'd76: rc_tab = 4'd1;
        7'd77: rc_tab = 4'd7;
        7'd78: rc_tab = 4'd10;
        7'd79: rc_tab = 4'd0;
        7'd80: rc_tab = 4'd5;
        7'd81: rc_tab = 4'd14;
        7'd82: rc_tab = 4'd9;
        7'd83: rc_tab = 4'd6;
        7'd84: rc_tab = 4'd9;
        7'd85: rc_tab = 4'd11;
        7'd86: rc_tab = 4'd15;
        7'd87: rc_tab = 4'd6;
        7'd88: rc_tab = 4'd5;
        7'd89: rc_tab = 4'd3;
        7'd90: rc_tab = 4'd14;
        7'd91: rc_tab = 4'd4;
        7'd92: rc_tab = 4'd1;
        7'd93: rc_tab = 4'd10;
        7'd94: rc_tab = 4'd13;
        7'd95: rc_tab = 4'd2;
      default: rc_tab = 4'd0;
    endcase
  endfunction

  function [3:0] mm_tab;
    input [5:0] idx;   // row*8 + col
    case (idx)
        6'd0: mm_tab = 4'd2;
        6'd1: mm_tab = 4'd4;
        6'd2: mm_tab = 4'd2;
        6'd3: mm_tab = 4'd11;
        6'd4: mm_tab = 4'd2;
        6'd5: mm_tab = 4'd8;
        6'd6: mm_tab = 4'd5;
        6'd7: mm_tab = 4'd6;
        6'd8: mm_tab = 4'd12;
        6'd9: mm_tab = 4'd9;
        6'd10: mm_tab = 4'd8;
        6'd11: mm_tab = 4'd13;
        6'd12: mm_tab = 4'd7;
        6'd13: mm_tab = 4'd7;
        6'd14: mm_tab = 4'd5;
        6'd15: mm_tab = 4'd2;
        6'd16: mm_tab = 4'd4;
        6'd17: mm_tab = 4'd4;
        6'd18: mm_tab = 4'd13;
        6'd19: mm_tab = 4'd13;
        6'd20: mm_tab = 4'd9;
        6'd21: mm_tab = 4'd4;
        6'd22: mm_tab = 4'd13;
        6'd23: mm_tab = 4'd9;
        6'd24: mm_tab = 4'd1;
        6'd25: mm_tab = 4'd6;
        6'd26: mm_tab = 4'd5;
        6'd27: mm_tab = 4'd1;
        6'd28: mm_tab = 4'd12;
        6'd29: mm_tab = 4'd13;
        6'd30: mm_tab = 4'd15;
        6'd31: mm_tab = 4'd14;
        6'd32: mm_tab = 4'd15;
        6'd33: mm_tab = 4'd12;
        6'd34: mm_tab = 4'd9;
        6'd35: mm_tab = 4'd13;
        6'd36: mm_tab = 4'd14;
        6'd37: mm_tab = 4'd5;
        6'd38: mm_tab = 4'd14;
        6'd39: mm_tab = 4'd13;
        6'd40: mm_tab = 4'd9;
        6'd41: mm_tab = 4'd14;
        6'd42: mm_tab = 4'd5;
        6'd43: mm_tab = 4'd15;
        6'd44: mm_tab = 4'd4;
        6'd45: mm_tab = 4'd12;
        6'd46: mm_tab = 4'd9;
        6'd47: mm_tab = 4'd6;
        6'd48: mm_tab = 4'd12;
        6'd49: mm_tab = 4'd2;
        6'd50: mm_tab = 4'd2;
        6'd51: mm_tab = 4'd10;
        6'd52: mm_tab = 4'd3;
        6'd53: mm_tab = 4'd1;
        6'd54: mm_tab = 4'd1;
        6'd55: mm_tab = 4'd14;
        6'd56: mm_tab = 4'd15;
        6'd57: mm_tab = 4'd1;
        6'd58: mm_tab = 4'd13;
        6'd59: mm_tab = 4'd10;
        6'd60: mm_tab = 4'd5;
        6'd61: mm_tab = 4'd10;
        6'd62: mm_tab = 4'd2;
        6'd63: mm_tab = 4'd3;
      default: mm_tab = 4'd0;
    endcase
  endfunction

  function [3:0] sbox4;
    input [3:0] v;
    case (v)
        4'd0: sbox4 = 4'd12;
        4'd1: sbox4 = 4'd5;
        4'd2: sbox4 = 4'd6;
        4'd3: sbox4 = 4'd11;
        4'd4: sbox4 = 4'd9;
        4'd5: sbox4 = 4'd0;
        4'd6: sbox4 = 4'd10;
        4'd7: sbox4 = 4'd13;
        4'd8: sbox4 = 4'd3;
        4'd9: sbox4 = 4'd14;
        4'd10: sbox4 = 4'd15;
        4'd11: sbox4 = 4'd8;
        4'd12: sbox4 = 4'd4;
        4'd13: sbox4 = 4'd7;
        4'd14: sbox4 = 4'd1;
        4'd15: sbox4 = 4'd2;
      default: sbox4 = 4'd0;
    endcase
  endfunction

  // GF(2^4) multiply, modulus x^4+x+1 (ReductionPoly=0x3 = the value x^4
  // reduces to). x/ret kept 8 bits wide, matching the reference's `byte`
  // type -- see file header (BYTE ORDER / PHOTON256 notes) for why this
  // must not be narrowed to 4 bits.
  function [3:0] field_mult;
    input [3:0] a, b;
    reg [7:0] x, ret;
    integer i;
    begin
      x = {4'd0, a}; ret = 8'd0;
      for (i = 0; i < 4; i = i + 1) begin
        if (b[i]) ret = ret ^ x;
        if (x[3]) x = (x << 1) ^ 8'h03;
        else      x = x << 1;
      end
      field_mult = ret[3:0];
    end
  endfunction

  // One PHOTON256 round: AddKey, SubCell, ShiftRow, MixColumn. `s` is the
  // full 256-bit state (byte k at s[255-8k -: 8]); nibble n = row n/8, col
  // n%8, packed two-per-byte (n even -> low nibble of byte n/2, n odd ->
  // high nibble).
  function [255:0] photon_round;
    input [255:0] s;
    input [3:0]   rnd;
    reg [3:0] nib    [0:63];
    reg [3:0] shifted[0:63];
    reg [3:0] mixed  [0:63];
    integer   n, row, col, k;
    reg [7:0] byteval;
    reg [3:0] sum;
    reg [255:0] o;
    begin
      // unpack
      for (n = 0; n < 64; n = n + 1) begin
        byteval = s[255 - 8*(n/2) -: 8];
        nib[n] = (n % 2 == 0) ? byteval[3:0] : byteval[7:4];
      end
      // AddKey: cell(row,0) = cell(row*8) gets RC[row][rnd] XORed in
      for (row = 0; row < 8; row = row + 1)
        nib[row*8] = nib[row*8] ^ rc_tab({row[2:0], rnd});
      // SubCell
      for (n = 0; n < 64; n = n + 1)
        nib[n] = sbox4(nib[n]);
      // ShiftRow: new[row][col] = old[row][(col+row)%8]
      for (row = 0; row < 8; row = row + 1)
        for (col = 0; col < 8; col = col + 1)
          shifted[row*8+col] = nib[row*8 + ((col+row) % 8)];
      // MixColumn: new[row][col] = XOR_k field_mult(MM[row][k], shifted[k][col])
      for (col = 0; col < 8; col = col + 1)
        for (row = 0; row < 8; row = row + 1) begin
          sum = 4'd0;
          for (k = 0; k < 8; k = k + 1)
            sum = sum ^ field_mult(mm_tab({row[2:0], k[2:0]}), shifted[k*8+col]);
          mixed[row*8+col] = sum;
        end
      // repack
      o = 256'd0;
      for (n = 0; n < 64; n = n + 1) begin
        if (n % 2 == 0) o[255 - 8*(n/2) -: 4]     = mixed[n];
        else            o[255 - 8*(n/2) - 4 -: 4] = mixed[n];
      end
      photon_round = o;
    end
  endfunction

  // ROTR1 across an 8-byte half: out[i] = (in[i]>>1) | (in[(i+1)%8][0]<<7),
  // per the reference's byte-array formula (NOT a same-width scalar rotate
  // -- see file header).
  function [63:0] rotr1_64;
    input [63:0] p;   // byte i at p[63-8i -: 8]
    reg [7:0] b [0:7];
    reg [7:0] o [0:7];
    integer i;
    begin
      for (i = 0; i < 8; i = i + 1) b[i] = p[63-8*i -: 8];
      for (i = 0; i < 7; i = i + 1) o[i] = {b[i][0], 7'b0} | (b[i] >> 1);
      o[7] = {b[0][0], 7'b0} | (b[7] >> 1);
      rotr1_64 = {o[0], o[1], o[2], o[3], o[4], o[5], o[6], o[7]};
    end
  endfunction

  // ------------------------------------------------------------ state regs
  reg [127:0] key_r;
  reg [127:0] npub_r;
  reg [15:0]  ad_len, pt_len;

  reg [255:0] state;
  reg [255:0] perm_state;
  reg [3:0]   rnd_idx;
  reg [5:0]   perm_ret;

  reg [127:0] blk_in;           // collected 16-byte AD/message block
  reg [127:0] out_blk;          // computed output block (message phase)
  reg [1:0]   wsel;             // word-within-block index while collecting
  reg [15:0]  ad_i, pt_i;       // bytes absorbed so far in this phase
  reg         pt_last_blk_r;    // latched is-last-block, for S_PT_OUT (see below)
  reg [1:0]   pt_coll_words_r;  // latched word count, for S_PT_OUT
  reg [1:0]   owc;              // output word counter (message phase)

  reg [1:0]   wcnt;             // small word counter (key/npub/tag)
  reg         decrypt_r, tag_ok;

  // Per-phase block sizing. ad_i/pt_i only change in S_AD_ABSORB/S_PT_RHO,
  // so these wires stay valid (all derived from the SAME stable ad_i/pt_i)
  // across a whole block's collect-permute-absorb journey; no register
  // holds a length/last-block flag that could go stale relative to a
  // same-cycle update of ad_i/pt_i (the bug that an earlier draft of this
  // file had). The one exception is S_PT_OUT, reached one cycle AFTER
  // pt_i has already advanced to the NEXT block -- pt_last_blk_r/
  // pt_coll_words_r are latched in S_PT_RHO (using the still-old pt_i) for
  // that one case.
  wire [15:0] ad_rem     = ad_len - ad_i;
  wire [4:0]  ad_eff_len = (ad_rem >= 16'd16) ? 5'd16 : ad_rem[4:0];   // 1..16
  wire        ad_is_last = (ad_rem <= 16'd16);
  wire [4:0]  ad_coll_words5 = (ad_eff_len + 5'd3) >> 2;                // 1..4
  wire [2:0]  ad_coll_words = ad_coll_words5[2:0];

  wire [15:0] pt_rem     = pt_len - pt_i;
  wire [4:0]  pt_eff_len = (pt_rem >= 16'd16) ? 5'd16 : pt_rem[4:0];
  wire        pt_is_last = (pt_rem <= 16'd16);
  wire [4:0]  pt_coll_words5 = (pt_eff_len + 5'd3) >> 2;
  wire [2:0]  pt_coll_words = pt_coll_words5[2:0];

  // c0/c1 domain constants (selectConst in the reference), valid once
  // ad_len/pt_len are both known.
  wire [2:0] c0 = ( (pt_len != 16'd0) &&  (ad_len[3:0] == 4'd0)) ? 3'd1 :
                  ( (pt_len != 16'd0)                           ) ? 3'd2 :
                  (                        (ad_len[3:0] == 4'd0)) ? 3'd3 : 3'd4;
  wire [2:0] c1 = ( (ad_len != 16'd0) &&  (pt_len[3:0] == 4'd0)) ? 3'd1 :
                  ( (ad_len != 16'd0)                           ) ? 3'd2 :
                  (                        (pt_len[3:0] == 4'd0)) ? 3'd5 : 3'd6;

  // -------------------------------------------------------- rho / masking
  wire [63:0] part1 = state[255:192];      // state rate bytes 0..7
  wire [63:0] part2 = state[191:128];      // state rate bytes 8..15
  wire [63:0] part1_rotr = rotr1_64(part1);

  wire [7:0] blk_byte [0:15];
  genvar gi;
  generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : g_blk_byte
      assign blk_byte[gi] = blk_in[127-8*gi -: 8];
    end
  endgenerate

  wire [7:0] rho_out [0:15];
  generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : g_rho_lo
      assign rho_out[gi] = part2[63-8*gi -: 8] ^ blk_byte[gi];
    end
    for (gi = 8; gi < 16; gi = gi + 1) begin : g_rho_hi
      assign rho_out[gi] = part1_rotr[63-8*(gi-8) -: 8] ^ blk_byte[gi];
    end
  endgenerate

  wire [7:0] plain_byte [0:15];
  generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : g_plain
      assign plain_byte[gi] = decrypt_r ? rho_out[gi] : blk_byte[gi];
    end
  endgenerate

  wire [127:0] out_blk_next = {rho_out[0],rho_out[1],rho_out[2],rho_out[3],
                                rho_out[4],rho_out[5],rho_out[6],rho_out[7],
                                rho_out[8],rho_out[9],rho_out[10],rho_out[11],
                                rho_out[12],rho_out[13],rho_out[14],rho_out[15]};

  // rate-half XOR-absorb masks for AD (HASH: absorb blk_in directly) and
  // message (ENCorDEC: absorb plain_byte), each covering only *_eff_len
  // bytes, plus the ozs pad bit (0x01) at byte position *_eff_len when
  // that is < 16 (a partial block).
  reg [127:0] ad_absorb_mask, pt_absorb_mask;
  integer bi;
  always @* begin
    ad_absorb_mask = 128'd0;
    pt_absorb_mask = 128'd0;
    for (bi = 0; bi < 16; bi = bi + 1) begin
      if (bi < {27'd0, ad_eff_len}) ad_absorb_mask[127-8*bi -: 8] = blk_byte[bi];
      else if (bi == {27'd0, ad_eff_len} && ad_eff_len != 5'd16) ad_absorb_mask[127-8*bi -: 8] = 8'h01;

      if (bi < {27'd0, pt_eff_len}) pt_absorb_mask[127-8*bi -: 8] = plain_byte[bi];
      else if (bi == {27'd0, pt_eff_len} && pt_eff_len != 5'd16) pt_absorb_mask[127-8*bi -: 8] = 8'h01;
    end
  end

  localparam [5:0]
    S_IDLE       = 6'd0,  S_SDI_HDR    = 6'd1,  S_SDI_KEY   = 6'd2,
    S_PDI_OP     = 6'd3,  S_PDI_NHDR   = 6'd4,  S_PDI_NDATA = 6'd5,
    S_PDI_AHDR   = 6'd6,
    S_AD_WORD    = 6'd7,  S_AD_PERM    = 6'd8,  S_PERM_RUN  = 6'd9,
    S_AD_PERM_DN = 6'd10, S_AD_ABSORB  = 6'd11,
    S_PDI_PHDR   = 6'd12, S_DO_PTHDR   = 6'd13, S_EMPTY_CONST = 6'd14,
    S_PT_WORD    = 6'd15, S_PT_PERM    = 6'd16, S_PT_PERM_DN  = 6'd17,
    S_PT_RHO     = 6'd18, S_PT_OUT     = 6'd19,
    S_TAG_PERM   = 6'd20, S_TAG_PERM_DN= 6'd21,
    S_DO_TAGHDR  = 6'd22, S_TAG_OUT    = 6'd23,
    S_PDI_THDR   = 6'd24, S_TAG_IN     = 6'd25,
    S_OUT_STATUS = 6'd26;

  reg [5:0] fsm;

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

  wire [31:0] out_word = out_blk[127-32*{30'd0,owc} -: 32];
  wire [31:0] tag_word = state[255-32*{30'd0,wcnt} -: 32];

  assign do_data =
      (fsm == S_DO_PTHDR)  ? {(decrypt_r ? SEGT_PT : SEGT_CT), 1'b0, 1'b0,
                              1'b1, decrypt_r, 8'd0, pt_len} :
      (fsm == S_PT_OUT)    ? out_word :
      (fsm == S_DO_TAGHDR) ? {SEGT_TAG, 1'b0, 1'b0, 1'b1, 1'b1, 8'd0, 16'd16} :
      (fsm == S_TAG_OUT)   ? tag_word :
      (fsm == S_OUT_STATUS)? {(decrypt_r ? (tag_ok ? ST_SUCCESS : ST_FAILURE)
                                         : ST_SUCCESS), 28'd0} :
      32'd0;

  // ------------------------------------------------------------------- FSM
  always @(posedge clk) begin
    if (rst) begin
      fsm <= S_IDLE; decrypt_r <= 1'b0; tag_ok <= 1'b1;
      wcnt <= 2'd0; wsel <= 2'd0; owc <= 2'd0;
      ad_i <= 16'd0; pt_i <= 16'd0;
      pt_last_blk_r <= 1'b0; pt_coll_words_r <= 2'd0;
      key_r <= 128'd0; npub_r <= 128'd0; ad_len <= 16'd0; pt_len <= 16'd0;
      state <= 256'd0; perm_state <= 256'd0; rnd_idx <= 4'd0; perm_ret <= 6'd0;
      blk_in <= 128'd0; out_blk <= 128'd0;
    end else begin
      case (fsm)
        S_IDLE: begin
          if (sdi_valid)      fsm <= S_SDI_HDR;
          else if (pdi_valid) fsm <= S_PDI_OP;
        end
        S_SDI_HDR: if (sdi_valid) begin wcnt <= 2'd0; fsm <= S_SDI_KEY; end
        S_SDI_KEY: if (sdi_valid) begin
          key_r <= {key_r[95:0], sdi_data};
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
            state <= {npub_r, key_r};   // concatenate(State,N,16,K,16), no permute
            fsm <= S_PDI_AHDR;
          end
        end

        S_PDI_AHDR: if (pdi_valid) begin
          ad_len <= pdi_data[15:0];
          ad_i   <= 16'd0;
          wsel   <= 2'd0;
          fsm <= (pdi_data[15:0] == 16'd0) ? S_PDI_PHDR : S_AD_WORD;
        end
        // ad_coll_words/ad_eff_len/ad_is_last are pure combinational
        // functions of ad_i/ad_len, which do not change again until
        // S_AD_ABSORB -- so they stay valid for the whole collect loop
        // below without needing to be latched.
        S_AD_WORD: if (pdi_valid) begin
          blk_in <= {blk_in[95:0], pdi_data};
          if (wsel == ad_coll_words[1:0] - 2'd1) begin
            wsel <= 2'd0;
            perm_state <= state; rnd_idx <= 4'd0; perm_ret <= S_AD_PERM_DN;
            fsm <= S_PERM_RUN;
          end else wsel <= wsel + 2'd1;
        end
        S_PERM_RUN: begin
          perm_state <= photon_round(perm_state, rnd_idx);
          if (rnd_idx == 4'd11) fsm <= perm_ret;
          else                  rnd_idx <= rnd_idx + 4'd1;
        end
        S_AD_PERM_DN: begin
          state <= perm_state;
          fsm <= S_AD_ABSORB;
        end
        S_AD_ABSORB: begin
          state[127:0] <= state[127:0] ^ ad_absorb_mask;
          ad_i <= ad_i + {11'd0, ad_eff_len};
          wsel <= 2'd0;
          if (ad_is_last) begin
            state[7:0] <= state[7:0] ^ ad_absorb_mask[7:0] ^ {c0, 5'b0};
            fsm <= S_PDI_PHDR;
          end else begin
            fsm <= S_AD_WORD;
          end
        end

        S_PDI_PHDR: if (pdi_valid) begin
          pt_len <= pdi_data[15:0];
          pt_i   <= 16'd0;
          wsel   <= 2'd0;
          fsm    <= S_DO_PTHDR;
        end
        S_DO_PTHDR: if (do_ready) begin
          if (ad_len == 16'd0 && pt_len == 16'd0) fsm <= S_EMPTY_CONST;
          else if (pt_len == 16'd0)                fsm <= S_TAG_PERM;
          else                                      fsm <= S_PT_WORD;
        end
        S_EMPTY_CONST: begin
          state[7:0] <= state[7:0] ^ {3'd1, 5'b0};
          fsm <= S_TAG_PERM;
        end

        // Same stability argument as S_AD_WORD: pt_i is unchanged from
        // S_PDI_PHDR/S_PT_OUT's loop-back through to S_PT_RHO, so
        // pt_coll_words/pt_eff_len/pt_is_last stay valid throughout.
        S_PT_WORD: if (pdi_valid) begin
          blk_in <= {blk_in[95:0], pdi_data};
          if (wsel == pt_coll_words[1:0] - 2'd1) begin
            wsel <= 2'd0;
            perm_state <= state; rnd_idx <= 4'd0; perm_ret <= S_PT_PERM_DN;
            fsm <= S_PERM_RUN;
          end else wsel <= wsel + 2'd1;
        end
        S_PT_PERM_DN: begin
          state <= perm_state;
          fsm <= S_PT_RHO;
        end
        S_PT_RHO: begin
          out_blk <= out_blk_next;
          owc <= 2'd0;
          state[127:0] <= state[127:0] ^ pt_absorb_mask;
          pt_i <= pt_i + {11'd0, pt_eff_len};
          wsel <= 2'd0;
          // Latch this block's last-flag/word-count for S_PT_OUT, reached
          // one cycle after pt_i (above) has already advanced -- see the
          // file-header note by their declarations.
          pt_last_blk_r   <= pt_is_last;
          pt_coll_words_r <= pt_coll_words[1:0];
          if (pt_is_last)
            state[7:0] <= state[7:0] ^ pt_absorb_mask[7:0] ^ {c1, 5'b0};
          fsm <= S_PT_OUT;
        end
        S_PT_OUT: if (do_ready) begin
          if (owc == pt_coll_words_r - 2'd1) begin
            fsm <= pt_last_blk_r ? S_TAG_PERM : S_PT_WORD;
          end else owc <= owc + 2'd1;
        end

        S_TAG_PERM: begin
          perm_state <= state; rnd_idx <= 4'd0; perm_ret <= S_TAG_PERM_DN;
          fsm <= S_PERM_RUN;
        end
        S_TAG_PERM_DN: begin
          state <= perm_state;
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
