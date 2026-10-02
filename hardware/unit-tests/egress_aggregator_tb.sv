`timescale 1ns / 1ps

// Standalone testbench for the link-level egress aggregate counter copied VERBATIM from
// vfpga_top.svh (lines ~619-653). No package / interface dependencies, so it runs with plain xsim:
//
//   cd ~/oasis/hardware/unit-tests
//   xvlog -sv egress_aggregator_tb.sv
//   xelab -debug typical egress_aggregator_tb -s tb
//   xsim tb -runall
//
// Purpose: the real build (build-34, 1-lane, timing MET) reads agg_beats=6.25M correctly but
// agg_window=0. window <= window + 1 sits in the SAME always_ff as beats, so window must be
// >= beats. This TB drives a realistic tvalid/tready pattern and checks whether the RTL LOGIC
// produces a nonzero window.
//   - window nonzero here  -> RTL is correct  -> the hardware 0 is a SYNTHESIS anomaly.
//   - window zero here     -> real logic bug  -> the waveform shows it.

module egress_aggregator_tb;

    localparam int NUM_STREAMS = 1;

    logic clk = 0;
    logic rst_n = 0;
    always #2 clk = ~clk;   // 250 MHz (4 ns)

    // -- Stimulus: per-stream tvalid / tready (stand in for axis_host_send[i]) -------------------
    logic [NUM_STREAMS-1:0] tvalid, tready;
    logic                   agg_stop;

    logic [31:0] egress_agg_beats, egress_agg_stalled, egress_agg_window;

    // ================= COUNTER LOGIC -- copied verbatim from vfpga_top.svh =====================
    logic [NUM_STREAMS - 1:0] egress_valid, egress_beat, egress_blocked;
    for (genvar I = 0; I < NUM_STREAMS; I++) begin
        assign egress_valid  [I] = tvalid[I];
        assign egress_beat   [I] = tvalid[I] &&  tready[I];
        assign egress_blocked[I] = tvalid[I] && !tready[I];
    end

    logic egress_any_valid, egress_any_blocked;
    logic [$clog2(NUM_STREAMS + 1) - 1:0] egress_beats_this_cycle;

    always_comb begin
        egress_any_valid        = |egress_valid;
        egress_any_blocked      = |egress_blocked;
        egress_beats_this_cycle = '0;
        for (int i = 0; i < NUM_STREAMS; i++) begin
            egress_beats_this_cycle += egress_beat[i];
        end
    end

    logic egress_agg_started;
    always_ff @(posedge clk) begin
        if (!rst_n || agg_stop) begin
            egress_agg_started <= 1'b0;
            egress_agg_beats   <= '0;
            egress_agg_stalled <= '0;
            egress_agg_window  <= '0;
        end else if (egress_agg_started || egress_any_valid) begin
            egress_agg_started <= 1'b1;
            egress_agg_beats   <= egress_agg_beats   + egress_beats_this_cycle;
            egress_agg_stalled <= egress_agg_stalled + egress_any_blocked;
            egress_agg_window  <= egress_agg_window  + 1;
        end
    end
    // ==========================================================================================

    // A software-visible model of what each register SHOULD hold, tracked independently.
    int exp_beats, exp_stalled, exp_window;
    always_ff @(posedge clk) begin
        if (!rst_n || agg_stop) begin
            exp_beats <= 0; exp_stalled <= 0; exp_window <= 0;
        end else if (egress_agg_started || egress_any_valid) begin
            exp_beats   <= exp_beats   + (tvalid[0] && tready[0]);
            exp_stalled <= exp_stalled + (tvalid[0] && !tready[0]);
            exp_window  <= exp_window  + 1;
        end
    end

    task automatic step(input logic v, input logic r);
        tvalid[0] = v; tready[0] = r;
        @(posedge clk);
        #0;
    endtask

    initial begin
        tvalid = '0; tready = '0; agg_stop = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // idle before first beat
        repeat (5) step(1'b0, 1'b0);

        // a "stream": 100 handshakes (valid & ready)
        repeat (100) step(1'b1, 1'b1);

        // 20 stall cycles (valid, not ready)
        repeat (20) step(1'b1, 1'b0);

        // 30 more handshakes
        repeat (30) step(1'b1, 1'b1);

        // tlast-style gap / idle between streams
        repeat (15) step(1'b0, 1'b0);

        // second stream: 50 handshakes
        repeat (50) step(1'b1, 1'b1);

        step(1'b0, 1'b0);

        $display("");
        $display("=== after activity (before any read/stop) ===");
        $display("  beats   = %0d   (expected %0d)", egress_agg_beats,   exp_beats);
        $display("  stalled = %0d   (expected %0d)", egress_agg_stalled, exp_stalled);
        $display("  window  = %0d   (expected %0d)", egress_agg_window,  exp_window);

        if (egress_agg_window == 0)
            $display(">>> window is ZERO -- reproduced in RTL sim: this IS a logic bug.");
        else if (egress_agg_window == exp_window && egress_agg_beats == exp_beats)
            $display(">>> window/beats CORRECT in RTL sim: logic is fine -> hardware 0 is a SYNTHESIS anomaly.");
        else
            $display(">>> MISMATCH (not simple zero) -- inspect waveform.");

        // Now emulate the readout resetting the counters (agg_stop pulse on the 'window' read).
        agg_stop = 1; @(posedge clk); #0; agg_stop = 0;
        @(posedge clk); #0;
        $display("=== after agg_stop pulse (readout reset) ===");
        $display("  beats=%0d stalled=%0d window=%0d (all should be ~0)",
                 egress_agg_beats, egress_agg_stalled, egress_agg_window);

        $finish;
    end

endmodule
