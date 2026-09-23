//
//  uplink-player.mm
//  CallBridge
//
//  Experiment: can generated PCM be placed on the cellular uplink, so the far end hears it,
//  without playing it through a speaker for the microphone to pick up?
//
//  call-recorder attaches an ATAudioTap to an *input* AudioQueue with
//  kAudioQueueProperty_TapOutputBypass and reads the telephony stream. This tool does the
//  symmetric thing: it attaches the same kind of tap to an *output* queue and writes a tone.
//  Whether that reaches the uplink is exactly the open question.
//
//  Generating a tone rather than playing a file keeps the experiment clean: no file transfer, no
//  format conversion, and a signal the far end cannot mistake for background noise.
//

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

#import "ATAudioTap.h"
#import "ATAudioTapDescription.h"
#import "AudioQueue+Private.h"

#include <math.h>

static const int kNumberOfBuffers = 3;
static const UInt32 kFramesPerBuffer = 4096;
static const double kSampleRate = 44100.0;

static AudioStreamBasicDescription mDataFormat = {0};
static AudioQueueRef mQueueRef = NULL;
static AudioQueueBufferRef mBuffers[kNumberOfBuffers] = {0};
static ATAudioTap *mAudioTap = nil;

static int mTapPID = (int)kATAudioTapDescriptionPIDMicrophone;
static BOOL mUseTap = YES;
static double mFrequency = 1000.0;
static double mSeconds = 20.0;
static Float32 mAmplitude = 0.6f;

static UInt32 mChannels = 1;
static double mPhase = 0.0;
static double mPhaseIncrement = 0.0;
static SInt64 mFramesRemaining = 0;

/* The PID macros are unsigned literals, so compare and assign through int explicitly. */
static const int kPIDMicrophone = (int)kATAudioTapDescriptionPIDMicrophone;
static const int kPIDSpeaker = (int)kATAudioTapDescriptionPIDSpeaker;
static const int kPIDSystemAudio = (int)kATAudioTapDescriptionPIDSystemAudio;

static NSString *ChannelName(int pid) {
    if (pid == kPIDMicrophone)
        return @"microphone (uplink)";
    if (pid == kPIDSpeaker)
        return @"speaker (downlink)";
    if (pid == kPIDSystemAudio)
        return @"system audio";
    return @"unknown";
}

static void FillBuffer(AudioQueueBufferRef buffer) {
    UInt32 capacity = buffer->mAudioDataBytesCapacity / (UInt32)(sizeof(Float32) * mChannels);
    UInt32 frames = capacity;

    if (mFramesRemaining <= 0) {
        buffer->mAudioDataByteSize = 0;
        return;
    }
    if ((SInt64)frames > mFramesRemaining)
        frames = (UInt32)mFramesRemaining;

    Float32 *samples = (Float32 *)buffer->mAudioData;
    for (UInt32 frame = 0; frame < frames; frame++) {
        Float32 value = (Float32)(sin(mPhase) * mAmplitude);
        mPhase += mPhaseIncrement;
        if (mPhase >= 2.0 * M_PI)
            mPhase -= 2.0 * M_PI;
        for (UInt32 channel = 0; channel < mChannels; channel++)
            samples[frame * mChannels + channel] = value;
    }

    buffer->mAudioDataByteSize = frames * (UInt32)(sizeof(Float32) * mChannels);
    mFramesRemaining -= frames;

    OSStatus status = AudioQueueEnqueueBuffer(mQueueRef, buffer, 0, NULL);
    if (status != noErr)
        NSLog(@"uplink-player: AudioQueueEnqueueBuffer (%d)", (int)status);
}

static void PlayerCallback(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    (void)context;
    (void)queue;
    FillBuffer(buffer);
}

static OSStatus Setup(void) {
    OSStatus status = noErr;

    /* The microphone tap is mono; the speaker and system taps are stereo. Match it exactly, so a
       failure cannot be blamed on format conversion. */
    mChannels = (mTapPID == kPIDMicrophone) ? 1 : 2;
    mPhaseIncrement = 2.0 * M_PI * mFrequency / kSampleRate;
    mFramesRemaining = (SInt64)(mSeconds * kSampleRate);

    AVAudioFormat *audioFormat =
        [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                         sampleRate:kSampleRate
                                           channels:(AVAudioChannelCount)mChannels
                                        interleaved:YES];
    if (!audioFormat) {
        NSLog(@"uplink-player: could not build the audio format");
        return -1;
    }
    mDataFormat = *([audioFormat streamDescription]);

    status = AudioQueueNewOutput(&mDataFormat, PlayerCallback, NULL, CFRunLoopGetCurrent(),
                                 kCFRunLoopCommonModes, 0, &mQueueRef);
    if (status != noErr) {
        NSLog(@"uplink-player: AudioQueueNewOutput (%d)", (int)status);
        return status;
    }

    if (mUseTap) {
        ATAudioTapDescription *description = nil;
        if ([ATAudioTapDescription instancesRespondToSelector:@selector(initTapInternalWithFormat:
                                                                                            PIDs:)]) {
            description = [[ATAudioTapDescription alloc] initTapInternalWithFormat:audioFormat
                                                                              PIDs:@[ @(mTapPID) ]];
        } else {
            description = [[ATAudioTapDescription alloc] initProcessTapInternalWithFormat:audioFormat
                                                                                      PID:mTapPID];
        }
        if (!description) {
            NSLog(@"uplink-player: could not build the tap description");
            return -1;
        }

        mAudioTap = [[ATAudioTap alloc] initWithTapDescription:description];
        if (!mAudioTap) {
            NSLog(@"uplink-player: could not build the tap");
            return -1;
        }

        /* The decisive call. On an input queue this is what hands the telephony stream over; if it
           refuses here, an output queue cannot carry a tap and this whole approach is dead. */
        status = AudioQueueSetProperty(mQueueRef, kAudioQueueProperty_TapOutputBypass,
                                       (__bridge void *)mAudioTap, 8);
        NSLog(@"uplink-player: AudioQueueSetProperty(TapOutputBypass) -> %d%@", (int)status,
              status == noErr ? @" (accepted)" : @" (refused)");
        if (status != noErr)
            return status;
    }

    for (int i = 0; i < kNumberOfBuffers; i++) {
        status = AudioQueueAllocateBuffer(
            mQueueRef, kFramesPerBuffer * (UInt32)(sizeof(Float32) * mChannels), &mBuffers[i]);
        if (status != noErr) {
            NSLog(@"uplink-player: AudioQueueAllocateBuffer (%d)", (int)status);
            return status;
        }
        FillBuffer(mBuffers[i]);
    }

    status = AudioQueueSetParameter(mQueueRef, kAudioQueueParam_Volume, 1.0f);
    if (status != noErr)
        NSLog(@"uplink-player: AudioQueueSetParameter (%d)", (int)status);

    return noErr;
}

static void PrintUsage(const char *argv0) {
    fprintf(stderr,
            "Usage: %s [--channel microphone|speaker|system] [--freq 1000] [--seconds 20]\n"
            "          [--amplitude 0.6] [--no-tap]\n"
            "\n"
            "  --channel    which tap to attach the output queue to (default: microphone)\n"
            "  --no-tap     play normally with no tap, as a control run\n",
            argv0);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            NSString *argument = [NSString stringWithUTF8String:argv[i]];

            if ([argument isEqualToString:@"--no-tap"]) {
                mUseTap = NO;
            } else if ([argument isEqualToString:@"--channel"] && i + 1 < argc) {
                NSString *value = [NSString stringWithUTF8String:argv[++i]];
                if ([value isEqualToString:@"microphone"])
                    mTapPID = kPIDMicrophone;
                else if ([value isEqualToString:@"speaker"])
                    mTapPID = kPIDSpeaker;
                else if ([value isEqualToString:@"system"])
                    mTapPID = kPIDSystemAudio;
                else {
                    PrintUsage(argv[0]);
                    return 2;
                }
            } else if ([argument isEqualToString:@"--freq"] && i + 1 < argc) {
                mFrequency = atof(argv[++i]);
            } else if ([argument isEqualToString:@"--seconds"] && i + 1 < argc) {
                mSeconds = atof(argv[++i]);
            } else if ([argument isEqualToString:@"--amplitude"] && i + 1 < argc) {
                mAmplitude = (Float32)fmin(fmax(atof(argv[++i]), 0.0), 1.0);
            } else {
                PrintUsage(argv[0]);
                return 2;
            }
        }

        NSLog(@"uplink-player: %.0f Hz for %.1f s at amplitude %.2f, tap: %@", mFrequency, mSeconds,
              mAmplitude, mUseTap ? ChannelName(mTapPID) : @"none (control run)");

        OSStatus status = Setup();
        if (status != noErr) {
            NSLog(@"uplink-player: setup failed (%d)", (int)status);
            return 1;
        }

        status = AudioQueueStart(mQueueRef, NULL);
        if (status != noErr) {
            NSLog(@"uplink-player: AudioQueueStart (%d)", (int)status);
            return 1;
        }

        NSLog(@"uplink-player: playing — ask the far end whether they hear the tone");

        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        while (CFAbsoluteTimeGetCurrent() - started < mSeconds + 1.0)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);

        AudioQueueStop(mQueueRef, true);
        AudioQueueDispose(mQueueRef, true);
        mAudioTap = nil;

        NSLog(@"uplink-player: done");
    }
    return 0;
}
