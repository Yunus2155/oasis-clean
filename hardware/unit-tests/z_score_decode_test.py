from coyote_test import fpga_test_case, fpga_stream, fpga_register, simulation_time


# -- Minimal Thrift/Parquet helpers --------------------------------------------------
# Inlined from parcore's page_header_parser_test / column_chunk_decoder_test so this
# test stays self-contained (no pyarrow dependency, no extra PYTHONPATH entry).

def _zigzag_encode(n: int) -> int:
    return (n << 1) ^ (n >> 31)


def _encode_varint(n: int) -> bytearray:
    n = _zigzag_encode(n)
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            b |= 0x80
        out.append(b)
        if not n:
            break
    return out


def _make_data_page_header(num_values: int, uncompressed_size: int,
                           compressed_size: int, encoding: int) -> bytearray:
    """Minimal Thrift compact DataPageHeader (no CRC, no statistics)."""
    h = bytearray()
    h += b'\x15' + _encode_varint(0)                # fid1: page_type=DATA_PAGE(0)
    h += b'\x15' + _encode_varint(uncompressed_size)
    h += b'\x15' + _encode_varint(compressed_size)
    h += b'\x2c'                                     # fid5: data_page_header STRUCT
    h += b'\x15' + _encode_varint(num_values)        # inner fid1: num_values
    h += b'\x15' + _encode_varint(encoding)          # inner fid2: encoding
    h += b'\x15' + _encode_varint(0)                 # inner fid3: def_level_enc=PLAIN
    h += b'\x15' + _encode_varint(0)                 # inner fid4: rep_level_enc=PLAIN
    h += b'\x00'                                     # inner STOP
    h += b'\x00'                                     # outer STOP
    return h


def _make_def_levels(num_values: int) -> bytes:
    # RLE/bit-packing hybrid, bit_width=1, all values = 1 (all present).
    header = num_values << 1
    varint = []
    v = header
    while True:
        b = v & 0x7f
        v >>= 7
        if v:
            varint.append(b | 0x80)
        else:
            varint.append(b)
            break
    rle_body = bytes(varint) + bytes([0x01])
    return len(rle_body).to_bytes(4, 'little') + rle_body


class ZScoreDecodeTestCase(fpga_test_case.FPGATestCase):
    """
    Integration test: ColumnChunkDecoder -> my_z_score_squared.

    A PLAIN-encoded int32 column chunk is decoded by ParCore; the decoded values
    then flow through the z-score operator. The SAME chunk is fed twice (two
    decodes) so the z-score gets its two passes (pass 1 = stats, pass 2 = classify).
    Output = one int32 flag per value (1 = outlier). Threshold k = 3.
    """

    alternative_vfpga_top_file = "vfpga-tops/z_score_decode_test.sv"
    debug_mode = True

    K = 3            # must match the module's K
    TYPE_T_INT32 = 1  # stream_type_to_libstf_type_t(SIGNED_INT_32)

    def _flags(self, values: list[int]) -> list[int]:
        # Golden model: same division-free test as the hardware.
        n = len(values)
        S = sum(values)
        Q = sum(v * v for v in values)
        thresh = (self.K * self.K) * (n * Q - S * S)
        return [1 if (n * v - S) ** 2 > thresh else 0 for v in values]

    def _plain_int32_chunk(self, items: list[int]) -> bytearray:
        values = fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, items).data_to_bytearray()
        def_levels = _make_def_levels(len(items))
        payload = bytearray(def_levels) + bytearray(values)
        hdr = _make_data_page_header(len(items), len(payload), len(payload), encoding=0)  # PLAIN
        return bytearray(hdr) + payload

    def _chunk_register(self, num_values: int, compression: int = 0) -> bytearray:
        # column_chunk_conf_t (MSB->LSB): compression[1] | num_values[32] | type_t[3]
        packed = (compression << 35) | ((num_values & 0xFFFFFFFF) << 3) | (self.TYPE_T_INT32 & 0x7)
        return bytearray(packed.to_bytes(8, 'little'))

    def run_zscore(self, values: list[int]):
        chunk = self._plain_int32_chunk(values)
        flags = self._flags(values)

        print(f"\n[z_score_decode] {self._testMethodName}")
        print(f"  values   = {values}")
        print(f"  expected = {flags}")

        # Run until the design is done -- decode + z-score is a longer pipeline.
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())

        # 2-pass: feed the SAME chunk twice -> two decodes -> z-score pass 1 + pass 2.
        # One chunk-config register write per decode (GlobalConfig occupies regs 0..2,
        # so the chunk config is register 3, mirroring column_chunk_decoder_test).
        self.write_register(fpga_register.vFPGARegister(3, self._chunk_register(len(values))))
        self.write_register(fpga_register.vFPGARegister(3, self._chunk_register(len(values))))
        self.set_stream_input(0, chunk)
        self.set_stream_input(0, chunk)
        self.set_expected_output(0, fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, flags))

        self.simulate_fpga()
        self.assert_simulation_output()


class ZScoreDecodeTest(ZScoreDecodeTestCase):
    def test_no_outliers(self):
        self.run_zscore([10, 11, 9, 10, 12, 8, 10, 11, 9, 10])

    def test_single_outlier(self):
        self.run_zscore([10, 11, 9, 10, 12, 8, 10, 11, 9, 10, 100])
