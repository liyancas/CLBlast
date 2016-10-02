
// =================================================================================================
// This file is part of the CLBlast project. The project is licensed under Apache Version 2.0. This
// project loosely follows the Google C++ styleguide and uses a tab-size of two spaces and a max-
// width of 100 characters per line.
//
// Author(s):
//   Cedric Nugteren <www.cedricnugteren.nl>
//
// This is a generic GEMM kernel that works for all sizes and configurations: it doesn't require any
// pre and and post-processing kernels.
//
// This kernel is seperated into three files. This is part 1 out of 2.
//
// =================================================================================================

// Enables loading of this file using the C++ pre-processor's #include (C++11 standard raw string
// literal). Comment-out this line for syntax-highlighting when developing.
R"(

// Parameters set by the tuner or by the database. Here they are given a basic default value in case
// this kernel file is used outside of the CLBlast library. Note that all parameters here have a
// suffix 'D' to denote that they are for the 'direct' version of the GEMM kernel.
#ifndef WGD
  #define WGD 8      // Tile-size in dimension M, N, and K (e.g. 8, 16, 32, 64)
#endif
#ifndef MDIMCD
  #define MDIMCD 8    // Threads per workgroup in M-dimension (e.g. 8, 16, 32)
#endif
#ifndef NDIMCD
  #define NDIMCD 8    // Threads per workgroup in N-dimension (e.g. 8, 16, 32)
#endif
#ifndef MDIMAD
  #define MDIMAD 8    // Re-shaped tile dimension of matrix A: KDIMAD * MDIMAD
#endif
#ifndef NDIMBD
  #define NDIMBD 8    // Re-shaped tile dimension of matrix B: KDIMBD * NDIMBD
#endif
#ifndef KWID
  #define KWID 1      // Unroll factor of the WGD loop (smaller or equal than WGD)
#endif
#ifndef VWMD
  #define VWMD 1      // Vector width of matrices A and C
#endif
#ifndef VWND
  #define VWND 1      // Vector width of matrix B
#endif
#ifndef PADA
  #define PADA 1      // Local memory padding for matrix A
#endif
#ifndef PADB
  #define PADB 1      // Local memory padding for matrix B
#endif

// Helper parameters based on the above tuning parameters
#define MWID (WGD/MDIMCD)                // Work per work-item (M-dimension)
#define NWID (WGD/NDIMCD)                // Work per work-item (N-dimension)
#define KDIMAD ((MDIMCD*NDIMCD)/(MDIMAD)) // Re-shaped tile dimension of matrix A: KDIMAD * MDIMAD
#define KDIMBD ((MDIMCD*NDIMCD)/(NDIMBD)) // Re-shaped tile dimension of matrix B: KDIMBD * NDIMBD
#define MWAD (WGD/MDIMAD)                // Amount of loads-per-thread for matrix A (M-dimension)
#define KWAD (WGD/KDIMAD)                // Amount of loads-per-thread for matrix A (K-dimension)
#define KWBD (WGD/KDIMBD)                // Amount of loads-per-thread for matrix B (K-dimension)
#define NWBD (WGD/NDIMBD)                // Amount of loads-per-thread for matrix B (N-dimension)

// =================================================================================================

// Data-widths in dimension M
#if VWMD == 1
    typedef real realMD;
#elif VWMD == 2
    typedef real2 realMD;
#elif VWMD == 4
    typedef real4 realMD;
#elif VWMD == 8
    typedef real8 realMD;
#elif VWMD == 16
    typedef real16 realMD;
#endif

// Data-widths in dimension N
#if VWND == 1
    typedef real realND;
#elif VWND == 2
    typedef real2 realND;
#elif VWND == 4
    typedef real4 realND;
#elif VWND == 8
    typedef real8 realND;
#elif VWND == 16
    typedef real16 realND;
#endif

// =================================================================================================

// Caches global off-chip memory into local (shared) memory on-chip. This function is specific for
// caching the A input matrix.
inline void GlobalToLocalDirectA(const __global realMD* restrict agm, __local real* alm,
                                 const int a_ld, const int a_offset, const int kwg,
                                 const int a_transpose, const int a_conjugate) {
  #if MDIMCD == MDIMAD
    const int la0 = get_local_id(0);
    const int la1 = get_local_id(1);
  #else
    const int tid = get_local_id(0) + MDIMCD*get_local_id(1);
    const int la0 = tid % MDIMAD;
    const int la1 = tid / MDIMAD;
  #endif
  #pragma unroll
  for (int mia=0; mia<MWAD/VWMD; ++mia) {
    #pragma unroll
    for (int kia=0; kia<KWAD; ++kia) {

      // Computes the indices for the global memory
      int mg = mia + la0*(MWAD/VWMD);
      int kg = kia + la1*KWAD;
      int idm = (a_transpose) ? mg + kwg/VWMD : mg + GetGroupID0()*(WGD/VWMD);
      int idk = (a_transpose) ? kg + GetGroupID0()*WGD : kg + kwg;

      // Loads the data from global memory into the local memory
      const realMD avec = agm[idk*(a_ld/VWMD) + idm + a_offset];
      #if VWMD == 1
         alm[kg*(WGD + PADA) + mg] = avec;
      #elif VWMD == 2
         alm[kg*(WGD + PADA) + mg*VWMD + 0] = avec.x;
         alm[kg*(WGD + PADA) + mg*VWMD + 1] = avec.y;
      #elif VWMD == 4
         alm[kg*(WGD + PADA) + mg*VWMD + 0] = avec.x;
         alm[kg*(WGD + PADA) + mg*VWMD + 1] = avec.y;
         alm[kg*(WGD + PADA) + mg*VWMD + 2] = avec.z;
         alm[kg*(WGD + PADA) + mg*VWMD + 3] = avec.w;
      #elif VWMD == 8
         alm[kg*(WGD + PADA) + mg*VWMD + 0] = avec.s0;
         alm[kg*(WGD + PADA) + mg*VWMD + 1] = avec.s1;
         alm[kg*(WGD + PADA) + mg*VWMD + 2] = avec.s2;
         alm[kg*(WGD + PADA) + mg*VWMD + 3] = avec.s3;
         alm[kg*(WGD + PADA) + mg*VWMD + 4] = avec.s4;
         alm[kg*(WGD + PADA) + mg*VWMD + 5] = avec.s5;
         alm[kg*(WGD + PADA) + mg*VWMD + 6] = avec.s6;
         alm[kg*(WGD + PADA) + mg*VWMD + 7] = avec.s7;
      #elif VWMD == 16
         alm[kg*(WGD + PADA) + mg*VWMD + 0] = avec.s0;
         alm[kg*(WGD + PADA) + mg*VWMD + 1] = avec.s1;
         alm[kg*(WGD + PADA) + mg*VWMD + 2] = avec.s2;
         alm[kg*(WGD + PADA) + mg*VWMD + 3] = avec.s3;
         alm[kg*(WGD + PADA) + mg*VWMD + 4] = avec.s4;
         alm[kg*(WGD + PADA) + mg*VWMD + 5] = avec.s5;
         alm[kg*(WGD + PADA) + mg*VWMD + 6] = avec.s6;
         alm[kg*(WGD + PADA) + mg*VWMD + 7] = avec.s7;
         alm[kg*(WGD + PADA) + mg*VWMD + 8] = avec.s8;
         alm[kg*(WGD + PADA) + mg*VWMD + 9] = avec.s9;
         alm[kg*(WGD + PADA) + mg*VWMD + 10] = avec.sA;
         alm[kg*(WGD + PADA) + mg*VWMD + 11] = avec.sB;
         alm[kg*(WGD + PADA) + mg*VWMD + 12] = avec.sC;
         alm[kg*(WGD + PADA) + mg*VWMD + 13] = avec.sD;
         alm[kg*(WGD + PADA) + mg*VWMD + 14] = avec.sE;
         alm[kg*(WGD + PADA) + mg*VWMD + 15] = avec.sF;
      #endif
      if (a_conjugate) {
        for (int vm=0; vm<VWMD; ++vm) {
          COMPLEX_CONJUGATE(alm[kg*(WGD + PADA) + mg*VWMD + vm]);
        }
      }
    }
  }
}

// Same as above, but now for the B input matrix
inline void GlobalToLocalDirectB(const __global realND* restrict bgm, __local real* blm,
                                 const int b_ld, const int b_offset, const int kwg,
                                 const int b_transpose, const int b_conjugate) {
  #if MDIMCD == NDIMBD
    const int lb0 = get_local_id(0);
    const int lb1 = get_local_id(1);
  #else
    const int tid = get_local_id(0) + MDIMCD*get_local_id(1);
    const int lb0 = tid % NDIMBD;
    const int lb1 = tid / NDIMBD;
  #endif
  #pragma unroll
  for (int kib=0; kib<KWBD; ++kib) {
    #pragma unroll
    for (int nib=0; nib<NWBD/VWND; ++nib) {

      // Computes the indices for the global memory
      int ng = nib + lb0*(NWBD/VWND);
      int kg = kib + lb1*KWBD;
      int idn = (b_transpose) ? ng + kwg/VWND : ng + GetGroupID1()*(WGD/VWND);
      int idk = (b_transpose) ? kg + GetGroupID1()*WGD : kg + kwg;

      // Loads the data from global memory into the local memory
      const realND bvec = bgm[idk*(b_ld/VWND) + idn + b_offset];
      #if VWND == 1
         blm[kg*(WGD + PADB) + ng] = bvec;
      #elif VWND == 2
         blm[kg*(WGD + PADB) + ng*VWND + 0] = bvec.x;
         blm[kg*(WGD + PADB) + ng*VWND + 1] = bvec.y;
      #elif VWND == 4
         blm[kg*(WGD + PADB) + ng*VWND + 0] = bvec.x;
         blm[kg*(WGD + PADB) + ng*VWND + 1] = bvec.y;
         blm[kg*(WGD + PADB) + ng*VWND + 2] = bvec.z;
         blm[kg*(WGD + PADB) + ng*VWND + 3] = bvec.w;
      #elif VWND == 8
         blm[kg*(WGD + PADB) + ng*VWND + 0] = bvec.s0;
         blm[kg*(WGD + PADB) + ng*VWND + 1] = bvec.s1;
         blm[kg*(WGD + PADB) + ng*VWND + 2] = bvec.s2;
         blm[kg*(WGD + PADB) + ng*VWND + 3] = bvec.s3;
         blm[kg*(WGD + PADB) + ng*VWND + 4] = bvec.s4;
         blm[kg*(WGD + PADB) + ng*VWND + 5] = bvec.s5;
         blm[kg*(WGD + PADB) + ng*VWND + 6] = bvec.s6;
         blm[kg*(WGD + PADB) + ng*VWND + 7] = bvec.s7;
      #elif VWND == 16
         blm[kg*(WGD + PADB) + ng*VWND + 0] = bvec.s0;
         blm[kg*(WGD + PADB) + ng*VWND + 1] = bvec.s1;
         blm[kg*(WGD + PADB) + ng*VWND + 2] = bvec.s2;
         blm[kg*(WGD + PADB) + ng*VWND + 3] = bvec.s3;
         blm[kg*(WGD + PADB) + ng*VWND + 4] = bvec.s4;
         blm[kg*(WGD + PADB) + ng*VWND + 5] = bvec.s5;
         blm[kg*(WGD + PADB) + ng*VWND + 6] = bvec.s6;
         blm[kg*(WGD + PADB) + ng*VWND + 7] = bvec.s7;
         blm[kg*(WGD + PADB) + ng*VWND + 8] = bvec.s8;
         blm[kg*(WGD + PADB) + ng*VWND + 9] = bvec.s9;
         blm[kg*(WGD + PADB) + ng*VWND + 10] = bvec.sA;
         blm[kg*(WGD + PADB) + ng*VWND + 11] = bvec.sB;
         blm[kg*(WGD + PADB) + ng*VWND + 12] = bvec.sC;
         blm[kg*(WGD + PADB) + ng*VWND + 13] = bvec.sD;
         blm[kg*(WGD + PADB) + ng*VWND + 14] = bvec.sE;
         blm[kg*(WGD + PADB) + ng*VWND + 15] = bvec.sF;
      #endif
      if (b_conjugate) {
        for (int vn=0; vn<VWND; ++vn) {
          COMPLEX_CONJUGATE(blm[kg*(WGD + PADB) + ng*VWND + vn]);
        }
      }
    }
  }
}

// =================================================================================================

// Caches on-chip local memory into per-thread private memory (registers). This function is specific
// for caching the A input matrix.
inline void LocalToPrivateDirectA(__local real* alm, real apm[MWID], const int kg,
                                  const int a_transpose) {
  #pragma unroll
  for (int mi=0; mi<MWID; ++mi) {
    const int mg = mi + get_local_id(0)*MWID;
    const int index = (a_transpose) ? mg*(WGD + PADA) + kg : kg*(WGD + PADA) + mg;
    apm[mi] = alm[index];
  }
}

// Same as above, but now for the B input matrix
inline void LocalToPrivateDirectB(__local real* blm, real bpm[NWID], const int kg,
                                  const int b_transpose) {
  #pragma unroll
  for (int ni=0; ni<NWID; ++ni) {
    const int ng = ni + get_local_id(1)*NWID;
    const int index = (b_transpose) ? ng*(WGD + PADB) + kg : kg*(WGD + PADB) + ng;
    bpm[ni] = blm[index];
  }
}

// =================================================================================================

// Initializes the accumulation registers to zero
inline void InitAccRegistersDirect(real cpm[NWID][MWID]) {
  #pragma unroll
  for (int mi=0; mi<MWID; ++mi) {
    #pragma unroll
    for (int ni=0; ni<NWID; ++ni) {
      SetToZero(cpm[ni][mi]);
    }
  }
}

// =================================================================================================

// Performs the actual computation: Cpm += Apm * Bpm
inline void MultiplyAccumulateDirect(real cpm[NWID][MWID], real apm[MWID], real bpm[NWID]) {
  #pragma unroll
  for (int ni=0; ni<NWID; ++ni) {
    #pragma unroll
    for (int mi=0; mi<MWID; ++mi) {
      MultiplyAdd(cpm[ni][mi], apm[mi], bpm[ni]);
    }
  }
}

// =================================================================================================

// End of the C++11 raw string literal
)"

// =================================================================================================