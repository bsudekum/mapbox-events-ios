#import "MMEMetricsManager.h"
#import "MMEReachability.h"
#import "MMEConstants.h"
#import "MMEDate.h"
#import "MMEEventLogger.h"
#import "MMEEventsManager.h"
#import "MMECommonEventData.h"
#import "MMEAPIClient.h"

#pragma mark -

@interface MMEEventsManager (Private)

- (void)pushEvent:(MMEEvent *)event;

@property (nonatomic) MMECommonEventData *commonEventData;
@property (nonatomic) id<MMEAPIClient> apiClient;

@end

#pragma mark -

@interface MMEMetricsManager ()

@property (nonatomic) MMEMetrics *metrics;

@end

#pragma mark -

@implementation MMEMetricsManager

+ (instancetype)sharedManager {
    static MMEMetricsManager *_sharedManager;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        _sharedManager = [[MMEMetricsManager alloc] init];
    });
    
    return _sharedManager;
}

+ (NSString *)pendingMetricsEventPath {
    static NSString *pendingMetricFile = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        NSString *libraryPath = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).lastObject;
        NSString *frameworkLibraryPath = [libraryPath stringByAppendingPathComponent:[NSBundle bundleForClass:self].bundleIdentifier];
        pendingMetricFile = [frameworkLibraryPath stringByAppendingPathComponent:@"pending-metrics.event"];
    });

    return pendingMetricFile;
}

/*! @brief Remove any existing pending metrics event, logging any errors that occur */
+ (BOOL)deletePendingMetricsEventFile {
    BOOL success = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:MMEMetricsManager.pendingMetricsEventPath]) {
        NSError *fileError = nil;
        if (![NSFileManager.defaultManager removeItemAtPath:MMEMetricsManager.pendingMetricsEventPath error:&fileError]) {
            MMEEvent *errorEvent = [MMEEvent debugEventWithError:fileError];
            [MMEEventLogger.sharedLogger logEvent:errorEvent];
        }
        else {  // we successufll removed the file
            success = YES;

        }
    }
    else { // there was no file to begin with
        success = YES;
    }

    return success;
}

#pragma mark -

- (instancetype)init {
    if (self = [super init]) {
        [self resetMetrics];
    }
    return self;
}

- (void)updateMetricsFromEventQueue:(NSArray *)eventQueue {
    if (eventQueue.count > 0) {
        if (self.metrics.eventCountPerType == nil) {
            self.metrics.eventCountPerType = [[NSMutableDictionary alloc] init];
        }
        
        self.metrics.eventCountTotal += (int)eventQueue.count;
        
        for (MMEEvent *event in eventQueue) {
            NSNumber *eventCount = [self.metrics.eventCountPerType objectForKey:event.name];
            eventCount = [NSNumber numberWithInteger:[eventCount integerValue] + 1];
            [self.metrics.eventCountPerType setObject:eventCount forKey:event.name];
        }
    }
}

- (void)updateMetricsFromEventCount:(NSUInteger)eventCount request:(nullable NSURLRequest *)request error:(nullable NSError *)error {
    if (request.HTTPBody) {
        [self updateSentBytes:request.HTTPBody.length];
    }
    
    if (request == nil && error == nil) {
        [self updateEventsFailedCount:eventCount];
    } else if (error == nil) {
        //successful request -- the events for this are counted elsewhere
        self.metrics.requests++;
    } else {
        [self updateEventsFailedCount:eventCount];

        NSHTTPURLResponse *response = (NSHTTPURLResponse *)[error.userInfo objectForKey:MMEResponseKey];
        NSString *urlString = response.URL.absoluteString;
        NSNumber *statusCode = @(response.statusCode);
        NSString *statusCodeKey = [statusCode stringValue];
        
        if (self.metrics.failedRequestsDict == nil) {
            self.metrics.failedRequestsDict = [[NSMutableDictionary alloc] init];
        }
        
        if (urlString && [self.metrics.failedRequestsDict objectForKey:MMEEventKeyHeader] == nil) {
            [self.metrics.failedRequestsDict setObject:urlString forKey:MMEEventKeyHeader];
        }
    
        if ([self.metrics.failedRequestsDict objectForKey:MMEEventKeyFailedRequests] == nil) {
            [self.metrics.failedRequestsDict setObject:[NSMutableDictionary new] forKey:MMEEventKeyFailedRequests];
        }
        
        NSMutableDictionary *failedRequests = [self.metrics.failedRequestsDict objectForKey:MMEEventKeyFailedRequests];
        
        NSNumber *failedCount = [failedRequests objectForKey:statusCodeKey];
        failedCount = [NSNumber numberWithInteger:[failedCount integerValue] + 1];
        [failedRequests setObject:failedCount forKey:statusCodeKey];
        
        [self.metrics.failedRequestsDict setObject:failedRequests forKey:MMEEventKeyFailedRequests];
    }
}

- (void)updateEventsFailedCount:(NSUInteger)eventCount {
    self.metrics.eventCountFailed += eventCount;
}

- (void)updateSentBytes:(NSUInteger)bytes {
    if ([[MMEReachability reachabilityForLocalWiFi] isReachableViaWiFi]) {
        self.metrics.wifiBytesSent += bytes;
    } else {
        self.metrics.cellBytesSent += bytes;
    }
}

- (void)updateReceivedBytes:(NSUInteger)bytes {
    if ([[MMEReachability reachabilityForLocalWiFi] isReachableViaWiFi]) {
        self.metrics.wifiBytesReceived += bytes;
    } else {
        self.metrics.cellBytesReceived += bytes;
    }
}

- (void)incrementAppWakeUpCount {
    self.metrics.appWakeups++;
}

- (void)updateConfigurationJSON:(NSDictionary *)configuration {
    if (configuration) {
        self.metrics.configResponseDict = configuration;
    }
}

- (void)updateCoordinate:(CLLocationCoordinate2D)coordinate {
    if (!self.metrics.deviceLat || !self.metrics.deviceLon) {
        self.metrics.deviceLat = round(coordinate.latitude*1000)/1000;
        self.metrics.deviceLon = round(coordinate.longitude*1000)/1000;
    }
}

- (void)resetMetrics {
    self.metrics = [MMEMetrics new];
}

- (NSDictionary *)attributes {
    MMEMutableMapboxEventAttributes *attributes = [MMEMutableMapboxEventAttributes dictionary];
    if (self.metrics.recordingStarted) {
        attributes[MMEEventDateUTC] = [MMEDate.iso8601DateOnlyFormatter stringFromDate:self.metrics.recordingStarted];
    }
    attributes[MMEEventKeyFailedRequests] = [self jsonStringfromDict:self.metrics.failedRequestsDict];
    attributes[MMEEventEventCountPerType] = [self jsonStringfromDict:self.metrics.eventCountPerType];
    attributes[MMEEventConfigResponse] = [self jsonStringfromDict:self.metrics.configResponseDict];
    attributes[MMEEventTotalDataSent] = @(self.metrics.totalBytesSent);
    attributes[MMEEventCellDataSent] = @(self.metrics.cellBytesSent);
    attributes[MMEEventWiFiDataSent] = @(self.metrics.wifiBytesSent);
    attributes[MMEEventTotalDataReceived] = @(self.metrics.totalBytesReceived);
    attributes[MMEEventCellDataReceived] = @(self.metrics.cellBytesReceived);
    attributes[MMEEventWiFiDataReceived] = @(self.metrics.wifiBytesReceived);
    attributes[MMEEventEventCountFailed] = @(self.metrics.eventCountFailed);
    attributes[MMEEventEventCountTotal] = @(self.metrics.eventCountTotal);
    attributes[MMEEventEventCountMax] = @(self.metrics.eventCountMax);
    attributes[MMEEventAppWakeups] = @(self.metrics.appWakeups);
    attributes[MMEEventRequests] = @(self.metrics.requests);
    attributes[MMEEventDeviceTimeDrift] = @(MMEDate.recordedTimeOffsetFromServer);
    if (self.metrics.deviceLat != 0 && self.metrics.deviceLon != 0) {
        attributes[MMEEventDeviceLat] = @(self.metrics.deviceLat);
        attributes[MMEEventDeviceLon] = @(self.metrics.deviceLon);
    }
    attributes[MMEEventKeyVendorID] = [MMEEventsManager sharedManager].commonEventData.vendorId;
    attributes[MMEEventKeyModel] = [MMEEventsManager sharedManager].commonEventData.model;
    attributes[MMEEventKeyOperatingSystem] = [MMEEventsManager sharedManager].commonEventData.osVersion;
    attributes[MMEEventKeyPlatform] = [MMEEventsManager sharedManager].commonEventData.platform;
    attributes[MMEEventKeyDevice] = [MMEEventsManager sharedManager].commonEventData.device;
    
    attributes[MMEEventSDKIdentifier] = [MMEEventsManager sharedManager].apiClient.userAgentBase;
    attributes[MMEEventSDKVersion] = [MMEEventsManager sharedManager].apiClient.hostSDKVersion;
    attributes[MMEEventKeyUserAgent] = [MMEEventsManager sharedManager].apiClient.userAgent;

    return attributes;
}

- (MMEEvent *)loadPendingTelemetryMetricsEvent {
    MMEEvent* pending = nil;

    if ([NSFileManager.defaultManager fileExistsAtPath:MMEMetricsManager.pendingMetricsEventPath]) {
        @try {
            NSData *thenData = [NSData dataWithContentsOfFile:MMEMetricsManager.pendingMetricsEventPath];
            NSKeyedUnarchiver* unarchiver = [NSKeyedUnarchiver.alloc initForReadingWithData:thenData];
            unarchiver.requiresSecureCoding = YES;
            pending = [unarchiver decodeObjectOfClass:MMEDate.class forKey:NSKeyedArchiveRootObjectKey];
        }
        @catch (NSException *exception) {
            [MMEEventLogger.sharedLogger logEvent:[MMEEvent debugEventWithException:exception]];
        }
    }

    return pending;
}

- (MMEEvent *)generateTelemetryMetricsEvent {
    NSDate *zeroHour = [self.metrics.recordingStarted mme_startOfTomorrow];
    NSString *metricsDate = [MMEDate.iso8601DateFormatter stringFromDate:NSDate.date];
    MMEEvent *telemetryMetrics = [MMEEvent telemetryMetricsEventWithDateString:metricsDate attributes:self.attributes];

    if (zeroHour.timeIntervalSinceNow > 0) { // it's not time to send metrics yet, write them to a pending file
        NSString *debugDescription = [NSString stringWithFormat:@"TelemetryMetrics event isn't ready to be sent; writing to %@ and waiting until %@ to send", MMEMetricsManager.pendingMetricsEventPath, zeroHour];
        
        [self pushDebugEventWithAttributes:@{MMEDebugEventType: MMEDebugEventTypeTelemetryMetrics,
                                             MMEEventKeyLocalDebugDescription: debugDescription}];

        [MMEMetricsManager deletePendingMetricsEventFile];

        @try { // to write the metrics event to the pending metrics event path
            [NSKeyedArchiver archiveRootObject:telemetryMetrics toFile:MMEMetricsManager.pendingMetricsEventPath];
        }
        @catch (NSException* exception) {
            [MMEEventLogger.sharedLogger logEvent:[MMEEvent debugEventWithException:exception]];
        }

        return nil;
    }

    [MMEEventLogger.sharedLogger logEvent:telemetryMetrics];
    [MMEMetricsManager deletePendingMetricsEventFile];
    
    return telemetryMetrics;
}

- (void)pushDebugEventWithAttributes:(NSDictionary *)attributes {
    NSMutableDictionary *combinedAttributes = [NSMutableDictionary dictionaryWithDictionary:attributes];
    [combinedAttributes setObject:[MMEDate.iso8601DateFormatter stringFromDate:NSDate.date] forKey:@"created"];
    MMEEvent *debugEvent = [MMEEvent debugEventWithAttributes:attributes];
    [MMEEventLogger.sharedLogger logEvent:debugEvent];
}

#pragma mark -

- (NSString *)jsonStringfromDict:(NSDictionary *)dictionary {
    //prevents empty dictionaries from being stringified
    if ([dictionary count] > 0) {
        NSString *jsonString;
        NSError *jsonError = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&jsonError];
        
        if (jsonData) {
            jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        } else if (jsonError) {
            [[MMEEventsManager sharedManager] pushEvent:[MMEEvent debugEventWithError:jsonError]];
        }
        return jsonString;
    }
    return nil;
}

@end
