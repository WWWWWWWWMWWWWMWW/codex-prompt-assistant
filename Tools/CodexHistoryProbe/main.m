#import <Foundation/Foundation.h>

#import "../../Sources/CodexDataCore/CodexSourceScanner.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: CodexHistoryProbe <active-dir> <archived-dir>\n");
            return 2;
        }

        NSURL *active = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]
            isDirectory:YES];
        NSURL *archived = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]
            isDirectory:YES];
        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        NSError *error = nil;
        CPACodexScanReport *report = [[[CPACodexSourceScanner alloc] init]
            scanActiveDirectory:active archivedDirectory:archived error:&error];
        if (report == nil) {
            fprintf(stderr, "scan_failed=%s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        double elapsed = CFAbsoluteTimeGetCurrent() - started;
        printf("files=%lu root=%lu subagent=%lu unsupported=%lu duplicates=%lu "
            "visible_messages=%lu trailing_files=%lu parse_errors=%lu "
            "inspected_bytes=%llu elapsed_ms=%.0f\n",
            (unsigned long)report.discoveredJSONLCount,
            (unsigned long)report.rootThreadCount,
            (unsigned long)report.subagentThreadCount,
            (unsigned long)report.unsupportedSourceCount,
            (unsigned long)report.duplicateThreadCount,
            (unsigned long)report.visibleMessageCount,
            (unsigned long)report.trailingPartialFileCount,
            (unsigned long)report.messageParseErrorCount,
            report.inspectedByteCount,
            elapsed * 1000.0);
    }
    return 0;
}
