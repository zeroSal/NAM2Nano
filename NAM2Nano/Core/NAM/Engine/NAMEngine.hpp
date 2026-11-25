// NAMEngine.hpp — real-time processing core of NAM2Nano (pure C++, no Apple APIs).
//
// Signal path for one host block (48 kHz, the Nano Cortex's fixed USB rate):
//
//   source (USB input channel | pink noise | sine | silence)
//     -> input gain (smoothed)
//     -> [48k -> model rate] -> NeuralAmpModelerCore DSP -> [model rate -> 48k]   (optional)
//     -> output gain (smoothed) -> clip guard -> selected USB output channel (OUT 1L)
//
// Threading contract:
//  * render()/processMono() run on the real-time audio thread: no locks, no allocation.
//  * loadModel()/unloadModel()/collectGarbage() run on a non-RT thread. A new model is
//    fully built and prewarmed there, then published through an atomic pointer; the RT
//    thread adopts it at the start of the next block and hands the previous one back
//    through a "retired" slot that collectGarbage() frees.
//  * Parameter setters are atomics: callable from any thread.

#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "SignalGenerators.hpp"

namespace nam2nano
{

enum class SourceMode : int
{
  Silence = 0,
  USBInput = 1,
  PinkNoise = 2,
  Sine = 3,
};

struct MeterSnapshot
{
  float sourcePeak = 0;  ///< linear peak of the selected source (pre gain)
  float modelInPeak = 0; ///< linear peak entering the model (post input gain)
  float outputPeak = 0;  ///< linear peak sent to the Nano (post output gain)
  uint32_t xruns = 0;    ///< FIFO underruns + host render errors (cumulative)
  uint32_t overloads = 0;///< blocks whose processing exceeded 90% of the block budget (cumulative)
  uint32_t clips = 0;    ///< output samples hard-limited at 0 dBFS (cumulative)
  float cpuLoad = 0;     ///< max processing time / block duration since last read
};

struct ModelLoadInfo
{
  double modelSampleRate = 48000.0;
  bool resampling = false;
  int numInputChannels = 1;
  int numOutputChannels = 1;
  double resamplerLatencyMs = 0.0;
};

class Engine
{
public:
  static constexpr int kMaxChannels = 32;

  Engine(double hostSampleRate, int maxBlockSize);
  ~Engine();

  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;

  // ---- non real-time -------------------------------------------------------
  /// Build, reset and prewarm a model, then publish it. Throws std::exception on failure.
  ModelLoadInfo loadModel(const std::string& path);
  /// Publish "no model" (render falls back to dry pass-through when model processing is on).
  void unloadModel();
  /// Free models retired by the RT thread. Call periodically (e.g. from a UI timer).
  void collectGarbage();
  bool hasModel() const { return mHasModel.load(std::memory_order_acquire); }
  double hostSampleRate() const { return mHostRate; }
  int maxBlockSize() const { return mMaxBlock; }

  // ---- parameters (any thread) --------------------------------------------
  void setSourceMode(SourceMode m) { mSourceMode.store(static_cast<int>(m)); }
  SourceMode sourceMode() const { return static_cast<SourceMode>(mSourceMode.load()); }
  /// 0-based USB input channel used when SourceMode::USBInput.
  void setSourceChannel(int ch) { mSourceChannel.store(ch); }
  int sourceChannel() const { return mSourceChannel.load(); }
  void setProcessThroughModel(bool on) { mProcessModel.store(on); }
  void setOutputMuted(bool muted) { mMuted.store(muted); }
  void setInputGainDB(float db) { mInputGain.store(dbToLin(db)); }
  void setOutputGainDB(float db) { mOutputGain.store(dbToLin(db)); }
  void setToneFrequency(float hz) { mToneHz.store(hz); }
  /// Sine: peak level. Pink noise: RMS level.
  void setGeneratorLevelDB(float db) { mGenLevel.store(dbToLin(db)); }

  // ---- metering (any thread) -----------------------------------------------
  MeterSnapshot readMeters(bool resetPeaks);
  /// Peak of a raw USB input channel (0-based), linear.
  float readInputChannelPeak(int channel, bool reset);

  // ---- real-time -------------------------------------------------------------
  /// Multichannel host callback entry. `inputs` may be null when numInputs == 0.
  /// The processed mono signal is written to outputs[outChannel]; all other outputs are zeroed.
  void render(const float* const* inputs, int numInputs, float* const* outputs, int numOutputs, int outChannel,
              int frames);
  /// Mono convenience path (tests): in/out may alias.
  void processMono(const float* in, float* out, int frames);
  /// Host reports a render error (counts as an xrun).
  void reportHostError() { mXruns.fetch_add(1, std::memory_order_relaxed); }

  static float dbToLin(float db);

private:
  struct Model;

  void adoptPendingModel();
  void processBlock(const float* source, float* out, int frames);
  static void updatePeak(std::atomic<float>& slot, float v);

  const double mHostRate;
  const int mMaxBlock;

  // RT-owned
  Model* mActive = nullptr;
  std::vector<float> mScratchSrc;
  std::vector<float> mScratchIn;
  std::vector<float> mScratchOut;
  float mInGainSmoothed = 1.0f;
  float mOutGainSmoothed = 1.0f;
  float mSmoothCoef = 0.0f;
  SineGenerator mSine;
  PinkNoiseGenerator mPink;

  // cross-thread
  std::atomic<Model*> mPending{nullptr};
  std::atomic<Model*> mRetired{nullptr};
  std::atomic<bool> mPendingIsUnload{false};
  std::atomic<bool> mHasModel{false};

  std::atomic<int> mSourceMode{static_cast<int>(SourceMode::Silence)};
  std::atomic<int> mSourceChannel{3};
  std::atomic<bool> mProcessModel{false};
  std::atomic<bool> mMuted{true};
  std::atomic<float> mInputGain{1.0f};
  std::atomic<float> mOutputGain{1.0f};
  std::atomic<float> mToneHz{1000.0f};
  std::atomic<float> mGenLevel{0.1f};

  std::atomic<float> mSourcePeak{0};
  std::atomic<float> mModelInPeak{0};
  std::atomic<float> mOutputPeak{0};
  std::atomic<float> mCpuLoad{0};
  std::atomic<uint32_t> mXruns{0};
  std::atomic<uint32_t> mOverloads{0};
  std::atomic<uint32_t> mClips{0};
  std::array<std::atomic<float>, kMaxChannels> mChannelPeaks{};
};

} // namespace nam2nano
