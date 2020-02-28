// this will be a module to access a 1Mx8 SRAM / flash module such as I own for soldering practice. They will be useful for
// testing data structure acceleration, too, I reckon.

`default_nettype none

// timing constants generated by data/sram_config.py
// run from the data directory with e.g.
//python3 sram_config.py 12000000 > ../sram_sim_config.inc
//python3 sram_config.py 6000000 > ../sram_build_config.inc
// current versions were created thus, assuming a 6 MHz clock for top.
// presumably can run much faster.
`ifndef SIM_STEP
`include "./sram_build_config.inc"
`else
`include "./sram_sim_config.inc"
`endif


//right so let's do this iteratively.
//parameterize the address and data widths bc let's get used to that. 1Mx8 is 20 bits addr, 8 bits data
//then have a flag for read or write, where 1 = write
//one for reset a la wishbone
//later have handshakey stuff. For the moment, start with one byte. Later do multi byte read/write.
//THIS NEEDS TO TALK TO THE CHIP DIRECTLY, YES?
//so address will come from mentor, and this will register it and pass it along - I don't think
//we want the address to go straight from caller to pins. Likewise data... so how do we handle that?
//pin connections have to be in the top module's ports, yes? Well, I guess so. Figure out how to verify.
// OK SO WHY DON'T WE JUST DO THIS WISHBONE CLASSIC NON-PIPELINED bc that is nice and standard and
// I understand it. baby yoda steps!
// Could first try with a single read/single write only, and then support block?
// why not.
// so, the latest commit before I try changing all of everything is:
// commit 1017599c0c9acc4150620f4ebab5a9a67c8a1f07 (HEAD -> master, origin/master, origin/HEAD)
//Author: Sean Igo <samwibatt@gmail.com>
//Date:   Sat Feb 15 12:05:02 2020 -0800
//    progress on state machine yay
// *************************************************************************************************
// SO: looking in the wishbone spec 4,
// 3.5.6 Data Organization for 8-bit Ports
// shows how you can order 8 bit data for big endian or little endian transfers of
// >8 bit quantities.
// There doesn't appear to be any limitation on address width, except that it be <= 64 bits
// Data, not as sure, but it looks like 8, 16, 32, and 64 are the allowable widths and
// granularities.
// in this case I will use 8 bit width and granularity, so everything is really straightforward.
// let's use tags, or be ready to, start with teeny 2-bit ones by default.
module sram_1Mx8 #(parameter ADDR_WIDTH=20, parameter DATA_WIDTH=8,
    parameter DTAG_WIDTH=2, parameter ATAG_WIDTH=2, parameter CTAG_WIDTH=2) (
    //syscon stuff
    input wire CLK_I,       //was i_clk,
    input wire RST_I,       //was i_reset,
    //inputs from MENTOR
    input wire WE_I,        //was i_write,
    input wire[ADDR_WIDTH-1:0] ADR_I,       //was i_addr,
    input wire[ATAG_WIDTH-1:0] TGA_I,       //address tag, get used to
    input wire[DATA_WIDTH-1:0] DAT_I,       //was i_data, //data from mentor, for writes
    input wire[DTAG_WIDTH-1:0] TGD_I,       //data tag for incoming data, get used to
    input wire LOCK_I,                      //lock flag, ignore signals from any other mentor. Worry re yet?
    input wire SEL_I,                       //select... for 8 bit data, shouldn't need it, but get used to it.
    input wire CYC_I,                       //cycle flag
    input wire[CTAG_WIDTH-1:0] TGC_I,       //cycle tag, get used to
    input wire STB_I,                       //strobe
    //output to MENTOR
    output wire[DATA_WIDTH-1:0] DAT_O,      //was o_data, //data to mentor, for reads
    output wire ACK_O,                      //acknowledge
    //output wire STALL_I,                  //stall is only for pipelined
    output wire ERR_O,                      //error
    output wire RTY_O,                      //retry
    //non-Wishbone stuff such as pins out to actual RAM chip
    output wire[ADDR_WIDTH-1:0] o_addr,     //connects straight to pins
    inout wire[DATA_WIDTH-1:0] io_c_data,   //straight to pins
    output wire o_n_oe,                     //~OE (active low output enable), to pins, purely controlled by this module
    output wire o_n_we                      //~WE (active low write enable), to pins
    );


    /* now designing actual state machine
    * much of this comes from my wiki 00-what the module does page
    * only now it's from data/sram_config.py
    * idle, keep the pins hi-z
        - from https://electronics.stackexchange.com/questions/22220/how-to-assign-value-to-bidirectional-port-in-verilog
        If you must use any port as inout, Here are few things to remember:

        1. You can't read and write inout port simultaneously, hence kept highZ for reading.
        2. inout port can NEVER be of type reg.
        3. There should be a condition at which it should be written. (data in mem should be written when
           Write = 1 and should be able to read when Write = 0).
        For e.g. I'll write your code in following way.

        module test (value, var);
          inout value;
          output reg var;
          assign value = (condition) ? <some value / expression> : 'bz;
          always @(<event>)
            var = value;
        endmodule

        BTW When var is of type wire, you can read it in following fashion:

        assign var = (different condition than writing) ? value : [something else];

        Hence as you can see there is no restriction how to read it but inout port MUST
        be written the way shown above.

        ------
        (Other example moved below by assigns)


    * then for read and write ops:
    * could do something like I did with the LCD piece where I used a counter for the state machine, hd44780_nybsen.v - had the python script that could calculate the delays, and I could do a thing like that for the RAM timing and test it with a few values like 48MHz which in theory the up5K could do.
        * and have it err on the side of slow s.t. anything that should get a delay does get a cycle
        * can tighten it all up later, first get it to work!

    ***************** PUT THE STATE MACHINE DESCRIPTION HERE!
    # * so given that the chip enables are always set, read cycle 2:
    #     * at idle both ~OE and ~WE high
    #     * mark cycle start, or whatever
    #     * mark busy
    #     * set address (would also set CE lines here too)
    #     * (would be a wait then set BLE/BHE, though those are also glued)
    #     * wait - tACE - tDOE = max 45 - max 22 = 23 ns?
    ticks_tace_tdoe = ticks_per_ns(23,g_sysfreq)
    #     * drop ~OE
    #     * wait tDOE = max 22ns
    ticks_tdoe = ticks_per_ns(22,g_sysfreq)
    #     * latch data
    #     * mark ready for mentor to harvest the byte?
    #     * wait for rest of tRC ... I think can do 0
    #
    #
    #
    # * then can do subsequent bytes, as many as needed, rdcyc 1
    #     * mark busy
    #     * change address
    #     * wait tAA = max 45ns
    ticks_taa = ticks_per_ns(45,g_sysfreq)
    #     * latch data
    #     * mark ready for mentor to harvest
    # * to wrap up,
    #     * raise ~OE
    #     * wait tHZOE = max 18ns (note 29, I/Os are in output, do not apply signal)
    ticks_thzoe = ticks_per_ns(18,g_sysfreq)
    #     * mark cycle end
    #
    #
    #
    # * write: Looks like I'm using write cycle 1 from the docs...?
    #     * address
    #     * raise ~OE - or is it already?
    #     * wait tHZOE = max 18 ns (note 29, I/Os are in output, do not apply signal)
    # already got thzoe
    #     * wait tSA - tHZOE = min 0 ns, no max ....??? let's do 1 tick
    ticks_tsa_thzoe = ticks_per_ns(1,g_sysfreq)
    #         * Write cycle 1 timings are subject to the notes 26 27 and 28:
    #           "26. The internal write time of the memory is defined by the overlap of WE, CE =
    #           V IL , BHE, BLE or both = V IL , and CE 2 = V IH . All signals must be active to initiate
    #           a write and any of these signals can terminate a write by going inactive. The data
    #           input setup and hold timing must be referenced to the edge of the signal that
    #           terminates the write. (In my case that'd be ~WE, bc all the others are hardwired)
    #           27. Data I/O is high impedance if OE = V IH .
    #           28. If CE 1 goes HIGH and CE 2 goes LOW simultaneously with WE = V IH , the output
    #           remains in a high impedance state.
    #           29. During this period (raise ~OE), the I/Os are in output state. Do not apply input signals.
    #     * drop ~WE
    #     * wait...??? no time given
    #     * present data on output pins
    #     * wait for rest of write length, tPWE = 35 ns?
    ticks_tpwe = ticks_per_ns(35,g_sysfreq)
    #     * raise ~WE
    #     * wait tHD = min 0...? not less than 1 tick, say
    ticks_thd = ticks_per_ns(1,g_sysfreq)
    #     * wait the rest of tWC = 45 ns, so
    #         * really tHA - tHD = min 0... so I guess rest of 45ns
    #         * not less than 1 tick
    ticks_tha_thd = ticks_per_ns(max(1,45 - (ticks_tsa_thzoe + ticks_tpwe + ticks_thd)),g_sysfreq)

    THESE ARE EMITTED AS THE FOLLOWING DEFINES IN THE CONFIG .INC FILE:
    `define SR_SYSFREQ         (6_000_000)
    `define SR_TICKS_TACE_TDOE (1)
    `define SR_TICKS_TDOE      (1)
    `define SR_TICKS_TAA       (1)
    `define SR_TICKS_THZOE     (1)
    `define SR_TICKS_TSA_THZOE (1)
    `define SR_TICKS_TPWE      (1)
    `define SR_TICKS_THD       (1)
    `define SR_TICKS_THA_THD   (1)
    // count bits must accommodate max of readcycle2 ticks=(2) readcycle1 ticks=(2) and writecycle1 ticks=(4) so 4
    `define SRNS_COUNT_BITS    (3)
    */

    //declarations
    //keep the input address in a nice stable register so we're not sensitive to
    //irrelevant changes to the input addr port during operations. Also, for
    //multibyte contiguous transfers we want to be able to increment it within the module ...?
    //or does the mentor keep sending new addrs? Even then we'll want to sync it. So register.
    //yeah, mentor keeps sending new values. That way it can be contiguous or not, and we
    //send back or receive one byte at a time - ? yes, see state machine
    reg [ADDR_WIDTH-1:0] addr_reg = 0;
    reg [DATA_WIDTH-1:0] data_reg = 0;
    //similarly preserve whether current operation is a write;
    //shouldn't get changed during cycle, I'd think. Verify w/wishbone docs and
    //be ready to enforce with formal verification
    reg write_reg = 0;
    //similar, cycle register.
    //TODO find out if all signals are supposed to be synched, I think they are.
    //in any case latching cyc at every clock seems like a good idea, investigate timing.
    reg cyc_reg = 0;


    //other wishbone signals: ack, err, retry
    reg ack_reg = 0;
    reg err_reg = 0;
    reg retry_reg = 0;

    //then regs for the ~WE and ~OE pins
    //BOTH POSITIVE LOGIC IN REG AND NEGATIVE IN OUTPUT!
    //so that zeroing them disables both in reset
    reg o_oe_reg = 0;
    reg o_we_reg = 0;

    //actual state machine - will try it my usual way with synch and <=
    //and here is our "state downcounter" - load with the total number of ticks in the cycle,
    //immediately after reset is raised, then downcount. Cycle is done when counter reaches
    //0, and various signals are triggered at points along the way calculated from the config
    //file's timing constants.
    reg[`SRNS_COUNT_BITS-1:0] STDC = 0;
    // mode: 0 means ...idle, 1 means read initial, 2 means read subsequent, 3 means write
    localparam  SRMODE_NONE  = 0;
    localparam  SRMODE_RD1ST = 1;
    localparam  SRMODE_RDSUB = 2;
    localparam  SRMODE_WRT   = 3;
    reg[1:0] mode = 0;      //HARDCODED #bits to hold mode, adjust as necessary
    //do I need some state machine logic *outside* the count? like IDLE, WAIT_FOR_STBDROP,
    //RUNNING (during which it's uninterruptible and does the counter), ACK, DONE?
    //I need to write this down and plan it out, I suppose
    localparam SRST_IDLE    = 0;
    localparam SRST_STBWAIT = 1;
    localparam SRST_RUNNING = 2;
    localparam SRST_SENDACK = 3;
    localparam SRST_DONE    = 4;
    localparam SRST_ERROR   = 5;
    reg[2:0] state = 0;      //HARDCODED #bits to hold state, adjust as necessary


    always @(posedge CLK_I) begin
        if(RST_I) begin
            //reset! zero out address, make all the i/o pins hi-z
            //hi-z has to happen in assign block bc wires
            //data will always be hi-z when reset is active and also otherwise unless
            //write_reg is true
            addr_reg <= 0;
            data_reg <= 0;
            write_reg <= 0;
            cyc_reg <= 0;
            mode <= 0;
            STDC <= 0;
            //other wishbone signals: ack, err, retry
            ack_reg <= 0;
            err_reg <= 0;
            retry_reg <= 0;
            o_oe_reg <= 0;
            o_we_reg <= 0;
            //and state!
            state <= SRST_IDLE;
        end else begin
            //latch cycle register every tick
            //is this going to lag too much to be useful?
            //TODO keep an eye on timing
            cyc_reg <= CYC_I;

            //not in reset, we are in state machine!
            case (state)
                SRST_IDLE: begin
                    //Here we are awaiting a strobe from the mentor
                    if(STB_I) begin
                        //latch write / address / data at this point (?) see wb spec
                        //latching data in read mode isn't meaningful but it's probably not good
                        //to leave things unassigned. ??? or should we latch only if in write
                        //and otherwise 0 out?
                        addr_reg <= ADR_I;
                        write_reg <= WE_I;
                        state = SRST_STBWAIT;
                        //should we also do the counter load here? let's.
                        //fetch clock start value from config include; rd1st is read cycle 1,
                        //wrt is write cycle 1.
                        //TODO figure out how to do SRMODE_RDSUB
                        if(WE_I) begin
                            //latch data in
                            data_reg <= DAT_I;
                            mode <= SRMODE_WRT;
                            STDC <= `SR_WRITE1_TICKS;
                        end else begin
                            //zero out data reg bc data in is meaningless in a read.
                            //could be a debug sentinel
                            data_reg <= 0;
                            mode <= SRMODE_RD1ST;
                            STDC <= `SR_READ2_TICKS;
                        end
                    end
                end

                SRST_STBWAIT: begin
                    //wait for strobe to drop before starting the counter
                    //it will be all ready to go bc st on exit of SRST_IDLE
                    //after this, until we return to idle, strobe will be ignored.
                    //TODO: find out if I need to set some kind of busy signal for this
                    if(!STB_I) begin
                        state <= SRST_RUNNING;
                    end
                end

                SRST_RUNNING: begin
                    //sub-state-machine! downcount and send signals as appropriate
                    if(|STDC) begin
                        //downcounter is not zero, count down
                        //this doesn't happen until the end of the clock, so can still compare
                        //to the 'current' value
                        STDC <= STDC - 1;
                        //do a case on mode and have logic inside the cases. gross but should work.
                        case (mode)
                            //maybe should make localparams for these? Defines probably even better.
                            //order by length of time, why not.
                            SRMODE_RD1ST: begin
                                //here would go the "if tree" checking against timings, according to mode.
                                if(STDC == `SR_READ2_OEON) begin
                                    o_oe_reg <= 1;  //enable (lower) ~OE but our register is poslogic so raise
                                end else if(STDC == `SR_READ2_LATCH) begin
                                    data_reg <= io_c_data;
                                end
                            end

                            SRMODE_RDSUB: begin
                                //here would go the "if tree" checking against timings, according to mode.
                                // TODO WRITE ME ****************************************************************************************************
                                // TODO WRITE ME ****************************************************************************************************
                                // TODO WRITE ME ****************************************************************************************************
                            end

                            SRMODE_WRT: begin
                                //here would go the "if tree" checking against timings, according to mode.
                                // TODO WRITE ME ****************************************************************************************************
                                // TODO WRITE ME ****************************************************************************************************
                                // TODO WRITE ME ****************************************************************************************************
                                if(STDC == `SR_WRITE1_NEWADDR) begin
                                    //address should already be in place. make sure output enable is disabled
                                    o_oe_reg <= 0;
                                end else if(STDC == `SR_WRITE1_WEON) begin
                                    //data should already be ready on the data pins, enable write enable
                                    //but if data ISN't on the pins, put it there here
                                    o_we_reg <= 1;
                                end else if(STDC == `SR_WRITE1_WEOFF) begin
                                    //by now the data should have been written to the ram, disable we
                                    o_we_reg <= 0;
                                end
                                    //then after this there's no other control stuff, currently.
                            end

                            default: begin                 //should this generate an error? yeah, let's do that
                                state <= SRST_ERROR;
                            end
                        endcase
                    end else begin
                        //counter is 0!
                        //conclude whatever needs concluding by mode
                        //ASSUMING THAT THE _DONE VALUES FOR ALL THE MODES IS 0.
                        case (mode)
                            SRMODE_RD1ST: begin
                                // and if there are no subsequent bytes, disable (raise) ~OE
                                //TODO figure out how to know this. Cycle? YES! From WB4 spec,
                                //CYC_I
                                //The cycle input [CYC_I], when asserted, indicates that a valid bus cycle is in progress. The
                                //signal is asserted for the duration of all bus cycles. For example, during a BLOCK transfer
                                //cycle there can be multiple data transfers. The [CYC_I] signal is asserted during the first
                                //data transfer, and remains asserted until the last data transfer.
                                // SR_READ2_DONE      (0)
                                if(!cyc_reg) begin
                                    o_oe_reg <= 0;
                                end
                            end

                            SRMODE_RDSUB: begin
                                //if this is the last byte, disable (raise) ~OE by lowering our positive logic regr
                                //SR_READ1_DONE
                                if(!cyc_reg) begin
                                    o_oe_reg <= 0;
                                end
                            end

                            SRMODE_WRT: begin
                                //I don't think anything else needs to be done here
                                state <= SRST_DONE;         //TODO figure out
                            end

                            default: begin                 //should this generate an error? with count = 0, it's not as bad...?
                                state <= SRST_DONE;         //TODO figure out
                            end
                        endcase
                        // PUT THIS BACK IN if I need the extra state for ack send
                        //state <= SRST_SENDACK;
                        //otherwise I'm moving its contents here:
                        //raise ack
                        ack_reg <= 1;
                        state <= SRST_DONE;
                        //should I zero out write_reg here too to make sure data pins are hi-z?
                        //yeah let's
                        write_reg <= 0;
                    end
                end

                /* this state seems wasteful. Put it back if timings are too tight, which I don't expect.
                SRST_SENDACK: begin
                    //raise ack
                    ack_reg <= 1;
                    state <= SRST_DONE;
                    //should I zero out write_reg here too to make sure data pins are hi-z?
                    //yeah let's
                    write_reg <= 0;
                end
                */

                SRST_DONE: begin
                    //lower (keep low) ack
                    ack_reg <= 0;
                    //TODO: figure out what other signal stuff needs to change
                    //probably in every case zero out write reg or otherwise assure the
                    //data i/o pins are at high-z? yeah, for now at least
                    write_reg <= 0;
                    state <= SRST_IDLE;
                end

                SRST_ERROR: begin
                    err_reg <= 1;
                    //what else to do? clear all the signals?
                    //do we have to wait for mentor to address this,
                    //or just pulse it?
                    //TODO FIGURE OUT
                end

                default: begin
                    //always have a default!
                    //error?
                    //treat like a reset?
                    addr_reg <= 0;
                    data_reg <= 0;
                    write_reg <= 0;
                    cyc_reg <= 0;
                    mode <= 0;
                    STDC <= 0;
                    //other wishbone signals: ack, err, retry
                    ack_reg <= 0;
                    err_reg <= 0;       //TODO DECIDE IF GO TO ERROR STATE
                    retry_reg <= 0;
                    o_oe_reg <= 0;
                    o_we_reg <= 0;
                    //and state!
                    state <= SRST_IDLE;
                end

            endcase
        end
    end

    //assigns, I like to group them after the clockyblock bc why not
    // recall that inouts must use this form:
    //output reg var;
    //assign value = (condition) ? <some value / expression> : 'bz;
    //always @(<event>)
    //  var = value;
    // so, looks like you can always read, but write
    // perhaps a bit clearer is the other example
    /*
    module bidirec (oe, clk, inp, outp, bidir);

        // Port Declaration
        input   oe;
        input   clk;
        input   [7:0] inp;
        output  [7:0] outp;
        inout   [7:0] bidir;

        reg     [7:0] a;
        reg     [7:0] b;

        assign bidir = oe ? a : 8'bZ ;
        assign outp  = b;

        // Always Construct
        always @ (posedge clk)
        begin
            b <= bidir;
            a <= inp;
        end
    endmodule
    */
    //inout wire[DATA_WIDTH-1:0] io_c_data,              //straight to pins
    //so if we're in reset, we want hi-z; if writing, want value, so
    //we want value when (NOT reset) AND writing, yes? otherwise hi-z
    //how to do variable-width hi-z? Per https://stackoverflow.com/questions/18328006/how-can-i-set-a-full-variable-constant
    //you do a = {`SIZE{1'b1}};
    //slightly different here bc we're using a parameter and not a define, so don't need backtick
    assign io_c_data = (!RST_I & write_reg) ? data_reg : {DATA_WIDTH{1'bz}};

    //and address
    assign o_addr = addr_reg;

    //sending back to mentor with some other wires
    assign DAT_O = data_reg;        //Is this right? data_reg latches DAT_I for writes, ram return for reads...?
                                    //need to assign it *something*

    assign ACK_O = ack_reg;         //acknowledge
    assign ERR_O = err_reg;         //error
    assign RTY_O = retry_reg;       //retry

    assign o_n_oe = ~o_oe_reg;      //output enable
    assign o_n_we = ~o_we_reg;      //write enable

endmodule
