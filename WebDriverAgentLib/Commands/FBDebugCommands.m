/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBDebugCommands.h"

#import "FBApplication.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "XCAXClient_iOS.h"
#import "XCUIDevice.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIElement+FBUtilities.h"
#import "FBXPath.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCTestManager_ManagerInterface-Protocol.h"
#import "XCAccessibilityElement.h"
#import "XCUIElement+FBIsVisible.h"

@implementation FBDebugCommands

#define DEFAULT_SNAPSHOT_WAIT 1.0

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/source"] respondWithTarget:self action:@selector(handleGetSourceCommand:)],
    [[FBRoute GET:@"/source"].withoutSession respondWithTarget:self action:@selector(handleGetSourceCommand:)],
    [[FBRoute GET:@"/wda/accessibleSource"] respondWithTarget:self action:@selector(handleGetAccessibleSourceCommand:)],
    [[FBRoute GET:@"/wda/accessibleSource"].withoutSession respondWithTarget:self action:@selector(handleGetAccessibleSourceCommand:)],
    [[FBRoute GET:@"/appTerminate"].withoutSession respondWithTarget:self action:@selector(handleGetAppTerminateCommand:)],
    [[FBRoute GET:@"/appStateRunningForeground"].withoutSession respondWithTarget:self action:@selector(handleGetAppStateRunningForegroundCommand:)],
    [[FBRoute GET:@"/appAtPoint"].withoutSession respondWithTarget:self action:@selector(handleGetAppAtPointCommand:)],
    [[FBRoute GET:@"/elementAtPoint"].withoutSession respondWithTarget:self action:@selector(handleGetElementAtPointCommand:)],
    [[FBRoute GET:@"/remoteWebView"].withoutSession respondWithTarget:self action:@selector(handleGetWebViewCommand:)],
  ];
}


#pragma mark - Commands

static NSString *const SOURCE_FORMAT_XML = @"xml";
static NSString *const SOURCE_FORMAT_JSON = @"json";
static NSString *const SOURCE_FORMAT_DESCRIPTION = @"description";

+ (id<FBResponsePayload>)handleGetSourceCommand:(FBRouteRequest *)request
{
  FBApplication *application = request.session.activeApplication ?: [FBApplication fb_activeApplication];
  NSString *sourceType = request.parameters[@"format"] ?: SOURCE_FORMAT_XML;
  id result;
  if ([sourceType caseInsensitiveCompare:SOURCE_FORMAT_XML] == NSOrderedSame) {
    result = application.fb_xmlRepresentation;
  } else if ([sourceType caseInsensitiveCompare:SOURCE_FORMAT_JSON] == NSOrderedSame) {
    result = application.fb_tree;
  } else if ([sourceType caseInsensitiveCompare:SOURCE_FORMAT_DESCRIPTION] == NSOrderedSame) {
    result = application.fb_descriptionRepresentation;
  } else {
    return FBResponseWithStatus(
      FBCommandStatusUnsupported,
      [NSString stringWithFormat:@"Unknown source format '%@'. Only %@ source formats are supported.",
       sourceType, @[SOURCE_FORMAT_XML, SOURCE_FORMAT_JSON, SOURCE_FORMAT_DESCRIPTION]]
    );
  }
  if (nil == result) {
    return FBResponseWithErrorFormat(@"Cannot get '%@' source of the current application", sourceType);
  }
  return FBResponseWithObject(result);
}

+ (id<FBResponsePayload>)handleGetAccessibleSourceCommand:(FBRouteRequest *)request
{
  FBApplication *application = request.session.activeApplication;
  return FBResponseWithObject(application.fb_accessibilityTree ?: @{});
}

+ (id<FBResponsePayload>)handleGetAppTerminateCommand:(FBRouteRequest *)request
{
  NSString *bundleId = request.parameters[@"bundleId"];
  XCUIApplication * app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
  [app terminate];

//  - (void)_XCT_terminateApplicationWithBundleID:(NSString *)arg1 completion:(void (^)(NSError *))arg2;
  BOOL isTerminated = [app waitForState:XCUIApplicationStateNotRunning timeout:9.0];

  return FBResponseWithObject(@{@"isTerminated": @(isTerminated)});
}

+ (id<FBResponsePayload>)handleGetAppStateRunningForegroundCommand:(FBRouteRequest *)request
{
  NSString *bundleId = request.parameters[@"bundleId"];
  NSTimeInterval timeout = [request.parameters[@"timeout"] doubleValue];
  BOOL debug = [request.parameters[@"debug"] boolValue];
  BOOL getDOM = [request.parameters[@"getDOM"] boolValue];

  XCUIApplication * app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
  BOOL isRunning = [app waitForState:XCUIApplicationStateRunningForeground timeout:timeout];
  NSString *debugDescription = debug ? [app debugDescription] : @"";

  NSDictionary *tree = nil;

  if (getDOM) {
    FBApplication *fb_app = [FBApplication appWithPID:[app processID]];
    tree = fb_app.fb_tree;
  } else {
    tree = [[NSMutableDictionary alloc] init];
  }

  return FBResponseWithObject(@{@"isRunning": @(isRunning), @"debugDescription": debugDescription, @"dom": tree});
}

+ (id<FBResponsePayload>)handleGetAppAtPointCommand:(FBRouteRequest *)request
{
  BOOL getDOM = [request.parameters[@"getDOM"] boolValue];
  CGFloat x = [request.parameters[@"x"] floatValue];
  CGFloat y = [request.parameters[@"y"] floatValue];
  CGPoint point = CGPointMake(x, y);

  __block XCAccessibilityElement *resultElement = nil;
  __block NSError *resultError = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);

  id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
  [proxy _XCT_requestElementAtPoint:point
                              reply:^(XCAccessibilityElement *element, NSError *error) {
                                if (nil == error) {
                                  resultElement = element;
                                } else {
                                  resultError = error;
                                }
                                dispatch_semaphore_signal(sem);
                              }];

  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DEFAULT_SNAPSHOT_WAIT * NSEC_PER_SEC)));

  if (nil != resultError) {
    return FBResponseWithObject(@{@"status": @"error", @"message": [resultError description]});
  }

  if (nil == resultElement) {
    return FBResponseWithObject(@{@"status": @"error", @"message": @"No element found"});
  }

  pid_t pid = resultElement.processIdentifier;

  __block NSString *resultBundleId = nil;
  dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);
  [proxy _XCT_requestBundleIDForPID:pid
                              reply:^(NSString *bundleID, NSError *error) {
                                if (nil == error) {
                                  resultBundleId = bundleID;
                                } else {
                                  resultError = error;
                                }
                                dispatch_semaphore_signal(sem2);
                              }];
  dispatch_semaphore_wait(sem2, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DEFAULT_SNAPSHOT_WAIT * NSEC_PER_SEC)));

  XCUIApplication * app = [[XCUIApplication alloc] initWithBundleIdentifier:resultBundleId];
  NSString *debugDescription = [app debugDescription];

  NSDictionary *tree = nil;

  if (getDOM) {
    FBApplication *fb_app = [FBApplication appWithPID:[app processID]];
    tree = fb_app.fb_tree;
  } else {
    tree = [[NSMutableDictionary alloc] init];
  }

  return FBResponseWithObject(@{@"status": @"success", @"bundleId": resultBundleId,  @"debugDescription": debugDescription, @"dom": tree});
}

+ (id<FBResponsePayload>)handleGetWebViewCommand:(FBRouteRequest *)request
{
  XCAccessibilityElement *onScreenElement = [self z_onScreenElement];
  NSMutableArray<XCElementSnapshot *> *snapshots = [[NSMutableArray alloc] init];
  id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
  [self parentSnapshots:onScreenElement proxy:proxy snapshots:snapshots];
  XCElementSnapshot *webViewSnap = [self elementSnapshot:[[snapshots lastObject] accessibilityElement]];

  NSDictionary *result = [self elementTreeWithSnapshot:webViewSnap];
  return FBResponseWithObject(@{@"webViewSnap": result});
}

+ (id<FBResponsePayload>)handleGetElementAtPointCommand:(FBRouteRequest *)request
{
  CGFloat x = [request.parameters[@"x"] floatValue];
  CGFloat y = [request.parameters[@"y"] floatValue];

  XCAccessibilityElement *element = [self z_elementAtPointX:x Y:y];
  XCElementSnapshot *snap = [self elementSnapshot:element];

  return FBResponseWithObject(@{@"element": [self elementTreeWithSnapshot:snap]});
}

+ (NSDictionary *)elementTreeWithSnapshot:(XCElementSnapshot *)rootSnapshot
{
  NSMutableDictionary<NSString *, NSObject *> *elementDict = [[NSMutableDictionary alloc] init];

  elementDict[@"elementDescription"] = rootSnapshot.debugDescription;
  elementDict[@"elementId"]          = [NSString stringWithFormat:@"%p", rootSnapshot];
  elementDict[@"identifier"]         = [NSString stringWithFormat:@"%@", rootSnapshot.identifier];
  elementDict[@"value"]              = [NSString stringWithFormat:@"%@", rootSnapshot.value];
  elementDict[@"label"]              = [NSString stringWithFormat:@"%@", rootSnapshot.label];
  elementDict[@"frame"]              = NSStringFromCGRect(rootSnapshot.frame);
  elementDict[@"enabled"]            = [NSString stringWithFormat:@"%@", rootSnapshot.enabled ? @"YES" : @"NO"];
  elementDict[@"visible"]            = [NSString stringWithFormat:@"%@", rootSnapshot.fb_isVisible ? @"YES" : @"NO"];

  NSValue *hitPointValue = [[rootSnapshot suggestedHitpoints] firstObject];
  if (hitPointValue != nil) {
    CGPoint hitPoint = [hitPointValue CGPointValue];
    elementDict[@"hitpoint"] = NSStringFromCGPoint(hitPoint);
  }

  NSArray<XCElementSnapshot *> *children = [rootSnapshot children];
  NSMutableArray<NSDictionary *> *childrenDescription = [NSMutableArray arrayWithCapacity:children.count];

  for (XCElementSnapshot *child in children) {
    [childrenDescription addObject:[self elementTreeWithSnapshot:child]];
  }

  elementDict[@"children"] = childrenDescription;

  return elementDict;
}

+ (XCAccessibilityElement *)z_onScreenElement
{
  static CGPoint screenPoint;
  static dispatch_once_t oncePoint;
  dispatch_once(&oncePoint, ^{
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    screenPoint = CGPointMake(screenSize.width * 0.5, screenSize.height * 0.5);
  });

  __block XCAccessibilityElement *onScreenElement = nil;
  id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [proxy _XCT_requestElementAtPoint:screenPoint
                              reply:^(XCAccessibilityElement *element, NSError *error) {
                                if (error == nil) {
                                  onScreenElement = element;
                                } else {
                                  NSLog(@"Cannot request the screen point at %@: %@", [NSValue valueWithCGPoint:screenPoint], error.description);
                                }
                                dispatch_semaphore_signal(sem);
                              }];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DEFAULT_SNAPSHOT_WAIT * NSEC_PER_SEC)));
  return onScreenElement;
}

+ (XCAccessibilityElement *)z_elementAtPointX:(CGFloat )x Y:(CGFloat)y
{
  CGPoint screenPoint = CGPointMake(x, y);

  __block XCAccessibilityElement *elementAtPoint = nil;
  id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  [proxy _XCT_requestElementAtPoint:screenPoint
                              reply:^(XCAccessibilityElement *element, NSError *error) {
                                if (error == nil) {
                                  elementAtPoint = element;
                                } else {
                                  NSLog(@"Cannot request the screen point at %@: %@", [NSValue valueWithCGPoint:screenPoint], error.description);
                                }
                                dispatch_semaphore_signal(sem);
                              }];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DEFAULT_SNAPSHOT_WAIT * NSEC_PER_SEC)));
  return elementAtPoint;
}

+(void)parentSnapshots:(XCAccessibilityElement *)element proxy:(id<XCTestManager_ManagerInterface>)proxy snapshots:(NSMutableArray<XCElementSnapshot *> *)snapshots
{
  NSArray<NSString *> *propertyNames = @[
    @"identifier",
    @"elementType",
  ];

  NSSet *attributes = [[XCElementSnapshot class] axAttributesForElementSnapshotKeyPaths:propertyNames isMacOS:NO];
  NSArray *axAttributes = [attributes allObjects];
  NSDictionary *defaultParameters = [[XCUIDevice.sharedDevice accessibilityInterface] defaultParameters];

  __block XCElementSnapshot *snapshotWithAttributes = nil;
  __block NSError *innerError = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);

  [proxy _XCT_requestSnapshotForElement:element
                             attributes:axAttributes
                             parameters:defaultParameters
                                  reply:^(XCElementSnapshot *snapshot, NSError *error) {
                                    if (nil == error) {
                                      snapshotWithAttributes = snapshot;
                                    } else {
                                      innerError = error;
                                    }
                                    dispatch_semaphore_signal(sem);
                                  }];

  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DEFAULT_SNAPSHOT_WAIT * NSEC_PER_SEC)));

  if (snapshotWithAttributes == nil) {
    return;
  }

  if ([[NSString stringWithString:@"RemoteViewBridge"] isEqualToString:[snapshotWithAttributes identifier]]) {
    return;
  }

  XCAccessibilityElement *parent = [snapshotWithAttributes parentAccessibilityElement];

  if (parent == nil || parent == element) {
    return;
  }

  if ([snapshotWithAttributes elementType] != 0x1000) {
    [snapshots addObject:snapshotWithAttributes];
  }

  [self parentSnapshots:parent proxy:proxy snapshots:snapshots];
}

+(XCElementSnapshot *)elementSnapshot:(XCAccessibilityElement *)element
{
    NSArray<NSString *> *propertyNames = @[
      @"identifier",
      @"value",
      @"label",
      @"frame",
      @"enabled",
      @"elementType",
      @"IsVisible",
      @"VisibleFrame",

//      @"children",

//      @"FocusedApplications",
//      @"RunningApplications",
//      @"MainWindow",
//      @"UserTestingSnapshot",
//      @"parent",
    ];

  NSSet *attributes = [[XCElementSnapshot class] axAttributesForElementSnapshotKeyPaths:propertyNames isMacOS:NO];

  NSArray *axAttributes = [attributes allObjects];
  NSDictionary *defaultParameters = [[XCUIDevice.sharedDevice accessibilityInterface] defaultParameters];

  __block XCElementSnapshot *snapshotWithAttributes = nil;
  __block NSError *innerError = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);

  id<XCTestManager_ManagerInterface> proxy = [FBXCTestDaemonsProxy testRunnerProxy];

  [proxy _XCT_requestSnapshotForElement:element
                             attributes:axAttributes
                             parameters:defaultParameters
                                  reply:^(XCElementSnapshot *snapshot, NSError *error) {
                                    if (nil == error) {
                                      snapshotWithAttributes = snapshot;
                                    } else {
                                      innerError = error;
                                      NSLog(@"ZZZZZ ERROR: %@", error);
                                    }
                                    dispatch_semaphore_signal(sem);
                                  }];

  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DEFAULT_SNAPSHOT_WAIT * NSEC_PER_SEC)));

  return snapshotWithAttributes;
}

@end
