module spi_module #(
    parameter NO_OF_SLAVES   = 2,
    parameter REGISTER_WIDTH = 8,
    parameter ADDR_WIDTH     = 2
)(
    input clk,
    input rst_n,
    // interfata APB
    input  [ADDR_WIDTH-1:0]         paddr,
    input                           psel,
    input                           penable,
    input                           pwrite,
    input  [REGISTER_WIDTH-1:0]     pwdata,
    output reg [REGISTER_WIDTH-1:0] prdata,
    output reg                      pready,
    // interfata SPI
    output reg [NO_OF_SLAVES-1:0]   spi_ss_n,
    output reg                      spi_clk,
    output reg                      spi_mosi,
    input                           spi_miso
);

reg [REGISTER_WIDTH-1:0] spcr;     // registru de control  adresa 0
reg [REGISTER_WIDTH-1:0] spsr;     // registru de stare    adresa 1
reg [REGISTER_WIDTH-1:0] spdr_tx;  // date de trimis la Arduino adresa 3
reg [REGISTER_WIDTH-1:0] spdr_rx;  // date primite de la Arduino adresa 4
reg                      transfer_req; // 1 ciclu → porneste transferul SPI

// scriere APB → registre interne
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        spcr         <= 0;
        spsr         <= 0;
        spdr_tx      <= 0;
        transfer_req <= 0;
    end else begin
        transfer_req <= 0; // implicit 0
        if (psel && penable && pready && pwrite) // faza ACCESS, scriere
            case (paddr)
                2'd0: spcr        <= pwdata;      // scriem in registrul de control
                2'd1: spsr[0]     <= pwdata[0];   // scriem in registrul de stare
                2'd2: begin
                    spdr_tx      <= pwdata;        // scriem data de trimis
                    transfer_req <= 1;             // declanseaza transferul SPI
                end
            endcase
    end

// citire registre interne → APB
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        prdata <= {REGISTER_WIDTH{1'b0}};
    else if (psel && !penable && !pwrite) // faza SETUP, citire
        case (paddr)
            2'd0: prdata <= spcr;    // citim registrul de control
            2'd1: prdata <= spsr;    // citim registrul de stare
            2'd2: prdata <= spdr_rx; // citim datele primite de la Arduino
        endcase

// pready
always @(posedge clk or negedge rst_n)
    if (!rst_n)
        pready <= 1'b0;
    else if (psel && !penable) // faza SETUP → pregatim raspunsul
        pready <= 1'b1;
    else
        pready <= 1'b0;

// SPI state machine → urmatorul pas

endmodule