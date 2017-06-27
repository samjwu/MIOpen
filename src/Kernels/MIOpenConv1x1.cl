/*******************************************************************************
 * 
 * MIT License
 * 
 * Copyright (c) 2017 Advanced Micro Devices, Inc.
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 * 
 *******************************************************************************/

#define _FLOAT					float
#define _FLOAT2					float2
#define _FLOAT4					float4
#define _FLOAT8					float8

#ifndef FLT_MAX
#define FLT_MAX         3.402823466e+38F        /* max value */
#endif

#define UNUSED __attribute__((__unused__))

#define DBG_OUT_OF_RNGE 0

// calculating the size of the area for weights prefetch

#if MLO_N_MAPS_PERGROUP > 1
#define MLO_WEIGHTS_PER_LOOP_MAX 8
#else
#define MLO_WEIGHTS_PER_LOOP_MAX 16
#endif
#if ((MLO_N_MAPS_PERGROUP*MLO_N_LCL_IN_MAPS) < MLO_N_INPUTS)
#define MLO_LCL_IN_ROW (MLO_N_MAPS_PERGROUP*MLO_N_LCL_IN_MAPS)
#else
#define MLO_LCL_IN_ROW (MLO_N_INPUTS)
#endif

#define MLO_WEIGHTS_PER_LOOP_TMP ((MLO_N_INPUTS + MLO_LCL_IN_ROW - 1)/MLO_LCL_IN_ROW)

#if (MLO_WEIGHTS_PER_LOOP_TMP < MLO_WEIGHTS_PER_LOOP_MAX)
#define MLO_WEIGHTS_PER_LOOP (MLO_WEIGHTS_PER_LOOP_TMP)
#else
#define MLO_WEIGHTS_PER_LOOP (MLO_WEIGHTS_PER_LOOP_MAX)
#endif
#define MLO_LCL_WEIGHTS_ROW (MLO_WEIGHTS_PER_LOOP * MLO_LCL_IN_ROW)
#define MLO_WEIGHTS_ROW (MLO_LCL_WEIGHTS_ROW* MLO_WEI_CHANNEL_STRIDE)

// size of the area for weights prefetch
#define MLO_WEIGHTS_LCL_SZ (MLO_WEIGHTS_ROW * MLO_N_LCL_OUT_MAPS)

// size of area for exchanging partial sums
#define MLO_EXCHNGE_SZ4 (MLO_MAP_SZ4*MLO_EXCHANGE_STEP * MLO_N_MAPS_PERGROUP)


#if MLO_N_MAPS_PERGROUP > 1 && ((MLO_EXCHNGE_SZ4 * MLO_READ_UNIT) > MLO_WEIGHTS_LCL_SZ)
#define MLO_LCL_MEM_SZ (MLO_EXCHNGE_SZ4 * MLO_READ_UNIT)
#else
#define MLO_LCL_MEM_SZ MLO_WEIGHTS_LCL_SZ
#endif

__attribute__((always_inline))
uint iDiv(uint v, uint d)
{
	uint r = (uint)((float)v * (1.0f / (float)d) + 0.00001f);
	return(r);
}

__attribute__((always_inline))
uint iMod(uint v, uint u, uint d)
{
	uint r = v - mul24(u, d);
	return(r);
}

/*
Layout:
assuming NCHW data layout.

Data:
data has been fetch by 4 floats sequentially.
MLO_MAP_SZ4 = (map_width*map_height + 3)/4.
in case of total size not a multiple of 4 the the last pixel has a special treatment.
There are 2 cases:
MLO_N_MAPS_PERGROUP == 1
and
MLO_N_MAPS_PERGROUP > 1, when MLO_MAP_SZ4 <= GPROUP_SIZE/2, in other words when more than 1 map can be held by a group.
Case MLO_N_MAPS_PERGROUP == 1:
Data, by 4 floats, may come from MLO_N_LCL_IN_MAPS sequential input maps from MLO_N_LCL_BATCHS neighboring batches.
Weigts:
on each MLO_WEIGHTS_PER_LOOP input loop set of weight are prefetched for another MLO_WEIGHTS_PER_LOOP loops.
Each input map contributes to partial sums of MLO_N_LCL_OUT_MAPS output maps.
Case MLO_N_MAPS_PERGROUP > 1:
Similar to a previous case.
The difference is that several input sequential input maps are kept by group.
Each taking part in the calculation of partial sums of the same MLO_N_LCL_OUT_MAPS output maps.
After completion of the main MLO_IN_LOOP loop partial sums have been summed up in parallel.

*/

__kernel void MIOpenConv1x1(
       const __global _FLOAT * __restrict in_ptr,
       const __global _FLOAT * __restrict wei_ptr,
#if MLO_CONV_BIAS
       const __global _FLOAT * __restrict bias,
#endif
 	  __global _FLOAT * __restrict out_ptr,
	   UNUSED _FLOAT dummy_val // nothing
	   )
{
// KERNEL
// private buffers
	__private _FLOAT in_stage[MLO_N_LCL_BATCHS][MLO_N_LCL_IN_MAPS][MLO_READ_UNIT];
	__private _FLOAT wei_stage;
	__private _FLOAT out_tiles[MLO_N_LCL_BATCHS][MLO_N_LCL_OUT_MAPS][MLO_READ_UNIT];
	__local _FLOAT lcl_wei_stage[MLO_LCL_MEM_SZ];

#if MLO_N_MAPS_PERGROUP > 1
	__local _FLOAT * lcl_out_stage = lcl_wei_stage;

#endif

	uint lcl_id0 = get_local_id(0);
	int in_map_id = 0; // map
	uint pix_id = get_global_id(0);  // inside map
	in_map_id = pix_id / MLO_MAP_SZ4; // mad id inside group
	uint out_grp_block = get_group_id(1); // block of outputs for the entire group
	uint out_block = out_grp_block;
	uint batch_block = get_group_id(2); // block of batchs
// multipe maps per group

	pix_id = (pix_id - in_map_id * MLO_MAP_SZ4);  // pixel inside map

	uint in_map_off_id = (in_map_id >= MLO_N_MAPS_PERGROUP) ? MLO_N_MAPS_PERGROUP - 1 : in_map_id;

	uint in_off = batch_block * MLO_N_LCL_BATCHS * MLO_IN_BATCH_STRIDE
		+ in_map_off_id * MLO_IN_CHANNEL_STRIDE
				+ pix_id * MLO_READ_UNIT;

	uint wei_off = out_grp_block * MLO_N_LCL_OUT_MAPS *
#if MLO_DIR_FORWARD==1
		MLO_WEI_BSTRIDE
#else
		MLO_WEI_CHANNEL_STRIDE
#endif
		;
	for (uint j = 0; j < MLO_N_LCL_BATCHS; ++j)
	{
		for (uint i = 0; i < MLO_N_LCL_OUT_MAPS; ++i)
		{
			for (uint k = 0; k < MLO_READ_UNIT; ++k)
			{
				out_tiles[j][i][k] = 0;
			}
		}
	}
// over all input maps; with step == MLO_N_LCL_IN_MAPS * MLO_N_MAPS_PERGROUP; MLO_IN_LOOP
	for (uint wc = 0; wc < MLO_IN_LOOP; wc += MLO_WEIGHTS_PER_LOOP) {
		// read array of weights
		barrier(CLK_LOCAL_MEM_FENCE);

		for (uint w = lcl_id0; w < MLO_WEIGHTS_LCL_SZ ; w += MLO_GRP_SZ0)
		{

#if (MLO_WEIGHTS_ROW) & (MLO_WEIGHTS_ROW - 1)

			uint oi = iDiv(w, MLO_WEIGHTS_ROW);
			uint lwi = iMod(w, oi, MLO_WEIGHTS_ROW);
#else
			uint oi = (w / MLO_WEIGHTS_ROW);
			uint lwi = (w & (MLO_WEIGHTS_ROW - 1));
#endif

			uint wi = (wc * (MLO_N_LCL_IN_MAPS * MLO_N_MAPS_PERGROUP) + lwi)*
#if MLO_DIR_FORWARD==1
				MLO_WEI_CHANNEL_STRIDE;
#else
				MLO_WEI_BSTRIDE;
#endif

			// out of range check
			uint wei_off_r = wei_off + wi + oi *
#if MLO_DIR_FORWARD==1
				MLO_WEI_BSTRIDE;
#else
				MLO_WEI_CHANNEL_STRIDE;
#endif

			wei_off_r = (wei_off_r < MLO_N_OUTPUTS *MLO_N_INPUTS) ? wei_off_r : 0;
			_FLOAT wei_val = wei_ptr[wei_off_r];
			wei_val = (wei_off_r < MLO_N_OUTPUTS *MLO_N_INPUTS) ? wei_val : 0;
			lcl_wei_stage[w] = wei_val;

		}

		barrier(CLK_LOCAL_MEM_FENCE);

#if MLO_WEIGHTS_PER_LOOP > 7
#pragma unroll (MLO_WEIGHTS_PER_LOOP / 8)
#endif
		for (uint ci = 0; ci < MLO_WEIGHTS_PER_LOOP; ++ci,
			in_off += MLO_IN_CHANNEL_STRIDE*MLO_N_LCL_IN_MAPS * MLO_N_MAPS_PERGROUP
			)
		{
			uint c = wc + ci;
			uint wei_indx = ci;

			// read data
			// over all local batchs
			uint in_off1 = in_off;
			for (uint ib = 0; ib < MLO_N_LCL_BATCHS
				; ++ib, in_off1 += MLO_IN_BATCH_STRIDE)
			{
				uint in_off2 = in_off1;
				// lcl in maps (in data tiles) is has the stride = MLO_N_MAPS_PERGROUP
				for (uint ilc = 0; ilc < MLO_N_LCL_IN_MAPS; ++ilc, in_off2 += MLO_IN_CHANNEL_STRIDE * MLO_N_MAPS_PERGROUP)
				{
					bool v =
#if MLO_BATCH_ALIGNED == 0
						(batch_block*MLO_N_LCL_BATCHS + ib < MLO_BATCH_SZ) &&
#endif
						c*MLO_N_LCL_IN_MAPS * MLO_N_MAPS_PERGROUP + in_map_id + ilc* MLO_N_MAPS_PERGROUP < MLO_N_INPUTS;
					__global const _FLOAT *in_p = &in_ptr[in_off2];
#if MLO_C1x1_PIXLEFT > 0
					// if the last one
					if (pix_id == MLO_MAP_SZ4 - 1)
					{

						for (uint i = 0; i < MLO_C1x1_PIXLEFT; ++i)
						{
#ifdef __AMDGCN__
							in_stage[ib][ilc][i] = v ? in_p[i] : 0.0f;
#else
							_FLOAT val = in_p[i];
							in_stage[ib][ilc][i] = v ? val : 0.0f;
#endif
#if DBG_OUT_OF_RNGE
							if (in_off2 + i >= MLO_IN_BATCH_STRIDE * MLO_BATCH_SZ)
							{
								printf("k:err:in-of-range\n");
							}
#endif
						}
					}
					else

#endif
					{
						for (uint i = 0; i < MLO_READ_UNIT; ++i)
						{
#ifdef __AMDGCN__
							in_stage[ib][ilc][i] = v ? in_p[i] : 0.0f;
#else
							_FLOAT val = in_p[i];
							in_stage[ib][ilc][i] = v ? val : 0.0f;
#endif
#if DBG_OUT_OF_RNGE
							if (in_off2 + i >= MLO_IN_BATCH_STRIDE * MLO_BATCH_SZ)
							{
								printf("k:err:in-of-range\n");
							}
#endif
						}
					}
				}
			}


			// convolve
			for (uint olc = 0, lcl_wei_off = wei_indx*MLO_N_LCL_IN_MAPS * MLO_N_MAPS_PERGROUP*MLO_WEI_CHANNEL_STRIDE; olc < MLO_N_LCL_OUT_MAPS; ++olc, lcl_wei_off += MLO_WEIGHTS_ROW)
			{
				// lcl in maps (in data tiles) is has the stride = MLO_N_MAPS_PERGROUP, weights are mapped accordingly
				uint lcl_wei_off1 = lcl_wei_off;
				for (uint ilc = 0; ilc < MLO_N_LCL_IN_MAPS; ++ilc, lcl_wei_off1 += MLO_N_MAPS_PERGROUP*MLO_WEI_CHANNEL_STRIDE)
				{
					// read weights
					uint lcl_wei_off2 = lcl_wei_off1 + mul24(in_map_id, (int)MLO_WEI_CHANNEL_STRIDE);
					wei_stage = lcl_wei_stage[lcl_wei_off2];
					for (uint ib = 0; ib < MLO_N_LCL_BATCHS; ++ib)
					{
						for (uint i = 0; i < MLO_READ_UNIT; ++i)
						{
							out_tiles[ib][olc][i] += in_stage[ib][ilc][i] * wei_stage;
						}
					}
				}
			}


		}
	}

// out of range check
	if (in_map_id >= MLO_N_MAPS_PERGROUP || in_map_id*MLO_N_LCL_IN_MAPS >= MLO_N_INPUTS)
	{
		return;
	}

	out_block = out_grp_block * MLO_N_LCL_OUT_MAPS;
	uint out_off = batch_block * MLO_N_LCL_BATCHS * MLO_OUT_BATCH_STRIDE
		+ out_block *  MLO_OUT_CHANNEL_STRIDE
		+ pix_id * MLO_READ_UNIT;

// small groups
#if MLO_N_MAPS_PERGROUP > 1

	// calculate reduction over all partial sums
	// MLO_N_LCL_OUT_MAPS is multiple of MLO_EXCHANGE_STEP
	// write data into local memory

	for (uint ib = 0; ib < MLO_N_LCL_BATCHS; ++ib)
	{
		for (uint t = 0; t < MLO_N_LCL_OUT_MAPS; t += MLO_EXCHANGE_STEP)
		{

			barrier(CLK_LOCAL_MEM_FENCE);

			if (lcl_id0 < MLO_MAP_SZ4 * MLO_N_MAPS_PERGROUP)
			{
				for (uint om = 0; om < MLO_EXCHANGE_STEP; ++om)
				{
					uint lcl_off = (om * MLO_MAP_SZ4*MLO_N_MAPS_PERGROUP + in_map_id*MLO_MAP_SZ4 + pix_id) * MLO_READ_UNIT;
					for (uint i = 0; i < MLO_READ_UNIT; ++i)
					{
						lcl_out_stage[lcl_off + i] = out_tiles[ib][t + om][i];
					}
				}

			}
			barrier(CLK_LOCAL_MEM_FENCE);

			// sum partial sum
			// MLO_N_MAPS_PERGROUP >= MLO_EXCHANGE_STEP
			// in_map_id is an index of the output map now.
			if (in_map_id < MLO_EXCHANGE_STEP)
			{
				_FLOAT sum[MLO_READ_UNIT];
				for (uint i = 0; i < MLO_READ_UNIT; ++i)
				{
					sum[i] = 0;
				}

				for (uint s = 0; s < MLO_N_MAPS_PERGROUP; ++s)
				{
					uint imp = in_map_id + s;
					imp = (imp >= MLO_N_MAPS_PERGROUP) ? imp - MLO_N_MAPS_PERGROUP : imp;
					uint lcl_off = (in_map_id* MLO_MAP_SZ4*MLO_N_MAPS_PERGROUP + imp*MLO_MAP_SZ4 + pix_id) * MLO_READ_UNIT;
					for (uint i = 0; i < MLO_READ_UNIT; ++i)
					{
						sum[i] += lcl_out_stage[lcl_off + i];
					}

				}



				// write it out
				uint olc = t + in_map_id;

				if (true 
#if MLO_BATCH_ALIGNED == 0
					&& (batch_block*MLO_N_LCL_BATCHS + ib < MLO_BATCH_SZ)
#endif
#if MLO_OUTPUTS_ALIGNED == 0
					&& out_block + olc < MLO_N_OUTPUTS
#endif
					)
				{
				
					uint out_off2 = out_off + ib * MLO_OUT_BATCH_STRIDE + olc * MLO_OUT_CHANNEL_STRIDE;
					__global _FLOAT *out_p = &out_ptr[out_off2];

#if MLO_CONV_BIAS
					_FLOAT  bias_val = 0;
					bias_val = bias[out_block* MLO_N_LCL_OUT_MAPS + olc];
#endif
#if MLO_C1x1_PIXLEFT > 0

					// if the last one
					if (pix_id == MLO_MAP_SZ4 - 1)
					{
						for (uint i = 0; i < MLO_C1x1_PIXLEFT; ++i)
						{
							out_p[i] = sum[i]
#if MLO_CONV_BIAS
								+ bias_val
#endif
								;

#if DBG_OUT_OF_RNGE
							if (out_off2 + i >= MLO_OUT_BATCH_STRIDE * MLO_BATCH_SZ)
							{
								printf("k:err:out-of-range\n");
							}
#endif

						}

					}
					else
#endif
					{

						for (uint i = 0; i < MLO_READ_UNIT; ++i)
						{
							out_p[i] = sum[i]
#if MLO_CONV_BIAS
								+ bias_val
#endif
								;
#if DBG_OUT_OF_RNGE
							if (out_off2 + i >= MLO_OUT_BATCH_STRIDE * MLO_BATCH_SZ)
							{
								printf("k:err:out-of-range\n");
							}
#endif

						}

					}


				} //if (true

			} // if (in_map_id < MLO_EXCHANGE_STEP)

		} // for (int t = 0, p = 0; t < MLO_N_LCL_OUT_MAPS; t += MLO_EXCHANGE_STEP)

	} // 	for (int ib = 0; ib < MLO_N_LCL_BATCHS; ++ib)



#else // #if MLO_N_MAPS_PERGROUP > 1




	uint out_off1 = out_off;
	for (uint ib = 0; ib < MLO_N_LCL_BATCHS
		; ++ib, out_off1 += MLO_OUT_BATCH_STRIDE)
	{

		uint out_off2 = out_off1;
		for (uint olc = 0; olc < MLO_N_LCL_OUT_MAPS
			; ++olc, out_off2 += MLO_OUT_CHANNEL_STRIDE)
		{
			__global _FLOAT *out_p = &out_ptr[out_off2];

		    if ( true
#if MLO_BATCH_ALIGNED == 0
			&& (batch_block*MLO_N_LCL_BATCHS + ib < MLO_BATCH_SZ)
#endif
#if MLO_OUTPUTS_ALIGNED == 0
			&& (out_block + olc < MLO_N_OUTPUTS)
#endif
			)
			{
#if MLO_CONV_BIAS
				_FLOAT  bias_val = 0;
				bias_val = bias[out_block* MLO_N_LCL_OUT_MAPS + olc];
#endif
#if MLO_C1x1_PIXLEFT > 0

			// if the last one
				if (pix_id == MLO_MAP_SZ4 - 1)
				{
					for (uint i = 0; i < MLO_C1x1_PIXLEFT; ++i)
					{
						out_p[i] = out_tiles[ib][olc][i]
#if MLO_CONV_BIAS
							+ bias_val
#endif
						;
#if DBG_OUT_OF_RNGE
						if (out_off2 + i >= MLO_OUT_BATCH_STRIDE * MLO_BATCH_SZ)
						{
							printf("k:err:out-of-range\n");
						}
#endif

					}

				}
				else
#endif
				{
					for (uint i = 0; i < MLO_READ_UNIT; ++i)
					{

						out_p[i] = out_tiles[ib][olc][i]
#if MLO_CONV_BIAS
						+ bias_val
#endif
						;
#if DBG_OUT_OF_RNGE
						if (out_off2 + i >= MLO_OUT_BATCH_STRIDE * MLO_BATCH_SZ)
						{
							printf("k:err:out-of-range\n");
						}
#endif
					}
				}
			}
		}

	}


#endif // #if MLO_N_MAPS_PERGROUP > 1

}
