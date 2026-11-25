// StreamingResampler.hpp — fixed-ratio, streaming windowed-sinc resampler.
//
// Real-time safe after construction: process() never allocates. Used when a .nam
// model was trained at a rate other than the Nano Cortex's fixed 48 kHz
// (48k -> model rate -> NAM -> 48k).
//
// The kernel is a Kaiser-windowed sinc sampled on a fine phase grid with linear
// interpolation between phases. Latency is `halfTaps` input samples.

#pragma once

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <vector>

namespace nam2nano
{

class StreamingResampler
{
public:
  /// \param inRate   input sample rate (Hz)
  /// \param outRate  output sample rate (Hz)
  /// \param maxInputFrames largest block passed to process()
  /// \param halfTaps half kernel length in input samples (16 -> 32-tap kernel)
  StreamingResampler(double inRate, double outRate, int maxInputFrames, int halfTaps = 16, int phases = 512)
  : mStep(inRate / outRate)
  , mHalf(halfTaps)
  , mPhases(phases)
  {
    assert(inRate > 0 && outRate > 0 && maxInputFrames > 0);
    // Anti-alias / anti-image cutoff, relative to the input Nyquist.
    const double ratio = std::min(1.0, outRate / inRate);
    mCutoff = 0.90 * ratio;
    buildKernel();
    // History: 2*half zeros so that the very first call already produces
    // ~n/step outputs (steady state from the start).
    mBuffer.assign(static_cast<size_t>(2 * mHalf + maxInputFrames + 8), 0.0f);
    mLen = 2 * mHalf;
    mPos = static_cast<double>(mHalf);
  }

  /// Upper bound of output frames produced from `inputFrames` input frames.
  int maxOutputFrames(int inputFrames) const
  {
    return static_cast<int>(std::ceil((inputFrames + 2.0) / mStep)) + 2;
  }

  /// Consume `nIn` input frames, write at most `maxOut` output frames. Returns frames written.
  int process(const float* in, int nIn, float* out, int maxOut)
  {
    // Append input (capacity is guaranteed by construction).
    const int room = static_cast<int>(mBuffer.size()) - mLen;
    const int take = std::min(nIn, room);
    std::memcpy(mBuffer.data() + mLen, in, sizeof(float) * static_cast<size_t>(take));
    mLen += take;

    int produced = 0;
    while (produced < maxOut)
    {
      const int base = static_cast<int>(std::floor(mPos));
      if (base + mHalf >= mLen)
        break;
      const double frac = mPos - base;
      double acc = 0.0;
      // taps k = base - half + 1 ... base + half ; distance d = mPos - k
      for (int j = -mHalf + 1; j <= mHalf; ++j)
      {
        const double d = frac - j; // (mPos - (base + j))
        acc += static_cast<double>(mBuffer[static_cast<size_t>(base + j)]) * kernel(d);
      }
      out[produced++] = static_cast<float>(acc);
      mPos += mStep;
    }

    // Drop samples that can no longer contribute.
    const int keepFrom = std::max(0, static_cast<int>(std::floor(mPos)) - mHalf + 1);
    if (keepFrom > 0)
    {
      const int remaining = mLen - keepFrom;
      std::memmove(mBuffer.data(), mBuffer.data() + keepFrom, sizeof(float) * static_cast<size_t>(remaining));
      mLen = remaining;
      mPos -= keepFrom;
    }
    return produced;
  }

  void reset()
  {
    std::fill(mBuffer.begin(), mBuffer.end(), 0.0f);
    mLen = 2 * mHalf;
    mPos = static_cast<double>(mHalf);
  }

  /// Group delay in output samples.
  double latencyOutputFrames() const { return mHalf / mStep; }

private:
  static double besselI0(double x)
  {
    double sum = 1.0, term = 1.0;
    const double q = x * x / 4.0;
    for (int k = 1; k < 64; ++k)
    {
      term *= q / (static_cast<double>(k) * k);
      sum += term;
      if (term < sum * 1e-12)
        break;
    }
    return sum;
  }

  void buildKernel()
  {
    const double beta = 8.0;
    const double i0b = besselI0(beta);
    const int n = mHalf * mPhases;
    mTable.resize(static_cast<size_t>(n + 2));
    for (int i = 0; i <= n + 1; ++i)
    {
      const double x = static_cast<double>(i) / mPhases; // 0..half (input samples)
      double v = 0.0;
      if (x < mHalf)
      {
        const double t = x / mHalf;
        const double w = besselI0(beta * std::sqrt(std::max(0.0, 1.0 - t * t))) / i0b;
        const double a = M_PI * mCutoff * x;
        const double sinc = (x == 0.0) ? 1.0 : std::sin(a) / a;
        v = mCutoff * sinc * w;
      }
      mTable[static_cast<size_t>(i)] = v;
    }
  }

  inline double kernel(double d) const
  {
    const double x = std::fabs(d) * mPhases;
    const int i = static_cast<int>(x);
    if (i >= mHalf * mPhases)
      return 0.0;
    const double f = x - i;
    return mTable[static_cast<size_t>(i)] + (mTable[static_cast<size_t>(i + 1)] - mTable[static_cast<size_t>(i)]) * f;
  }

  double mStep;
  int mHalf;
  int mPhases;
  double mCutoff = 0.9;
  std::vector<double> mTable;
  std::vector<float> mBuffer;
  int mLen = 0;
  double mPos = 0.0;
};

} // namespace nam2nano
