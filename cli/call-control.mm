#import <Foundation/Foundation.h>
#include <unistd.h>

#import "CTCall.h"

static const NSInteger kExitUsage = 2;
static const NSInteger kExitNoMatchingCall = 3;
static const NSInteger kExitVerificationTimeout = 4;
static const NSInteger kExitAmbiguousCall = 5;

static NSString *Timestamp(void) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                  NSISO8601DateFormatWithFractionalSeconds;
    });
    return [formatter stringFromDate:[NSDate date]];
}

static NSString *StatusName(CTCallStatus status) {
    switch (status) {
    case kCTCallStatusAnswered:
        return @"active";
    case kCTCallStatusDroppedInterrupted:
        return @"dropped";
    case kCTCallStatusOutgoingInitiated:
        return @"dialing";
    case kCTCallStatusIncomingCall:
        return @"ringing";
    case kCTCallStatusIncomingCallEnded:
        return @"ended";
    case kCTCallStatusUnknown:
    default:
        return @"unknown";
    }
}

static NSString *TypeName(CTCallType type) {
    if (!type)
        return @"unknown";
    if (kCTCallTypeNormal && CFEqual(type, kCTCallTypeNormal))
        return @"cellular";
    if (kCTCallTypeVOIP && CFEqual(type, kCTCallTypeVOIP))
        return @"voip";
    if (kCTCallTypeVideoConference && CFEqual(type, kCTCallTypeVideoConference))
        return @"video";
    if (kCTCallTypeVoicemail && CFEqual(type, kCTCallTypeVoicemail))
        return @"voicemail";
    return @"unknown";
}

static BOOL IsCellularCall(CTCallRef call) {
    CTCallType type = CTCallGetCallType(call);
    return type && kCTCallTypeNormal && CFEqual(type, kCTCallTypeNormal);
}

static NSString *CopyCallID(CTCallRef call) {
    CFStringRef value = CTCallCopyUniqueStringID(kCFAllocatorDefault, call);
    if (!value)
        return @"unknown";
    return CFBridgingRelease(value);
}

static NSString *CopyAddress(CTCallRef call) {
    CFStringRef value = CTCallCopyAddress(kCFAllocatorDefault, call);
    if (!value)
        return nil;
    return CFBridgingRelease(value);
}

static NSDictionary *CallJSON(CTCallRef call, BOOL includeAddress) {
    NSMutableDictionary *json = [@{
        @"callId" : CopyCallID(call),
        @"state" : StatusName(CTCallGetStatus(call)),
        @"direction" : CTCallIsOutgoing(call) ? @"outgoing" : @"incoming",
        @"type" : TypeName(CTCallGetCallType(call)),
    } mutableCopy];

    NSString *address = CopyAddress(call);
    if (address.length > 0)
        json[@"address"] = includeAddress ? address : @"[REDACTED_PHONE]";

    return json;
}

static void PrintJSON(NSDictionary *json) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    if (!data) {
        fprintf(stderr, "call-control: could not serialize JSON: %s\n",
                error.localizedDescription.UTF8String);
        return;
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

static NSDictionary *ErrorJSON(NSString *command, NSString *code, NSString *message,
                               NSDictionary *details) {
    NSMutableDictionary *json = [@{
        @"ok" : @NO,
        @"command" : command ?: @"unknown",
        @"error" : @{
            @"code" : code,
            @"message" : message,
        },
        @"timestamp" : Timestamp(),
    } mutableCopy];
    if (details)
        json[@"details"] = details;
    return json;
}

static CFArrayRef CopyCalls(void) {
    CFArrayRef calls = CTCopyCurrentCalls(kCFAllocatorDefault);
    if (calls)
        return calls;
    return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
}

static NSArray<NSValue *> *CandidateCalls(CFArrayRef calls, CTCallStatus requiredStatus) {
    NSMutableArray<NSValue *> *candidates = [NSMutableArray array];
    for (CFIndex i = 0; i < CFArrayGetCount(calls); i++) {
        CTCallRef call = (CTCallRef)CFArrayGetValueAtIndex(calls, i);
        if (IsCellularCall(call) && CTCallGetStatus(call) == requiredStatus)
            [candidates addObject:[NSValue valueWithPointer:call]];
    }
    return candidates;
}

static BOOL FindCallState(NSString *callID, NSString **state) {
    CFArrayRef calls = CopyCalls();
    BOOL found = NO;
    for (CFIndex i = 0; i < CFArrayGetCount(calls); i++) {
        CTCallRef call = (CTCallRef)CFArrayGetValueAtIndex(calls, i);
        if ([CopyCallID(call) isEqualToString:callID]) {
            *state = StatusName(CTCallGetStatus(call));
            found = YES;
            break;
        }
    }
    CFRelease(calls);
    return found;
}

static BOOL WaitForTransition(NSString *callID, NSString *command, NSInteger timeoutMs,
                              NSString **finalState, NSInteger *elapsedMs) {
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    while (true) {
        NSString *state = nil;
        BOOL found = FindCallState(callID, &state);

        if ([command isEqualToString:@"answer"] && found && [state isEqualToString:@"active"]) {
            *finalState = state;
            break;
        }
        if ([command isEqualToString:@"hangup"] &&
            (!found || [state isEqualToString:@"ended"] || [state isEqualToString:@"dropped"])) {
            *finalState = found ? state : @"ended";
            break;
        }

        NSInteger currentElapsed =
            (NSInteger)((CFAbsoluteTimeGetCurrent() - started) * 1000.0);
        if (currentElapsed >= timeoutMs) {
            *finalState = found ? state : @"not-found";
            *elapsedMs = currentElapsed;
            return NO;
        }
        usleep(100 * 1000);
    }

    *elapsedMs = (NSInteger)((CFAbsoluteTimeGetCurrent() - started) * 1000.0);
    return YES;
}

static NSInteger ParseTimeout(NSArray<NSString *> *arguments, NSString **errorMessage) {
    NSInteger timeoutMs = 5000;
    NSUInteger index = [arguments indexOfObject:@"--timeout-ms"];
    if (index == NSNotFound)
        return timeoutMs;
    if (index + 1 >= arguments.count) {
        *errorMessage = @"--timeout-ms requires a value";
        return -1;
    }

    NSScanner *scanner = [NSScanner scannerWithString:arguments[index + 1]];
    NSInteger value = 0;
    if (![scanner scanInteger:&value] || !scanner.isAtEnd || value < 100 || value > 30000) {
        *errorMessage = @"--timeout-ms must be between 100 and 30000";
        return -1;
    }
    return value;
}

static BOOL ValidateArguments(NSArray<NSString *> *arguments, NSString *command,
                              NSString **errorMessage) {
    BOOL sawIncludeAddress = NO;
    BOOL sawTimeout = NO;
    for (NSUInteger index = 1; index < arguments.count; index++) {
        NSString *argument = arguments[index];
        if ([argument isEqualToString:@"--include-address"]) {
            if (sawIncludeAddress) {
                *errorMessage = @"--include-address may only be supplied once";
                return NO;
            }
            if (![command isEqualToString:@"status"]) {
                *errorMessage = @"--include-address is only valid with status";
                return NO;
            }
            sawIncludeAddress = YES;
            continue;
        }
        if ([argument isEqualToString:@"--timeout-ms"]) {
            if (sawTimeout) {
                *errorMessage = @"--timeout-ms may only be supplied once";
                return NO;
            }
            if ([command isEqualToString:@"status"]) {
                *errorMessage = @"--timeout-ms is only valid with answer or hangup";
                return NO;
            }
            sawTimeout = YES;
            index++;
            if (index >= arguments.count) {
                *errorMessage = @"--timeout-ms requires a value";
                return NO;
            }
            continue;
        }

        *errorMessage = [NSString stringWithFormat:@"Unknown argument: %@", argument];
        return NO;
    }
    return YES;
}

static int RunStatus(BOOL includeAddress) {
    CFArrayRef calls = CopyCalls();
    NSMutableArray *items = [NSMutableArray array];
    for (CFIndex i = 0; i < CFArrayGetCount(calls); i++) {
        CTCallRef call = (CTCallRef)CFArrayGetValueAtIndex(calls, i);
        if (IsCellularCall(call))
            [items addObject:CallJSON(call, includeAddress)];
    }
    CFRelease(calls);

    PrintJSON(@{
        @"ok" : @YES,
        @"command" : @"status",
        @"count" : @(items.count),
        @"calls" : items,
        @"timestamp" : Timestamp(),
    });
    return 0;
}

static int RunAction(NSString *command, NSInteger timeoutMs) {
    CTCallStatus requiredStatus = [command isEqualToString:@"answer"]
                                      ? kCTCallStatusIncomingCall
                                      : kCTCallStatusAnswered;
    CFArrayRef calls = CopyCalls();
    NSArray<NSValue *> *candidates = CandidateCalls(calls, requiredStatus);

    if (candidates.count == 0) {
        CFRelease(calls);
        PrintJSON(ErrorJSON(command, @"no_matching_call",
                            [command isEqualToString:@"answer"]
                                ? @"No ringing cellular call was found"
                                : @"No active cellular call was found",
                            nil));
        return (int)kExitNoMatchingCall;
    }
    if (candidates.count > 1) {
        NSInteger count = candidates.count;
        CFRelease(calls);
        PrintJSON(ErrorJSON(command, @"ambiguous_call",
                            @"More than one matching cellular call was found",
                            @{ @"candidateCount" : @(count) }));
        return (int)kExitAmbiguousCall;
    }

    CTCallRef call = (CTCallRef)candidates.firstObject.pointerValue;
    NSString *callID = CopyCallID(call);
    NSString *initialState = StatusName(CTCallGetStatus(call));
    if ([command isEqualToString:@"answer"])
        CTCallAnswer(call);
    else
        CTCallDisconnect(call);
    CFRelease(calls);

    NSString *finalState = nil;
    NSInteger elapsedMs = 0;
    BOOL verified = WaitForTransition(callID, command, timeoutMs, &finalState, &elapsedMs);
    if (!verified) {
        PrintJSON(ErrorJSON(command, @"verification_timeout",
                            @"The command was sent but the expected call transition was not observed",
                            @{
                                @"callId" : callID,
                                @"fromState" : initialState,
                                @"observedState" : finalState ?: @"unknown",
                                @"elapsedMs" : @(elapsedMs),
                            }));
        return (int)kExitVerificationTimeout;
    }

    PrintJSON(@{
        @"ok" : @YES,
        @"command" : command,
        @"callId" : callID,
        @"fromState" : initialState,
        @"toState" : finalState,
        @"elapsedMs" : @(elapsedMs),
        @"timestamp" : Timestamp(),
    });
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argv;
        NSArray<NSString *> *arguments = [[NSProcessInfo processInfo].arguments
            subarrayWithRange:NSMakeRange(1, MAX(argc - 1, 0))];
        NSString *command = arguments.firstObject;
        BOOL includeAddress = [arguments containsObject:@"--include-address"];

        if (!command || ![@[ @"status", @"answer", @"hangup" ] containsObject:command]) {
            PrintJSON(ErrorJSON(command, @"usage",
                                @"Usage: call-control <status|answer|hangup> [--include-address] "
                                 "[--timeout-ms 5000]",
                                nil));
            return (int)kExitUsage;
        }

        NSString *argumentError = nil;
        if (!ValidateArguments(arguments, command, &argumentError)) {
            PrintJSON(ErrorJSON(command, @"usage", argumentError, nil));
            return (int)kExitUsage;
        }

        NSString *timeoutError = nil;
        NSInteger timeoutMs = ParseTimeout(arguments, &timeoutError);
        if (timeoutMs < 0) {
            PrintJSON(ErrorJSON(command, @"usage", timeoutError, nil));
            return (int)kExitUsage;
        }

        if ([command isEqualToString:@"status"])
            return RunStatus(includeAddress);
        return RunAction(command, timeoutMs);
    }
}

