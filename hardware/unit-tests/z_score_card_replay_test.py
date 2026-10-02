from libstf_utils.output_writer_test_case import OutputWriterTestCase
from coyote_test import fpga_stream
from unit_test.io_writer import CoyoteOperator, CoyoteStreamType
from unit_test.simulation_time import SimulationTime, SimulationTimeUnit


class ZScoreCardReplayTestCase(OutputWriterTestCase):
    """
    Drives the DECODE-ONCE z-score path: fork -> CardWrite -> HBM, then ZScoreCardReplay reads it
    back for pass 2 so the host only sends the column ONCE.

    Unlike z_score_test.py (which issues two LOCAL_READ/STREAM_HOST transfers for the 2-pass), here:
      pass 1 -> single LOCAL_READ from STREAM_HOST; hardware also stores the column into HBM.
      pass 2 -> hardware self-issues a card read; NO second host transfer.

    Output is identical to the plain z-score: one int32 flag per value (1 = outlier), global stats,
    threshold k = 3 ((n*x - S)^2 > 9*(n*Q - S^2)).
    """

    alternative_vfpga_top_file = "vfpga-tops/z_score_card_replay_test.sv"

    debug_mode = True

    K = 3  # must match the module's K

    def setUp(self):
        super().setUp()
        self.values: list[int] = None

    def _flags(self, values: list[int]) -> list[int]:
        # Golden model: same division-free test as the hardware.
        n = len(values)
        S = sum(values)
        Q = sum(v * v for v in values)
        thresh = (self.K * self.K) * (n * Q - S * S)
        return [1 if (n * v - S) ** 2 > thresh else 0 for v in values]

    def simulate_fpga(self):
        assert self.values, "need input values"
        column = fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, self.values)
        flags = self._flags(self.values)
        expected = fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, flags)

        n_beats = (len(self.values) + 15) // 16
        print(f"\n[z_score_card_replay] {self._testMethodName}")
        print(f"  values   = {self.values}   ({len(self.values)} vals, {n_beats} beat(s))")
        print(f"  expected = {flags}")

        # The HBM round-trip (store DMA -> wait -> read DMA back) exceeds the 4us sim default, so give
        # it room. Bump higher if the waveform shows the run ending mid-replay.
        self.overwrite_simulation_time(SimulationTime.fixed_time(50, SimulationTimeUnit.MICROSECONDS))

        self.simulate_fpga_non_blocking()

        # DECODE-ONCE: send the column ONCE. Pass 1 = this host read (also stored to HBM by CardWrite);
        # pass 2 is replayed from HBM by the hardware, so there is no second host transfer.
        io = self.get_io_writer()
        data = column.data_to_bytearray()
        vaddr = io.allocate_and_write_to_next_free_sim_memory(data)
        io.invoke_transfer(CoyoteOperator.LOCAL_READ, CoyoteStreamType.STREAM_HOST, 0, vaddr, len(data), True)

        self.set_expected_output(0, expected)
        self.finish_fpga_simulation()


class ZScoreCardReplayTest(ZScoreCardReplayTestCase):
    def test_no_outliers(self):
        self.values = [10, 11, 9, 10, 12, 8, 10, 11, 9, 10]
        self.simulate_fpga()
        self.assert_simulation_output()

    def test_single_outlier(self):
        self.values = [10, 11, 9, 10, 12, 8, 10, 11, 9, 10, 100]
        self.simulate_fpga()
        self.assert_simulation_output()

    def test_two_beats(self):
        self.values = [50] * 20 + [500]
        self.simulate_fpga()
        self.assert_simulation_output()
