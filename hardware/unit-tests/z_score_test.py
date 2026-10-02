from libstf_utils.output_writer_test_case import OutputWriterTestCase
from coyote_test import fpga_stream
from unit_test.io_writer import CoyoteOperator, CoyoteStreamType


class ZScoreTestCase(OutputWriterTestCase):
    """
    Drives celeris my_z_score_squared.sv in the oasis sim: z-score outlier detection
    (division-free).

    TWO-PASS operator, so the host sends the SAME column twice:
      pass 1 -> accumulate stats (S, Q, n)
      pass 2 -> classify each value, emitting one flag (1 = outlier, 0 = normal)

    Output = one int32 flag per input value, using the global stats of the column.
    Threshold k = 3 (the module compares (n*x - S)^2 > 9*(n*Q - S^2)).
    """

    alternative_vfpga_top_file = "vfpga-tops/z_score_test.sv"

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
        print(f"\n[z_score] {self._testMethodName}")
        print(f"  values   = {self.values}   ({len(self.values)} vals, {n_beats} beat(s))")
        print(f"  expected = {flags}")

        self.simulate_fpga_non_blocking()

        # 2-pass feed: the z-score reads the SAME column twice (pass 1 accumulates
        # stats, pass 2 classifies). We allocate the column ONCE and issue two
        # LOCAL_READ transfers from the same vaddr -- mirroring the real host re-read.
        # (Calling set_stream_input_batched twice allocates two separate last-marked
        # buffers on one stream, which the oasis sim generator faults on.)
        io = self.get_io_writer()
        data = column.data_to_bytearray()
        vaddr = io.allocate_and_write_to_next_free_sim_memory(data)
        io.invoke_transfer(CoyoteOperator.LOCAL_READ, CoyoteStreamType.STREAM_HOST, 0, vaddr, len(data), True)  # pass 1
        io.invoke_transfer(CoyoteOperator.LOCAL_READ, CoyoteStreamType.STREAM_HOST, 0, vaddr, len(data), True)  # pass 2

        self.set_expected_output(0, expected)
        self.finish_fpga_simulation()


class ZScoreTest(ZScoreTestCase):
    def test_no_outliers(self):
        # tight cluster -> nobody is > 3 sigma
        self.values = [10, 11, 9, 10, 12, 8, 10, 11, 9, 10]
        self.simulate_fpga()
        self.assert_simulation_output()

    def test_single_outlier(self):
        # 10 clustered values + one far value (100); only the 100 is an outlier
        self.values = [10, 11, 9, 10, 12, 8, 10, 11, 9, 10, 100]
        self.simulate_fpga()
        self.assert_simulation_output()

    def test_two_beats(self):
        # 21 values = 2 beats; the 500 (in the 2nd beat) is the outlier
        self.values = [50] * 20 + [500]
        self.simulate_fpga()
        self.assert_simulation_output()
