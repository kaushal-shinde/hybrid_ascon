// Romulus-N, implementing the CryptoCore-facing protocol of the NIST
// Lightweight Cryptography Hardware API (see tinyjambu_lwc.v's header for
// the full API citation; same ports, opcodes and segment-header format).
//
// WARNING: Romulus did NOT win the NIST LWC competition -- Ascon did. This
// core exists for hardware comparison against ascon_aead128.v (this directory),
// not as a recommendation. Lint-checked (Verilator + Vivado) but NOT run
// against the official KAT vectors in simulation -- unlike tinyjambu_lwc.v.
// It is a careful transliteration, not a confirmed-correct one.
//
// Algorithm: transliterated from the official reference C in
// ../lwc-finalists/romulus/ (romulus_n_reference.c, the AEAD mode, +
// skinny_reference.c, the SKINNY-128-384+ tweakable block cipher). Key = 16
// B, Npub = 16 B, tag = 16 B. Romulus-N re-keys the underlying TBC after
// EVERY absorbed block (a deliberate leakage-resilience design choice, like
// ISAP's expensive re-keying, not an artifact of this transliteration).
//
// SKINNY-128-384+: a 4x4-byte (128-bit) state plus THREE independent 4x4-byte
// (128-bit) "tweakey" cells (TK1/TK2/TK3, together the 384-bit tweakey), 40
// rounds. Each round: SubCell8 (256-entry byte S-box, sbox8 below, verbatim
// from skinny_reference.c's sbox_8[]), AddConstants (a 6-bit round-constant
// table, rc40 below, XORed into 3 specific state bytes), AddKey (XOR the
// three tweakey cells' TOP TWO ROWS into the state's top two rows, THEN
// permute+update all three tweakey cells for the NEXT round), ShiftRows
// (row i rotated right by i), MixColumn (a small XOR-only 4x4 matrix, unlike
// PHOTON's GF(2^4) MixColumn -- this cipher needs no field arithmetic at
// all). State/tweakey cells are represented as flat 128-bit vectors with
// byte idx (0..15, row idx/4, col idx%4, matching the reference's
// state[i>>2][i&0x3] indexing) at bits [127-8*idx -: 8] -- byte 0 in the
// MSB, matching pad_block's own indexing below. CORRECTION (found via
// KAT, wrong from the very first record): this file originally assumed
// the LWC bus itself delivers bytes MSB-first per word and needed no
// swap -- it doesn't. The bus is little-endian (byte 0 in pdi_data[7:0]),
// confirmed by tinyjambu_lwc.v/xoodyak_lwc.v/giftcofb_lwc.v's own KAT
// runs; bswap32() below converts at every bus-facing load and output
// site (key_r, npub_r, blk_in, out_word, tag_word).
//
// TWEAKEY SCHEDULE: each round, ALL THREE cells go through the same fixed
// byte permutation (tweakey_perm, from TWEAKEY_P[] -- new_cell[idx] =
// old_cell[TWEAKEY_P[idx]], a pure wire shuffle); TK1 (built fresh from CNT/
// D every block_cipher call, see below) is then left alone, while TK2 and
// TK3's rows 0-1 (byte indices 0..7) each go through their OWN distinct
// 1-bit LFSR (lfsr_tk2_byte / lfsr_tk3_byte below, transliterated directly
// from AddKey's two `if(k==1)`/`else if(k==2)` branches) -- rows 2-3 of TK2/
// TK3 get only the permutation, matching the reference's `i<=1` guard on
// the LFSR loop.
//
// TWEAKEY COMPOSITION (compose_tweakey/block_cipher): every TBC call in this
// mode builds a fresh 384-bit tweakey from THREE pieces: TK1 = {CNT (7
// bytes), D (1 domain-separation byte), 8 zero bytes}; TK2 = a 16-byte
// "tweak" T that differs by call site (an AD block, or the nonce); TK3 =
// the 16-byte key, unchanged throughout. This core keeps one shared 40-round
// round-transform engine (S_TBC_SETUP/S_TBC_ROUND/S_TBC_DONE, one round per
// cycle like every other multi-round permutation in this directory),
// composes the tweakey fresh at each call site via `tbc_T`/`tbc_D`, and
// resumes at `tbc_ret` once done.
//
// CNT: a 56-bit LFSR (GF(2^56), modulus x^56+x^7+x^4+x^2+1) that advances by
// one step before/after most block-processing steps -- see
// romulus_n_reference.c's lfsr_gf56(). Represented here as cnt[55:0] with
// byte i (0..6) at cnt[8*i+7 -: 8] (LITTLE-endian byte packing -- this is a
// self-contained counter, and its own reference implementation treats it
// that way internally; it converts to TK1's array-index byte order only at
// the point TK1 is built, cnt byte i -> TK1 byte i).
//
// MODE STRUCTURE: AD is absorbed in PAIRS of up to-16-byte blocks -- an
// "odd" block (rho_ad: simple pad-then-XOR into the state, no TBC call) and,
// if AD remains, an "even" block (used as the TWEAK of a full TBC call,
// domain byte 0x08) -- with one CNT step after each. After the LAST such
// pair (tracked here by latching ad_final_D_r/ad_is_last_r from the AD
// remaining-byte count at the START of each pair, since that count is what
// the reference's outer while-loop compares against -- an earlier draft of
// this file read a not-yet-updated register one cycle too late here and was
// corrected), one more CNT step and a TBC call keyed with Npub as the tweak
// (domain 0x18 if the total AD was an exact multiple of 16, else 0x1a)
// finishes AD processing; CNT is then reset. The message is then absorbed
// ONE 16-byte block at a time, each block: computing a per-byte keystream
// G(s) (g8a_byte below, a fixed per-byte bit permutation -- see the
// reference's g8A(), NOT a permutation call), XORing it with the input to
// produce the output (the SAME formula both directions, matching every
// other duplex-style core here), absorbing the resulting PLAINTEXT (raw
// input when encrypting, the just-recovered plaintext when decrypting) into
// the state, then a CNT step and a full TBC call (Npub as tweak; domain
// 0x04/0x14/0x15 for a normal/exact-final/short-final block) before the
// next block. An empty AD or empty message is its own direct CNT-step +
// TBC(Npub) call, matching the reference's `adlen==0`/`mlen==0` branches.
// Finally G(s) once more (no TBC call) yields the tag.

module romulus_n_lwc (
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
  function [7:0] sbox8;
    input [7:0] v;
    case (v)
        8'd0: sbox8 = 8'h65;
        8'd1: sbox8 = 8'h4c;
        8'd2: sbox8 = 8'h6a;
        8'd3: sbox8 = 8'h42;
        8'd4: sbox8 = 8'h4b;
        8'd5: sbox8 = 8'h63;
        8'd6: sbox8 = 8'h43;
        8'd7: sbox8 = 8'h6b;
        8'd8: sbox8 = 8'h55;
        8'd9: sbox8 = 8'h75;
        8'd10: sbox8 = 8'h5a;
        8'd11: sbox8 = 8'h7a;
        8'd12: sbox8 = 8'h53;
        8'd13: sbox8 = 8'h73;
        8'd14: sbox8 = 8'h5b;
        8'd15: sbox8 = 8'h7b;
        8'd16: sbox8 = 8'h35;
        8'd17: sbox8 = 8'h8c;
        8'd18: sbox8 = 8'h3a;
        8'd19: sbox8 = 8'h81;
        8'd20: sbox8 = 8'h89;
        8'd21: sbox8 = 8'h33;
        8'd22: sbox8 = 8'h80;
        8'd23: sbox8 = 8'h3b;
        8'd24: sbox8 = 8'h95;
        8'd25: sbox8 = 8'h25;
        8'd26: sbox8 = 8'h98;
        8'd27: sbox8 = 8'h2a;
        8'd28: sbox8 = 8'h90;
        8'd29: sbox8 = 8'h23;
        8'd30: sbox8 = 8'h99;
        8'd31: sbox8 = 8'h2b;
        8'd32: sbox8 = 8'he5;
        8'd33: sbox8 = 8'hcc;
        8'd34: sbox8 = 8'he8;
        8'd35: sbox8 = 8'hc1;
        8'd36: sbox8 = 8'hc9;
        8'd37: sbox8 = 8'he0;
        8'd38: sbox8 = 8'hc0;
        8'd39: sbox8 = 8'he9;
        8'd40: sbox8 = 8'hd5;
        8'd41: sbox8 = 8'hf5;
        8'd42: sbox8 = 8'hd8;
        8'd43: sbox8 = 8'hf8;
        8'd44: sbox8 = 8'hd0;
        8'd45: sbox8 = 8'hf0;
        8'd46: sbox8 = 8'hd9;
        8'd47: sbox8 = 8'hf9;
        8'd48: sbox8 = 8'ha5;
        8'd49: sbox8 = 8'h1c;
        8'd50: sbox8 = 8'ha8;
        8'd51: sbox8 = 8'h12;
        8'd52: sbox8 = 8'h1b;
        8'd53: sbox8 = 8'ha0;
        8'd54: sbox8 = 8'h13;
        8'd55: sbox8 = 8'ha9;
        8'd56: sbox8 = 8'h05;
        8'd57: sbox8 = 8'hb5;
        8'd58: sbox8 = 8'h0a;
        8'd59: sbox8 = 8'hb8;
        8'd60: sbox8 = 8'h03;
        8'd61: sbox8 = 8'hb0;
        8'd62: sbox8 = 8'h0b;
        8'd63: sbox8 = 8'hb9;
        8'd64: sbox8 = 8'h32;
        8'd65: sbox8 = 8'h88;
        8'd66: sbox8 = 8'h3c;
        8'd67: sbox8 = 8'h85;
        8'd68: sbox8 = 8'h8d;
        8'd69: sbox8 = 8'h34;
        8'd70: sbox8 = 8'h84;
        8'd71: sbox8 = 8'h3d;
        8'd72: sbox8 = 8'h91;
        8'd73: sbox8 = 8'h22;
        8'd74: sbox8 = 8'h9c;
        8'd75: sbox8 = 8'h2c;
        8'd76: sbox8 = 8'h94;
        8'd77: sbox8 = 8'h24;
        8'd78: sbox8 = 8'h9d;
        8'd79: sbox8 = 8'h2d;
        8'd80: sbox8 = 8'h62;
        8'd81: sbox8 = 8'h4a;
        8'd82: sbox8 = 8'h6c;
        8'd83: sbox8 = 8'h45;
        8'd84: sbox8 = 8'h4d;
        8'd85: sbox8 = 8'h64;
        8'd86: sbox8 = 8'h44;
        8'd87: sbox8 = 8'h6d;
        8'd88: sbox8 = 8'h52;
        8'd89: sbox8 = 8'h72;
        8'd90: sbox8 = 8'h5c;
        8'd91: sbox8 = 8'h7c;
        8'd92: sbox8 = 8'h54;
        8'd93: sbox8 = 8'h74;
        8'd94: sbox8 = 8'h5d;
        8'd95: sbox8 = 8'h7d;
        8'd96: sbox8 = 8'ha1;
        8'd97: sbox8 = 8'h1a;
        8'd98: sbox8 = 8'hac;
        8'd99: sbox8 = 8'h15;
        8'd100: sbox8 = 8'h1d;
        8'd101: sbox8 = 8'ha4;
        8'd102: sbox8 = 8'h14;
        8'd103: sbox8 = 8'had;
        8'd104: sbox8 = 8'h02;
        8'd105: sbox8 = 8'hb1;
        8'd106: sbox8 = 8'h0c;
        8'd107: sbox8 = 8'hbc;
        8'd108: sbox8 = 8'h04;
        8'd109: sbox8 = 8'hb4;
        8'd110: sbox8 = 8'h0d;
        8'd111: sbox8 = 8'hbd;
        8'd112: sbox8 = 8'he1;
        8'd113: sbox8 = 8'hc8;
        8'd114: sbox8 = 8'hec;
        8'd115: sbox8 = 8'hc5;
        8'd116: sbox8 = 8'hcd;
        8'd117: sbox8 = 8'he4;
        8'd118: sbox8 = 8'hc4;
        8'd119: sbox8 = 8'hed;
        8'd120: sbox8 = 8'hd1;
        8'd121: sbox8 = 8'hf1;
        8'd122: sbox8 = 8'hdc;
        8'd123: sbox8 = 8'hfc;
        8'd124: sbox8 = 8'hd4;
        8'd125: sbox8 = 8'hf4;
        8'd126: sbox8 = 8'hdd;
        8'd127: sbox8 = 8'hfd;
        8'd128: sbox8 = 8'h36;
        8'd129: sbox8 = 8'h8e;
        8'd130: sbox8 = 8'h38;
        8'd131: sbox8 = 8'h82;
        8'd132: sbox8 = 8'h8b;
        8'd133: sbox8 = 8'h30;
        8'd134: sbox8 = 8'h83;
        8'd135: sbox8 = 8'h39;
        8'd136: sbox8 = 8'h96;
        8'd137: sbox8 = 8'h26;
        8'd138: sbox8 = 8'h9a;
        8'd139: sbox8 = 8'h28;
        8'd140: sbox8 = 8'h93;
        8'd141: sbox8 = 8'h20;
        8'd142: sbox8 = 8'h9b;
        8'd143: sbox8 = 8'h29;
        8'd144: sbox8 = 8'h66;
        8'd145: sbox8 = 8'h4e;
        8'd146: sbox8 = 8'h68;
        8'd147: sbox8 = 8'h41;
        8'd148: sbox8 = 8'h49;
        8'd149: sbox8 = 8'h60;
        8'd150: sbox8 = 8'h40;
        8'd151: sbox8 = 8'h69;
        8'd152: sbox8 = 8'h56;
        8'd153: sbox8 = 8'h76;
        8'd154: sbox8 = 8'h58;
        8'd155: sbox8 = 8'h78;
        8'd156: sbox8 = 8'h50;
        8'd157: sbox8 = 8'h70;
        8'd158: sbox8 = 8'h59;
        8'd159: sbox8 = 8'h79;
        8'd160: sbox8 = 8'ha6;
        8'd161: sbox8 = 8'h1e;
        8'd162: sbox8 = 8'haa;
        8'd163: sbox8 = 8'h11;
        8'd164: sbox8 = 8'h19;
        8'd165: sbox8 = 8'ha3;
        8'd166: sbox8 = 8'h10;
        8'd167: sbox8 = 8'hab;
        8'd168: sbox8 = 8'h06;
        8'd169: sbox8 = 8'hb6;
        8'd170: sbox8 = 8'h08;
        8'd171: sbox8 = 8'hba;
        8'd172: sbox8 = 8'h00;
        8'd173: sbox8 = 8'hb3;
        8'd174: sbox8 = 8'h09;
        8'd175: sbox8 = 8'hbb;
        8'd176: sbox8 = 8'he6;
        8'd177: sbox8 = 8'hce;
        8'd178: sbox8 = 8'hea;
        8'd179: sbox8 = 8'hc2;
        8'd180: sbox8 = 8'hcb;
        8'd181: sbox8 = 8'he3;
        8'd182: sbox8 = 8'hc3;
        8'd183: sbox8 = 8'heb;
        8'd184: sbox8 = 8'hd6;
        8'd185: sbox8 = 8'hf6;
        8'd186: sbox8 = 8'hda;
        8'd187: sbox8 = 8'hfa;
        8'd188: sbox8 = 8'hd3;
        8'd189: sbox8 = 8'hf3;
        8'd190: sbox8 = 8'hdb;
        8'd191: sbox8 = 8'hfb;
        8'd192: sbox8 = 8'h31;
        8'd193: sbox8 = 8'h8a;
        8'd194: sbox8 = 8'h3e;
        8'd195: sbox8 = 8'h86;
        8'd196: sbox8 = 8'h8f;
        8'd197: sbox8 = 8'h37;
        8'd198: sbox8 = 8'h87;
        8'd199: sbox8 = 8'h3f;
        8'd200: sbox8 = 8'h92;
        8'd201: sbox8 = 8'h21;
        8'd202: sbox8 = 8'h9e;
        8'd203: sbox8 = 8'h2e;
        8'd204: sbox8 = 8'h97;
        8'd205: sbox8 = 8'h27;
        8'd206: sbox8 = 8'h9f;
        8'd207: sbox8 = 8'h2f;
        8'd208: sbox8 = 8'h61;
        8'd209: sbox8 = 8'h48;
        8'd210: sbox8 = 8'h6e;
        8'd211: sbox8 = 8'h46;
        8'd212: sbox8 = 8'h4f;
        8'd213: sbox8 = 8'h67;
        8'd214: sbox8 = 8'h47;
        8'd215: sbox8 = 8'h6f;
        8'd216: sbox8 = 8'h51;
        8'd217: sbox8 = 8'h71;
        8'd218: sbox8 = 8'h5e;
        8'd219: sbox8 = 8'h7e;
        8'd220: sbox8 = 8'h57;
        8'd221: sbox8 = 8'h77;
        8'd222: sbox8 = 8'h5f;
        8'd223: sbox8 = 8'h7f;
        8'd224: sbox8 = 8'ha2;
        8'd225: sbox8 = 8'h18;
        8'd226: sbox8 = 8'hae;
        8'd227: sbox8 = 8'h16;
        8'd228: sbox8 = 8'h1f;
        8'd229: sbox8 = 8'ha7;
        8'd230: sbox8 = 8'h17;
        8'd231: sbox8 = 8'haf;
        8'd232: sbox8 = 8'h01;
        8'd233: sbox8 = 8'hb2;
        8'd234: sbox8 = 8'h0e;
        8'd235: sbox8 = 8'hbe;
        8'd236: sbox8 = 8'h07;
        8'd237: sbox8 = 8'hb7;
        8'd238: sbox8 = 8'h0f;
        8'd239: sbox8 = 8'hbf;
        8'd240: sbox8 = 8'he2;
        8'd241: sbox8 = 8'hca;
        8'd242: sbox8 = 8'hee;
        8'd243: sbox8 = 8'hc6;
        8'd244: sbox8 = 8'hcf;
        8'd245: sbox8 = 8'he7;
        8'd246: sbox8 = 8'hc7;
        8'd247: sbox8 = 8'hef;
        8'd248: sbox8 = 8'hd2;
        8'd249: sbox8 = 8'hf2;
        8'd250: sbox8 = 8'hde;
        8'd251: sbox8 = 8'hfe;
        8'd252: sbox8 = 8'hd7;
        8'd253: sbox8 = 8'hf7;
        8'd254: sbox8 = 8'hdf;
        8'd255: sbox8 = 8'hff;
      default: sbox8 = 8'd0;
    endcase
  endfunction

  function [5:0] rc40;
    input [5:0] r;
    case (r)
        6'd0: rc40 = 6'h01;
        6'd1: rc40 = 6'h03;
        6'd2: rc40 = 6'h07;
        6'd3: rc40 = 6'h0f;
        6'd4: rc40 = 6'h1f;
        6'd5: rc40 = 6'h3e;
        6'd6: rc40 = 6'h3d;
        6'd7: rc40 = 6'h3b;
        6'd8: rc40 = 6'h37;
        6'd9: rc40 = 6'h2f;
        6'd10: rc40 = 6'h1e;
        6'd11: rc40 = 6'h3c;
        6'd12: rc40 = 6'h39;
        6'd13: rc40 = 6'h33;
        6'd14: rc40 = 6'h27;
        6'd15: rc40 = 6'h0e;
        6'd16: rc40 = 6'h1d;
        6'd17: rc40 = 6'h3a;
        6'd18: rc40 = 6'h35;
        6'd19: rc40 = 6'h2b;
        6'd20: rc40 = 6'h16;
        6'd21: rc40 = 6'h2c;
        6'd22: rc40 = 6'h18;
        6'd23: rc40 = 6'h30;
        6'd24: rc40 = 6'h21;
        6'd25: rc40 = 6'h02;
        6'd26: rc40 = 6'h05;
        6'd27: rc40 = 6'h0b;
        6'd28: rc40 = 6'h17;
        6'd29: rc40 = 6'h2e;
        6'd30: rc40 = 6'h1c;
        6'd31: rc40 = 6'h38;
        6'd32: rc40 = 6'h31;
        6'd33: rc40 = 6'h23;
        6'd34: rc40 = 6'h06;
        6'd35: rc40 = 6'h0d;
        6'd36: rc40 = 6'h1b;
        6'd37: rc40 = 6'h36;
        6'd38: rc40 = 6'h2d;
        6'd39: rc40 = 6'h1a;
      default: rc40 = 6'd0;
    endcase
  endfunction

  function [3:0] twp;
    input [3:0] idx;
    case (idx)
        4'd0: twp = 4'd9;
        4'd1: twp = 4'd15;
        4'd2: twp = 4'd8;
        4'd3: twp = 4'd13;
        4'd4: twp = 4'd10;
        4'd5: twp = 4'd14;
        4'd6: twp = 4'd12;
        4'd7: twp = 4'd11;
        4'd8: twp = 4'd0;
        4'd9: twp = 4'd1;
        4'd10: twp = 4'd2;
        4'd11: twp = 4'd3;
        4'd12: twp = 4'd4;
        4'd13: twp = 4'd5;
        4'd14: twp = 4'd6;
        4'd15: twp = 4'd7;
      default: twp = 4'd0;
    endcase
  endfunction

  // ------------------------------------------------------------- SKINNY
  function [127:0] tweakey_perm;
    input [127:0] c;
    integer idx;
    reg [127:0] o;
    begin
      o = 128'd0;
      for (idx = 0; idx < 16; idx = idx + 1)
        o[127-8*idx -: 8] = c[127-8*twp(idx[3:0]) -: 8];
      tweakey_perm = o;
    end
  endfunction

  function [7:0] lfsr_tk2_byte;
    input [7:0] b;
    begin lfsr_tk2_byte = {b[6:0], b[7]^b[5]}; end
  endfunction

  function [7:0] lfsr_tk3_byte;
    input [7:0] b;
    begin lfsr_tk3_byte = {b[0]^b[6], b[7:1]}; end
  endfunction

  // One SKINNY-128-384+ round. Packed input/output: {state,tk1,tk2,tk3},
  // 128 bits each. Order: SubCell8, AddConstants, AddKey (state XOR, using
  // the OLD tweakeys, then tweakey schedule update), ShiftRows, MixColumn.
  function [511:0] skinny_round;
    input [511:0] sk;
    input [5:0]   rnd;
    reg [127:0] state, tk1, tk2, tk3;
    reg [127:0] sub, keyed, shifted, mixed;
    reg [127:0] tk1p, tk2p, tk3p;
    integer row, col;
    reg [7:0] r0, r1, r2, r3;
    reg [5:0] rc_val;
    begin
      state = sk[511:384]; tk1 = sk[383:256]; tk2 = sk[255:128]; tk3 = sk[127:0];

      // SubCell8
      for (row = 0; row < 16; row = row + 1)
        sub[127-8*row -: 8] = sbox8(state[127-8*row -: 8]);

      // AddConstants: byte0(row0,col0)^=RC&0xF, byte4(row1,col0)^=(RC>>4)&0x3,
      // byte8(row2,col0)^=0x2. rc_val holds rc40(rnd) so the slices below
      // don't part-select a function call's return value directly -- yosys's
      // Verilog-2005 frontend rejects that, unlike Verilator/Vivado.
      rc_val = rc40(rnd);
      sub[127:120] = sub[127:120] ^ {4'd0, rc_val[3:0]};
      sub[95:88]   = sub[95:88]   ^ {6'd0, rc_val[5:4]};
      sub[63:56]   = sub[63:56]   ^ 8'h02;

      // AddKey: rows 0-1 (byte idx 0..7) of state XOR TK1^TK2^TK3; rows 2-3
      // untouched.
      keyed = sub;
      for (row = 0; row < 8; row = row + 1)
        keyed[127-8*row -: 8] = sub[127-8*row -: 8]
                               ^ tk1[127-8*row -: 8] ^ tk2[127-8*row -: 8] ^ tk3[127-8*row -: 8];

      // Tweakey schedule: permute all three, then LFSR rows 0-1 of TK2/TK3.
      tk1p = tweakey_perm(tk1);
      tk2p = tweakey_perm(tk2);
      tk3p = tweakey_perm(tk3);
      for (row = 0; row < 8; row = row + 1) begin
        tk2p[127-8*row -: 8] = lfsr_tk2_byte(tk2p[127-8*row -: 8]);
        tk3p[127-8*row -: 8] = lfsr_tk3_byte(tk3p[127-8*row -: 8]);
      end

      // ShiftRows: row0 unchanged; row1 right-rotate by 1; row2 right-rotate
      // by 2 (swap opposite pairs); row3 right-rotate by 3 (= left by 1).
      shifted[127:96] = keyed[127:96];                                      // row0
      shifted[95:88]  = keyed[71:64];  shifted[87:80] = keyed[95:88];       // row1: new0=old3,new1=old0
      shifted[79:72]  = keyed[87:80];  shifted[71:64] = keyed[79:72];       //        new2=old1,new3=old2
      shifted[63:56]  = keyed[47:40];  shifted[55:48] = keyed[39:32];       // row2: new0=old2,new1=old3
      shifted[47:40]  = keyed[63:56];  shifted[39:32] = keyed[55:48];       //        new2=old0,new3=old1
      shifted[31:24]  = keyed[23:16];  shifted[23:16] = keyed[15:8];        // row3: new0=old1,new1=old2
      shifted[15:8]   = keyed[7:0];    shifted[7:0]   = keyed[31:24];       //        new2=old3,new3=old0

      // MixColumn (per column j, rows packed as bytes 4j+0..4j+3 -- wait,
      // rows are actually byte idx = row*4+col, so column j's four bytes are
      // idx = j, j+4, j+8, j+12): newR0=r0^r2^r3; newR1=r0; newR2=r1^r2;
      // newR3=r0^r2 (see file header derivation).
      for (col = 0; col < 4; col = col + 1) begin
        r0 = shifted[127-8*(col)    -: 8];
        r1 = shifted[127-8*(col+4)  -: 8];
        r2 = shifted[127-8*(col+8)  -: 8];
        r3 = shifted[127-8*(col+12) -: 8];
        mixed[127-8*(col)    -: 8] = r0 ^ r2 ^ r3;
        mixed[127-8*(col+4)  -: 8] = r0;
        mixed[127-8*(col+8)  -: 8] = r1 ^ r2;
        mixed[127-8*(col+12) -: 8] = r0 ^ r2;
      end

      skinny_round = {mixed, tk1p, tk2p, tk3p};
    end
  endfunction

  // g8A per-byte linear transform (keystream / tag generation, NOT a
  // multi-round permutation): new_bit7 = old_bit7^old_bit0, new_bits6..0 =
  // old_bits7..1.
  function [127:0] g8a;
    input [127:0] s;
    integer i;
    reg [127:0] o;
    reg [7:0] b;
    begin
      o = 128'd0;
      for (i = 0; i < 16; i = i + 1) begin
        b = s[127-8*i -: 8];
        o[127-8*i -: 8] = {b[7]^b[0], b[7:1]};
      end
      g8a = o;
    end
  endfunction

  // ------------------------------------------------------------ state regs
  reg [127:0] key_r;
  reg [127:0] npub_r;
  reg [15:0]  ad_len, pt_len;

  reg [127:0] s;                // Romulus running state
  reg [55:0]  cnt;              // 56-bit LFSR counter
  reg [15:0]  ad_rem, pt_rem;   // bytes not yet absorbed in this phase

  reg [511:0] perm_state;       // {state,tk1,tk2,tk3} while a TBC call runs
  reg [5:0]   rnd_idx;
  reg [5:0]   tbc_ret;

  reg [127:0] tbc_T;
  reg [7:0]   tbc_D;

  reg [127:0] blk_in;           // collected up-to-16-byte block
  reg [127:0] out_blk;          // computed output block (message phase)
  reg [1:0]   wsel;             // word index while collecting a block
  reg [1:0]   owc;              // output word counter

  reg         ad_is_last_r;     // latched from ad_rem at the START of a pair
  reg [7:0]   ad_final_D_r;

  reg [1:0]   wcnt;             // small word counter (key/npub/tag)
  reg         decrypt_r, tag_ok;

  // Block sizing, stable across a block's collect/absorb (ad_rem/pt_rem only
  // change at the absorb step itself) -- same pattern as isap_lwc.v /
  // photonbeetle_lwc.v.
  wire [15:0] ad_blk_len = (ad_rem >= 16'd16) ? 16'd16 : ad_rem;
  wire [15:0] ad_words_m1_16 = ((ad_blk_len + 16'd3) >> 2) - 16'd1;
  wire [1:0]  ad_words_m1 = ad_words_m1_16[1:0];
  wire [15:0] pt_blk_len = (pt_rem >= 16'd16) ? 16'd16 : pt_rem;
  wire [15:0] pt_words_m1_16 = ((pt_blk_len + 16'd3) >> 2) - 16'd1;
  wire [1:0]  pt_words_m1 = pt_words_m1_16[1:0];

  wire [7:0] blk_byte [0:15];
  genvar gi;
  generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : g_blk_byte
      assign blk_byte[gi] = blk_in[127-8*gi -: 8];
    end
  endgenerate

  // pad(): real bytes for i<len, 0 for len<=i<15, (len&0xF) at byte 15 when
  // len<16 (a "complete" 16-byte block is returned unchanged).
  // BYTE ORDER: every 128-bit block here (blk_in, tbc_T, key_r, s...)
  // represents byte i at bits [127-8i -: 8] -- byte 0 in the MSB, matching
  // pad_block's own indexing below and SKINNY's usual byte-array
  // convention. The LWC bus, though, delivers each word little-endian
  // (byte 0 in pdi_data[7:0] -- the convention tinyjambu_lwc.v,
  // xoodyak_lwc.v and giftcofb_lwc.v all use and that their KAT runs
  // confirmed). Loading bus words into key_r/npub_r/blk_in via a plain
  // shift-in, and reading tag/ciphertext words straight out of `s`/
  // `out_blk`, without correcting for that mismatch, put every byte in the
  // right 4-byte GROUP but the wrong order within it -- exactly the same
  // bug class found and fixed in giftcofb_lwc.v, checked for here
  // proactively after that experience rather than rediscovered from
  // scratch (it still took a from-scratch KAT run to notice the pattern).
  function [31:0] bswap32;
    input [31:0] w;
    begin bswap32 = {w[7:0], w[15:8], w[23:16], w[31:24]}; end
  endfunction

  function [127:0] pad_block;
    input [127:0] blk;
    input [15:0]  len;
    integer i;
    reg [127:0] o;
    begin
      o = 128'd0;
      for (i = 0; i < 16; i = i + 1) begin
        if (i < len) o[127-8*i -: 8] = blk[127-8*i -: 8];
        else if (i == 15) o[7:0] = {4'd0, len[3:0]};
      end
      pad_block = o;
    end
  endfunction

  // Message-phase keystream/output/absorb (rho / irho unified -- see file
  // header).
  wire [127:0] ks = g8a(s);
  wire [7:0]  out_byte [0:15];
  wire [7:0]  plain_byte [0:15];
  generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : g_msg
      // Reference rho/irho explicitly zero the output byte (c[i]/m[i])
      // for i >= len8 on a short final block instead of leaking ks^stale
      // -- required both by the spec and by the API's Sec. 2.7 "clear
      // unused output portions" rule.
      assign out_byte[gi]   = (gi < pt_blk_len) ? (ks[127-8*gi -: 8] ^ blk_byte[gi]) : 8'd0;
      assign plain_byte[gi] = decrypt_r ? out_byte[gi] : blk_byte[gi];
    end
  endgenerate

  reg [127:0] pt_absorb_mask;
  integer bi;
  always @* begin
    pt_absorb_mask = 128'd0;
    for (bi = 0; bi < 16; bi = bi + 1) begin
      if (bi < pt_blk_len) pt_absorb_mask[127-8*bi -: 8] = plain_byte[bi];
      else if (bi == 15 && pt_blk_len < 16'd16) pt_absorb_mask[7:0] = {4'd0, pt_blk_len[3:0]};
    end
  end

  wire [127:0] out_blk_next = {out_byte[0],out_byte[1],out_byte[2],out_byte[3],
                                out_byte[4],out_byte[5],out_byte[6],out_byte[7],
                                out_byte[8],out_byte[9],out_byte[10],out_byte[11],
                                out_byte[12],out_byte[13],out_byte[14],out_byte[15]};

  // Message-block domain byte: 0x15 short-final, 0x14 exact-final, 0x04
  // normal (more remain after this block).
  wire [7:0] pt_D = (pt_rem < 16'd16) ? 8'h15 : (pt_rem == 16'd16) ? 8'h14 : 8'h04;
  wire       pt_is_final = (pt_rem <= 16'd16);

  localparam [5:0]
    S_IDLE        = 6'd0,  S_SDI_HDR     = 6'd1,  S_SDI_KEY    = 6'd2,
    S_PDI_OP      = 6'd3,  S_PDI_NHDR    = 6'd4,  S_PDI_NDATA  = 6'd5,
    S_PDI_AHDR    = 6'd6,
    S_AD_ODD_COLL = 6'd7,  S_AD_ODD_ABS  = 6'd8,
    S_AD_EVN_COLL = 6'd9,  S_AD_EVN_SET  = 6'd10, S_AD_EVN_PST = 6'd11,
    S_AD_NE_SET   = 6'd12,
    S_TBC_SETUP   = 6'd13, S_TBC_ROUND   = 6'd14, S_TBC_DONE   = 6'd15,
    S_PDI_PHDR    = 6'd16, S_DO_PTHDR    = 6'd17, S_MSG_EMPTY  = 6'd18,
    S_PT_COLL     = 6'd19, S_PT_ABSORB   = 6'd20, S_PT_OUT     = 6'd21,
    S_PT_NE_SET   = 6'd22,
    S_TAG_CALC    = 6'd23,
    S_DO_TAGHDR   = 6'd24, S_TAG_OUT     = 6'd25,
    S_PDI_THDR    = 6'd26, S_TAG_IN      = 6'd27,
    S_OUT_STATUS  = 6'd28;

  reg [5:0] fsm;

  wire [55:0] cnt_next = {cnt[54:0], 1'b0} ^ (cnt[55] ? 56'h95 : 56'h0);

  // ------------------------------------------------------------- handshakes
  assign pdi_ready = (fsm == S_IDLE)      || (fsm == S_PDI_OP)   ||
                     (fsm == S_PDI_NHDR) || (fsm == S_PDI_NDATA)||
                     (fsm == S_PDI_AHDR) || (fsm == S_AD_ODD_COLL) ||
                     (fsm == S_AD_EVN_COLL) ||
                     (fsm == S_PDI_PHDR) || (fsm == S_PT_COLL)  ||
                     (fsm == S_PDI_THDR) || (fsm == S_TAG_IN);
  assign sdi_ready = (fsm == S_IDLE) || (fsm == S_SDI_HDR) || (fsm == S_SDI_KEY);

  assign do_valid = (fsm == S_DO_PTHDR) || (fsm == S_PT_OUT) ||
                    (fsm == S_DO_TAGHDR)|| (fsm == S_TAG_OUT) ||
                    (fsm == S_OUT_STATUS);
  assign do_last  = (fsm == S_OUT_STATUS);

  wire [31:0] out_word = bswap32(out_blk[127-32*{30'd0,owc} -: 32]);
  wire [31:0] tag_word = bswap32(s[127-32*{30'd0,wcnt} -: 32]);

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
      ad_rem <= 16'd0; pt_rem <= 16'd0;
      ad_is_last_r <= 1'b0; ad_final_D_r <= 8'd0;
      key_r <= 128'd0; npub_r <= 128'd0; ad_len <= 16'd0; pt_len <= 16'd0;
      s <= 128'd0; cnt <= 56'd0;
      perm_state <= 512'd0; rnd_idx <= 6'd0; tbc_ret <= 6'd0;
      tbc_T <= 128'd0; tbc_D <= 8'd0;
      blk_in <= 128'd0; out_blk <= 128'd0;
    end else begin
      case (fsm)
        S_IDLE: begin
          if (sdi_valid)      fsm <= S_SDI_HDR;
          else if (pdi_valid) fsm <= S_PDI_OP;
        end
        S_SDI_HDR: if (sdi_valid) begin wcnt <= 2'd0; fsm <= S_SDI_KEY; end
        S_SDI_KEY: if (sdi_valid) begin
          key_r <= {key_r[95:0], bswap32(sdi_data)};
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
          npub_r <= {npub_r[95:0], bswap32(pdi_data)};
          wcnt   <= wcnt + 2'd1;
          if (wcnt == 2'd3) begin
            s   <= 128'd0;
            cnt <= {56'h01};              // reset_lfsr_gf56: CNT[0]=1, rest 0
            fsm <= S_PDI_AHDR;
          end
        end

        S_PDI_AHDR: if (pdi_valid) begin
          ad_len <= pdi_data[15:0];
          ad_rem <= pdi_data[15:0];
          wsel   <= 2'd0;
          if (pdi_data[15:0] == 16'd0) begin
            cnt <= cnt_next;
            tbc_T <= npub_r; tbc_D <= 8'h1a; tbc_ret <= S_PDI_PHDR;
            fsm <= S_TBC_SETUP;
          end else fsm <= S_AD_ODD_COLL;
        end

        // odd block: rho_ad -- pad + XOR-absorb, no TBC call.
        S_AD_ODD_COLL: if (pdi_valid) begin
          // Positional (not shift-in) write: a shift register only lands
          // data left-aligned when exactly 4 words are collected. Every
          // partial (<16-byte) AD/PT block collects fewer words, and a
          // shift-in would land them at the bottom of blk_in instead of
          // top-aligned at byte 0 -- and blk_in is only cleared on global
          // reset, so the unused high bytes would carry over stale content
          // from a previous block instead of being predictable. Writing
          // each word to its final slot by wsel sidesteps both problems;
          // pad_block() below never reads past byte (len-1) so the
          // never-written high word(s) of a short block don't matter.
          blk_in[127-32*{30'd0,wsel} -: 32] <= bswap32(pdi_data);
          if (wsel == ad_words_m1) begin wsel <= 2'd0; fsm <= S_AD_ODD_ABS; end
          else wsel <= wsel + 2'd1;
        end
        S_AD_ODD_ABS: begin
          s <= s ^ pad_block(blk_in, ad_blk_len);
          cnt <= cnt_next;
          // Latch the last-pair decision from ad_rem AS IT STANDS NOW
          // (before this cycle's own update below) -- these bits are read
          // again only after the (possible) even block's TBC call, many
          // cycles later, so they must not depend on a register that will
          // have changed by then.
          ad_is_last_r  <= (ad_rem <= 16'd32);
          ad_final_D_r  <= (ad_rem[3:0] == 4'd0) ? 8'h18 : 8'h1a;
          ad_rem <= ad_rem - ad_blk_len;
          if (ad_rem - ad_blk_len != 16'd0) begin
            wsel <= 2'd0;
            fsm <= S_AD_EVN_COLL;
          end else begin
            fsm <= S_AD_NE_SET;
          end
        end

        // even block: used as the TWEAK of a full TBC call (domain 0x08).
        S_AD_EVN_COLL: if (pdi_valid) begin
          // Positional (not shift-in) write: a shift register only lands
          // data left-aligned when exactly 4 words are collected. Every
          // partial (<16-byte) AD/PT block collects fewer words, and a
          // shift-in would land them at the bottom of blk_in instead of
          // top-aligned at byte 0 -- and blk_in is only cleared on global
          // reset, so the unused high bytes would carry over stale content
          // from a previous block instead of being predictable. Writing
          // each word to its final slot by wsel sidesteps both problems;
          // pad_block() below never reads past byte (len-1) so the
          // never-written high word(s) of a short block don't matter.
          blk_in[127-32*{30'd0,wsel} -: 32] <= bswap32(pdi_data);
          if (wsel == ad_words_m1) begin wsel <= 2'd0; fsm <= S_AD_EVN_SET; end
          else wsel <= wsel + 2'd1;
        end
        S_AD_EVN_SET: begin
          tbc_T <= pad_block(blk_in, ad_blk_len);
          tbc_D <= 8'h08;
          tbc_ret <= S_AD_EVN_PST;
          fsm <= S_TBC_SETUP;
        end
        S_AD_EVN_PST: begin
          cnt <= cnt_next;
          ad_rem <= ad_rem - ad_blk_len;
          if (ad_is_last_r) fsm <= S_AD_NE_SET;
          else begin wsel <= 2'd0; fsm <= S_AD_ODD_COLL; end
        end

        // Finish AD: one more CNT step (already done, at S_AD_ODD_ABS or
        // S_AD_EVN_PST) then a TBC call keyed with Npub.
        S_AD_NE_SET: begin
          tbc_T <= npub_r; tbc_D <= ad_final_D_r; tbc_ret <= S_PDI_PHDR;
          fsm <= S_TBC_SETUP;
        end

        // Shared 40-round SKINNY engine.
        S_TBC_SETUP: begin
          perm_state <= {s, {cnt[7:0],cnt[15:8],cnt[23:16],cnt[31:24],
                              cnt[39:32],cnt[47:40],cnt[55:48], tbc_D, 64'd0},
                         tbc_T, key_r};
          rnd_idx <= 6'd0;
          fsm <= S_TBC_ROUND;
        end
        S_TBC_ROUND: begin
          perm_state <= skinny_round(perm_state, rnd_idx);
          if (rnd_idx == 6'd39) fsm <= S_TBC_DONE;
          else                  rnd_idx <= rnd_idx + 6'd1;
        end
        S_TBC_DONE: begin
          s <= perm_state[511:384];
          fsm <= tbc_ret;
        end

        S_PDI_PHDR: if (pdi_valid) begin
          pt_len <= pdi_data[15:0];
          pt_rem <= pdi_data[15:0];
          wsel   <= 2'd0;
          cnt    <= 56'h01;              // reset_lfsr_gf56 before the message phase
          fsm    <= S_DO_PTHDR;
        end
        S_DO_PTHDR: if (do_ready) begin
          fsm <= (pt_len == 16'd0) ? S_MSG_EMPTY : S_PT_COLL;
        end
        S_MSG_EMPTY: begin
          cnt <= cnt_next;
          tbc_T <= npub_r; tbc_D <= 8'h15; tbc_ret <= S_TAG_CALC;
          fsm <= S_TBC_SETUP;
        end

        S_PT_COLL: if (pdi_valid) begin
          // Positional (not shift-in) write: a shift register only lands
          // data left-aligned when exactly 4 words are collected. Every
          // partial (<16-byte) AD/PT block collects fewer words, and a
          // shift-in would land them at the bottom of blk_in instead of
          // top-aligned at byte 0 -- and blk_in is only cleared on global
          // reset, so the unused high bytes would carry over stale content
          // from a previous block instead of being predictable. Writing
          // each word to its final slot by wsel sidesteps both problems;
          // pad_block() below never reads past byte (len-1) so the
          // never-written high word(s) of a short block don't matter.
          blk_in[127-32*{30'd0,wsel} -: 32] <= bswap32(pdi_data);
          if (wsel == pt_words_m1) begin wsel <= 2'd0; fsm <= S_PT_ABSORB; end
          else wsel <= wsel + 2'd1;
        end
        S_PT_ABSORB: begin
          out_blk <= out_blk_next;
          owc <= 2'd0;
          s <= s ^ pt_absorb_mask;
          fsm <= S_PT_OUT;
        end
        S_PT_OUT: if (do_ready) begin
          if (owc == pt_words_m1) begin
            cnt <= cnt_next;
            tbc_T <= npub_r; tbc_D <= pt_D;
            tbc_ret <= pt_is_final ? S_TAG_CALC : S_PT_NE_SET;
            fsm <= S_TBC_SETUP;
          end else owc <= owc + 2'd1;
        end
        // (non-final block only) resume collecting the next block once the
        // re-keying TBC call lands.
        S_PT_NE_SET: begin
          pt_rem <= pt_rem - pt_blk_len;
          fsm <= S_PT_COLL;
        end

        S_TAG_CALC: begin
          s <= g8a(s);
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
