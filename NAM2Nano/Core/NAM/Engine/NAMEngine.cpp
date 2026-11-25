// NAMEngine.cpp — see NAMEngine.hpp for the threading contract.

#include "NAMEngine.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <type_traits>

#include "StreamingResampler.hpp"
#include "dsp.h"
#include "get_dsp.h"

static_assert(std::is_same<NAM_SAMPLE, float>::value,
              "NAM2Nano expects NeuralAmpModelerCore built with NAM_SAMPLE_FLOAT defined");

namespace nam2nano
{

namespace
{
constexpr int kMaxModelIO = 8;     // channel pointers handed to the DSP
constexpr int kFifoPrimeFrames = 32; // safety margin against resampler jitter (+-1 frame per stage)
} // namespace

struct Engine::Model
{
  std::unique_ptr<nam::DSP> dsp; // null => "no model" marker
  double rate = 48000.0;
  bool resample = false;
  int dspMaxBlock = 0;
  int numIn = 1;
  int numOut = 1;

  std::unique_ptr<StreamingResampler> up;   // host -> model rate
  std::unique_ptr<StreamingResampler> down; // model -> host rate
  std::vector<float> upBuf;
  std::vector<float> dspOut;
  std::vector<float> downBuf;
  std::vector<std::vector<float>> extraOuts; // for models with >1 output channel (discarded)

  // Output FIFO (RT-thread only, so no atomics needed).
  std::vector<float> fifo;
  int fifoRead = 0;
  int fifoCount = 0;

  void fifoPush(const float* src, int n)
  {
    const int cap = static_cast<int>(fifo.size());
    n = std::min(n, cap - fifoCount);
    int write = (fifoRead + fifoCount) % cap;
    for (int i = 0; i < n; ++i)
    {
      fifo[static_cast<size_t>(write)] = src[i];
      write = (write + 1 == cap) ? 0 : write + 1;
    }
    fifoCount += n;
  }

  /// Returns number of frames that were missing (underrun).
  int fifoPop(float* dst, int n)
  {
    const int cap = static_cast<int>(fifo.size());
    const int avail = std::min(n, fifoCount);
    for (int i = 0; i < avail; ++i)
    {
      dst[i] = fifo[static_cast<size_t>(fifoRead)];
      fifoRead = (fifoRead + 1 == cap) ? 0 : fifoRead + 1;
    }
    fifoCount -= avail;
    for (int i = avail; i < n; ++i)
      dst[i] = 0.0f;
    return n - avail;
  }

  /// Run the DSP over `n` frames in chunks no larger than its max buffer size.
  void runDSP(float* in, float* out, int n)
  {
    float* inPtrs[kMaxModelIO];
    float* outPtrs[kMaxModelIO];
    int offset = 0;
    while (offset < n)
    {
      const int chunk = std::min(dspMaxBlock, n - offset);
      for (int c = 0; c < numIn && c < kMaxModelIO; ++c)
        inPtrs[c] = in + offset; // mono source duplicated to every model input
      outPtrs[0] = out + offset;
      for (int c = 1; c < numOut && c < kMaxModelIO; ++c)
        outPtrs[c] = extraOuts[static_cast<size_t>(c - 1)].data();
      dsp->process(inPtrs, outPtrs, chunk);
      offset += chunk;
    }
  }
};

float Engine::dbToLin(float db)
{
  return std::pow(10.0f, db / 20.0f);
}

Engine::Engine(double hostSampleRate, int maxBlockSize)
: mHostRate(hostSampleRate)
, mMaxBlock(std::max(16, maxBlockSize))
{
  mScratchIn.assign(static_cast<size_t>(mMaxBlock), 0.0f);
  mScratchOut.assign(static_cast<size_t>(mMaxBlock), 0.0f);
  mScratchSrc.assign(static_cast<size_t>(mMaxBlock), 0.0f);
  mSmoothCoef = 1.0f - std::exp(-1.0f / (0.02f * static_cast<float>(mHostRate)));
  mSine.setSampleRate(mHostRate);
  for (auto& p : mChannelPeaks)
    p.store(0.0f);
}

Engine::~Engine()
{
  // The audio callback must be stopped before the engine is destroyed.
  delete mActive;
  delete mPending.exchange(nullptr);
  delete mRetired.exchange(nullptr);
}

ModelLoadInfo Engine::loadModel(const std::string& path)
{
  auto m = std::make_unique<Model>();

  nam::DspLoadOptions options;
  options.prewarm = false; // prewarm happens once, in Reset() below, at the final rate/buffer size
  m->dsp = nam::get_dsp(std::filesystem::path(path), options);
  if (!m->dsp)
    throw std::runtime_error("NeuralAmpModelerCore returned no DSP for this file");

  double rate = m->dsp->GetExpectedSampleRate();
  if (rate <= 0.0) // very old .nam files: NAM assumes 48 kHz
    rate = 48000.0;
  if (m->dsp->SupportsArbitrarySampleRate()) // e.g. Linear (IR) models adapt inside Reset()
    rate = mHostRate;

  m->rate = rate;
  m->resample = std::fabs(rate - mHostRate) > 0.5;
  m->numIn = std::max(1, m->dsp->NumInputChannels());
  m->numOut = std::max(1, m->dsp->NumOutputChannels());

  ModelLoadInfo info;
  info.modelSampleRate = rate;
  info.resampling = m->resample;
  info.numInputChannels = m->numIn;
  info.numOutputChannels = m->numOut;

  if (m->resample)
  {
    m->up = std::make_unique<StreamingResampler>(mHostRate, rate, mMaxBlock);
    const int upCap = m->up->maxOutputFrames(mMaxBlock);
    m->down = std::make_unique<StreamingResampler>(rate, mHostRate, upCap);
    const int downCap = m->down->maxOutputFrames(upCap);
    m->upBuf.assign(static_cast<size_t>(upCap), 0.0f);
    m->dspOut.assign(static_cast<size_t>(upCap), 0.0f);
    m->downBuf.assign(static_cast<size_t>(downCap), 0.0f);
    m->fifo.assign(static_cast<size_t>(4 * mMaxBlock + 4 * kFifoPrimeFrames), 0.0f);
    m->fifoCount = kFifoPrimeFrames; // prime with silence
    m->dspMaxBlock = upCap;
    info.resamplerLatencyMs =
      1000.0 * (m->up->latencyOutputFrames() / rate + m->down->latencyOutputFrames() / mHostRate)
      + 1000.0 * kFifoPrimeFrames / mHostRate;
  }
  else
  {
    m->dspMaxBlock = mMaxBlock;
  }

  for (int c = 1; c < m->numOut; ++c)
    m->extraOuts.emplace_back(static_cast<size_t>(m->dspMaxBlock), 0.0f);

  m->dsp->SetPrewarmOnReset(true);
  m->dsp->Reset(rate, m->dspMaxBlock); // allocates + prewarms: never on the RT thread

  delete mPending.exchange(m.release(), std::memory_order_acq_rel); // a never-adopted model can be freed here
  mHasModel.store(true, std::memory_order_release);
  return info;
}

void Engine::unloadModel()
{
  auto* empty = new Model(); // dsp == nullptr
  delete mPending.exchange(empty, std::memory_order_acq_rel);
  mHasModel.store(false, std::memory_order_release);
}

void Engine::collectGarbage()
{
  delete mRetired.exchange(nullptr, std::memory_order_acq_rel);
}

void Engine::adoptPendingModel()
{
  if (mPending.load(std::memory_order_acquire) == nullptr)
    return;
  if (mRetired.load(std::memory_order_acquire) != nullptr)
    return; // previous model not collected yet: try again next block (never free on the RT thread)
  Model* next = mPending.exchange(nullptr, std::memory_order_acq_rel);
  if (next == nullptr)
    return;
  mRetired.store(mActive, std::memory_order_release);
  mActive = next;
}

void Engine::updatePeak(std::atomic<float>& slot, float v)
{
  if (v > slot.load(std::memory_order_relaxed))
    slot.store(v, std::memory_order_relaxed);
}

void Engine::processBlock(const float* source, float* out, int frames)
{
  // 1) input gain (smoothed) + metering
  const float inTarget = mInputGain.load(std::memory_order_relaxed);
  float srcPeak = 0.0f, inPeak = 0.0f;
  for (int i = 0; i < frames; ++i)
  {
    const float s = source[i];
    srcPeak = std::max(srcPeak, std::fabs(s));
    mInGainSmoothed += (inTarget - mInGainSmoothed) * mSmoothCoef;
    const float x = s * mInGainSmoothed;
    inPeak = std::max(inPeak, std::fabs(x));
    mScratchIn[static_cast<size_t>(i)] = x;
  }
  updatePeak(mSourcePeak, srcPeak);
  updatePeak(mModelInPeak, inPeak);

  // 2) model
  Model* m = mActive;
  const bool useModel = mProcessModel.load(std::memory_order_relaxed) && m != nullptr && m->dsp != nullptr;
  if (useModel && !m->resample)
  {
    m->runDSP(mScratchIn.data(), out, frames);
  }
  else if (useModel)
  {
    const int upN =
      m->up->process(mScratchIn.data(), frames, m->upBuf.data(), static_cast<int>(m->upBuf.size()));
    m->runDSP(m->upBuf.data(), m->dspOut.data(), upN);
    const int downN =
      m->down->process(m->dspOut.data(), upN, m->downBuf.data(), static_cast<int>(m->downBuf.size()));
    m->fifoPush(m->downBuf.data(), downN);
    if (m->fifoPop(out, frames) > 0)
      mXruns.fetch_add(1, std::memory_order_relaxed);
  }
  else
  {
    std::memcpy(out, mScratchIn.data(), sizeof(float) * static_cast<size_t>(frames));
  }

  // 3) output gain (smoothed), clip guard, mute
  const float outTarget = mOutputGain.load(std::memory_order_relaxed);
  const bool muted = mMuted.load(std::memory_order_relaxed);
  float outPeak = 0.0f;
  uint32_t clips = 0;
  for (int i = 0; i < frames; ++i)
  {
    mOutGainSmoothed += (outTarget - mOutGainSmoothed) * mSmoothCoef;
    float y = out[i] * mOutGainSmoothed;
    if (!std::isfinite(y))
      y = 0.0f;
    if (y > 1.0f)
    {
      y = 1.0f;
      ++clips;
    }
    else if (y < -1.0f)
    {
      y = -1.0f;
      ++clips;
    }
    if (muted)
      y = 0.0f;
    outPeak = std::max(outPeak, std::fabs(y));
    out[i] = y;
  }
  if (clips)
    mClips.fetch_add(clips, std::memory_order_relaxed);
  updatePeak(mOutputPeak, outPeak);
}

void Engine::render(const float* const* inputs, int numInputs, float* const* outputs, int numOutputs, int outChannel,
                    int frames)
{
  const auto t0 = std::chrono::steady_clock::now();
  adoptPendingModel();

  for (int c = 0; c < numInputs && c < kMaxChannels; ++c)
  {
    const float* in = inputs ? inputs[c] : nullptr;
    if (!in)
      continue;
    float p = 0.0f;
    for (int i = 0; i < frames; ++i)
      p = std::max(p, std::fabs(in[i]));
    updatePeak(mChannelPeaks[static_cast<size_t>(c)], p);
  }

  const auto mode = static_cast<SourceMode>(mSourceMode.load(std::memory_order_relaxed));
  const int srcCh = mSourceChannel.load(std::memory_order_relaxed);
  const float genLevel = mGenLevel.load(std::memory_order_relaxed);
  mSine.setFrequency(mToneHz.load(std::memory_order_relaxed));

  float* dest = (outChannel >= 0 && outChannel < numOutputs) ? outputs[outChannel] : nullptr;

  int offset = 0;
  while (offset < frames)
  {
    const int n = std::min(mMaxBlock, frames - offset);
    const float* src = mScratchSrc.data();
    switch (mode)
    {
      case SourceMode::USBInput:
        if (inputs && srcCh >= 0 && srcCh < numInputs && inputs[srcCh])
          src = inputs[srcCh] + offset;
        else
          std::fill(mScratchSrc.begin(), mScratchSrc.begin() + n, 0.0f);
        break;
      case SourceMode::PinkNoise: mPink.render(mScratchSrc.data(), n, genLevel); break;
      case SourceMode::Sine: mSine.render(mScratchSrc.data(), n, genLevel); break;
      case SourceMode::Silence:
      default: std::fill(mScratchSrc.begin(), mScratchSrc.begin() + n, 0.0f); break;
    }
    processBlock(src, mScratchOut.data(), n);
    if (dest)
      std::memcpy(dest + offset, mScratchOut.data(), sizeof(float) * static_cast<size_t>(n));
    offset += n;
  }

  for (int c = 0; c < numOutputs; ++c)
    if (c != outChannel && outputs[c])
      std::memset(outputs[c], 0, sizeof(float) * static_cast<size_t>(frames));

  const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  const double budget = frames / mHostRate;
  const float load = static_cast<float>(elapsed / budget);
  updatePeak(mCpuLoad, load);
  if (load > 0.9f)
    mOverloads.fetch_add(1, std::memory_order_relaxed);
}

void Engine::processMono(const float* in, float* out, int frames)
{
  adoptPendingModel();
  int offset = 0;
  while (offset < frames)
  {
    const int n = std::min(mMaxBlock, frames - offset);
    processBlock(in + offset, mScratchOut.data(), n);
    std::memcpy(out + offset, mScratchOut.data(), sizeof(float) * static_cast<size_t>(n));
    offset += n;
  }
}

MeterSnapshot Engine::readMeters(bool resetPeaks)
{
  MeterSnapshot s;
  if (resetPeaks)
  {
    s.sourcePeak = mSourcePeak.exchange(0.0f);
    s.modelInPeak = mModelInPeak.exchange(0.0f);
    s.outputPeak = mOutputPeak.exchange(0.0f);
    s.cpuLoad = mCpuLoad.exchange(0.0f);
  }
  else
  {
    s.sourcePeak = mSourcePeak.load();
    s.modelInPeak = mModelInPeak.load();
    s.outputPeak = mOutputPeak.load();
    s.cpuLoad = mCpuLoad.load();
  }
  s.xruns = mXruns.load();
  s.overloads = mOverloads.load();
  s.clips = mClips.load();
  return s;
}

float Engine::readInputChannelPeak(int channel, bool reset)
{
  if (channel < 0 || channel >= kMaxChannels)
    return 0.0f;
  auto& slot = mChannelPeaks[static_cast<size_t>(channel)];
  return reset ? slot.exchange(0.0f) : slot.load();
}

} // namespace nam2nano
