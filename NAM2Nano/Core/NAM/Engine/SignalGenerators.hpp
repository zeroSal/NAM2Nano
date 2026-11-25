// SignalGenerators.hpp — tiny real-time safe test signal sources.
//
//  * SineGenerator: pilot tone for the OUT 1L -> CAPTURE IN continuity test.
//  * PinkNoiseGenerator: broadband "guitar-like" excitation used to estimate the
//    model's output level when auto-staging the Nano's CAPTURE IN gain.

#pragma once

#include <cmath>
#include <cstdint>

namespace nam2nano
{

class SineGenerator
{
public:
  void setSampleRate(double sr) { mSampleRate = sr; }
  void setFrequency(double hz) { mFrequency = hz; }

  /// Fills `out` with a sine of peak amplitude `amp`.
  void render(float* out, int frames, float amp)
  {
    const double inc = 2.0 * M_PI * mFrequency / mSampleRate;
    for (int i = 0; i < frames; ++i)
    {
      out[i] = amp * static_cast<float>(std::sin(mPhase));
      mPhase += inc;
      if (mPhase >= 2.0 * M_PI)
        mPhase -= 2.0 * M_PI;
    }
  }

private:
  double mSampleRate = 48000.0;
  double mFrequency = 1000.0;
  double mPhase = 0.0;
};

/// Paul Kellet's refined pink filter on a xorshift white source.
/// Output RMS is normalised to ~1.0 (measured), so `amp` is the target RMS.
class PinkNoiseGenerator
{
public:
  void render(float* out, int frames, float rmsAmp)
  {
    for (int i = 0; i < frames; ++i)
    {
      const float white = nextWhite();
      b0 = 0.99886f * b0 + white * 0.0555179f;
      b1 = 0.99332f * b1 + white * 0.0750759f;
      b2 = 0.96900f * b2 + white * 0.1538520f;
      b3 = 0.86650f * b3 + white * 0.3104856f;
      b4 = 0.55000f * b4 + white * 0.5329522f;
      b5 = -0.7616f * b5 - white * 0.0168980f;
      const float pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362f;
      b6 = white * 0.115926f;
      out[i] = pink * kNormalise * rmsAmp;
    }
  }

private:
  // Uniform white in [-1, 1) has RMS 1/sqrt(3); the filter adds ~+11.3 dB.
  // Normalisation constant measured over 10 s (see Tools/engine_test).
  static constexpr float kNormalise = 0.5547f;

  float nextWhite()
  {
    mState ^= mState << 13;
    mState ^= mState >> 17;
    mState ^= mState << 5;
    return static_cast<float>(static_cast<int32_t>(mState)) * (1.0f / 2147483648.0f);
  }

  uint32_t mState = 0x9E3779B9u;
  float b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
};

} // namespace nam2nano
