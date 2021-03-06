/*  Copyright 2014 Aaron Boxer (boxerab@gmail.com)

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>. */


#include "ocl_platform.cl"

//////////////////////////
// dimensions of window
// WIN_SIZE_X	
// WIN_SIZE_Y assume this equals number of work items in work group
///////////////////////////


//  scratch buffer (in local memory of GPU) where block of input image is stored.
//  All operations expect WIN_SIZE_Y threads.

 /**

Layout for scratch buffer

Odd and even rows are separated. (Generates less bank conflicts when using lifting scheme.)
All even rows are stored first, then all odd rows.

Left (even) boundary row
Even rows
Right (even) boundary row
Left (odd) boundary row
Odd rows
Right (odd) boundary row

 **/

#define BOUNDARY_Y 4

#define HORIZONTAL_STRIDE 64  // WIN_SIZE_X/2 


// two vertical neighbours: pointer diff:
#define BUFFER_SIZE            512	// HORIZONTAL_STRIDE * WIN_SIZE_X


#define CHANNEL_BUFFER_SIZE     1024            // BUFFER_SIZE + BUFFER_SIZE

#define CHANNEL_BUFFER_SIZE_X2  2048   
#define CHANNEL_BUFFER_SIZE_X3  3072   

#define PIXEL_BUFFER_SIZE   4096

#define VERTICAL_EVEN_TO_PREVIOUS_ODD  511
#define VERTICAL_EVEN_TO_NEXT_ODD      512

#define VERTICAL_ODD_TO_PREVIOUS_EVEN_MINUS_ONE -513
#define VERTICAL_ODD_TO_PREVIOUS_EVEN -512
#define VERTICAL_ODD_TO_NEXT_EVEN     -511
#define VERTICAL_ODD_TO_NEXT_EVEN_PLUS_ONE     -510

#define P1  -1.586134342f 
#define U1  -0.05298011854f  
#define P2  0.8829110762f 
#define U2  0.4435068522f   

// U1 * P1
#define U1P1  0.08403358545952490068f

#define scale97Mul  1.23017410491400f
#define scale97Div   0.81289306611596153187273657637352f

/*

Lifting scheme consists of four steps: Predict1 Update1 Predict2 Update2
followed by scaling (even points are scaled by scale97Div, odd points are scaled by scale97Mul)


Predict Calculation:

For S odd, we have:


plusOne_P1 = plusOne + P1*(current + plusTwo)

plusOne_P2 = plusOne_P1 + 
             P2*(current_U1 + plusTwo_U1)
           =   plusOne + P1*(current + plusTwo) +
		         P2*(current + U1*(minusOne + plusOne) + U1P1*(minusTwo + 2*current + plusTwo) + 
				     plusTwo + U1*(plusOne + plusThree) + U1P1*(current + 2*plusTwo + plusFour)  )



Update Calculation

For S even, we have

current_U1 = current + U1*(minusOne_P1 + plusOne_P1)
           = current + U1*(minusOne + P1*(minusTwo + current) + plusOne + P1*(current + plusTwo))
		   = current + U1*(minusOne + plusOne) + U1P1*(minusTwo + 2*current + plusTwo)

current_U2 = current_U1 + U2*(minusOne_P2 + plusOne_P2)

*/
  

///////////////////////////////////////////////////////////////////////

CONSTANT sampler_t sampler = CLK_NORMALIZED_COORDS_TRUE | CLK_ADDRESS_MIRRORED_REPEAT  | CLK_FILTER_NEAREST;

inline int getCorrectedGlobalIdY() {
      return getGlobalId(1) - 2 * BOUNDARY_Y * getGroupId(1);
}


// read pixel from local buffer
inline float4 readPixel( LOCAL float*  restrict  src) {
	return (float4)(*src, *(src+CHANNEL_BUFFER_SIZE),  *(src+CHANNEL_BUFFER_SIZE_X2),  *(src+CHANNEL_BUFFER_SIZE_X3)) ;
}

//write pixel to column
inline void writePixel(float4 pix, LOCAL float*  restrict  dest) {
	*dest = pix.x;
	dest += CHANNEL_BUFFER_SIZE;
	*dest = pix.y;
	dest += CHANNEL_BUFFER_SIZE;
	*dest = pix.z;
	dest += CHANNEL_BUFFER_SIZE;
	*dest = pix.w;
}

// write row to destination
void writeRowToOutput(LOCAL float* restrict currentScratch, write_only image2d_t odata, 
																		unsigned int firstX, unsigned int outputY, unsigned int width, unsigned int halfWidth){

	int2 posOut = {firstX>>1, outputY};
	for (int j = 0; j < WIN_SIZE_X; j+=2) {
	
	    // low pass
		//only need to check evens, since even point will be the first out of bound point
	    if (posOut.x >= halfWidth)
			break;

		write_imagef(odata, posOut,scale97Div * readPixel(currentScratch));

		// high pass
		currentScratch += HORIZONTAL_STRIDE ;
		posOut.x+= halfWidth;

		write_imagef(odata, posOut,scale97Mul * readPixel(currentScratch));

		currentScratch += HORIZONTAL_STRIDE;
		posOut.x -= (halfWidth - 1);
	}
}

// write row to destination
void writeRowToMixedOutput(LOCAL float* restrict currentScratch, write_only image2d_t odataLL, write_only image2d_t odata, 
																		unsigned int firstX, unsigned int outputY, unsigned int width, unsigned int halfWidth){

	int2 posOut = {firstX>>1, outputY};
	for (int j = 0; j < WIN_SIZE_X; j+=2) {
	
	    // low pass
		//only need to check evens, since even point will be the first out of bound point
	    if (posOut.x >= halfWidth)
			break;

		write_imagef(odataLL, posOut,scale97Div * readPixel(currentScratch));

		// high pass
		currentScratch += HORIZONTAL_STRIDE ;
		posOut.x+= halfWidth;

		write_imagef(odata, posOut,scale97Mul * readPixel(currentScratch));

		currentScratch += HORIZONTAL_STRIDE;
		posOut.x -= (halfWidth - 1);
	}
}

// initial scratch offset when transforming horizontally
inline unsigned int getScratchOffset(){
   return (getLocalId(1)>> 1) + (getLocalId(1)&1) * BUFFER_SIZE;
}

// assumptions: width and height are both even
// (we will probably have to relax these assumptions in the future)
void KERNEL run(read_only image2d_t idata, write_only image2d_t odataLL, write_only image2d_t odata, 
                       const unsigned int  width, const unsigned int  height, const unsigned int steps,
					   const unsigned int  level, const unsigned int levels) {

	int inputY = getCorrectedGlobalIdY();
	int outputY = -1;
	if (inputY < height && inputY >= 0)
	    outputY = (inputY >> 1) + (inputY & 1)*( height >> 1);
	bool pureOutput = (inputY&1) || (level == levels-1);

	bool writeRow = ((getLocalId(1) >= BOUNDARY_Y) && ( getLocalId(1) < WIN_SIZE_Y - BOUNDARY_Y) && outputY != -1);
	bool doP2 = false;
	bool doU2 = false;
	if (getLocalId(1)&1)
		doP2 = (getLocalId(1) >= BOUNDARY_Y-1) && (getLocalId(1) < WIN_SIZE_Y-BOUNDARY_Y);
	else
		doU2 = (getLocalId(1) >= BOUNDARY_Y) && (getLocalId(1) < WIN_SIZE_Y-BOUNDARY_Y) ;

    const unsigned int halfWidth = width >> 1;
	LOCAL float scratch[PIXEL_BUFFER_SIZE];
	const float xDelta = 1.0/(width-1);
	int firstX = getGlobalId(0) * (steps * WIN_SIZE_X);
	
	//0. Initialize: fetch first pixel (and 2 top boundary pixels)

	// read -4 point
	float2 posIn = (float2)(firstX-4, inputY) /  (float2)(width-1, height-1);	
	float4 minusFour = read_imagef(idata, sampler, posIn);

	posIn.x += xDelta;
	float4 minusThree = read_imagef(idata, sampler, posIn);

	// read -2 point
	posIn.x += xDelta;
	float4 minusTwo = read_imagef(idata, sampler, posIn);

	// read -1 point
	posIn.x += xDelta;
	float4 minusOne = read_imagef(idata, sampler, posIn);

	// read 0 point
	posIn.x += xDelta;
	float4 current = read_imagef(idata, sampler, posIn);

	// +1 point
	posIn.x += xDelta;
	float4 plusOne = read_imagef(idata, sampler, posIn);

	// +2 point
	posIn.x += xDelta;
	float4 plusTwo = read_imagef(idata, sampler, posIn);

	float4 minusThree_P1 = minusThree + P1*(minusFour + minusTwo);
	float4 minusOne_P1   = minusOne   + P1*(minusTwo + current);
	float4 plusOne_P1    = plusOne    + P1*(current + plusTwo);

	float4 minusTwo_U1 = minusTwo + U1*(minusThree_P1 + minusOne_P1);
	float4 current_U1  = current + U1*(minusOne_P1 + plusOne_P1);
	float4 minusOne_P2 = minusOne_P1 + P2*(minusTwo_U1 + current_U1);
		
	for (int i = 0; i < steps; ++i) {

		// 1. read from source image, transform rows, and store in local scratch
		LOCAL float* currentScratch = scratch + getScratchOffset();
		for (int j = 0; j < WIN_SIZE_X; j+=2) {

	        //read next two points

			// +3 point
			posIn.x += xDelta;
			float4 plusThree = read_imagef(idata, sampler, posIn);
	   
	   		// +4 point
			posIn.x += xDelta;
	   		if (posIn.x > 1 + 3*xDelta)
				break;
			float4 plusFour = read_imagef(idata, sampler, posIn);

			float4 plusThree_P1    = plusThree  + P1*(plusTwo + plusFour);
			float4 plusTwo_U1      = plusTwo + U1*(plusOne_P1 + plusThree_P1);
			float4 plusOne_P2      = plusOne_P1 + P2*(current_U1 + plusTwo_U1);
								 
					  
			//write current U2 (even)
			writePixel(scale97Div * (current_U1 +  U2 * (minusOne_P2 + plusOne_P2)), currentScratch);

			//advance scratch pointer
			currentScratch += HORIZONTAL_STRIDE;

			//write current P2 (odd)
			writePixel(scale97Mul* plusOne_P2 , currentScratch);

			//advance scratch pointer
			currentScratch += HORIZONTAL_STRIDE;

			// shift registers up by two
			minusFour = minusTwo;
			minusThree = minusOne;
			minusTwo = current;
			minusOne = plusOne;
			current = plusTwo;
			plusOne = plusThree;
			plusTwo = plusFour;
			//update P1s
			minusThree_P1 = minusOne_P1;
			minusOne_P1 = plusOne_P1;
			plusOne_P1 = plusThree_P1;

			//update U1s
			minusTwo_U1 = current_U1;
			current_U1 = plusTwo_U1;

			//update P2s
			minusOne_P2 = plusOne_P2;
		}

		
		//4. transform vertically
		currentScratch = scratch + getScratchOffset();	

		
		localMemoryFence();
		// P2 - predict odd columns (skip left three boundary columns and all right boundary columns)
		if ( doP2 ) {
			for (int j = 0; j < WIN_SIZE_X; j++) {
				float4 minusOne = readPixel(currentScratch -1);
				float4 plusOne = readPixel(currentScratch);
				float4 plusThree = readPixel(currentScratch + 1); 

				float4 minusTwo, current,plusTwo, plusFour;

				minusTwo.x = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN_MINUS_ONE];
				current.x  = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN];
				plusTwo.x  = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN];
				plusFour.x = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN_PLUS_ONE];

				currentScratch += CHANNEL_BUFFER_SIZE;
				minusTwo.y = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN_MINUS_ONE];
				current.y  = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN];
				plusTwo.y  = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN];
				plusFour.y = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN_PLUS_ONE];

				currentScratch += CHANNEL_BUFFER_SIZE;
				minusTwo.z = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN_MINUS_ONE];
				current.z  = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN];
				plusTwo.z  = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN];
				plusFour.z = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN_PLUS_ONE];


				currentScratch += CHANNEL_BUFFER_SIZE;
				minusTwo.w = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN_MINUS_ONE];
				current.w  = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN];
				plusTwo.w  = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN];
				plusFour.w = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN_PLUS_ONE];

				currentScratch -= CHANNEL_BUFFER_SIZE_X3;

				float4 current_U1 = current + U1*(minusOne + plusOne) + U1P1*(minusTwo + 2*current + plusTwo);

				// write P2
				writePixel( scale97Mul*(plusOne + P1*(current + plusTwo) +
		         				      P2*(current_U1 + plusTwo + U1*(plusOne + plusThree) +
									  U1P1*(current + 2*plusTwo + plusFour)  )),
									  currentScratch);
				// write U1, for use by even loop
				writePixel(current_U1, currentScratch + VERTICAL_ODD_TO_PREVIOUS_EVEN);

				currentScratch += HORIZONTAL_STRIDE;
			}
		}
		

		currentScratch = scratch + getScratchOffset();	
		localMemoryFence();
		//U2 - update even columns (skip left and right boundary columns)
		if ( doU2 ) {
			for (int j = 0; j < WIN_SIZE_X; j++) {

				float4 current = readPixel(currentScratch);

				// read previous and next odd
				float4 prevOdd, nextOdd;

				prevOdd.x = currentScratch[VERTICAL_EVEN_TO_PREVIOUS_ODD];
				nextOdd.x  = currentScratch[VERTICAL_EVEN_TO_NEXT_ODD];


				currentScratch += CHANNEL_BUFFER_SIZE;
				prevOdd.y = currentScratch[VERTICAL_EVEN_TO_PREVIOUS_ODD];
				nextOdd.y  = currentScratch[VERTICAL_EVEN_TO_NEXT_ODD];

				currentScratch += CHANNEL_BUFFER_SIZE;
				prevOdd.z = currentScratch[VERTICAL_EVEN_TO_PREVIOUS_ODD];
				nextOdd.z  = currentScratch[VERTICAL_EVEN_TO_NEXT_ODD];


				currentScratch += CHANNEL_BUFFER_SIZE;
				prevOdd.w = currentScratch[VERTICAL_EVEN_TO_PREVIOUS_ODD];
				nextOdd.w  = currentScratch[VERTICAL_EVEN_TO_NEXT_ODD];

				currentScratch -= CHANNEL_BUFFER_SIZE_X3;
				//////////////////////////////////////////////////////////////////

				// write U2
				writePixel( scale97Div*(current + U2*(prevOdd + nextOdd)), currentScratch);
				currentScratch += HORIZONTAL_STRIDE;
			}
		}
		localMemoryFence();
		


		//5. write local buffer column to destination image
		// (only write non-boundary columns that are within the image bounds)
		if (writeRow) {
		   if (pureOutput)
			   writeRowToOutput(scratch + getScratchOffset(), odata, firstX, outputY, width, halfWidth);
			else
			   writeRowToMixedOutput(scratch + getScratchOffset(), odataLL, odata, firstX, outputY, width, halfWidth);

		}
		// move to next step 
		firstX += WIN_SIZE_X;
	}
}

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// DWT with Quantization
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// write quantized low and high bands (relative to horizontal axis)
void writeQuantizedRowToOutput(LOCAL float* restrict currentScratch, write_only image2d_t odata, 
													unsigned int firstX, unsigned int outputY, unsigned int width, unsigned int halfWidth,
													 const float quantLow, const float quantHigh){

	int2 posOut = {firstX>>1, outputY};
	for (int j = 0; j < WIN_SIZE_X; j+=2) {
	
	    // low pass
		//only need to check evens, since even point will be the first out of bound point
	    if (posOut.x >= halfWidth)
			break;

		write_imagei(odata, posOut, convert_int4_rte(ceil(quantLow * readPixel(currentScratch))) );

		// high pass
		currentScratch += HORIZONTAL_STRIDE ;
		posOut.x+= halfWidth;

		write_imagei(odata, posOut, convert_int4_rte(ceil(quantHigh * readPixel(currentScratch))) );

		currentScratch += HORIZONTAL_STRIDE;
		posOut.x -= (halfWidth - 1);
	}
}


// write low and high bands (relative to horizontal axis)
// low band is not quantized, but high band is
// odata is integer buffer (use quantization), while odataLL is float buffer (no quantization) 
void writeMixedQuantizedRowToOutput(LOCAL float* restrict currentScratch, write_only image2d_t odataLL,
										 write_only image2d_t odata, unsigned int firstX, unsigned int outputY, unsigned int width, unsigned int halfWidth,
										  const float quantLow, const float quantHigh){

	int2 posOut = {firstX>>1, outputY};
	for (int j = 0; j < WIN_SIZE_X; j+=2) {
	
	    // low pass
		//only need to check evens, since even point will be the first out of bound point
	    if (posOut.x >= halfWidth)
			break;

		write_imagef(odataLL, posOut,quantLow * readPixel(currentScratch));

		// high pass
		currentScratch += HORIZONTAL_STRIDE ;
		posOut.x+= halfWidth;

		write_imagei(odata, posOut, convert_int4_rte(ceil(quantHigh * readPixel(currentScratch))) );

		currentScratch += HORIZONTAL_STRIDE;
		posOut.x -= (halfWidth - 1);
	}
}



// assumptions: width and height are both even
// (we will probably have to relax these assumptions in the future)
void KERNEL runWithQuantization(read_only image2d_t idata,  write_only image2d_t odataLL, write_only image2d_t odata,
                       const unsigned int  width, const unsigned int height, const unsigned int steps,
					   const unsigned int  level, const unsigned int levels, 
					   const float quantLL, const float quantLH, const float quantHH) {

	int inputY = getCorrectedGlobalIdY();
	int outputY = -1;
	if (inputY < height && inputY >= 0)
	    outputY = (inputY >> 1) + (inputY & 1)*( height >> 1);
	bool writeRow = ((getLocalId(1) >= BOUNDARY_Y) && ( getLocalId(1) < WIN_SIZE_Y - BOUNDARY_Y) && outputY != -1);
	bool doP2 = false;
	bool doU2 = false;
	if (getLocalId(1)&1)
		doP2 = (getLocalId(1) >= BOUNDARY_Y-1) && (getLocalId(1) < WIN_SIZE_Y-BOUNDARY_Y);
	else
		doU2 = (getLocalId(1) >= BOUNDARY_Y) && (getLocalId(1) < WIN_SIZE_Y-BOUNDARY_Y) ;

    bool oddInputY = inputY &1;
	bool pureOutput = oddInputY || (level == levels-1);
	const float quantLow = (oddInputY ? quantLH : quantLL) * scale97Div;
	const float quantHigh = (oddInputY ? quantHH : quantLH) * scale97Mul;

    const unsigned int halfWidth = width >> 1;
	LOCAL float scratch[PIXEL_BUFFER_SIZE];
	const float xDelta = 1.0/(width-1);
	int firstX = getGlobalId(0) * (steps * WIN_SIZE_X);
	
	//0. Initialize: fetch first pixel (and 2 top boundary pixels)

	// read -4 point
	float2 posIn = (float2)(firstX-4, inputY) /  (float2)(width-1, height-1);	
	float4 minusFour = read_imagef(idata, sampler, posIn);

	posIn.x += xDelta;
	float4 minusThree = read_imagef(idata, sampler, posIn);

	// read -2 point
	posIn.x += xDelta;
	float4 minusTwo = read_imagef(idata, sampler, posIn);

	// read -1 point
	posIn.x += xDelta;
	float4 minusOne = read_imagef(idata, sampler, posIn);

	// read 0 point
	posIn.x += xDelta;
	float4 current = read_imagef(idata, sampler, posIn);

	// +1 point
	posIn.x += xDelta;
	float4 plusOne = read_imagef(idata, sampler, posIn);

	// +2 point
	posIn.x += xDelta;
	float4 plusTwo = read_imagef(idata, sampler, posIn);

	float4 minusThree_P1 = minusThree + P1*(minusFour + minusTwo);
	float4 minusOne_P1   = minusOne   + P1*(minusTwo + current);
	float4 plusOne_P1    = plusOne    + P1*(current + plusTwo);

	float4 minusTwo_U1 = minusTwo + U1*(minusThree_P1 + minusOne_P1);
	float4 current_U1  = current + U1*(minusOne_P1 + plusOne_P1);
	float4 minusOne_P2 = minusOne_P1 + P2*(minusTwo_U1 + current_U1);
		
	for (int i = 0; i < steps; ++i) {

		// 1. read from source image, transform rows, and store in local scratch
		LOCAL float* currentScratch = scratch + getScratchOffset();
		for (int j = 0; j < WIN_SIZE_X; j+=2) {

	        //read next two points

			// +3 point
			posIn.x += xDelta;
			float4 plusThree = read_imagef(idata, sampler, posIn);
	   
	   		// +4 point
			posIn.x += xDelta;
	   		if (posIn.x > 1 + 3*xDelta)
				break;
			float4 plusFour = read_imagef(idata, sampler, posIn);

			float4 plusThree_P1    = plusThree  + P1*(plusTwo + plusFour);
			float4 plusTwo_U1      = plusTwo + U1*(plusOne_P1 + plusThree_P1);
			float4 plusOne_P2      = plusOne_P1 + P2*(current_U1 + plusTwo_U1);
								 
					  
			//write current U2 (even)
			writePixel(scale97Div * (current_U1 +  U2 * (minusOne_P2 + plusOne_P2)), currentScratch);

			//advance scratch pointer
			currentScratch += HORIZONTAL_STRIDE;

			//write current P2 (odd)
			writePixel(scale97Mul* plusOne_P2 , currentScratch);

			//advance scratch pointer
			currentScratch += HORIZONTAL_STRIDE;

			// shift registers up by two
			minusFour = minusTwo;
			minusThree = minusOne;
			minusTwo = current;
			minusOne = plusOne;
			current = plusTwo;
			plusOne = plusThree;
			plusTwo = plusFour;
			//update P1s
			minusThree_P1 = minusOne_P1;
			minusOne_P1 = plusOne_P1;
			plusOne_P1 = plusThree_P1;

			//update U1s
			minusTwo_U1 = current_U1;
			current_U1 = plusTwo_U1;

			//update P2s
			minusOne_P2 = plusOne_P2;
		}

		
		//4. transform vertically
		currentScratch = scratch + getScratchOffset();	

		
		localMemoryFence();
		// P2 - predict odd columns (skip left three boundary columns and all right boundary columns)
		if ( doP2 ) {
			for (int j = 0; j < WIN_SIZE_X; j++) {
				float4 minusOne = readPixel(currentScratch -1);
				float4 plusOne = readPixel(currentScratch);
				float4 plusThree = readPixel(currentScratch + 1); 

				float4 minusTwo, current,plusTwo, plusFour;

				minusTwo.x = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN_MINUS_ONE];
				current.x  = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN];
				plusTwo.x  = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN];
				plusFour.x = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN_PLUS_ONE];

				currentScratch += CHANNEL_BUFFER_SIZE;
				minusTwo.y = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN_MINUS_ONE];
				current.y  = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN];
				plusTwo.y  = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN];
				plusFour.y = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN_PLUS_ONE];

				currentScratch += CHANNEL_BUFFER_SIZE;
				minusTwo.z = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN_MINUS_ONE];
				current.z  = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN];
				plusTwo.z  = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN];
				plusFour.z = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN_PLUS_ONE];


				currentScratch += CHANNEL_BUFFER_SIZE;
				minusTwo.w = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN_MINUS_ONE];
				current.w  = currentScratch[VERTICAL_ODD_TO_PREVIOUS_EVEN];
				plusTwo.w  = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN];
				plusFour.w = currentScratch[VERTICAL_ODD_TO_NEXT_EVEN_PLUS_ONE];

				currentScratch -= CHANNEL_BUFFER_SIZE_X3;

				float4 current_U1 = current + U1*(minusOne + plusOne) + U1P1*(minusTwo + 2*current + plusTwo);

				// write P2
				writePixel( scale97Mul*(plusOne + P1*(current + plusTwo) +
		         				      P2*(current_U1 + plusTwo + U1*(plusOne + plusThree) +
									  U1P1*(current + 2*plusTwo + plusFour)  )),
									  currentScratch);
				// write U1, for use by even loop
				writePixel(current_U1, currentScratch + VERTICAL_ODD_TO_PREVIOUS_EVEN);

				currentScratch += HORIZONTAL_STRIDE;
			}
		}
		

		currentScratch = scratch + getScratchOffset();	
		localMemoryFence();
		//U2 - update even columns (skip left and right boundary columns)
		if ( doU2 ) {
			for (int j = 0; j < WIN_SIZE_X; j++) {

				float4 current = readPixel(currentScratch);

				// read previous and next odd
				float4 prevOdd, nextOdd;

				prevOdd.x = currentScratch[VERTICAL_EVEN_TO_PREVIOUS_ODD];
				nextOdd.x  = currentScratch[VERTICAL_EVEN_TO_NEXT_ODD];


				currentScratch += CHANNEL_BUFFER_SIZE;
				prevOdd.y = currentScratch[VERTICAL_EVEN_TO_PREVIOUS_ODD];
				nextOdd.y  = currentScratch[VERTICAL_EVEN_TO_NEXT_ODD];

				currentScratch += CHANNEL_BUFFER_SIZE;
				prevOdd.z = currentScratch[VERTICAL_EVEN_TO_PREVIOUS_ODD];
				nextOdd.z  = currentScratch[VERTICAL_EVEN_TO_NEXT_ODD];


				currentScratch += CHANNEL_BUFFER_SIZE;
				prevOdd.w = currentScratch[VERTICAL_EVEN_TO_PREVIOUS_ODD];
				nextOdd.w  = currentScratch[VERTICAL_EVEN_TO_NEXT_ODD];

				currentScratch -= CHANNEL_BUFFER_SIZE_X3;
				//////////////////////////////////////////////////////////////////

				// write U2
				writePixel( scale97Div*(current + U2*(prevOdd + nextOdd)), currentScratch);
				currentScratch += HORIZONTAL_STRIDE;
			}
		}
		localMemoryFence();
		


		//5. write local buffer column to destination image
		if (writeRow) {
		
		   if (pureOutput)
			   writeQuantizedRowToOutput(scratch + getScratchOffset(), odata, firstX, outputY, 
			                            width, halfWidth, quantLow, quantHigh);
			else
			   writeMixedQuantizedRowToOutput(scratch + getScratchOffset(), odataLL, odata, firstX, outputY, 
										width, halfWidth, quantLow, quantHigh);
										
		}
		// move to next step 
		firstX += WIN_SIZE_X;
	}
}
