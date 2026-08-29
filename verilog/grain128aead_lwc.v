// Grain-128AEADv2, implementing the CryptoCore-facing protocol of the NIST
// Lightweight Cryptography Hardware API (see tinyjambu_lwc.v's header for the
// full API citation; same ports, opcodes and segment-header format).
//
// WARNING: Grain-128AEAD did NOT win the NIST LWC competition -- Ascon did.
// This core exists for hardware comparison against ascon_aead128.v (this
// directory), not as a recommendation. Lint-checked (Verilator + Vivado) but
// NOT run against the official KAT vectors in simulation -- unlike
// tinyjambu_lwc.v. It is a careful transliteration, not a confirmed-correct
// one.
//
// Algorithm: transliterated from the official reference C,
// ../lwc-finalists/grain-128aead/grain128aead-v2.c, which is itself the NIST
// final-round submission. That reference is explicitly written "to be as
// close to a hardware implementation as possible" (one bit per array cell),
// so this is an unusually direct mapping: its bit arrays become shift
// registers and its per-bit functions become combinational logic.
//
// Key = 16 B, Npub = 12 B, tag = 8 B (CRYPTO_ABYTES=8, note: NOT 16 like the
// other cores here).
//
// BIT ORDER: the reference applies swapsb() to every input byte and then
// extracts bits MSB-first; those two operations compose to plain LSB-first
// extraction of the original byte. So bit j of input byte B is simply B[j],
// and likewise ciphertext/tag byte bit j is the j'th bit produced. This core
// therefore consumes and produces bits LSB-first with no bit-reversal
// anywhere -- the swapsb() calls in the C are an artifact of it being a
// software model of hardware, not part of the algorithm.
//
// STRUCTURE (next_z in the reference):
//   lfsr[128], nfsr[128] shift registers; index i = C's fsr[i]; each shift
//   does fsr[i]=fsr[i+1], fsr[127]=fb, i.e. {fb, old[127:1]} in Verilog.
//   auth_acc[64], auth_sr[64] likewise.
//   lfsr_fb = s96^s81^s70^s38^s7^s0
//   nfsr_fb = b96^b91^b56^b26^b0 ^ (b84&b68)^(b67&b3)^(b65&b61)^(b59&b27)
//             ^(b48&b40)^(b18&b17)^(b13&b11)
//             ^(b82&b78&b70)^(b25&b24&b22)^(b95&b93&b92&b88)
//   h = (b12&s8)^(s13&s20)^(b95&s42)^(s60&s79)^(b12&b95&s94)
//   y = h ^ s93 ^ (b2^b15^b36^b45^b64^b73^b89)
//   INIT   : lfsr<={lfsr_fb^y}, nfsr<={nfsr_fb^lfsr_out^y}
//   ADDKEY : same but ^keybit_64 (lfsr) and ^keybit (nfsr)
//   NORMAL : lfsr<={lfsr_fb},   nfsr<={nfsr_fb^lfsr_out}
//
// SCHEDULE:
//   init: lfsr[0:96]=iv, lfsr[96:127]=1, lfsr[127]=0, nfsr=key
//   320x INIT; 64x ADDKEY (key bits i and 64+i); 64x NORMAL -> auth_acc;
//   64x NORMAL -> auth_sr
//   AD:  DER(adlen) || ad, per BYTE: 16 z-bits; even j -> discarded,
//        odd j -> if databit: acc^=sr; then sr<={z,sr[63:1]}
//   MSG: per BYTE: 16 z; even j -> out_bit = msg_bit ^ z;
//        odd j -> if msg_bit: acc^=sr; then sr shift
//        (the reference walks the SAME padded message stream with two
//        counters, m_cnt for the even/keystream bits and ac_cnt for the odd/
//        MAC bits, both advancing 8 per byte, so they stay in lockstep --
//        one byte of message consumes 8 message bits, each used twice.)
//   after all message bytes: one extra next_z (discarded), then acc^=sr
//        unconditionally (this is the mandatory trailing 1 padding bit).
//   tag = auth_acc, byte k bit j = auth_acc[8k+j].
//
// DER length prefix (encode_der): len<128 -> one byte = len. Otherwise a
// 0x80|nbytes marker then nbytes big-endian length bytes. Segment lengths
// here are 16-bit, so at most 0x82,hi,lo is ever needed.
//
// For decrypt the roles swap in the usual way: the input bit is ciphertext,
// out_bit = ct_bit ^ z is the recovered plaintext, and it is that PLAINTEXT
// bit that drives the accumulate decision -- matching the reference's
// decrypt path, and the same "derive plaintext first, then absorb it"
// pattern as the other cores in this directory.

module grain128aead_lwc (
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

  localparam [1:0] R_INIT = 2'd0, R_ADDKEY = 2'd1, R_NORMAL = 2'd2;

  reg [127:0] lfsr, nfsr;
  reg [63:0]  acc, sr;
  reg [127:0] keyb;      // key bits, LSB-first per byte
  reg [95:0]  ivb;       // nonce bits, LSB-first per byte
  reg [1:0]   gmode;
  reg [8:0]   icnt;      // init counters (up to 320)

  // --- combinational Grain functions (direct from next_* in the reference)
  wire lfsr_fb = lfsr[96]^lfsr[81]^lfsr[70]^lfsr[38]^lfsr[7]^lfsr[0];
  wire nfsr_fb = nfsr[96]^nfsr[91]^nfsr[56]^nfsr[26]^nfsr[0]
               ^ (nfsr[84]&nfsr[68]) ^ (nfsr[67]&nfsr[3])
               ^ (nfsr[65]&nfsr[61]) ^ (nfsr[59]&nfsr[27])
               ^ (nfsr[48]&nfsr[40]) ^ (nfsr[18]&nfsr[17])
               ^ (nfsr[13]&nfsr[11])
               ^ (nfsr[82]&nfsr[78]&nfsr[70])
               ^ (nfsr[25]&nfsr[24]&nfsr[22])
               ^ (nfsr[95]&nfsr[93]&nfsr[92]&nfsr[88]);
  wire h_out   = (nfsr[12]&lfsr[8]) ^ (lfsr[13]&lfsr[20])
               ^ (nfsr[95]&lfsr[42]) ^ (lfsr[60]&lfsr[79])
               ^ (nfsr[12]&nfsr[95]&lfsr[94]);
  wire y_out   = h_out ^ lfsr[93]
               ^ nfsr[2]^nfsr[15]^nfsr[36]^nfsr[45]^nfsr[64]^nfsr[73]^nfsr[89];
  wire lfsr_out = lfsr[0];

  // key bits injected during ADDKEY (i and 64+i, i = icnt)
  wire kb_lo = keyb[{1'b0, icnt[5:0]}];
  wire kb_hi = keyb[{1'b1, icnt[5:0]}];   // 64 + i

  wire lfsr_in = (gmode==R_INIT)   ? (lfsr_fb ^ y_out)
               : (gmode==R_ADDKEY) ? (lfsr_fb ^ y_out ^ kb_hi)
                                   :  lfsr_fb;
  wire nfsr_in = (gmode==R_INIT)   ? (nfsr_fb ^ lfsr_out ^ y_out)
               : (gmode==R_ADDKEY) ? (nfsr_fb ^ lfsr_out ^ y_out ^ kb_lo)
                                   : (nfsr_fb ^ lfsr_out);

  // --- protocol / data path
  reg [31:0]  k0,k1,k2,k3, npub0,npub1,npub2;
  reg [15:0]  ad_len, pt_len, rem;
  reg [1:0]   wcnt;
  reg [31:0]  inword;        // buffered PDI word (4 bytes)
  reg [1:0]   bsel;          // which byte of inword
  reg [7:0]   curbyte;       // byte being processed, LSB-first
  reg [7:0]   outbyte;       // assembled ciphertext/plaintext byte
  reg [4:0]   jcnt;          // 0..15 within a byte
  reg [2:0]   bitpos;        // 0..7 data-bit index within the byte
  reg [31:0]  outword;
  reg [1:0]   owcnt;
  reg         decrypt_r, tag_ok, in_ad, der_phase;
  reg [1:0]   der_cnt, der_n;
  reg [23:0]  der_bytes;     // up to 3 DER bytes, first in [23:16]
  reg [2:0]   tag_wcnt;

  wire zbit = y_out;
  wire is_ks = (jcnt[0]==1'b0);            // even j -> keystream, odd -> MAC
  wire databit = curbyte[bitpos];
  wire outbit  = databit ^ zbit;
  // plaintext bit for MAC purposes: encrypt absorbs the input (plaintext);
  // decrypt absorbs the recovered plaintext (ct ^ z).
  wire macbit  = decrypt_r ? outbit : databit;

  localparam [5:0]
    S_IDLE=6'd0, S_SDI_HDR=6'd1, S_SDI_KEY=6'd2,
    S_PDI_OP=6'd3, S_PDI_NHDR=6'd4, S_PDI_NDATA=6'd5,
    S_INIT0=6'd6, S_INIT_RUN=6'd7, S_ADDK=6'd8, S_FILLACC=6'd9, S_FILLSR=6'd10,
    S_PDI_AHDR=6'd11, S_DER=6'd12, S_DER_BIT=6'd13,
    S_AD_WORD=6'd14, S_AD_BIT=6'd15,
    S_PDI_PHDR=6'd16, S_DO_PTHDR=6'd17,
    S_PT_WORD=6'd18, S_PT_BIT=6'd19, S_PT_OUT=6'd20,
    S_FINAL_Z=6'd21,
    S_DO_TAGHDR=6'd22, S_OUT_TAG=6'd23,
    S_PDI_THDR=6'd24, S_TAG_WORD=6'd25, S_OUT_STATUS=6'd26;

  reg [5:0] fsm;

  assign pdi_ready = (fsm==S_IDLE)||(fsm==S_PDI_OP)||(fsm==S_PDI_NHDR)||
                     (fsm==S_PDI_NDATA)||(fsm==S_PDI_AHDR)||(fsm==S_AD_WORD)||
                     (fsm==S_PDI_PHDR)||(fsm==S_PT_WORD)||(fsm==S_PDI_THDR)||
                     (fsm==S_TAG_WORD);
  assign sdi_ready = (fsm==S_IDLE)||(fsm==S_SDI_HDR)||(fsm==S_SDI_KEY);

  assign do_valid = (fsm==S_DO_PTHDR)||(fsm==S_PT_OUT)||(fsm==S_DO_TAGHDR)||
                    (fsm==S_OUT_TAG)||(fsm==S_OUT_STATUS);
  assign do_last  = (fsm==S_OUT_STATUS);
  assign do_data  =
      (fsm==S_DO_PTHDR)  ? {(decrypt_r?SEGT_PT:SEGT_CT),1'b0,1'b0,1'b1,
                            decrypt_r,8'd0,pt_len} :
      (fsm==S_PT_OUT)    ? outword :
      (fsm==S_DO_TAGHDR) ? {SEGT_TAG,1'b0,1'b0,1'b1,1'b1,8'd0,16'd8} :
      (fsm==S_OUT_TAG)   ? (tag_wcnt==3'd0 ? acc[31:0] : acc[63:32]) :
      (fsm==S_OUT_STATUS)? {(decrypt_r?(tag_ok?ST_SUCCESS:ST_FAILURE)
                                       :ST_SUCCESS),28'd0} : 32'd0;

  // DER prefix length for a 16-bit segment length
  function [1:0] der_len_of;
    input [15:0] l;
    begin
      if (l < 16'd128)      der_len_of = 2'd1;
      else if (l < 16'd256) der_len_of = 2'd2;
      else                  der_len_of = 2'd3;
    end
  endfunction

  integer bi;
  always @(posedge clk) begin
    if (rst) begin
      fsm<=S_IDLE; lfsr<=0; nfsr<=0; acc<=0; sr<=0; keyb<=0; ivb<=0;
      gmode<=R_INIT; icnt<=0; k0<=0;k1<=0;k2<=0;k3<=0;
      npub0<=0;npub1<=0;npub2<=0; ad_len<=0; pt_len<=0; rem<=0; wcnt<=0;
      inword<=0; bsel<=0; curbyte<=0; outbyte<=0; jcnt<=0; bitpos<=0;
      outword<=0; owcnt<=0; decrypt_r<=0; tag_ok<=0; in_ad<=0; der_phase<=0;
      der_cnt<=0; der_n<=0; der_bytes<=0; tag_wcnt<=0;
    end else begin
      case (fsm)
        S_IDLE: begin
          if (sdi_valid) fsm<=S_SDI_HDR;
          else if (pdi_valid) fsm<=S_PDI_OP;
        end
        S_SDI_HDR: if (sdi_valid) begin wcnt<=0; fsm<=S_SDI_KEY; end
        S_SDI_KEY: if (sdi_valid) begin
          case (wcnt)
            2'd0: k0<=sdi_data; 2'd1: k1<=sdi_data;
            2'd2: k2<=sdi_data; default: k3<=sdi_data;
          endcase
          if (wcnt==2'd3) fsm<=S_IDLE; else wcnt<=wcnt+2'd1;
        end

        S_PDI_OP: if (pdi_valid) begin
          decrypt_r<=(pdi_data[31:28]==OP_DEC); fsm<=S_PDI_NHDR;
        end
        S_PDI_NHDR: if (pdi_valid) begin wcnt<=0; fsm<=S_PDI_NDATA; end
        S_PDI_NDATA: if (pdi_valid) begin
          case (wcnt)
            2'd0: npub0<=pdi_data; 2'd1: npub1<=pdi_data;
            default: npub2<=pdi_data;
          endcase
          if (wcnt==2'd2) fsm<=S_INIT0; else wcnt<=wcnt+2'd1;
        end

        // key/iv words are little-endian byte order on the bus and bits are
        // taken LSB-first within each byte, so the concatenation below is
        // already in Grain's bit order with no reversal needed.
        S_INIT0: begin
          keyb <= {k3,k2,k1,k0};
          ivb  <= {npub2,npub1,npub0};
          lfsr <= {1'b0, 31'h7FFF_FFFF, {npub2,npub1,npub0}};
          nfsr <= {k3,k2,k1,k0};
          acc<=0; sr<=0;
          gmode<=R_INIT; icnt<=9'd0; fsm<=S_INIT_RUN;
        end
        S_INIT_RUN: begin
          lfsr <= {lfsr_in, lfsr[127:1]};
          nfsr <= {nfsr_in, nfsr[127:1]};
          if (icnt==9'd319) begin gmode<=R_ADDKEY; icnt<=9'd0; fsm<=S_ADDK; end
          else icnt<=icnt+9'd1;
        end
        S_ADDK: begin
          lfsr <= {lfsr_in, lfsr[127:1]};
          nfsr <= {nfsr_in, nfsr[127:1]};
          if (icnt==9'd63) begin gmode<=R_NORMAL; icnt<=9'd0; fsm<=S_FILLACC; end
          else icnt<=icnt+9'd1;
        end
        // auth_acc[i] = next_z(), i ascending -- the reference writes index i
        // on iteration i, so the FIRST z lands in acc[0]; shifting in at the
        // top and ending after 64 shifts leaves exactly that arrangement.
        S_FILLACC: begin
          acc  <= {y_out, acc[63:1]};
          lfsr <= {lfsr_in, lfsr[127:1]};
          nfsr <= {nfsr_in, nfsr[127:1]};
          if (icnt==9'd63) begin icnt<=9'd0; fsm<=S_FILLSR; end
          else icnt<=icnt+9'd1;
        end
        S_FILLSR: begin
          sr   <= {y_out, sr[63:1]};
          lfsr <= {lfsr_in, lfsr[127:1]};
          nfsr <= {nfsr_in, nfsr[127:1]};
          if (icnt==9'd63) begin icnt<=9'd0; fsm<=S_PDI_AHDR; end
          else icnt<=icnt+9'd1;
        end

        // ---- associated data: DER(adlen) first, then the AD bytes --------
        S_PDI_AHDR: if (pdi_valid) begin
          ad_len <= pdi_data[15:0];
          rem    <= pdi_data[15:0];
          der_n  <= der_len_of(pdi_data[15:0]);
          der_bytes <= (pdi_data[15:0] < 16'd128)
                       ? {pdi_data[7:0], 16'd0}
                       : (pdi_data[15:0] < 16'd256)
                         ? {8'h81, pdi_data[7:0], 8'd0}
                         : {8'h82, pdi_data[15:8], pdi_data[7:0]};
          der_cnt <= 2'd0;
          in_ad   <= 1'b1; der_phase <= 1'b1;
          fsm <= S_DER;
        end
        S_DER: begin
          curbyte <= (der_cnt==2'd0) ? der_bytes[23:16]
                   : (der_cnt==2'd1) ? der_bytes[15:8] : der_bytes[7:0];
          jcnt<=5'd0; bitpos<=3'd0; fsm<=S_DER_BIT;
        end
        S_DER_BIT: begin
          lfsr <= {lfsr_in, lfsr[127:1]};
          nfsr <= {nfsr_in, nfsr[127:1]};
          if (!is_ks) begin
            if (databit) acc <= acc ^ sr;
            sr <= {zbit, sr[63:1]};
            bitpos <= bitpos + 3'd1;
          end
          if (jcnt==5'd15) begin
            if (der_cnt+2'd1 == der_n)
              fsm <= (ad_len==16'd0) ? S_PDI_PHDR : S_AD_WORD;
            else begin der_cnt <= der_cnt+2'd1; fsm <= S_DER; end
            jcnt<=5'd0;
          end else jcnt <= jcnt + 5'd1;
        end
        S_AD_WORD: begin
          if (rem==16'd0) begin der_phase<=1'b0; fsm<=S_PDI_PHDR; end
          else if (bsel!=2'd0) begin
            curbyte <= (bsel==2'd1) ? inword[15:8]
                     : (bsel==2'd2) ? inword[23:16] : inword[31:24];
            jcnt<=0; bitpos<=0; fsm<=S_AD_BIT;
          end else if (pdi_valid) begin
            inword <= pdi_data; curbyte <= pdi_data[7:0];
            jcnt<=0; bitpos<=0; fsm<=S_AD_BIT;
          end
        end
        S_AD_BIT: begin
          lfsr <= {lfsr_in, lfsr[127:1]};
          nfsr <= {nfsr_in, nfsr[127:1]};
          if (!is_ks) begin
            if (databit) acc <= acc ^ sr;
            sr <= {zbit, sr[63:1]};
            bitpos <= bitpos + 3'd1;
          end
          if (jcnt==5'd15) begin
            jcnt<=5'd0; rem <= rem - 16'd1;
            bsel <= bsel + 2'd1;
            fsm <= S_AD_WORD;
          end else jcnt <= jcnt + 5'd1;
        end

        // ---- message ------------------------------------------------------
        S_PDI_PHDR: if (pdi_valid) begin
          pt_len <= pdi_data[15:0];
          rem    <= pdi_data[15:0];
          bsel<=2'd0; owcnt<=2'd0;
          fsm <= S_DO_PTHDR;
        end
        S_DO_PTHDR: if (do_ready) fsm <= (pt_len==16'd0) ? S_FINAL_Z : S_PT_WORD;
        S_PT_WORD: begin
          if (rem==16'd0) fsm <= S_FINAL_Z;
          else if (bsel!=2'd0) begin
            curbyte <= (bsel==2'd1) ? inword[15:8]
                     : (bsel==2'd2) ? inword[23:16] : inword[31:24];
            jcnt<=0; bitpos<=0; outbyte<=8'd0; fsm<=S_PT_BIT;
          end else if (pdi_valid) begin
            inword <= pdi_data; curbyte <= pdi_data[7:0];
            jcnt<=0; bitpos<=0; outbyte<=8'd0; fsm<=S_PT_BIT;
          end
        end
        // Even j: keystream bit -> output. Odd j: MAC bit. Both walk the
        // same 8 data bits of this byte, so bitpos advances on the ODD
        // phase only (after the even phase has already used the same index),
        // mirroring the reference's two counters advancing in lockstep.
        S_PT_BIT: begin
          lfsr <= {lfsr_in, lfsr[127:1]};
          nfsr <= {nfsr_in, nfsr[127:1]};
          if (is_ks) begin
            outbyte[bitpos] <= outbit;
          end else begin
            if (macbit) acc <= acc ^ sr;
            sr <= {zbit, sr[63:1]};
            bitpos <= bitpos + 3'd1;
          end
          if (jcnt==5'd15) begin
            jcnt<=5'd0; rem <= rem - 16'd1;
            case (bsel)
              2'd0: outword[7:0]   <= outbyte;
              2'd1: outword[15:8]  <= outbyte;
              2'd2: outword[23:16] <= outbyte;
              default: outword[31:24] <= outbyte;
            endcase
            if (bsel==2'd3 || rem==16'd1) fsm <= S_PT_OUT;
            else begin bsel <= bsel + 2'd1; fsm <= S_PT_WORD; end
          end else jcnt <= jcnt + 5'd1;
        end
        S_PT_OUT: if (do_ready) begin
          bsel <= 2'd0;
          fsm <= (rem==16'd0) ? S_FINAL_Z : S_PT_WORD;
        end

        // one discarded z, then the mandatory trailing 1 padding bit
        S_FINAL_Z: begin
          lfsr <= {lfsr_in, lfsr[127:1]};
          nfsr <= {nfsr_in, nfsr[127:1]};
          acc  <= acc ^ sr;
          fsm  <= S_DO_TAGHDR;
        end

        S_DO_TAGHDR: if (do_ready) begin tag_wcnt<=3'd0; fsm<=S_OUT_TAG; end
        S_OUT_TAG: if (do_ready) begin
          if (tag_wcnt==3'd1) fsm <= decrypt_r ? S_PDI_THDR : S_OUT_STATUS;
          else tag_wcnt <= tag_wcnt + 3'd1;
        end
        S_PDI_THDR: if (pdi_valid) begin tag_wcnt<=3'd0; fsm<=S_TAG_WORD; end
        S_TAG_WORD: if (pdi_valid) begin
          if (tag_wcnt==3'd0) begin
            tag_ok <= (pdi_data==acc[31:0]); tag_wcnt<=3'd1;
          end else begin
            tag_ok <= tag_ok & (pdi_data==acc[63:32]);
            fsm <= S_OUT_STATUS;
          end
        end
        S_OUT_STATUS: if (do_ready) fsm <= S_IDLE;
        default: fsm <= S_IDLE;
      endcase
    end
  end

endmodule
