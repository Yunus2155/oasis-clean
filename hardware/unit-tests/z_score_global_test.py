import unittest

from coyote_test import constants, fpga_register, fpga_stream
from libstf_utils.output_writer_test_case import OutputWriterTestCase
from unit_test.io_writer import CoyoteOperator, CoyoteStreamType


# Register map, mirroring z_score_global_test.sv. GlobalConfig reserves its OWN block first, and its
# size depends on the number of config slots: global_config.sv has NUM_GLOBAL_REGS = 2 + NUM_CONFIGS.
# The other z-score tops use NUM_CONFIGS=1, which is why they write slot 0 at register 3 -- this top
# has two slots, so everything sits one register higher.
NUM_CONFIGS = 2  # must match the GlobalConfig instantiation in z_score_global_test.sv
GLOBAL_REGS = 2 + NUM_CONFIGS
MEM_REGS = max(constants.MAX_NUMBER_STREAMS + 1, 3)
STATS_BASE = GLOBAL_REGS + MEM_REGS

# Write register offsets within ZScoreStatsConfig -- must match hardware/src/hdl/common.sv.
REG_MODE = STATS_BASE + 0
REG_COUNT = STATS_BASE + 1
REG_SUM = STATS_BASE + 2
REG_SUM_SQUARE = STATS_BASE + 3

MODE_LEGACY = 0
MODE_STATS = 1
MODE_CLASSIFY = 2

K = 3  # must match the module's K


def _reg(value: int, signed: bool = False) -> bytearray:
    """AXI-Lite registers are 64 bit here, so every write is 8 little-endian bytes."""
    return bytearray(value.to_bytes(8, "little", signed=signed))


class ZScoreGlobalTestCase(OutputWriterTestCase):
    """
    Drives the two GLOBAL-z-score modes added for whole-column normalisation.

    The hardware only ever sees one parquet row group per stream (tlast arrives per column chunk and
    that is what ends pass 1), so a single stream can only normalise a row group on itself. Since
    count/sum/sum-of-squares are additive, the host instead runs every row group through STATS mode,
    adds the partials up, writes the totals back, and re-runs everything in CLASSIFY mode.

    These tests check the two halves separately:
      STATS    -> one beat of (count, sum, sum_square) per stream, no classification
      CLASSIFY -> no pass 1 at all; flags computed against host-supplied totals
    """

    alternative_vfpga_top_file = "vfpga-tops/z_score_global_test.sv"

    debug_mode = True

    def _feed_once(self, values: list[int]):
        """Streams the column through the operator exactly once (both new modes are single-pass)."""
        column = fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, values)
        io = self.get_io_writer()
        data = column.data_to_bytearray()
        vaddr = io.allocate_and_write_to_next_free_sim_memory(data)
        io.invoke_transfer(
            CoyoteOperator.LOCAL_READ, CoyoteStreamType.STREAM_HOST, 0, vaddr, len(data), True
        )


class ZScoreStatsModeTest(ZScoreGlobalTestCase):
    """STATS mode: pass 1 runs, then one beat carrying this stream's partial statistics."""

    def _expected_stats_beat(self, values: list[int]) -> list[int]:
        # The beat is 512 bits = 16 int32 words. count/sum/sum_square are three int64s in the low 24
        # bytes, so as int32 words: [count_lo, count_hi=0, sum_lo, sum_hi, sq_lo, sq_hi, 0 ...].
        n = len(values)
        s = sum(values)
        q = sum(v * v for v in values)

        def split(v: int) -> list[int]:
            raw = v.to_bytes(8, "little", signed=True)
            lo = int.from_bytes(raw[0:4], "little", signed=True)
            hi = int.from_bytes(raw[4:8], "little", signed=True)
            return [lo, hi]

        words = split(n) + split(s) + split(q)
        return words + [0] * (16 - len(words))

    def run_stats(self, values: list[int]):
        expected = self._expected_stats_beat(values)
        print(f"\n[z_score_global/STATS] {self._testMethodName}")
        print(f"  values   = {values}")
        print(f"  n={len(values)} S={sum(values)} Q={sum(v * v for v in values)}")

        self.simulate_fpga_non_blocking()
        self.write_register(fpga_register.vFPGARegister(REG_MODE, _reg(MODE_STATS)))
        self._feed_once(values)
        self.set_expected_output(
            0, fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, expected)
        )
        self.finish_fpga_simulation()
        self.assert_simulation_output()

    def test_stats_single_beat(self):
        self.run_stats([10, 11, 9, 10, 12, 8, 10, 11, 9, 10])

    def test_stats_two_beats(self):
        # 21 values = 2 beats: checks the partials cover the whole stream, not just the first beat.
        self.run_stats([50] * 20 + [500])

    def test_stats_negative_values(self):
        # sum goes negative -> exercises the signed packing of the stats beat.
        self.run_stats([-10, -11, -9, -10, -12, -8, 100])


class ZScoreClassifyModeTest(ZScoreGlobalTestCase):
    """CLASSIFY mode: no pass 1; the threshold comes entirely from the host-supplied totals."""

    def _flags(self, values: list[int], n: int, s: int, q: int) -> list[int]:
        # Same division-free test as the hardware, but against the SUPPLIED statistics rather than
        # the ones this stream would have produced.
        thresh = (K * K) * (n * q - s * s)
        return [1 if (n * v - s) ** 2 > thresh else 0 for v in values]

    def run_classify(self, values: list[int], stats_values: list[int]):
        """stats_values is the population the totals are computed over -- deliberately allowed to
        differ from `values`, which is the whole point: phase 2 classifies a row group against the
        WHOLE column's statistics."""
        n = len(stats_values)
        s = sum(stats_values)
        q = sum(v * v for v in stats_values)
        flags = self._flags(values, n, s, q)

        print(f"\n[z_score_global/CLASSIFY] {self._testMethodName}")
        print(f"  values   = {values}")
        print(f"  stats    = n={n} S={s} Q={q}  (over {len(stats_values)} values)")
        print(f"  expected = {flags}")

        self.simulate_fpga_non_blocking()
        self.write_register(fpga_register.vFPGARegister(REG_COUNT, _reg(n)))
        self.write_register(fpga_register.vFPGARegister(REG_SUM, _reg(s, signed=True)))
        self.write_register(fpga_register.vFPGARegister(REG_SUM_SQUARE, _reg(q, signed=True)))
        # Mode last: the operator samples the totals when a stream starts, and the host contract is
        # that they are already published by then.
        self.write_register(fpga_register.vFPGARegister(REG_MODE, _reg(MODE_CLASSIFY)))
        self._feed_once(values)
        self.set_expected_output(0, fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, flags))
        self.finish_fpga_simulation()
        self.assert_simulation_output()

    def test_classify_matches_own_stats(self):
        # Totals computed over the same values -> must reproduce the LEGACY answer exactly.
        values = [10, 11, 9, 10, 12, 8, 10, 11, 9, 10, 100]
        self.run_classify(values, values)

    def test_classify_against_wider_population(self):
        # THE case the whole two-phase scheme exists for: this "row group" is uniform, so on its own
        # statistics nothing would be flagged, but against the whole column's spread the 100 is an
        # outlier. LEGACY cannot produce this answer.
        group = [10, 10, 10, 10, 100]
        whole_column = [10, 11, 9, 10, 12, 8, 10, 11, 9, 10] * 3 + [100]
        self.run_classify(group, whole_column)

    def test_classify_two_beats(self):
        values = [50] * 20 + [500]
        self.run_classify(values, values)

    @unittest.skip(
        "Harness limitation, not an operator bug: several LOCAL_READ transfers on one stream are "
        "not delivered back-to-back -- the VCD shows the operator re-arming correctly and waiting "
        "with tready high from 680 ns while tvalid never rises again. Needs one output buffer per "
        "stream to become a real regression test for the re-arm path."
    )
    def test_classify_back_to_back_streams(self):
        """Several CLASSIFY streams in a row against ONE set of totals.

        On hardware the operator re-arms between streams: it resets its accumulators at the last
        output beat, returns to `accumulate`, and reloads the host-supplied totals as soon as the
        next stream's first beat appears. Phase 2 of a real query drives that path once per row
        group -- 335 times for the taxi files -- and a rare, slightly-wrong threshold there is
        exactly the symptom we see in hardware (counts drifting by +-1, occasionally by ~160,
        while the phase-1 totals stay bit-exact). A single-stream test cannot catch it.

        Every stream carries the same values and must therefore produce identical flags; any
        difference between the first stream and a later one is the re-arm bug.
        """
        group = [10, 11, 9, 10, 12, 8, 10, 11, 9, 10, 100]
        n_streams = 4

        n = len(group)
        s = sum(group)
        q = sum(v * v for v in group)
        flags = self._flags(group, n, s, q)

        print(f"\n[z_score_global/CLASSIFY] {self._testMethodName}")
        print(f"  {n_streams} streams x {len(group)} values, stats n={n} S={s} Q={q}")
        print(f"  expected per stream = {flags}")

        self.simulate_fpga_non_blocking()
        self.write_register(fpga_register.vFPGARegister(REG_COUNT, _reg(n)))
        self.write_register(fpga_register.vFPGARegister(REG_SUM, _reg(s, signed=True)))
        self.write_register(fpga_register.vFPGARegister(REG_SUM_SQUARE, _reg(q, signed=True)))
        self.write_register(fpga_register.vFPGARegister(REG_MODE, _reg(MODE_CLASSIFY)))

        # Back-to-back: one allocation, several transfers, so the streams arrive with no host-side
        # gap between them -- the same pressure the phase-2 submit window puts on the operator.
        column = fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, group)
        io = self.get_io_writer()
        data = column.data_to_bytearray()
        vaddr = io.allocate_and_write_to_next_free_sim_memory(data)
        for _ in range(n_streams):
            io.invoke_transfer(
                CoyoteOperator.LOCAL_READ, CoyoteStreamType.STREAM_HOST, 0, vaddr, len(data), True
            )

        # Each stream terminates with its own tlast, so the OutputWriter closes one buffer per
        # stream -- expect them separately rather than as one concatenated result.
        for _ in range(n_streams):
            self.set_expected_output(
                0, fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, flags)
            )
        self.finish_fpga_simulation()
        self.assert_simulation_output()
