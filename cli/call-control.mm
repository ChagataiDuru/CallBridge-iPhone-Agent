#import <Foundation/Foundation.h>

#import "CTCall.h"
#import "CTTelephonyCenter.h"

static const NSInteger kExitUsage = 2;
static const NSInteger kExitNoMatchingCall = 3;
static const NSInteger kExitVerificationTimeout = 4;
static const NSInteger kExitAmbiguousCall = 5;
static const NSInteger kExitCallEnded = 6;
static const NSInteger kExitCallDropped = 7;

/* How long an answered call must stay active before the answer counts as a success. */
static const NSTimeInterval kAnswerStabilityInterval = 1.0;

/* One run loop slice. Short enough to catch a call that ends a few hundred ms after answering. */
static const NSTimeInterval kPollInterval = 0.05;

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

/*
 * CTCopyCurrentCalls answers from a client-side cache that is refreshed by CoreTelephony
 * notifications. A one-shot process that never runs its run loop keeps reading the snapshot it
 * took at startup, so the call list looks frozen for the whole verification window. The observer
 * below is the same mechanism call-monitor uses, and it is what actually reports the transition.
 */

static NSString *gWatchedCallID = nil;
static NSMutableArray<NSString *> *gObservedStates = nil;
static NSString *gNotifiedState = nil;

static void RecordObservedState(NSString *state) {
    if (!state.length || [gObservedStates.lastObject isEqualToString:state])
        return;
    [gObservedStates addObject:state];
}

static void TelephonyEventCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;

    if (!object || !gWatchedCallID || !name)
        return;
    if (CFStringCompare(name, kCTCallStatusChangeNotification, 0) != kCFCompareEqualTo &&
        CFStringCompare(name, kCTCallIdentificationChangeNotification, 0) != kCFCompareEqualTo)
        return;

    CTCallRef call = (CTCallRef)object;
    if (![CopyCallID(call) isEqualToString:gWatchedCallID])
        return;

    NSNumber *status = [(__bridge NSDictionary *)userInfo objectForKey:@"kCTCallStatus"];
    NSString *state =
        StatusName(status ? (CTCallStatus)status.integerValue : CTCallGetStatus(call));
    gNotifiedState = state;
    RecordObservedState(state);
}

static void StartObserving(NSString *callID, NSString *initialState) {
    gWatchedCallID = callID;
    gObservedStates = [NSMutableArray array];
    gNotifiedState = nil;
    RecordObservedState(initialState);

    CFNotificationCenterRef center = CTTelephonyCenterGetDefault();
    CTTelephonyCenterAddObserver(center, NULL, TelephonyEventCallback,
                                 kCTCallStatusChangeNotification, NULL,
                                 CFNotificationSuspensionBehaviorDeliverImmediately);
    CTTelephonyCenterAddObserver(center, NULL, TelephonyEventCallback,
                                 kCTCallIdentificationChangeNotification, NULL,
                                 CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void StopObserving(void) {
    CTTelephonyCenterRemoveEveryObserver(CTTelephonyCenterGetDefault(), NULL);
    gWatchedCallID = nil;
}

static BOOL IsTerminalState(NSString *state) {
    return [state isEqualToString:@"ended"] || [state isEqualToString:@"dropped"];
}

typedef NS_ENUM(NSInteger, TransitionOutcome) {
    TransitionVerified = 0,
    TransitionEndedEarly,
    TransitionDroppedAfterAnswer,
    TransitionTimedOut,
};

static TransitionOutcome WaitForTransition(NSString *callID, NSString *command, NSInteger timeoutMs,
                                           NSString **finalState, NSInteger *elapsedMs,
                                           NSInteger *activeForMs) {
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime answeredAt = 0;
    BOOL answering = [command isEqualToString:@"answer"];

    while (true) {
        /* Run the run loop instead of sleeping, so CoreTelephony can deliver the notification
           that carries the new call status. */
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, kPollInterval, false);

        NSString *polled = nil;
        BOOL found = FindCallState(callID, &polled);

        /* A notification, once received, is authoritative; the polled snapshot may be stale. */
        NSString *state = gNotifiedState ?: polled;
        BOOL gone = gNotifiedState ? IsTerminalState(gNotifiedState) : !found;

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        *finalState = state ?: @"not-found";

        if (answering && [state isEqualToString:@"active"] && !gone) {
            if (answeredAt == 0)
                answeredAt = now;
            /* Answering is only a success if the call then stays up: a call that is torn down
               moments after being answered must not be reported as answered. */
            if (now - answeredAt >= kAnswerStabilityInterval) {
                *elapsedMs = (NSInteger)((answeredAt - started) * 1000.0);
                *activeForMs = (NSInteger)((now - answeredAt) * 1000.0);
                return TransitionVerified;
            }
        } else if (gone || IsTerminalState(state)) {
            *finalState = IsTerminalState(state) ? state : @"ended";
            *elapsedMs = (NSInteger)((now - started) * 1000.0);
            if (!answering)
                return TransitionVerified;
            if (answeredAt > 0) {
                *activeForMs = (NSInteger)((now - answeredAt) * 1000.0);
                return TransitionDroppedAfterAnswer;
            }
            return TransitionEndedEarly;
        }

        NSInteger currentElapsed = (NSInteger)((now - started) * 1000.0);
        if (currentElapsed >= timeoutMs) {
            *elapsedMs = currentElapsed;
            return TransitionTimedOut;
        }
    }
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

    /* Observe before acting: the transition can land within a few hundred milliseconds. */
    StartObserving(callID, initialState);

    if ([command isEqualToString:@"answer"])
        CTCallAnswer(call);
    else
        CTCallDisconnect(call);
    CFRelease(calls);

    NSString *finalState = nil;
    NSInteger elapsedMs = 0;
    NSInteger activeForMs = 0;
    TransitionOutcome outcome =
        WaitForTransition(callID, command, timeoutMs, &finalState, &elapsedMs, &activeForMs);
    NSArray<NSString *> *observedStates = [gObservedStates copy];
    StopObserving();

    NSMutableDictionary *details = [@{
        @"callId" : callID,
        @"fromState" : initialState,
        @"observedState" : finalState ?: @"unknown",
        @"observedStates" : observedStates ?: @[],
        @"elapsedMs" : @(elapsedMs),
    } mutableCopy];
    if (activeForMs > 0)
        details[@"activeForMs"] = @(activeForMs);

    switch (outcome) {
    case TransitionEndedEarly:
        PrintJSON(ErrorJSON(command, @"call_ended",
                            @"The call ended before the expected transition was observed", details));
        return (int)kExitCallEnded;
    case TransitionDroppedAfterAnswer:
        PrintJSON(ErrorJSON(command, @"call_dropped_after_answer",
                            @"The call was answered but was torn down before it stayed active",
                            details));
        return (int)kExitCallDropped;
    case TransitionTimedOut:
        PrintJSON(ErrorJSON(command, @"verification_timeout",
                            @"The command was sent but the expected call transition was not observed",
                            details));
        return (int)kExitVerificationTimeout;
    case TransitionVerified:
        break;
    }

    NSMutableDictionary *result = [@{
        @"ok" : @YES,
        @"command" : command,
        @"callId" : callID,
        @"fromState" : initialState,
        @"toState" : finalState,
        @"observedStates" : observedStates ?: @[],
        @"elapsedMs" : @(elapsedMs),
        @"timestamp" : Timestamp(),
    } mutableCopy];
    if (activeForMs > 0)
        result[@"stableForMs"] = @(activeForMs);

    PrintJSON(result);
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

