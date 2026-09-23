#import <Foundation/Foundation.h>
#import "../../Sources/CodexPromptAssistantPOC/ConversationContextProvider.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) return 2;
        NSString *identifier = [NSString stringWithUTF8String:argv[1]];
        NSURL *sessions = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
        NSURL *database = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]]];
        CPAConversationContextProvider *provider = [[CPAConversationContextProvider alloc]
            initWithSessionsDirectoryURL:sessions stateDatabaseURL:database];
        [provider selectConversationWithIdentifier:identifier];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (provider.currentSnapshot.availability == CPAContextAvailabilityLoading
            && deadline.timeIntervalSinceNow > 0) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        CPAConversationContextSnapshot *snapshot = provider.currentSnapshot;
        BOOL markerA = NO, markerB = NO;
        NSUInteger users = 0, assistants = 0;
        for (NSDictionary *message in snapshot.messages) {
            if ([message[@"role"] isEqual:@"user"]) {
                users++;
                NSString *text = [message[@"content"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                text = [text stringByReplacingOccurrencesOfString:@"\\_" withString:@"_"];
                markerA |= [text isEqual:@"CPA_CONTEXT_A_260909"];
                markerB |= [text isEqual:@"CPA_CONTEXT_B_260909"];
            } else if ([message[@"role"] isEqual:@"assistant"]) assistants++;
        }
        NSDictionary *result = @{@"contextAvailability": @(snapshot.availability),
            @"contextMessageCount": @(snapshot.messages.count), @"contextUserCount": @(users),
            @"contextAssistantCount": @(assistants), @"contextMarkerA": @(markerA),
            @"contextMarkerB": @(markerB), @"contextReadReady": @(snapshot.availability == CPAContextAvailabilityReady
                || snapshot.availability == CPAContextAvailabilityReadyEmpty)};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        [provider stop];
        return [result[@"contextReadReady"] boolValue] ? 0 : 6;
    }
}
