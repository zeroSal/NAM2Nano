// NAMProcessorBridge.h — Objective-C facade over the C++ nam2nano::Engine.
//
// Pure Objective-C/C header (no C++), imported by Swift through the bridging header.
// All model loading happens off the real-time thread; NAMEngineRender() is the only
// entry point meant for the CoreAudio render callback.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NAMSourceMode) {
    NAMSourceModeSilence = 0,
    NAMSourceModeUSBInput = 1,
    NAMSourceModePinkNoise = 2,
    NAMSourceModeSine = 3,
};

typedef struct {
    float sourcePeak;   // linear
    float modelInPeak;  // linear
    float outputPeak;   // linear
    uint32_t xruns;
    uint32_t overloads;
    uint32_t clips;
    float cpuLoad;      // 0...1 (fraction of the block budget)
} NAMMeterSnapshot;

@interface NAMModelLoadResult : NSObject
@property (nonatomic, readonly) double modelSampleRate;
@property (nonatomic, readonly) BOOL resampling;
@property (nonatomic, readonly) NSInteger inputChannels;
@property (nonatomic, readonly) NSInteger outputChannels;
@property (nonatomic, readonly) double resamplerLatencyMs;
@end

@interface NAMProcessorBridge : NSObject

- (instancetype)initWithHostSampleRate:(double)sampleRate maxBlockSize:(NSInteger)maxBlockSize NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Blocking: parses, builds, resets and prewarms the model. Call from a background queue.
- (nullable NAMModelLoadResult *)loadModelAtPath:(NSString *)path error:(NSError **)error;
- (void)unloadModel;
/// Frees models retired by the audio thread. Safe to call often (UI timer).
- (void)collectGarbage;

@property (nonatomic, readonly) BOOL hasModel;
@property (nonatomic, readonly) double hostSampleRate;

@property (nonatomic) NAMSourceMode sourceMode;
/// 0-based USB input channel used when sourceMode == NAMSourceModeUSBInput.
@property (nonatomic) NSInteger sourceChannel;
@property (nonatomic) BOOL processThroughModel;
@property (nonatomic) BOOL outputMuted;
@property (nonatomic) float inputGainDB;
@property (nonatomic) float outputGainDB;
@property (nonatomic) float toneFrequency;
/// Sine: peak level in dBFS. Pink noise: RMS level in dBFS.
@property (nonatomic) float generatorLevelDB;

- (NAMMeterSnapshot)readMetersResettingPeaks:(BOOL)reset;
- (float)inputChannelPeak:(NSInteger)channel reset:(BOOL)reset;

/// Opaque pointer handed to the render callback (valid for the lifetime of this object).
@property (nonatomic, readonly) void *engineHandle;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// Real-time safe. `inputs`/`outputs` are arrays of non-interleaved Float32 channel pointers.
void NAMEngineRender(void *engineHandle,
                     const float *_Nullable const *_Nullable inputs, int numInputs,
                     float *_Nullable const *_Nonnull outputs, int numOutputs,
                     int outputChannel, int frames);

/// Real-time safe: counts a host-side render error as an xrun.
void NAMEngineReportHostError(void *engineHandle);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
