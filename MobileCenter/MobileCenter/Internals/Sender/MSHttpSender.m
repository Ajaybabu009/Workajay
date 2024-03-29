#import "MSHttpSender.h"
#import "MSHttpSenderPrivate.h"
#import "MSMobileCenterInternal.h"
#import "MSSenderCall.h"

static NSTimeInterval kRequestTimeout = 60.0;

// URL components' name within a partial URL.
static NSString *const kMSPartialURLComponentsName[] = {@"scheme", @"user", @"password", @"host", @"port", @"path"};

@implementation MSHttpSender

@synthesize baseURL = _baseURL;
@synthesize apiPath = _apiPath;
@synthesize reachability = _reachability;
@synthesize suspended = _suspended;

#pragma mark - Initialize

- (id)initWithBaseUrl:(NSString *)baseUrl
              apiPath:(NSString *)apiPath
              headers:(NSDictionary *)headers
         queryStrings:(NSDictionary *)queryStrings
         reachability:(MS_Reachability *)reachability
       retryIntervals:(NSArray *)retryIntervals {
  if ((self = [super init])) {
    _httpHeaders = headers;
    _pendingCalls = [NSMutableDictionary new];
    _reachability = reachability;
    _enabled = YES;
    _suspended = NO;
    _delegates = [NSHashTable weakObjectsHashTable];
    _callsRetryIntervals = retryIntervals;
    _apiPath = apiPath;

    // Construct the URL string with the query string.
    NSString *urlString = [baseUrl stringByAppendingString:apiPath];
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    NSMutableArray *queryItemArray = [NSMutableArray array];

    // Set query parameter.
    [queryStrings enumerateKeysAndObjectsUsingBlock:^(id _Nonnull key, id _Nonnull queryString,
                                                      __attribute__((unused)) BOOL *_Nonnull stop) {
      NSURLQueryItem *queryItem = [NSURLQueryItem queryItemWithName:key value:queryString];
      [queryItemArray addObject:queryItem];
    }];
    components.queryItems = queryItemArray;

    // Set send URL which can't be null
    _sendURL = (NSURL * _Nonnull)components.URL;

    // Hookup to reachability.
    [MS_NOTIFICATION_CENTER addObserver:self
                               selector:@selector(networkStateChanged:)
                                   name:kMSReachabilityChangedNotification
                                 object:nil];
    [self.reachability startNotifier];

    // Apply current network state.
    [self networkStateChanged];
  }
  return self;
}

#pragma mark - MSSender

- (void)sendAsync:(NSObject *)data completionHandler:(MSSendAsyncCompletionHandler)handler {
  [self sendAsync:data callId:MS_UUID_STRING completionHandler:handler];
}

- (void)addDelegate:(id<MSSenderDelegate>)delegate {
  @synchronized(self) {
    [self.delegates addObject:delegate];
  }
}

- (void)removeDelegate:(id<MSSenderDelegate>)delegate {
  @synchronized(self) {
    [self.delegates removeObject:delegate];
  }
}

#pragma mark - Life cycle

- (void)setEnabled:(BOOL)isEnabled andDeleteDataOnDisabled:(BOOL)deleteData {
  @synchronized(self) {
    if (self.enabled != isEnabled) {
      self.enabled = isEnabled;
      if (isEnabled) {
        [self resume];
        [self.reachability startNotifier];
      } else {
        [self.reachability stopNotifier];
        [self suspend];

        // Data deletion is required.
        if (deleteData) {

          // Cancel all the tasks and invalidate current session to free resources.
          [self.session invalidateAndCancel];
          self.session = nil;

          // Remove pending calls.
          [self.pendingCalls removeAllObjects];
        }
      }

      // Forward enabled state.
      [self
          enumerateDelegatesForSelector:@selector(senderDidSuspend:)
                              withBlock:^(id<MSSenderDelegate> delegate) {
                                [delegate sender:self didSetEnabled:(BOOL)isEnabled andDeleteDataOnDisabled:deleteData];
                              }];
    }
  }
}

- (void)suspend {
  @synchronized(self) {
    if (!self.suspended) {
      MSLogInfo([MSMobileCenter logTag], @"Suspend sender.");
      self.suspended = YES;

      // Suspend all tasks.
      [self.session getTasksWithCompletionHandler:^(
                        NSArray<NSURLSessionDataTask *> *_Nonnull dataTasks,
                        __attribute__((unused)) NSArray<NSURLSessionUploadTask *> *_Nonnull uploadTasks,
                        __attribute__((unused)) NSArray<NSURLSessionDownloadTask *> *_Nonnull downloadTasks) {
        [dataTasks enumerateObjectsUsingBlock:^(__kindof NSURLSessionTask *_Nonnull call,
                                                __attribute__((unused)) NSUInteger idx,
                                                __attribute__((unused)) BOOL *_Nonnull stop) {
          [call suspend];
        }];
      }];

      // Suspend current calls' retry.
      [self.pendingCalls.allValues
          enumerateObjectsUsingBlock:^(MSSenderCall *_Nonnull call, __attribute__((unused)) NSUInteger idx,
                                       __attribute__((unused)) BOOL *_Nonnull stop) {
            if (!call.submitted) {
              [call resetRetry];
            }
          }];

      // Notify delegates.
      [self enumerateDelegatesForSelector:@selector(senderDidSuspend:)
                                withBlock:^(id<MSSenderDelegate> delegate) {
                                  [delegate senderDidSuspend:self];
                                }];
    }
  }
}

- (void)resume {
  @synchronized(self) {

    // Resume only while enabled.
    if (self.suspended && self.enabled) {
      MSLogInfo([MSMobileCenter logTag], @"Resume sender.");
      self.suspended = NO;

      // Resume existing calls.
      [self.session getTasksWithCompletionHandler:^(
                        NSArray<NSURLSessionDataTask *> *_Nonnull dataTasks,
                        __attribute__((unused)) NSArray<NSURLSessionUploadTask *> *_Nonnull uploadTasks,
                        __attribute__((unused)) NSArray<NSURLSessionDownloadTask *> *_Nonnull downloadTasks) {
        [dataTasks enumerateObjectsUsingBlock:^(__kindof NSURLSessionTask *_Nonnull call,
                                                __attribute__((unused)) NSUInteger idx,
                                                __attribute__((unused)) BOOL *_Nonnull stop) {
          [call resume];
        }];
      }];

      // Resume calls.
      [self.pendingCalls.allValues
          enumerateObjectsUsingBlock:^(MSSenderCall *_Nonnull call, __attribute__((unused)) NSUInteger idx,
                                       __attribute__((unused)) BOOL *_Nonnull stop) {
            if (!call.submitted) {
              [self sendCallAsync:call];
            }
          }];

      // Propagate.
      [self enumerateDelegatesForSelector:@selector(senderDidResume:)
                                withBlock:^(id<MSSenderDelegate> delegate) {
                                  [delegate senderDidResume:self];
                                }];
    }
  }
}

#pragma mark - MSSenderCallDelegate

- (void)sendCallAsync:(MSSenderCall *)call {
  @synchronized(self) {
    if (self.suspended)
      return;

    if (!call)
      return;

    // Create the request.
    NSURLRequest *request = [self createRequest:call.data];
    if (!request)
      return;

    // Create a task for the request.
    NSURLSessionDataTask *task = [self.session
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            @synchronized(self) {
              NSString *payload = nil;
              NSInteger statusCode = [MSSenderUtil getStatusCode:response];
              if (data) {

                // Error instance for JSON parsing.
                NSError *jsonError = nil;
                id dictionary = [NSJSONSerialization JSONObjectWithData:data
                                                                options:NSJSONReadingMutableContainers
                                                                  error:&jsonError];
                if (jsonError) {
                  payload = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                } else {
                  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionary
                                                                     options:NSJSONWritingPrettyPrinted
                                                                       error:&jsonError];
                  if (!jsonData || jsonError) {
                    payload = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                  } else {

                    // NSJSONSerialization escapes paths by default so we replace them.
                    payload = [[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]
                        stringByReplacingOccurrencesOfString:@"\\/"
                                                  withString:@"/"];
                  }
                }
              }
              MSLogDebug([MSMobileCenter logTag], @"HTTP response received with status code=%lu and payload=%@",
                         (unsigned long)statusCode, payload);

              // Call handles the completion.
              if (call) {
                call.submitted = NO;
                [call sender:self callCompletedWithStatus:statusCode data:data error:error];
              }
            }
          }];

    // TODO: Set task priority.
    [task resume];
    call.submitted = YES;
  }
}

- (void)callCompletedWithId:(NSString *)callId {
  @synchronized(self) {
    if (!callId) {
      MSLogWarning([MSMobileCenter logTag], @"Call object is invalid");
      return;
    }
    [self.pendingCalls removeObjectForKey:callId];
    MSLogInfo([MSMobileCenter logTag], @"Removed call id:%@ from pending calls:%@", callId,
              [self.pendingCalls description]);
  }
}

#pragma mark - Reachability

- (void)networkStateChanged:(NSNotificationCenter *)notification {
  (void)notification;
  [self networkStateChanged];
}

#pragma mark - Private

- (void)setBaseURL:(NSString *)baseURL {
  @synchronized(self) {
    BOOL success = false;
    NSURLComponents *components;
    _baseURL = baseURL;
    NSURL *partialURL = [NSURL URLWithString:[baseURL stringByAppendingString:self.apiPath]];

    // Merge new parial URL and current full URL.
    if (partialURL) {
      components = [NSURLComponents componentsWithURL:self.sendURL resolvingAgainstBaseURL:NO];
      @try {
        for (u_long i = 0; i < sizeof(kMSPartialURLComponentsName) / sizeof(*kMSPartialURLComponentsName); i++) {
          NSString *propertyName = kMSPartialURLComponentsName[i];
          [components setValue:[partialURL valueForKey:propertyName] forKey:propertyName];
        }
      } @catch (NSException *ex) {
        MSLogInfo([MSMobileCenter logTag], @"Error while updating HTTP URL %@ with %@: \n%@",
                  self.sendURL.absoluteString, baseURL, ex);
      }

      // Update full URL.
      if (components.URL) {
        self.sendURL = (NSURL * _Nonnull)components.URL;
        success = true;
      }
    }

    // Notify failure.
    if (!success) {
      MSLogInfo([MSMobileCenter logTag], @"Failed to update HTTP URL %@ with %@", self.sendURL.absoluteString, baseURL);
    }
  }
}

- (void)networkStateChanged {
  if ([self.reachability currentReachabilityStatus] == NotReachable) {
    MSLogInfo([MSMobileCenter logTag], @"Internet connection is down.");
    [self suspend];
  } else {
    MSLogInfo([MSMobileCenter logTag], @"Internet connection is up.");
    [self resume];
  }
}

/**
 * This is an empty method and expect to be overridden in sub classes.
 */
- (NSURLRequest *)createRequest:(NSObject *)data {
  (void)data;
  return nil;
}

- (NSString *)obfuscateHeaderValue:(NSString *)key value:(NSString *)value {
  (void)key;
  return value;
}

- (NSURLSession *)session {
  if (!_session) {
    NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfiguration.timeoutIntervalForRequest = kRequestTimeout;
    _session = [NSURLSession sessionWithConfiguration:sessionConfiguration];
  }
  return _session;
}

- (void)enumerateDelegatesForSelector:(SEL)selector withBlock:(void (^)(id<MSSenderDelegate> delegate))block {
  for (id<MSSenderDelegate> delegate in self.delegates) {
    if (delegate && [delegate respondsToSelector:selector]) {
      block(delegate);
    }
  }
}

- (NSString *)prettyPrintHeaders:(NSDictionary<NSString *, NSString *> *)headers {
  NSMutableArray<NSString *> *flattenedHeaders = [NSMutableArray<NSString *> new];
  for (NSString *headerKey in headers) {
    [flattenedHeaders
        addObject:[NSString stringWithFormat:@"%@ = %@", headerKey,
                                             [self obfuscateHeaderValue:headerKey value:headers[headerKey]]]];
  }
  return [flattenedHeaders componentsJoinedByString:@", "];
}

- (void)sendAsync:(NSObject *)data callId:(NSString *)callId completionHandler:(MSSendAsyncCompletionHandler)handler {
  @synchronized(self) {

    // Check if call has already been created(retry scenario).
    MSSenderCall *call = self.pendingCalls[callId];
    if (call == nil) {
      call = [[MSSenderCall alloc] initWithRetryIntervals:self.callsRetryIntervals];
      call.delegate = self;
      call.data = data;
      call.callId = callId;
      call.completionHandler = handler;

      // Store call in calls array.
      self.pendingCalls[callId] = call;
    }
    [self sendCallAsync:call];
  }
}

- (void)dealloc {
  [self.reachability stopNotifier];
  [MS_NOTIFICATION_CENTER removeObserver:self name:kMSReachabilityChangedNotification object:nil];
}

@end
