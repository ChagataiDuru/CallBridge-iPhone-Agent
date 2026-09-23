//
//  callbridge-agent.mm
//  CallBridge
//
//  Long-lived agent: observes cellular call state, publishes it to one authenticated local
//  client as NDJSON, and executes answer/hangup commands. See docs/PROTOCOL.md.
//

#import <Foundation/Foundation.h>

#import "CTCall.h"
#import "CTTelephonyCenter.h"

#include <CommonCrypto/CommonHMAC.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

static const int kProtocolVersion = 1;
static NSString *const kAgentVersion = @"0.6";

static const NSUInteger kMaxLineLength = 64 * 1024;
static const NSTimeInterval kAuthTimeout = 5.0;
static const NSTimeInterval kPingInterval = 15.0;
static const NSTimeInterval kCommandCacheTTL = 60.0;
static const NSTimeInterval kAnswerStabilityInterval = 1.0;
static const NSTimeInterval kResolveInterval = 0.1;
static const NSInteger kDefaultPort = 8765;
static const NSInteger kMissedPingLimit = 2;

#pragma mark - Formatting helpers

static NSString *Timestamp(void) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                  NSISO8601DateFormatWithFractionalSeconds;
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    });
    return [formatter stringFromDate:[NSDate date]];
}

/* Logs never carry a full number. The protocol sends it to the authenticated client instead. */
static NSString *MaskedAddress(NSString *address) {
    if (address.length == 0)
        return @"[NONE]";
    if (address.length <= 4)
        return @"[REDACTED_PHONE]";
    return [NSString stringWithFormat:@"[REDACTED_PHONE:…%@]",
                                      [address substringFromIndex:address.length - 2]];
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

static BOOL IsTerminalState(NSString *state) {
    return [state isEqualToString:@"ended"] || [state isEqualToString:@"dropped"];
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
    return value ? CFBridgingRelease(value) : nil;
}

static NSString *CopyAddress(CTCallRef call) {
    CFStringRef value = CTCallCopyAddress(kCFAllocatorDefault, call);
    return value ? CFBridgingRelease(value) : nil;
}

static NSString *HexString(const uint8_t *bytes, size_t length) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:length * 2];
    for (size_t i = 0; i < length; i++)
        [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

#pragma mark - Pairing token

/*
 * The install prefix is derived from our own path rather than hardcoded, so the same binary works
 * under rootless (/var/jb), roothide and rootful layouts.
 */
static NSString *InstallPrefix(void) {
    char path[PATH_MAX] = {0};
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0)
        return @"";

    NSString *executable = [[NSString stringWithUTF8String:path] stringByStandardizingPath];
    NSRange suffix = [executable rangeOfString:@"/usr/local/bin/" options:NSBackwardsSearch];
    if (suffix.location == NSNotFound)
        return @"";
    return [executable substringToIndex:suffix.location];
}

static NSString *TokenPath(void) {
    return [NSString stringWithFormat:@"%@/etc/callbridge/token", InstallPrefix()];
}

static NSString *LoadOrCreateToken(NSError **error) {
    NSString *path = TokenPath();
    NSString *directory = path.stringByDeletingLastPathComponent;
    NSFileManager *manager = NSFileManager.defaultManager;

    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding
                                                      error:NULL];
    existing = [existing stringByTrimmingCharactersInSet:
                             NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (existing.length >= 32)
        return existing;

    uint8_t bytes[32];
    arc4random_buf(bytes, sizeof(bytes));
    NSString *token = HexString(bytes, sizeof(bytes));

    if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES
                             attributes:@{NSFilePosixPermissions : @(0700)}
                                  error:error])
        return nil;
    if (![token writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error])
        return nil;
    [manager setAttributes:@{NSFilePosixPermissions : @(0600)} ofItemAtPath:path error:NULL];

    NSLog(@"callbridge-agent: generated a new pairing token at %@", path);
    return token;
}

#pragma mark - Pending command

@interface CBPendingCommand : NSObject
@property(nonatomic, copy) NSString *requestID;
@property(nonatomic, copy) NSString *command;
@property(nonatomic, copy) NSString *callID;
@property(nonatomic, copy) NSString *fromState;
@property(nonatomic, strong) NSMutableArray<NSString *> *observedStates;
@property(nonatomic, assign) CFAbsoluteTime started;
@property(nonatomic, assign) CFAbsoluteTime answeredAt;
@property(nonatomic, assign) NSTimeInterval timeout;
@end

@implementation CBPendingCommand
@end

#pragma mark - Connection

@class CBConnection;

@interface CBAgent : NSObject
@property(nonatomic, assign) NSInteger port;
@property(nonatomic, copy) NSString *token;
- (BOOL)startListening:(NSError **)error;
- (void)handleMessage:(NSDictionary *)message fromConnection:(CBConnection *)connection;
- (void)connectionDidClose:(CBConnection *)connection;
- (void)telephonyEventForCall:(CTCallRef)call status:(CTCallStatus)status;
@end

@interface CBConnection : NSObject
@property(nonatomic, assign) int fd;
@property(nonatomic, assign) BOOL authenticated;
@property(nonatomic, copy) NSString *nonce;
@property(nonatomic, copy) NSString *clientName;
@property(nonatomic, assign) NSInteger missedPings;
@property(nonatomic, weak) CBAgent *agent;
- (instancetype)initWithFD:(int)fd agent:(CBAgent *)agent;
- (void)start;
- (void)sendMessage:(NSDictionary *)message;
- (void)closeWithReason:(NSString *)reason;
@end

@implementation CBConnection {
    dispatch_source_t _readSource;
    dispatch_source_t _writeSource;
    NSMutableData *_input;
    NSMutableData *_output;
    BOOL _writeSourceActive;
    BOOL _closed;
    NSInteger _liveSources;
}

- (instancetype)initWithFD:(int)fd agent:(CBAgent *)agent {
    self = [super init];
    if (!self)
        return nil;

    _fd = fd;
    _agent = agent;
    _input = [NSMutableData data];
    _output = [NSMutableData data];

    uint8_t bytes[32];
    arc4random_buf(bytes, sizeof(bytes));
    _nonce = HexString(bytes, sizeof(bytes));

    return self;
}

- (void)start {
    fcntl(_fd, F_SETFL, fcntl(_fd, F_GETFL, 0) | O_NONBLOCK);

    __weak typeof(self) weakSelf = self;
    int fd = _fd;

    _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0,
                                         dispatch_get_main_queue());
    _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0,
                                          dispatch_get_main_queue());
    _liveSources = 2;

    dispatch_source_set_event_handler(_readSource, ^{
        [weakSelf readAvailable];
    });
    dispatch_source_set_event_handler(_writeSource, ^{
        [weakSelf flushOutput];
    });

    dispatch_block_t cancelHandler = ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf sourceCancelled];
            return;
        }
        close(fd);
    };
    dispatch_source_set_cancel_handler(_readSource, cancelHandler);
    dispatch_source_set_cancel_handler(_writeSource, cancelHandler);

    dispatch_resume(_readSource);
    /* The write source stays suspended until there is output that could not be written inline. */
}

- (void)sourceCancelled {
    _liveSources--;
    if (_liveSources <= 0 && _fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

#pragma mark Reading

- (void)readAvailable {
    uint8_t buffer[4096];
    while (true) {
        ssize_t got = read(_fd, buffer, sizeof(buffer));
        if (got > 0) {
            [_input appendBytes:buffer length:(NSUInteger)got];
            continue;
        }
        if (got == 0) {
            [self closeWithReason:@"peer closed the connection"];
            return;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            break;
        if (errno == EINTR)
            continue;
        [self closeWithReason:[NSString stringWithFormat:@"read failed: %s", strerror(errno)]];
        return;
    }
    [self consumeLines];
}

- (void)consumeLines {
    while (!_closed) {
        const uint8_t *bytes = (const uint8_t *)_input.bytes;
        NSUInteger length = _input.length;
        NSUInteger newline = NSNotFound;
        for (NSUInteger i = 0; i < length; i++) {
            if (bytes[i] == '\n') {
                newline = i;
                break;
            }
        }

        if (newline == NSNotFound) {
            if (length > kMaxLineLength) {
                [self sendMessage:@{
                    @"type" : @"error",
                    @"error" : @{
                        @"code" : @"message_too_large",
                        @"message" : @"Line exceeded 64 KiB",
                    },
                    @"timestamp" : Timestamp(),
                }];
                [self closeWithReason:@"line too long"];
            }
            return;
        }

        NSData *line = [_input subdataWithRange:NSMakeRange(0, newline)];
        [_input replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
        [self handleLine:line];
    }
}

- (void)handleLine:(NSData *)line {
    if (line.length == 0)
        return;

    NSError *error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        [self sendMessage:@{
            @"type" : @"error",
            @"error" : @{
                @"code" : @"bad_request",
                @"message" : @"Each line must be one JSON object",
            },
            @"timestamp" : Timestamp(),
        }];
        return;
    }

    [self.agent handleMessage:(NSDictionary *)parsed fromConnection:self];
}

#pragma mark Writing

- (void)sendMessage:(NSDictionary *)message {
    if (_closed || _fd < 0)
        return;

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:&error];
    if (!data) {
        NSLog(@"callbridge-agent: could not serialize a %@ message: %@", message[@"type"],
              error.localizedDescription);
        return;
    }

    [_output appendData:data];
    [_output appendBytes:"\n" length:1];
    [self flushOutput];
}

- (void)flushOutput {
    while (_output.length > 0 && !_closed && _fd >= 0) {
        ssize_t written = write(_fd, _output.bytes, _output.length);
        if (written > 0) {
            [_output replaceBytesInRange:NSMakeRange(0, (NSUInteger)written) withBytes:NULL
                                  length:0];
            continue;
        }
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (!_writeSourceActive) {
                _writeSourceActive = YES;
                dispatch_resume(_writeSource);
            }
            return;
        }
        if (written < 0 && errno == EINTR)
            continue;
        [self closeWithReason:[NSString stringWithFormat:@"write failed: %s", strerror(errno)]];
        return;
    }

    if (_output.length == 0 && _writeSourceActive) {
        _writeSourceActive = NO;
        dispatch_suspend(_writeSource);
    }
}

#pragma mark Teardown

- (void)closeWithReason:(NSString *)reason {
    if (_closed)
        return;
    _closed = YES;

    NSLog(@"callbridge-agent: client disconnected (%@)", reason);

    /* A suspended source cannot be cancelled, so resume it first. */
    if (!_writeSourceActive) {
        _writeSourceActive = YES;
        dispatch_resume(_writeSource);
    }
    dispatch_source_cancel(_readSource);
    dispatch_source_cancel(_writeSource);

    [self.agent connectionDidClose:self];
}

@end

#pragma mark - Agent

static __weak CBAgent *gAgent = nil;

static void TelephonyEventCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;

    if (!object || !name || !gAgent)
        return;
    if (CFStringCompare(name, kCTCallStatusChangeNotification, 0) != kCFCompareEqualTo &&
        CFStringCompare(name, kCTCallIdentificationChangeNotification, 0) != kCFCompareEqualTo)
        return;

    CTCallRef call = (CTCallRef)object;
    NSNumber *raw = [(__bridge NSDictionary *)userInfo objectForKey:@"kCTCallStatus"];
    CTCallStatus status = raw ? (CTCallStatus)raw.integerValue : CTCallGetStatus(call);
    [gAgent telephonyEventForCall:call status:status];
}

@implementation CBAgent {
    int _listenFD;
    dispatch_source_t _acceptSource;
    dispatch_source_t _tickSource;
    CBConnection *_connection;

    /* callId -> {state, address, direction, callType} for calls we have published. */
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_calls;
    NSMutableArray<CBPendingCommand *> *_pending;
    /* requestId -> {result, at} so a retried command replays its result instead of running again. */
    NSMutableDictionary<NSString *, NSDictionary *> *_resultCache;
    CFAbsoluteTime _lastPingAt;
}

- (instancetype)init {
    self = [super init];
    if (!self)
        return nil;

    _listenFD = -1;
    _port = kDefaultPort;
    _calls = [NSMutableDictionary dictionary];
    _pending = [NSMutableArray array];
    _resultCache = [NSMutableDictionary dictionary];

    return self;
}

#pragma mark Listening

- (BOOL)startListening:(NSError **)error {
    _listenFD = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenFD < 0) {
        if (error)
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }

    int yes = 1;
    setsockopt(_listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons((uint16_t)_port);

    if (bind(_listenFD, (struct sockaddr *)&address, sizeof(address)) < 0 ||
        listen(_listenFD, 4) < 0) {
        if (error)
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        close(_listenFD);
        _listenFD = -1;
        return NO;
    }

    fcntl(_listenFD, F_SETFL, fcntl(_listenFD, F_GETFL, 0) | O_NONBLOCK);

    __weak typeof(self) weakSelf = self;
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_listenFD, 0,
                                           dispatch_get_main_queue());
    dispatch_source_set_event_handler(_acceptSource, ^{
        [weakSelf acceptConnection];
    });
    dispatch_resume(_acceptSource);

    _tickSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                         dispatch_get_main_queue());
    dispatch_source_set_timer(_tickSource, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(kResolveInterval * NSEC_PER_SEC),
                              (uint64_t)(0.02 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(_tickSource, ^{
        [weakSelf tick];
    });
    dispatch_resume(_tickSource);

    NSLog(@"callbridge-agent: listening on port %ld", (long)_port);
    return YES;
}

- (void)acceptConnection {
    struct sockaddr_in peer = {0};
    socklen_t peerLength = sizeof(peer);
    int fd = accept(_listenFD, (struct sockaddr *)&peer, &peerLength);
    if (fd < 0)
        return;

    CBConnection *connection = [[CBConnection alloc] initWithFD:fd agent:self];

    if (_connection) {
        /* One authenticated client at a time; tell the newcomer why rather than dropping it. */
        [connection start];
        [connection sendMessage:@{
            @"type" : @"error",
            @"error" : @{
                @"code" : @"busy",
                @"message" : @"Another client is already connected",
            },
            @"timestamp" : Timestamp(),
        }];
        [connection closeWithReason:@"busy"];
        return;
    }

    _connection = connection;
    [connection start];

    NSLog(@"callbridge-agent: client connected from %s", inet_ntoa(peer.sin_addr));

    [connection sendMessage:@{
        @"type" : @"hello",
        @"protocolVersion" : @(kProtocolVersion),
        @"agentVersion" : kAgentVersion,
        @"device" : [self deviceModel],
        @"nonce" : connection.nonce,
        @"authRequired" : @YES,
        @"timestamp" : Timestamp(),
    }];

    __weak typeof(self) weakSelf = self;
    __weak CBConnection *weakConnection = connection;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAuthTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       CBConnection *stillThere = weakConnection;
                       if (stillThere && !stillThere.authenticated)
                           [weakSelf rejectConnection:stillThere
                                             withCode:@"unauthorized"
                                              message:@"No authentication within 5 seconds"];
                   });
}

- (NSString *)deviceModel {
    char model[256] = {0};
    size_t length = sizeof(model);
    if (sysctlbyname("hw.machine", model, &length, NULL, 0) != 0)
        return @"unknown";
    return [NSString stringWithUTF8String:model] ?: @"unknown";
}

- (void)rejectConnection:(CBConnection *)connection
                withCode:(NSString *)code
                 message:(NSString *)message {
    [connection sendMessage:@{
        @"type" : @"error",
        @"error" : @{@"code" : code, @"message" : message},
        @"timestamp" : Timestamp(),
    }];
    [connection closeWithReason:code];
}

- (void)connectionDidClose:(CBConnection *)connection {
    if (_connection == connection)
        _connection = nil;
}

#pragma mark Messages

- (void)handleMessage:(NSDictionary *)message fromConnection:(CBConnection *)connection {
    NSString *type = message[@"type"];
    if (![type isKindOfClass:NSString.class]) {
        [self rejectConnection:connection withCode:@"bad_request" message:@"Missing type"];
        return;
    }

    /* Anything arriving proves the client is alive, not just a pong. */
    connection.missedPings = 0;

    if ([type isEqualToString:@"auth"]) {
        [self handleAuth:message fromConnection:connection];
        return;
    }

    if (!connection.authenticated) {
        [self rejectConnection:connection
                      withCode:@"unauthorized"
                       message:@"Authenticate before sending commands"];
        return;
    }

    if ([type isEqualToString:@"pong"]) {
        connection.missedPings = 0;
        return;
    }
    if ([type isEqualToString:@"call.command"]) {
        [self handleCommand:message fromConnection:connection];
        return;
    }

    [connection sendMessage:@{
        @"type" : @"error",
        @"error" : @{
            @"code" : @"bad_request",
            @"message" : [NSString stringWithFormat:@"Unsupported message type: %@", type],
        },
        @"timestamp" : Timestamp(),
    }];
}

- (void)handleAuth:(NSDictionary *)message fromConnection:(CBConnection *)connection {
    NSNumber *version = message[@"protocolVersion"];
    if (version && version.intValue != kProtocolVersion) {
        [self rejectConnection:connection
                      withCode:@"unsupported_version"
                       message:[NSString stringWithFormat:@"Agent speaks protocol version %d",
                                                          kProtocolVersion]];
        return;
    }

    NSString *proof = message[@"proof"];
    if (![proof isKindOfClass:NSString.class] || proof.length == 0) {
        [self rejectConnection:connection withCode:@"unauthorized" message:@"Missing proof"];
        return;
    }

    NSData *key = [self.token dataUsingEncoding:NSUTF8StringEncoding];
    NSData *nonce = [connection.nonce dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, nonce.bytes, nonce.length, digest);
    NSString *expected = HexString(digest, sizeof(digest));

    /* Compare in constant time: a timing oracle here would leak the proof byte by byte. */
    NSData *given = [proof.lowercaseString dataUsingEncoding:NSUTF8StringEncoding];
    NSData *want = [expected dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t difference = given.length == want.length ? 0 : 1;
    for (NSUInteger i = 0; i < want.length && i < given.length; i++)
        difference |= ((const uint8_t *)given.bytes)[i] ^ ((const uint8_t *)want.bytes)[i];

    if (difference != 0) {
        [self rejectConnection:connection withCode:@"unauthorized" message:@"Invalid proof"];
        return;
    }

    connection.authenticated = YES;
    connection.clientName = message[@"clientName"];
    /* Start the ping clock now, so the first ping is one interval away rather than immediate. */
    _lastPingAt = CFAbsoluteTimeGetCurrent();
    NSLog(@"callbridge-agent: client authenticated (%@)", connection.clientName ?: @"unnamed");

    [connection sendMessage:@{
        @"type" : @"auth.result",
        @"ok" : @YES,
        @"timestamp" : Timestamp(),
    }];

    [self refreshCallsPublishing:NO];
    NSMutableArray *calls = [NSMutableArray array];
    for (NSString *callID in _calls)
        [calls addObject:[self callPayloadForID:callID includeType:YES]];

    [connection sendMessage:@{
        @"type" : @"call.snapshot",
        @"calls" : calls,
        @"timestamp" : Timestamp(),
    }];
}

- (void)handleCommand:(NSDictionary *)message fromConnection:(CBConnection *)connection {
    NSString *requestID = message[@"requestId"];
    NSString *command = message[@"command"];

    if (![requestID isKindOfClass:NSString.class] || requestID.length == 0 ||
        ![command isKindOfClass:NSString.class]) {
        [connection sendMessage:[self resultForRequest:requestID
                                               command:command
                                              errorCode:@"bad_request"
                                                message:@"requestId and command are required"
                                                details:nil]];
        return;
    }
    if (![@[ @"answer", @"hangup" ] containsObject:command]) {
        [connection sendMessage:[self resultForRequest:requestID
                                               command:command
                                              errorCode:@"bad_request"
                                                message:@"Supported commands are answer and hangup"
                                                details:nil]];
        return;
    }

    NSDictionary *cached = _resultCache[requestID];
    if (cached) {
        /* Idempotency: a retry replays the stored result rather than acting twice. */
        [connection sendMessage:cached[@"result"]];
        return;
    }
    for (CBPendingCommand *pending in _pending) {
        if ([pending.requestID isEqualToString:requestID])
            return; /* Already running; its result will arrive when it resolves. */
    }

    NSString *wantedCallID = [message[@"callId"] isKindOfClass:NSString.class]
                                 ? message[@"callId"]
                                 : nil;
    NSNumber *timeout = message[@"timeoutMs"];
    NSTimeInterval timeoutSeconds = 5.0;
    if ([timeout isKindOfClass:NSNumber.class]) {
        NSInteger value = timeout.integerValue;
        if (value < 100 || value > 30000) {
            [connection sendMessage:[self resultForRequest:requestID
                                                   command:command
                                                  errorCode:@"bad_request"
                                                    message:@"timeoutMs must be 100-30000"
                                                    details:nil]];
            return;
        }
        timeoutSeconds = value / 1000.0;
    }

    CTCallStatus required = [command isEqualToString:@"answer"] ? kCTCallStatusIncomingCall
                                                                : kCTCallStatusAnswered;
    CFArrayRef calls = CTCopyCurrentCalls(kCFAllocatorDefault);
    NSMutableArray<NSValue *> *candidates = [NSMutableArray array];
    for (CFIndex i = 0; calls && i < CFArrayGetCount(calls); i++) {
        CTCallRef call = (CTCallRef)CFArrayGetValueAtIndex(calls, i);
        if (!IsCellularCall(call) || CTCallGetStatus(call) != required)
            continue;
        if (wantedCallID && ![CopyCallID(call) isEqualToString:wantedCallID])
            continue;
        [candidates addObject:[NSValue valueWithPointer:call]];
    }

    if (candidates.count == 0) {
        if (calls)
            CFRelease(calls);
        [self finishRequest:requestID
                    command:command
                 connection:connection
                    message:[self resultForRequest:requestID
                                           command:command
                                          errorCode:@"no_matching_call"
                                            message:[command isEqualToString:@"answer"]
                                                        ? @"No ringing cellular call was found"
                                                        : @"No active cellular call was found"
                                            details:nil]];
        return;
    }
    if (candidates.count > 1) {
        NSUInteger count = candidates.count;
        CFRelease(calls);
        [self finishRequest:requestID
                    command:command
                 connection:connection
                    message:[self resultForRequest:requestID
                                           command:command
                                          errorCode:@"ambiguous_call"
                                            message:@"More than one matching cellular call"
                                            details:@{@"candidateCount" : @(count)}]];
        return;
    }

    CTCallRef call = (CTCallRef)candidates.firstObject.pointerValue;
    NSString *callID = CopyCallID(call);
    NSString *fromState = StatusName(CTCallGetStatus(call));

    CBPendingCommand *pending = [CBPendingCommand new];
    pending.requestID = requestID;
    pending.command = command;
    pending.callID = callID;
    pending.fromState = fromState;
    pending.observedStates = [NSMutableArray arrayWithObject:fromState];
    pending.started = CFAbsoluteTimeGetCurrent();
    pending.timeout = timeoutSeconds;
    [_pending addObject:pending];

    if ([command isEqualToString:@"answer"])
        CTCallAnswer(call);
    else
        CTCallDisconnect(call);

    CFRelease(calls);

    NSLog(@"callbridge-agent: %@ issued for %@ (from %@)", command, callID, fromState);
}

#pragma mark Call state

- (NSDictionary *)callPayloadForID:(NSString *)callID includeType:(BOOL)includeType {
    NSDictionary *info = _calls[callID];
    NSMutableDictionary *payload = [@{
        @"callId" : callID,
        @"state" : info[@"state"] ?: @"unknown",
        @"direction" : info[@"direction"] ?: @"incoming",
    } mutableCopy];
    if (info[@"address"])
        payload[@"address"] = info[@"address"];
    if (includeType)
        payload[@"type"] = info[@"callType"] ?: @"unknown";
    else
        payload[@"callType"] = info[@"callType"] ?: @"unknown";
    return payload;
}

- (void)publishStateForCallID:(NSString *)callID {
    if (!_connection.authenticated)
        return;

    NSMutableDictionary *message = [[self callPayloadForID:callID includeType:NO] mutableCopy];
    message[@"type"] = @"call.state";
    message[@"timestamp"] = Timestamp();
    [_connection sendMessage:message];
}

- (void)applyState:(NSString *)state
         forCallID:(NSString *)callID
              info:(NSDictionary *)info {
    if (callID.length == 0 || state.length == 0)
        return;

    /*
     * CoreTelephony's first notification for a call can arrive before it has a status. Publishing
     * that would push an "unknown" transition to every client for every outgoing call, so hold it
     * back and wait for the real state; only the address is worth keeping from it.
     */
    if ([state isEqualToString:@"unknown"]) {
        [_calls[callID] addEntriesFromDictionary:info];
        return;
    }

    NSMutableDictionary *entry = _calls[callID];
    if (!entry) {
        entry = [NSMutableDictionary dictionary];
        _calls[callID] = entry;
    }

    /*
     * The same call is announced first in local format (05XXXXXXXXX) and then in E.164
     * (+905XXXXXXXXX). Keep the fully qualified one so the address does not change under the
     * client mid-call.
     */
    NSString *incoming = info[@"address"];
    NSString *known = entry[@"address"];
    if (incoming && [known hasPrefix:@"+"] && ![incoming hasPrefix:@"+"]) {
        NSMutableDictionary *withoutAddress = [info mutableCopy];
        [withoutAddress removeObjectForKey:@"address"];
        info = withoutAddress;
    }
    [entry addEntriesFromDictionary:info];

    BOOL changed = ![entry[@"state"] isEqualToString:state];
    entry[@"state"] = state;

    for (CBPendingCommand *pending in _pending) {
        if ([pending.callID isEqualToString:callID] &&
            ![pending.observedStates.lastObject isEqualToString:state])
            [pending.observedStates addObject:state];
    }

    if (!changed)
        return;

    NSLog(@"callbridge-agent: %@ %@ (%@)", callID, state,
          MaskedAddress(entry[@"address"]));
    [self publishStateForCallID:callID];

    if (IsTerminalState(state))
        [_calls removeObjectForKey:callID];
}

- (void)telephonyEventForCall:(CTCallRef)call status:(CTCallStatus)status {
    if (!IsCellularCall(call))
        return;

    NSString *callID = CopyCallID(call);
    if (!callID)
        return;

    NSString *address = CopyAddress(call);
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"direction"] = CTCallIsOutgoing(call) ? @"outgoing" : @"incoming";
    info[@"callType"] = TypeName(CTCallGetCallType(call));
    if (address.length > 0)
        info[@"address"] = address;

    [self applyState:StatusName(status) forCallID:callID info:info];
    [self resolvePendingCommands];
}

/* Catches calls that vanish without a terminal notification reaching us. */
- (void)refreshCallsPublishing:(BOOL)publish {
    CFArrayRef calls = CTCopyCurrentCalls(kCFAllocatorDefault);
    NSMutableSet<NSString *> *live = [NSMutableSet set];

    for (CFIndex i = 0; calls && i < CFArrayGetCount(calls); i++) {
        CTCallRef call = (CTCallRef)CFArrayGetValueAtIndex(calls, i);
        if (!IsCellularCall(call))
            continue;

        NSString *callID = CopyCallID(call);
        if (!callID)
            continue;
        [live addObject:callID];

        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"direction"] = CTCallIsOutgoing(call) ? @"outgoing" : @"incoming";
        info[@"callType"] = TypeName(CTCallGetCallType(call));
        NSString *address = CopyAddress(call);
        if (address.length > 0)
            info[@"address"] = address;

        NSString *state = StatusName(CTCallGetStatus(call));
        if (publish || !_calls[callID])
            [self applyState:state forCallID:callID info:info];
    }
    if (calls)
        CFRelease(calls);

    for (NSString *callID in _calls.allKeys) {
        if ([live containsObject:callID])
            continue;
        [self applyState:@"ended" forCallID:callID info:@{}];
    }
}

#pragma mark Command resolution

- (void)resolvePendingCommands {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    for (CBPendingCommand *pending in [_pending copy]) {
        NSString *state = _calls[pending.callID][@"state"];
        BOOL gone = state == nil;
        BOOL answering = [pending.command isEqualToString:@"answer"];

        NSMutableDictionary *details = [@{
            @"callId" : pending.callID,
            @"fromState" : pending.fromState,
            @"observedStates" : [pending.observedStates copy],
        } mutableCopy];

        if (answering && [state isEqualToString:@"active"]) {
            if (pending.answeredAt == 0)
                pending.answeredAt = now;
            /* Only a call that stays up counts as answered. */
            if (now - pending.answeredAt >= kAnswerStabilityInterval) {
                [self completePending:pending
                               result:@{
                                   @"toState" : @"active",
                                   @"elapsedMs" : @((NSInteger)((pending.answeredAt -
                                                                 pending.started) *
                                                                1000.0)),
                                   @"stableForMs" :
                                       @((NSInteger)((now - pending.answeredAt) * 1000.0)),
                               }];
            }
            continue;
        }

        if (gone || IsTerminalState(state)) {
            NSString *finalState = IsTerminalState(state) ? state : @"ended";
            details[@"observedState"] = finalState;
            details[@"elapsedMs"] = @((NSInteger)((now - pending.started) * 1000.0));

            if (!answering) {
                [self completePending:pending
                               result:@{
                                   @"toState" : finalState,
                                   @"elapsedMs" : details[@"elapsedMs"],
                               }];
                continue;
            }

            if (pending.answeredAt > 0) {
                details[@"activeForMs"] = @((NSInteger)((now - pending.answeredAt) * 1000.0));
                [self failPending:pending
                             code:@"call_dropped_after_answer"
                          message:@"The call was answered but was torn down before it stayed active"
                          details:details];
            } else {
                [self failPending:pending
                             code:@"call_ended"
                          message:@"The call ended before the expected transition was observed"
                          details:details];
            }
            continue;
        }

        if (now - pending.started >= pending.timeout) {
            details[@"observedState"] = state ?: @"not-found";
            details[@"elapsedMs"] = @((NSInteger)((now - pending.started) * 1000.0));
            [self failPending:pending
                         code:@"verification_timeout"
                      message:@"The command was sent but the expected transition was not observed"
                      details:details];
        }
    }
}

- (NSDictionary *)resultForRequest:(NSString *)requestID
                           command:(NSString *)command
                         errorCode:(NSString *)code
                           message:(NSString *)message
                           details:(NSDictionary *)details {
    NSMutableDictionary *result = [@{
        @"type" : @"call.result",
        @"ok" : @NO,
        @"command" : command ?: @"unknown",
        @"error" : @{@"code" : code, @"message" : message},
        @"timestamp" : Timestamp(),
    } mutableCopy];
    if (requestID)
        result[@"requestId"] = requestID;
    if (details)
        [result addEntriesFromDictionary:details];
    return result;
}

- (void)completePending:(CBPendingCommand *)pending result:(NSDictionary *)extra {
    NSMutableDictionary *result = [@{
        @"type" : @"call.result",
        @"requestId" : pending.requestID,
        @"ok" : @YES,
        @"command" : pending.command,
        @"callId" : pending.callID,
        @"fromState" : pending.fromState,
        @"observedStates" : [pending.observedStates copy],
        @"timestamp" : Timestamp(),
    } mutableCopy];
    [result addEntriesFromDictionary:extra];

    NSLog(@"callbridge-agent: %@ ok in %@ ms", pending.command, result[@"elapsedMs"]);
    [_pending removeObject:pending];
    [self finishRequest:pending.requestID command:pending.command connection:_connection
                message:result];
}

- (void)failPending:(CBPendingCommand *)pending
               code:(NSString *)code
            message:(NSString *)message
            details:(NSDictionary *)details {
    NSDictionary *result = [self resultForRequest:pending.requestID
                                          command:pending.command
                                        errorCode:code
                                          message:message
                                          details:details];
    NSLog(@"callbridge-agent: %@ failed (%@)", pending.command, code);
    [_pending removeObject:pending];
    [self finishRequest:pending.requestID command:pending.command connection:_connection
                message:result];
}

- (void)finishRequest:(NSString *)requestID
              command:(NSString *)command
           connection:(CBConnection *)connection
              message:(NSDictionary *)message {
    if (requestID) {
        _resultCache[requestID] = @{
            @"result" : message,
            @"at" : @(CFAbsoluteTimeGetCurrent()),
        };
    }
    [connection sendMessage:message];
}

#pragma mark Timer

- (void)tick {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    [self refreshCallsPublishing:NO];
    [self resolvePendingCommands];

    for (NSString *requestID in _resultCache.allKeys) {
        NSNumber *at = _resultCache[requestID][@"at"];
        if (now - at.doubleValue > kCommandCacheTTL)
            [_resultCache removeObjectForKey:requestID];
    }

    if (_connection.authenticated && now - _lastPingAt >= kPingInterval) {
        _lastPingAt = now;
        if (_connection.missedPings >= kMissedPingLimit) {
            [_connection closeWithReason:@"no pong"];
            return;
        }
        _connection.missedPings++;
        [_connection sendMessage:@{@"type" : @"ping", @"timestamp" : Timestamp()}];
    }
}

@end

#pragma mark - Entry point

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = [[NSProcessInfo processInfo].arguments
            subarrayWithRange:NSMakeRange(1, MAX(argc - 1, 0))];

        NSError *error = nil;
        NSString *token = LoadOrCreateToken(&error);
        if (!token) {
            fprintf(stderr, "callbridge-agent: could not prepare the pairing token: %s\n",
                    error.localizedDescription.UTF8String);
            return 1;
        }

        if ([arguments containsObject:@"--print-token"]) {
            printf("%s\n", token.UTF8String);
            return 0;
        }

        CBAgent *agent = [CBAgent new];
        agent.token = token;

        NSUInteger portIndex = [arguments indexOfObject:@"--port"];
        if (portIndex != NSNotFound) {
            if (portIndex + 1 >= arguments.count) {
                fprintf(stderr, "callbridge-agent: --port requires a value\n");
                return 2;
            }
            agent.port = arguments[portIndex + 1].integerValue;
        }

        gAgent = agent;

        CFNotificationCenterRef center = CTTelephonyCenterGetDefault();
        CTTelephonyCenterAddObserver(center, NULL, TelephonyEventCallback,
                                     kCTCallStatusChangeNotification, NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);
        CTTelephonyCenterAddObserver(center, NULL, TelephonyEventCallback,
                                     kCTCallIdentificationChangeNotification, NULL,
                                     CFNotificationSuspensionBehaviorDeliverImmediately);

        if (![agent startListening:&error]) {
            fprintf(stderr, "callbridge-agent: could not listen: %s\n",
                    error.localizedDescription.UTF8String);
            return 1;
        }

        CFRunLoopRun();
    }
    return 0;
}
