// engine_test — offline checks for the NAM2Nano C++ engine (runs on macOS or Linux).
//
//   Tools/engine_test/build.sh <path-to-NeuralAmpModelerCore> && ./build/engine_test <models...>
//
// Checks:
//  1. resampler chain 48k -> 44.1k -> 48k: unity gain, low error, stable frame counts
//  2. pink noise generator RMS calibration
//  3. every .nam given on the command line: load, process 10 s in 256-frame blocks,
//     finite output, real-time factor, zero FIFO underruns
//  4. model hot-swap while an "audio thread" renders (run under -fsanitize=thread)

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include "NAMEngine.hpp"
#include "SignalGenerators.hpp"
#include "StreamingResampler.hpp"

using namespace nam2nano;

static int gFailures = 0;
#define CHECK(cond, ...)                                                                                               \
  do                                                                                                                   \
  {                                                                                                                    \
    if (!(cond))                                                                                                       \
    {                                                                                                                  \
      std::printf("  FAIL: " __VA_ARGS__);                                                                             \
      std::printf("\n");                                                                                               \
      ++gFailures;                                                                                                     \
    }                                                                                                                  \
  } while (0)

static void testResampler(double modelRate)
{
  std::printf("[resampler] 48000 -> %.0f -> 48000\n", modelRate);
  const int block = 256;
  StreamingResampler up(48000.0, modelRate, block);
  const int upCap = up.maxOutputFrames(block);
  StreamingResampler down(modelRate, 48000.0, upCap);
  const int downCap = down.maxOutputFrames(upCap);

  std::vector<float> in(block), mid(upCap), out(downCap);
  std::vector<float> all;
  SineGenerator sine;
  sine.setSampleRate(48000.0);
  sine.setFrequency(997.0);

  const int blocks = 48000 * 5 / block;
  long long totalIn = 0, totalOut = 0;
  int minOut = 1 << 30, maxOut = 0;
  for (int b = 0; b < blocks; ++b)
  {
    sine.render(in.data(), block, 0.5f);
    const int m = up.process(in.data(), block, mid.data(), upCap);
    const int k = down.process(mid.data(), m, out.data(), downCap);
    totalIn += block;
    totalOut += k;
    if (b > 4)
    {
      minOut = std::min(minOut, k);
      maxOut = std::max(maxOut, k);
    }
    all.insert(all.end(), out.begin(), out.begin() + k);
  }
  std::printf("  frames in %lld out %lld, per-block out %d..%d\n", totalIn, totalOut, minOut, maxOut);
  CHECK(std::llabs(totalIn - totalOut) <= 64, "frame drift too large");
  CHECK(maxOut - minOut <= 2, "per-block output jitter > 2 frames");

  // Amplitude of the steady-state part.
  double sumSq = 0;
  const size_t start = all.size() / 4;
  for (size_t i = start; i < all.size(); ++i)
    sumSq += static_cast<double>(all[i]) * all[i];
  const double rms = std::sqrt(sumSq / static_cast<double>(all.size() - start));
  const double expected = 0.5 / std::sqrt(2.0);
  std::printf("  RMS %.5f (expected %.5f, %.3f dB)\n", rms, expected, 20 * std::log10(rms / expected));
  CHECK(std::fabs(20 * std::log10(rms / expected)) < 0.05, "passband gain error > 0.05 dB");

  // Residual vs ideal delayed sine: fit phase by brute force over delays.
  auto errAt = [&](double delay) {
    double err = 0;
    for (size_t i = start; i < start + 4800; ++i)
    {
      const double ideal = 0.5 * std::sin(2 * M_PI * 997.0 * (static_cast<double>(i) - delay) / 48000.0);
      err += (all[i] - ideal) * (all[i] - ideal);
    }
    return err;
  };
  double bestDelay = 0, bestErr = 1e9;
  for (double delay = 0; delay < 80; delay += 0.05)
  {
    const double e = errAt(delay);
    if (e < bestErr)
    {
      bestErr = e;
      bestDelay = delay;
    }
  }
  for (double step = 0.01; step > 1e-6; step /= 4) // refine around the coarse optimum
    for (double d = bestDelay - 4 * step; d <= bestDelay + 4 * step; d += step)
    {
      const double e = errAt(d);
      if (e < bestErr)
      {
        bestErr = e;
        bestDelay = d;
      }
    }
  std::printf("  latency %.3f samples\n", bestDelay);
  const double snr = 10 * std::log10((expected * expected * 4800) / bestErr);
  std::printf("  SNR vs ideal %.1f dB\n", snr);
  CHECK(snr > 60, "resampler SNR < 60 dB");
}

static void testPink()
{
  std::printf("[pink noise] RMS calibration\n");
  PinkNoiseGenerator pink;
  std::vector<float> buf(480000);
  pink.render(buf.data(), static_cast<int>(buf.size()), 1.0f);
  double s = 0;
  for (float v : buf)
    s += static_cast<double>(v) * v;
  const double rms = std::sqrt(s / buf.size());
  std::printf("  RMS for amp 1.0 = %.4f (%.2f dB)\n", rms, 20 * std::log10(rms));
  CHECK(std::fabs(20 * std::log10(rms)) < 0.5, "pink RMS off by > 0.5 dB");
}

static void testModel(const std::string& path)
{
  std::printf("[model] %s\n", path.c_str());
  Engine engine(48000.0, 512);
  ModelLoadInfo info;
  try
  {
    info = engine.loadModel(path);
  }
  catch (const std::exception& e)
  {
    std::printf("  load error: %s\n", e.what());
    ++gFailures;
    return;
  }
  std::printf("  rate %.0f resampling %d in/out %d/%d latency %.2f ms\n", info.modelSampleRate, info.resampling,
              info.numInputChannels, info.numOutputChannels, info.resamplerLatencyMs);
  engine.setProcessThroughModel(true);
  engine.setOutputMuted(false);
  engine.setInputGainDB(0);
  engine.setOutputGainDB(0);

  PinkNoiseGenerator pink;
  const int block = 256;
  const int blocks = 48000 * 10 / block;
  std::vector<float> buf(block);
  double sumSq = 0;
  bool finite = true;
  const auto t0 = std::chrono::steady_clock::now();
  for (int b = 0; b < blocks; ++b)
  {
    pink.render(buf.data(), block, 0.1f);
    engine.processMono(buf.data(), buf.data(), block);
    for (float v : buf)
    {
      finite = finite && std::isfinite(v);
      sumSq += static_cast<double>(v) * v;
    }
  }
  const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  const auto meters = engine.readMeters(true);
  std::printf("  10 s processed in %.3f s (x%.1f real-time), out RMS %.1f dBFS, xruns %u clips %u\n", secs,
              10.0 / secs, 10 * std::log10(sumSq / (blocks * block) + 1e-20), meters.xruns, meters.clips);
  CHECK(finite, "non-finite output");
  CHECK(meters.xruns == 0, "FIFO underruns in resampling path");
  engine.collectGarbage();
}

static void testHotSwap(const std::vector<std::string>& models)
{
  if (models.size() < 2)
    return;
  std::printf("[hot swap] %zu models while rendering\n", models.size());
  Engine engine(48000.0, 512);
  engine.setSourceMode(SourceMode::PinkNoise);
  engine.setGeneratorLevelDB(-20);
  engine.setProcessThroughModel(true);
  engine.setOutputMuted(false);

  std::atomic<bool> run{true};
  std::thread audio([&] {
    std::vector<float> o0(256), o1(256);
    float* outs[2] = {o0.data(), o1.data()};
    while (run.load())
      engine.render(nullptr, 0, outs, 2, 0, 256);
  });
  for (int round = 0; round < 3; ++round)
    for (const auto& m : models)
    {
      try
      {
        engine.loadModel(m);
      }
      catch (...)
      {
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      engine.collectGarbage();
    }
  engine.unloadModel();
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  engine.collectGarbage();
  run.store(false);
  audio.join();
  std::printf("  ok (xruns %u)\n", engine.readMeters(false).xruns);
}

int main(int argc, char** argv)
{
  testResampler(44100.0);
  testResampler(96000.0);
  testPink();
  std::vector<std::string> models;
  for (int i = 1; i < argc; ++i)
  {
    models.emplace_back(argv[i]);
    testModel(argv[i]);
  }
  testHotSwap(models);
  std::printf(gFailures ? "\n%d FAILURE(S)\n" : "\nALL OK\n", gFailures);
  return gFailures ? 1 : 0;
}
