// NAMProcessorBridge.mm — Objective-C++ wrapper around nam2nano::Engine.

#import "NAMProcessorBridge.h"

#include <exception>
#include <memory>
#include <string>

#include "Engine/NAMEngine.hpp"

static NSString *const NAMBridgeErrorDomain = @"NAM2Nano.NAMProcessorBridge";

@interface NAMModelLoadResult ()
- (instancetype)initWithInfo:(const nam2nano::ModelLoadInfo &)info;
@end

@implementation NAMModelLoadResult
- (instancetype)initWithInfo:(const nam2nano::ModelLoadInfo &)info {
    if ((self = [super init])) {
        _modelSampleRate = info.modelSampleRate;
        _resampling = info.resampling;
        _inputChannels = info.numInputChannels;
        _outputChannels = info.numOutputChannels;
        _resamplerLatencyMs = info.resamplerLatencyMs;
    }
    return self;
}
@end

@implementation NAMProcessorBridge {
    std::unique_ptr<nam2nano::Engine> _engine;
    float _inputGainDB;
    float _outputGainDB;
    float _toneFrequency;
    float _generatorLevelDB;
    BOOL _processThroughModel;
    BOOL _outputMuted;
}

- (instancetype)initWithHostSampleRate:(double)sampleRate maxBlockSize:(NSInteger)maxBlockSize {
    if ((self = [super init])) {
        _engine = std::make_unique<nam2nano::Engine>(sampleRate, (int)maxBlockSize);
        _toneFrequency = 1000.0f;
        _generatorLevelDB = -20.0f;
        _outputMuted = YES;
        _engine->setToneFrequency(_toneFrequency);
        _engine->setGeneratorLevelDB(_generatorLevelDB);
        _engine->setOutputMuted(true);
    }
    return self;
}

- (nullable NAMModelLoadResult *)loadModelAtPath:(NSString *)path error:(NSError **)error {
    try {
        const auto info = _engine->loadModel(std::string(path.fileSystemRepresentation));
        return [[NAMModelLoadResult alloc] initWithInfo:info];
    } catch (const std::exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:NAMBridgeErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithUTF8String:e.what()]}];
        }
    } catch (...) {
        if (error) {
            *error = [NSError errorWithDomain:NAMBridgeErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey : @"Unknown error while loading the model"}];
        }
    }
    return nil;
}

- (void)unloadModel { _engine->unloadModel(); }
- (void)collectGarbage { _engine->collectGarbage(); }
- (BOOL)hasModel { return _engine->hasModel(); }
- (double)hostSampleRate { return _engine->hostSampleRate(); }

- (NAMSourceMode)sourceMode { return (NAMSourceMode)_engine->sourceMode(); }
- (void)setSourceMode:(NAMSourceMode)sourceMode { _engine->setSourceMode((nam2nano::SourceMode)sourceMode); }

- (NSInteger)sourceChannel { return _engine->sourceChannel(); }
- (void)setSourceChannel:(NSInteger)sourceChannel { _engine->setSourceChannel((int)sourceChannel); }

- (BOOL)processThroughModel { return _processThroughModel; }
- (void)setProcessThroughModel:(BOOL)on { _processThroughModel = on; _engine->setProcessThroughModel(on); }

- (BOOL)outputMuted { return _outputMuted; }
- (void)setOutputMuted:(BOOL)muted { _outputMuted = muted; _engine->setOutputMuted(muted); }

- (float)inputGainDB { return _inputGainDB; }
- (void)setInputGainDB:(float)db { _inputGainDB = db; _engine->setInputGainDB(db); }

- (float)outputGainDB { return _outputGainDB; }
- (void)setOutputGainDB:(float)db { _outputGainDB = db; _engine->setOutputGainDB(db); }

- (float)toneFrequency { return _toneFrequency; }
- (void)setToneFrequency:(float)hz { _toneFrequency = hz; _engine->setToneFrequency(hz); }

- (float)generatorLevelDB { return _generatorLevelDB; }
- (void)setGeneratorLevelDB:(float)db { _generatorLevelDB = db; _engine->setGeneratorLevelDB(db); }

- (NAMMeterSnapshot)readMetersResettingPeaks:(BOOL)reset {
    const auto s = _engine->readMeters(reset);
    NAMMeterSnapshot out;
    out.sourcePeak = s.sourcePeak;
    out.modelInPeak = s.modelInPeak;
    out.outputPeak = s.outputPeak;
    out.xruns = s.xruns;
    out.overloads = s.overloads;
    out.clips = s.clips;
    out.cpuLoad = s.cpuLoad;
    return out;
}

- (float)inputChannelPeak:(NSInteger)channel reset:(BOOL)reset {
    return _engine->readInputChannelPeak((int)channel, reset);
}

- (void *)engineHandle { return _engine.get(); }

@end

void NAMEngineRender(void *engineHandle, const float *const *inputs, int numInputs, float *const *outputs,
                     int numOutputs, int outputChannel, int frames) {
    static_cast<nam2nano::Engine *>(engineHandle)->render(inputs, numInputs, outputs, numOutputs, outputChannel, frames);
}

void NAMEngineReportHostError(void *engineHandle) {
    static_cast<nam2nano::Engine *>(engineHandle)->reportHostError();
}
