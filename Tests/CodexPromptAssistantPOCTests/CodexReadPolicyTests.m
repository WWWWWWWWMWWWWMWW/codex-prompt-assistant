#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "../../Sources/CodexPromptAssistantPOC/SuggestionPolicyCoordinator.h"
static AXUIElementRef fixture, changedFixture;
static NSString *role, *subrole, *hint;
static NSUInteger bodyReads, focusReads;
static BOOL foreignOwner, focusUnavailable, focusChanged;
static pid_t observedPID;
static BOOL rowSelected;
static NSString *rowNode, *rowTitle, *rowIdentifier;
static AXError FakeCopy(AXUIElementRef element, CFStringRef attribute, CFTypeRef *out) {
    (void)element; *out=NULL;
    if (CFEqual(attribute,kAXFocusedUIElementAttribute)) {focusReads++;if(!focusUnavailable)*out=CFRetain(focusChanged?changedFixture:fixture);}
    else if (CFEqual(attribute,kAXRoleAttribute)) *out=CFBridgingRetain(role);
    else if (CFEqual(attribute,kAXSubroleAttribute)) *out=CFBridgingRetain(subrole);
    else if (CFEqual(attribute,kAXPlaceholderValueAttribute)) *out=CFBridgingRetain(hint);
    else if (CFEqual(attribute,kAXValueAttribute)) {bodyReads++;*out=CFBridgingRetain(@"固定合成草稿用于验证读取门禁");}
    else if (CFEqual(attribute,kAXPositionAttribute)) {CGPoint p=CGPointMake(100,100);*out=AXValueCreate(kAXValueCGPointType,&p);}
    else if (CFEqual(attribute,kAXSizeAttribute)) {CGSize s=CGSizeMake(600,160);*out=AXValueCreate(kAXValueCGSizeType,&s);}
    else if (CFEqual(attribute,kAXSelectedTextRangeAttribute)) {CFRange r=CFRangeMake(15,0);*out=AXValueCreate(kAXValueCFRangeType,&r);}
    else if (CFEqual(attribute,CFSTR("AXDOMClassList"))) *out=CFBridgingRetain(rowSelected ? @[@"sidebar-item",@"bg-primary-ghost-hover"] : @[]);
    else if (CFEqual(attribute,CFSTR("ChromeAXNodeId"))) *out=CFBridgingRetain(rowNode);
    else if (CFEqual(attribute,kAXDescriptionAttribute)) *out=CFBridgingRetain(rowTitle);
    else if (CFEqual(attribute,CFSTR("AXIdentifier"))) *out=CFBridgingRetain(rowIdentifier);
    else if (CFEqual(attribute,kAXChildrenAttribute)) *out=CFBridgingRetain(@[]);
    return *out ? kAXErrorSuccess:kAXErrorAttributeUnsupported;
}
static AXError FakePID(AXUIElementRef element,pid_t *pid) {(void)element;*pid=foreignOwner?getpid()+1:getpid();return kAXErrorSuccess;}
static AXError FakeSettable(AXUIElementRef e,CFStringRef a,Boolean *out) {(void)e;(void)a;*out=true;return kAXErrorSuccess;}
static AXError FakeBounds(AXUIElementRef e,CFStringRef a,CFTypeRef p,CFTypeRef *out){(void)e;(void)a;(void)p;*out=NULL;return kAXErrorAttributeUnsupported;}
static AXError FakeHit(AXUIElementRef e,float x,float y,AXUIElementRef *out){(void)e;(void)x;(void)y;*out=(AXUIElementRef)CFRetain(fixture);return kAXErrorSuccess;}
#define AXUIElementCopyAttributeValue FakeCopy
#define AXUIElementGetPid FakePID
#define AXUIElementIsAttributeSettable FakeSettable
#define AXUIElementCopyParameterizedAttributeValue FakeBounds
#define AXUIElementCopyElementAtPosition FakeHit
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#include "../../Sources/CodexPromptAssistantPOC/AccessibilityService.m"
#pragma clang diagnostic pop
#undef AXUIElementCopyAttributeValue
#undef AXUIElementGetPid
#undef AXUIElementIsAttributeSettable
#undef AXUIElementCopyParameterizedAttributeValue
#undef AXUIElementCopyElementAtPosition
@interface TestService : CPAAccessibilityService
@property(nonatomic) NSUInteger scans;
@property(nonatomic, copy) void (^duringScan)(void);
@end
@implementation TestService
- (BOOL)isTrustedWithPrompt:(BOOL)prompt {(void)prompt;return YES;}
- (pid_t)observedFrontmostProcessIdentifier {return observedPID;}
- (NSString *)selectedConversationTitleForProcess:(pid_t)pid window:(AXUIElementRef)window {(void)pid;(void)window;self.scans++;if(self.duringScan)self.duringScan();return @"synthetic task";}
- (void)scheduleBottomTextInputLookupForProcess:(pid_t)pid {(void)pid;}
@end
#define Check(x) do {if(!(x)){NSLog(@"FAIL: Codex read policy line %d",__LINE__);exit(1);}}while(0)
int main(void){@autoreleasepool{
 changedFixture=AXUIElementCreateApplication(getpid()+1);observedPID=getpid();
 fixture=AXUIElementCreateApplication(getpid());role=@"AXTextArea";subrole=@"";hint=@"";
 NSString *suite=[@"local.codex.read-policy-test." stringByAppendingString:NSUUID.UUID.UUIDString];
 NSUserDefaults *defaults=[[NSUserDefaults alloc]initWithSuiteName:suite];
 CPASuggestionPolicyStore *store=[[CPASuggestionPolicyStore alloc]initWithUserDefaults:defaults];
 TestService *service=[TestService new];
 service.policyCoordinator=[[CPASuggestionPolicyCoordinator alloc]initWithStore:store];
 for (NSUInteger i=0;i<11;i++) {
  role=@"AXTextArea";subrole=@"";hint=@"";foreignOwner=NO;focusUnavailable=NO;observedPID=getpid();service.inputReadingPaused=NO;
  CPAApplicationPolicyMode mode=CPAApplicationPolicyModeRecommended;
  if(i==0)mode=CPAApplicationPolicyModeDisabled;
  if(i==1)service.inputReadingPaused=YES;
  if(i==2){role=@"AXTextField";subrole=@"AXSecureTextField";}
  if(i==3)hint=@"verification code";
  if(i==4)hint=@"Search";
  if(i==5)foreignOwner=YES;
  if(i==6)hint=@"credit card";
  if(i==7)hint=@"login";
  if(i==8)focusUnavailable=YES;
  if(i==9)observedPID=getpid()+1;
  if(i==10)role=@"AXGroup";
  [store setRule:[[CPAApplicationRule alloc]initWithMode:mode searchExceptionEnabled:NO remoteCompletionAuthorized:YES] forBundleIdentifier:@"com.openai.codex"];
  bodyReads=0;focusReads=0;service.scans=0;
  CPAAccessibilitySnapshot *snapshot=[service inspectFocusedElementForCodexProcessIdentifier:getpid() frontmostProcessIdentifier:getpid()];
  Check(bodyReads==0 && service.scans==0 && snapshot.inputText==nil);
  if(i==0 || i==1 || i==9)Check(focusReads==0);
 }
 role=@"AXTextArea";subrole=@"";hint=@"";foreignOwner=NO;
 bodyReads=0;
 CPAAccessibilitySnapshot *allowed=[service inspectFocusedElementForCodexProcessIdentifier:getpid() frontmostProcessIdentifier:getpid()];
 Check(bodyReads==1 && allowed.inputText.length>0 && service.scans==1);
 // A slow metadata scan must not carry old permission to the body read.
 for(NSUInteger i=0;i<4;i++) {
  service.inputReadingPaused=NO;focusChanged=NO;role=@"AXTextArea";
  [store setRule:[[CPAApplicationRule alloc]initWithMode:CPAApplicationPolicyModeRecommended searchExceptionEnabled:NO remoteCompletionAuthorized:YES] forBundleIdentifier:@"com.openai.codex"];
  __weak TestService *weakService=service;
  service.duringScan=^{
   if(i==0)weakService.inputReadingPaused=YES;
   if(i==1)[store setRule:[[CPAApplicationRule alloc]initWithMode:CPAApplicationPolicyModeDisabled searchExceptionEnabled:NO remoteCompletionAuthorized:YES] forBundleIdentifier:@"com.openai.codex"];
   if(i==2)focusChanged=YES;
   if(i==3){weakService.inputReadingPaused=YES;weakService.inputReadingPaused=NO;}
  };
  bodyReads=0;
  CPAAccessibilitySnapshot *revoked=[service inspectFocusedElementForCodexProcessIdentifier:getpid() frontmostProcessIdentifier:getpid()];
  Check(bodyReads==0 && revoked.inputText==nil && revoked.conversationTitle==nil);
 }
 service.duringScan=nil;focusChanged=NO;
 service.policyCoordinator=nil;bodyReads=0;focusReads=0;
 [service inspectFocusedElementForCodexProcessIdentifier:getpid() frontmostProcessIdentifier:getpid()];
 Check(bodyReads==0 && focusReads==0);
 // The fallback search must never fetch a candidate's AXValue.
 bodyReads=0; AXUIElementRef candidate=[service copyTextInputAtBottomOfWindow:fixture windowFrame:CGRectMake(0,0,800,300)];
 Check(bodyReads==0 && candidate!=NULL); if(candidate)CFRelease(candidate);
 NSUInteger visited=0;CGFloat score=0;candidate=NULL;
 [service findBottomTextInputInElement:fixture windowFrame:CGRectMake(0,0,800,300) depth:0 visited:&visited best:&candidate score:&score];
 Check(bodyReads==0 && candidate!=NULL);if(candidate)CFRelease(candidate);
 // Live selected-row identity cannot be supplied by cached titles or overlays.
 rowSelected=YES;rowNode=@"row-1";rowTitle=@"same title";rowIdentifier=@"task-a";
 service.selectedConversationElement=(AXUIElementRef)CFRetain(fixture);service.conversationWindow=(__bridge id)fixture;
 NSString *token=[service liveConversationSelectionIdentityForWindow:fixture];Check(token.length>0);
 Check([token isEqual:[service liveConversationSelectionIdentityForWindow:fixture]]);
 rowIdentifier=@"task-b";NSString *other=[service liveConversationSelectionIdentityForWindow:fixture];Check(![other isEqual:token]);
 rowSelected=NO;Check([service liveConversationSelectionIdentityForWindow:fixture]==nil);
 rowSelected=YES;Check(![other isEqual:[service liveConversationSelectionIdentityForWindow:fixture]]);
 service.selectedConversationIsOverlay=YES;Check([service liveConversationSelectionIdentityForWindow:fixture]==nil);
 service.selectedConversationIsOverlay=NO;rowNode=nil;Check([service liveConversationSelectionIdentityForWindow:fixture]==nil);
 rowNode=@"row-1";Check([service liveConversationSelectionIdentityForWindow:changedFixture]==nil);
 [defaults removePersistentDomainForName:suite];CFRelease(fixture);CFRelease(changedFixture);
 puts("PASS: Codex deny-before-body, positive control, foreign focus, metadata-only fallback");
}}
