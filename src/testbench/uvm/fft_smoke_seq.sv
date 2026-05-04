// fft_smoke_seq.sv — One-shot sequence: fire a single randomized fft_input_txn
//
// Smallest sequence that exercises the full driver path. Later sequences
// (back-to-back, corner-case stimulus, etc.) will replace or extend this.

import fft_txn_pkg::*;

class fft_smoke_seq extends uvm_sequence #(fft_input_txn);

  `uvm_object_utils(fft_smoke_seq)

  function new(string name = "fft_smoke_seq");
    super.new(name);
  endfunction

  task body();
    fft_input_txn tx;
    real pi, theta;
    pi = 3.14159265358979323846;

    tx = fft_input_txn::type_id::create("tx");

    // Freeze twiddles before randomize() — the C reference uses ideal
    // unit-circle twiddles, so any off-circle random value would diverge
    // on every bin. Same approach as fft_random_seq.
    tx.tw_re.rand_mode(0);
    tx.tw_im.rand_mode(0);

    if (!tx.randomize())
      `uvm_fatal("RAND", "fft_input_txn randomize failed")

    // Q12 unit-circle twiddles: tw_re=cos(2πi/32)·4096, tw_im=-sin(...)·4096.
    for (int i = 0; i < NUM_TW; i++) begin
      theta = 2.0 * pi * i / 32.0;
      tx.tw_re[i] = $rtoi($floor( $cos(theta) * 4096.0 + 0.5));
      tx.tw_im[i] = $rtoi($floor(-$sin(theta) * 4096.0 + 0.5));
    end

    start_item(tx);
    finish_item(tx);
  endtask

endclass
