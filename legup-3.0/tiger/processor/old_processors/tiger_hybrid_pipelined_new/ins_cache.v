/*
  This work by Simon Moore and Gregory Chadwick is licenced under the
  Creative Commons Attribution-Non-Commercial-Share Alike 2.0
  UK: England & Wales License.

  To view a copy of this licence, visit:
     http://creativecommons.org/licenses/by-nc-sa/2.0/uk/
  or send a letter to:
     Creative Commons,
     171 Second Street,
     Suite 300,
     San Francisco,
     California 94105,
     USA.
*/
/*
   Cache.v - Toplevel for direct mapped cache for use with the Tiger MIPS
   processor.
   
   The cache is organised into blocks, each block contains several words,
   A memory address is partitioned into a tag which is stored in the cache,
   a cache address which is used to locate a particular block in the cache,
   and a block word which is used to select a word from a block in the cache.
   
   [         tag            | cache address | block word | 0 0 ]
   
   The number of blocks in the cache and number of words per block
   is parameterised.  2^blockSize is the block size in bytes,
   2^cacheSize is the number of blocks in the cache, blockSizeBits
   must give the block size in bits (so blockSizeBits = 2^blockSize * 8).
   
   When modifying blockSize there are two bits of code that must be altered.
   The assignment of memReadDataWord, and the case statement where fetchWord
   is written in the fetch state.
   
   When we lookup an address in the cache we use the cache address portion
   of it to address the internal memory block to retrieve the cache entry,
   we then compare the tag in the cache to the tag of the address, if
   they match and the valid bit is set we have a cache hit, otherwise we
   fetch the entire block from memory (read block number bytes from memory
   starting from the address formed by the tag and cache address with 0s for
   all lower bits).
   
   On a write we immediately start writing the data to memory (write through
   cache behaviour) we also lookup the address in the cache, if we have a hit
   we write the data to the cache as well, otherwise we don't bother.
   
   If the high bit of the address is set the cache is bypassed and data is
   directly read from and written to the avalon bus.
   
   Written by Greg Chadwick, Summer 2007 
*/

module ins_cache (
	input clk,
	input reset_n,

	//CPU side memory control signals
	input memRead,
	input [31:0]memAddress,
	output [31:0]memReadData,

	input flush,

	output canFlush,

	//True if the data on memReadData is valid (i.e. data we've just read from the cache)
	output readDataValid,

	//CPU pipeline stall
	output stall,

	//Avalon Bus side signals
	output reg avm_dataMaster_read,
	output reg [31:0]avm_dataMaster_address,
	output reg avm_dataMaster_beginbursttransfer,
	output reg [2:0]avm_dataMaster_burstcount,
	input [31:0]avm_dataMaster_readdata,
	input avm_dataMaster_waitrequest,
	input avm_dataMaster_readdatavalid
);
	localparam stateIDLE = 0;
	localparam stateREAD = 1;
	localparam stateFETCH = 2;
	localparam stateHOLD = 3;
	localparam stateFLUSH = 4;
	
	localparam blockSize = 4;
	localparam blockSizeBits = 128;
	localparam cacheSize = 9;
	localparam tagSizeBits = 32 - cacheSize - blockSize;
//	localparam burstCount = (2**blockSize)/32; //number of burst to main memory
	localparam burstCount = 3'd4; //number of burst to main memory
	
	wire cacheHit;
	wire [cacheSize - 1 : 0]cacheAddress;
	wire [tagSizeBits - 1 : 0]tag;
	
	reg [31:0]memReadDataWord;
	
	wire cacheWrite;
	wire cacheClkEn;
	wire [blockSizeBits + tagSizeBits : 0]cacheData;
	wire [blockSizeBits + tagSizeBits : 0]cacheQ;
	
	wire [tagSizeBits - 1 : 0]cacheTag;
	wire validBit;
	wire [blockSizeBits - 1 : 0]cacheQData;
	
	wire [tagSizeBits - 1 : 0]savedTag;
	wire [blockSize - 3 : 0]savedBlockWord;
	
	wire fetchDone;
	
	//wire bypassCache; //should we bypass the cache for the current read/write operation?
	reg [31:0]address;
	reg [blockSizeBits - 33 : 0]fetchData;
	reg [blockSize - 3 : 0]fetchWord;
	
	reg [2:0]state;
	reg [cacheSize - 1 : 0]flushAddr;
		
	assign tag = memAddress[31 : cacheSize + blockSize];
	
	assign cacheTag = cacheQ[tagSizeBits : 1];
	assign validBit = cacheQ[0];
	assign cacheQData = cacheQ[blockSizeBits + tagSizeBits : tagSizeBits + 1];
	
	assign savedTag = address[31 : cacheSize + blockSize];
	assign savedBlockWord = address[blockSize  - 1 : 2];
	
	//If we're in the fetch state, the data is valid and we've fetched
	//all but the last word we've done the fetch
//	assign fetchDone = (state == stateFETCH && avm_dataMaster_readdatavalid && fetchWord == blockSize - 1);
	assign fetchDone = (state == stateFETCH && avm_dataMaster_readdatavalid && fetchWord == burstCount - 1);
	
	//If the fetched data from the cache has the valid bit set
	//and the tag is the one we want we have a hit
	
	assign cacheHit = validBit && savedTag == cacheTag; 
	//assign cacheHit = 1'b0; //temp fix
	
	//Stall the pipeline if we're fetching data from memory, or if we've
	//just had a cache miss or if we're trying to write and not in the idle
	//state or if we're bypassing the cache and reading from the avalon bus
	//and the read hasn't completed yet or if we're flushing the cache
	assign stall = state == stateFETCH || (state == stateREAD && !cacheHit) 
		|| (state != stateIDLE && state != stateREAD && memRead)
		|| (state == stateHOLD)
		|| (state == stateFLUSH)
		|| (flush && !canFlush);
	
	//We can start a read in the idle state or the read state if we've had a cache hit
	//assign canRead = state == stateIDLE || (state == stateREAD && cacheHit);
	//We can start a write in the idle state
	//assign canWrite = state == stateIDLE;
	//We can start a flush in the idle state
	assign canFlush = state == stateIDLE || (state == stateREAD && cacheHit);
	
	assign readDataValid = state == stateREAD && cacheHit;
	//If we've just done a fetch we want to write to the correct cache address
	//or if we're writing data we want to write to the correct cache address,
	//if if we're flushing the cache we want to write to the current address we're flushing
	//otherwise we want the address given by memAddress.
	assign cacheAddress = fetchDone ? address[cacheSize + blockSize - 1 : blockSize] :
		state == stateFLUSH  ? flushAddr :
			memAddress[cacheSize + blockSize - 1 : blockSize];

	//If we've just finished fetching, enable write so we can write the fetched
	//data to the cache next cycle or if we need to write data to the cache
	//enable writing
	assign cacheWrite = fetchDone || state == stateFLUSH;
	
	//If we want to read and we're either idle or reading and just had a hit or if we've just finised
	//a fetch then enable the cache memory block clock.  If we want to write and we're idle or we've
	//had a hit (so we can write the data into the cache) enable the cache memory block clock.
	reg fetchDone_reg;
	always @(posedge clk)
	begin
		fetchDone_reg <= fetchDone;
	end
	//added fetchDone_reg to cacheClkEn since cache was turned on when data was being written but turned off when data was being read. It need an one additional cycle after writing to read fetched data.
	assign cacheClkEn = (memRead && (state == stateIDLE || (state == stateREAD && cacheHit))) || fetchDone || state == stateFLUSH || fetchDone_reg;


	//Data to write to the cache, in the format
	//[            data                 | tag | v ]
	//Where v is the valid bit (set if valid)
	//If we're writing and we've had a cache hit we can overwrite what's there
	//with new data, if we're flushing then write 0s, otherwise we just give 
	//data we may have just fetched (The write enable will only be asserted 
	//if we have just fetched this data and want it written)
	assign cacheData = 
		state == stateFLUSH ? {(blockSizeBits + tagSizeBits + 1){1'b0}} :
			{avm_dataMaster_readdata, fetchData, avm_dataMaster_address[31 : cacheSize + blockSize], 1'b1};
	
	//Multiplexer to select which word of the cache block we want
	//if we're reading from the avalon bus, bypass cache and give
	//data read directly from avalon
	always @(*)
	begin
		case(savedBlockWord)
			3'd0 : memReadDataWord = cacheQData[31 : 0];
			3'd1 : memReadDataWord = cacheQData[63 : 32];
			3'd2 : memReadDataWord = cacheQData[95 : 64];
			3'd3 : memReadDataWord = cacheQData[127 : 96];
			default : memReadDataWord = 32'bxxxx_xxxx_xxxx_xxxx_xxxx_xxxx_xxxx_xxxx;
		endcase
	end

	//for instruction cache, always 32-bit data is read out
	assign memReadData = memReadDataWord;
	
	cacheMem cacheMemIns(
						.address(cacheAddress),
						.clken(cacheClkEn),
						.clock(clk),
						.data(cacheData),
						.wren(cacheWrite),
						.q(cacheQ));
	
	always @(posedge clk or negedge reset_n) begin
		if(!reset_n) begin
			state <= stateIDLE;
			avm_dataMaster_read <= 0;
			address <= 0;
			avm_dataMaster_burstcount <= 0;
			avm_dataMaster_beginbursttransfer <= 0;
		end else begin
			case(state)
				stateIDLE: begin
					avm_dataMaster_burstcount <= 1;
					avm_dataMaster_beginbursttransfer <= 0;
					fetchWord <= 0;
					if(memRead) begin //If we want a read start a read
						state <= stateREAD;
						avm_dataMaster_address <= {tag, cacheAddress, {blockSize{1'b0}}};
						address <= memAddress;
					end else if(flush) begin
						state <= stateFLUSH;
						flushAddr <= 0;
					end					
				end
				stateREAD: begin
					avm_dataMaster_burstcount <= 1;
					//If we've had a cache hit either go back to idle
					//or if we want another read continue in the read state
					//or if we want to flush go to the flush state
					if(cacheHit) begin 
						if(flush) begin
							state <= stateFLUSH;
							flushAddr <= 0;
						end else if(!memRead) begin
							state <= stateIDLE;
						end else begin
							state <= stateREAD;
							avm_dataMaster_address <= {tag, cacheAddress, {blockSize{1'b0}}};
							address <= memAddress;							
						end
					end else begin //otherwise fetch data from memory
						state <= stateHOLD;
						avm_dataMaster_read <= 1;
						avm_dataMaster_burstcount <= burstCount;
						avm_dataMaster_beginbursttransfer <= 1;
					end
				end
				stateFETCH: begin
					//If wait request is low we can give another address to read from
/*					if(!avm_dataMaster_waitrequest) begin
						//If we've given address for all the blocks we want, stop reading
						if(avm_dataMaster_address[blockSize - 1 : 0] == {{(blockSize - 2){1'b1}}, 2'b0})
							avm_dataMaster_read <= 0;
						else //Otherwise give address of the next block
							avm_dataMaster_address <= avm_dataMaster_address + 4;
					end
	*/				
					//If we have valid data
					if(avm_dataMaster_readdatavalid) begin
						//store it in the fetchData register if it's not the last word
						//(the last word is fed straight into the data register of the memory
						// block)
						case(fetchWord)
							2'b00:
								fetchData[31:0] <= avm_dataMaster_readdata;
							2'b01:
								fetchData[63:32] <= avm_dataMaster_readdata;
							2'b10:
								fetchData[95:64] <= avm_dataMaster_readdata;
						endcase
						
						fetchWord <= fetchWord + 1'b1;
						//If this is the last word go back to the read state
						if(fetchWord == burstCount - 1) begin
							state <= stateREAD;
						end
					end
				end
				stateHOLD: begin //extra state to begin fetch before it goes into stateFETCH
					avm_dataMaster_beginbursttransfer <= 0;
					if(!avm_dataMaster_waitrequest) begin
						avm_dataMaster_read <= 0;
						state <= stateFETCH;
					end
				end
				stateFLUSH: begin
					flushAddr <= flushAddr + 1'b1;
					if(flushAddr == {cacheSize{1'b1}})
						state <= stateIDLE;
				end
			endcase
		end
	end 			 
endmodule
