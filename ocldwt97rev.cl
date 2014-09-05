/*  Copyright 2014 Aaron Boxer

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>. */


#include "ocl_platform.cl"

//////////////////////////
// dimensions of window
// WIN_SIZE_X	assume this equals number of work items in work group
// WIN_SIZE_Y
///////////////////////////


//  scratch buffer (in local memory of GPU) where block of input image is stored.
//  All operations expect WIN_SIZE_X threads.

 /**

Layout for scratch buffer

Odd and even columns are separated. (Generates less bank conflicts when using lifting scheme.)
All even columns are stored first, then all odd columns.

Left (even) boundary column
Even Columns
Right (even) boundary column
Left (odd) boundary column
Odd Columns
Right (odd) boundary column

 **/

#define BOUNDARY_Y 4

#define HORIZONTAL_STRIDE 64  // WIN_SIZE_Y/2 


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

CONSTANT float RevU2 = -0.4435068522;    ///< undo 9/7 update 2
CONSTANT float RevP2 = -0.8829110762;  ///< undo 9/7 predict 2
CONSTANT float RevU1 = 0.05298011854;    ///< undo 9/7 update 1
CONSTANT float RevP1 = 1.586134342;  ///< undo 9/7 predict 1

CONSTANT float RevU1P1 = 0.08403358545952490068;


CONSTANT float scale97Mul = 1.23017410491400f;
CONSTANT float scale97Div = 1.0 / 1.23017410491400f;

/*

Reverse Lifting scheme consists of reverse scaling followed by four steps: 
ReverseUpdate2 ReversePredict2 ReverseUpdate1 ReversePredict1   

Even points are scaled by scale97Mul, odd points are scaled by scale97Div.


Update Calculation

For S even, we have

current_RevU2 = current + RevU2*(minusOne + plusOne);

current_RevU1 = current_RevU2 + RevU1*(minusOne_RevP2 + plusOne_RevP2);
   
              = current + RevU2*(minusOne + plusOne) + 
			     RevU1*(plusOne + RevP2*( minusTwo + RevU2*(minusThree + minusOne) +  current + RevU2*(minusOne + plusOne)) + 
				        plusOne + RevP2*( current + RevU2*(minusOne + plusOne) +  plusTwo + RevU2*(plusOne + plusThree)) );

Predict Calculation:

For S odd, we have:

plusOne_RevP2 = plusOne + RevP2*(current_RevU2 + plusTwo_RevU2);

              = plusOne + RevP2*( current + RevU2*(minusOne + plusOne) +  plusTwo + RevU2*(plusOne + plusThree));


plusOne_RevP1 = plusOne_RevP2 + RevP1*(current_RevU2 + plusTwo_RevU2);


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

// write column to destination
void writeColumnToOutput(LOCAL float* restrict currentScratch, __write_only image2d_t odata, int firstX, int inputY, int height, int halfHeight){

	int2 posOut = {firstX>>1, inputY};
	for (int j = 0; j < WIN_SIZE_Y; j+=2) {
	
	    // even row
		
		//only need to check evens, since even point will be the first out of bound point
	    if (posOut.y >= halfHeight)
			break;

		write_imagef(odata, posOut,readPixel(currentScratch));

		// odd row
		currentScratch += HORIZONTAL_STRIDE ;
		posOut.y+= halfHeight;

		write_imagef(odata, posOut,readPixel(currentScratch));

		currentScratch += HORIZONTAL_STRIDE;
		posOut.y -= (halfHeight - 1);
	}
}

// initial scratch offset when transforming vertically
inline int getScratchOffset(){
   return (getLocalId(1)>> 1) + (getLocalId(1)&1) * BUFFER_SIZE;
}

// assumptions: width and height are both even
// (we will probably have to relax these assumptions in the future)
void KERNEL run(__read_only image2d_t idata, __write_only image2d_t odata,   
                       const unsigned int  width, const unsigned int  height, const unsigned int steps) {

	int inputY = getCorrectedGlobalIdY();

	int outputX = inputY;
	outputX = (outputX >> 1) + (outputX & 1)*( width >> 1);

    const unsigned int halfHeight = height >> 1;
	LOCAL float scratch[PIXEL_BUFFER_SIZE];
	const float yDelta = 1.0/(height-1);
	int firstX = getGlobalId(1) * (steps * WIN_SIZE_Y);
	
	//0. Initialize: fetch first pixel (and 2 top boundary pixels)

	// read -4 point
	float2 posIn = (float2)(inputY, firstX - 4) /  (float2)(width-1, height-1);	
	float4 minusFour = scale97Mul*read_imagef(idata, sampler, posIn);

	posIn.y += yDelta;
	float4 minusThree = scale97Div*read_imagef(idata, sampler, posIn);

	// read -2 point
	posIn.y += yDelta;
	float4 minusTwo = scale97Mul*read_imagef(idata, sampler, posIn);

	// read -1 point
	posIn.y += yDelta;
	float4 minusOne = scale97Div*read_imagef(idata, sampler, posIn);

	// read 0 point
	posIn.y += yDelta;
	float4 current = scale97Mul*read_imagef(idata, sampler, posIn);

	// +1 point
	posIn.y += yDelta;
	float4 plusOne = scale97Div*read_imagef(idata, sampler, posIn);

	// +2 point
	posIn.y += yDelta;
	float4 plusTwo = scale97Mul*read_imagef(idata, sampler, posIn);

	/*
	float4 minusThree_P1 = minusThree + P1*(minusFour + minusTwo);
	float4 minusOne_P1   = minusOne   + P1*(minusTwo + current);
	float4 plusOne_P1    = plusOne    + P1*(current + plusTwo);

	float4 minusTwo_U1 = minusTwo + U1*(minusThree_P1 + minusOne_P1);
	float4 current_U1  = current + U1*(minusOne_P1 + plusOne_P1);
	float4 minusOne_P2 = minusOne_P1 + P2*(minusTwo_U1 + current_U1);
		*/
	for (int i = 0; i < steps; ++i) {

		// 1. read from source image, transform columns, and store in local scratch
		LOCAL float* currentScratch = scratch + getScratchOffset();
		for (int j = 0; j < WIN_SIZE_Y; j+=2) {

	        //read next two points

			// +3 point
			posIn.y += yDelta;
			float4 plusThree = scale97Div*read_imagef(idata, sampler, posIn);
	   
	   		// +4 point
			posIn.y += yDelta;
	   		if (posIn.y > 1 + 3*yDelta)
				break;
			float4 plusFour = scale97Mul*read_imagef(idata, sampler, posIn);

			/*
			float4 plusThree_P1    = plusThree  + P1*(plusTwo + plusFour);
			float4 plusTwo_U1      = plusTwo + U1*(plusOne_P1 + plusThree_P1);
			float4 plusOne_P2      = plusOne_P1 + P2*(current_U1 + plusTwo_U1);
								 
					  
			//write current U2 (even)
			writePixel( (current_U1 +  U2 * (minusOne_P2 + plusOne_P2)), currentScratch);

			//advance scratch pointer
			currentScratch += HORIZONTAL_STRIDE;

			//write current P2 (odd)
			writePixel(plusOne_P2 , currentScratch);

			//advance scratch pointer
			currentScratch += HORIZONTAL_STRIDE;
			*/


			// shift registers up by two
			minusFour = minusTwo;
			minusThree = minusOne;
			minusTwo = current;
			minusOne = plusOne;
			current = plusTwo;
			plusOne = plusThree;
			plusTwo = plusFour;

			/*
			//update P1s
			minusThree_P1 = minusOne_P1;
			minusOne_P1 = plusOne_P1;
			plusOne_P1 = plusThree_P1;

			//update U1s
			minusTwo_U1 = current_U1;
			current_U1 = plusTwo_U1;

			//update P2s
			minusOne_P2 = plusOne_P2;
			*/
		}

		
		//4. transform horizontally
		currentScratch = scratch + getScratchOffset();	

		
		localMemoryFence();
		// P2 - odd columns (skip left three boundary columns and all right boundary columns)
		if ( (getLocalId(0)&1) && (getLocalId(0) >= BOUNDARY_Y-1) && (getLocalId(0) < WIN_SIZE_X-BOUNDARY_Y) ) {
			for (int j = 0; j < WIN_SIZE_Y; j++) {
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
				/*
				float4 current_U1 = current + U1*(minusOne + plusOne) + U1P1*(minusTwo + 2*current + plusTwo);

				writePixel(plusOne + P1*(current + plusTwo) +
		         				      P2*(current_U1 + plusTwo + U1*(plusOne + plusThree) +
									  U1P1*(current + 2*plusTwo + plusFour)  ),
									  currentScratch);
				writePixel(current_U1, currentScratch + VERTICAL_ODD_TO_PREVIOUS_EVEN);
				currentScratch += HORIZONTAL_STRIDE;
				*/
			}
		}
		

		currentScratch = scratch + getScratchOffset();	
		localMemoryFence();
		//U2 - even columns (skip left and right boundary columns)
		if ( !(getLocalId(0)&1) && (getLocalId(0) >= BOUNDARY_Y) && (getLocalId(0) < WIN_SIZE_X-BOUNDARY_Y)  ) {
			for (int j = 0; j < WIN_SIZE_Y; j++) {

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

				/*
				writePixel(current + U2*(prevOdd + nextOdd), currentScratch);
				currentScratch += HORIZONTAL_STRIDE;
				*/
			}
		}
		localMemoryFence();
		


		//5. write local buffer column to destination image
		// (only write non-boundary columns that are within the image bounds)
		if ((getLocalId(1) >= BOUNDARY_Y) && ( getLocalId(1) < WIN_SIZE_Y - BOUNDARY_Y) && (inputY < height) && inputY >= 0) {
			writeColumnToOutput(scratch + getScratchOffset(), odata, firstX, outputX, height, halfHeight);

		}
		// move to next step 
		firstX += WIN_SIZE_Y;
	}
}
