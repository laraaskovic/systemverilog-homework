//----------------------------------------------------------------------------
// Example
//----------------------------------------------------------------------------

module mux_2_1
(
  input        [3:0] d0, d1,
  input              sel,
  output logic [3:0] y
);

  always_comb
    if (sel)
      y = d1;
    else
      y = d0;

endmodule

//----------------------------------------------------------------------------
// Task
//----------------------------------------------------------------------------

module mux_4_1
(
  input        [3:0] d0, d1, d2, d3,
  input        [1:0] sel,
  output logic [3:0] y
);

  // Task:
  // Using code for mux_2_1 as an example,
  // write code for 4:1 mux using the "if" statement
  always_comb
    if (sel[1]) begin // if 1 then d2/3
      if (sel[0])
        y = d3;      
      else 
        y = d2;
    end
    else begin
      if (sel[0])
        y = d1;
      else
        y = d0;
    end

endmodule
