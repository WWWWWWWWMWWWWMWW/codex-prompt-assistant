#import "../../Sources/CodexPromptAssistantPOC/WorkBuddyContextReader.h"

@interface CPAWBFixture : NSObject <CPAWorkBuddyTreeReading>
@property(nonatomic, strong) NSMutableDictionary *nodes;
@property(nonatomic) NSUInteger bodyReads;
@property(nonatomic) BOOL batchEnabled;
@property(nonatomic) NSUInteger batchReads;
@property(nonatomic, copy) void (^onRead)(void);
@end
@implementation CPAWBFixture
- (NSDictionary *)workBuddyStructureAttributesForElement:(id)element {
    if (!self.batchEnabled) return nil;
    self.batchReads++;
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"AXDOMClassList",@"AXChildren",@"AXParent",@"AXRole"])
        values[name] = self.nodes[element][name] ?: NSNull.null;
    return values;
}
- (id)workBuddyAttribute:(NSString *)attribute element:(id)element {
    if ([attribute isEqual:@"AXValue"]) { self.bodyReads++; if (self.onRead) self.onRead(); }
    return self.nodes[element][attribute];
}
@end
static CPAWBFixture *WorkBuddyShellFixture(void) {
    CPAWBFixture *tree = [CPAWBFixture new]; tree.nodes = [NSMutableDictionary dictionary];
    void (^add)(NSNumber *, NSNumber *, NSArray *, NSArray *) = ^(NSNumber *key, NSNumber *parent, NSArray *classes, NSArray *children) {
        tree.nodes[key] = [@{@"AXParent":parent, @"AXDOMClassList":classes, @"AXChildren":children} mutableCopy];
    };
    add(@100,@999,@[@"conversation-shell"],@[@101]);
    add(@101,@100,@[@"conversation-shell__main"],@[@102,@110]);
    add(@102,@101,@[@"conversation-input"],@[@103]);
    add(@103,@102,@[@"cr-input-container"],@[]); tree.nodes[@103][@"AXRole"] = @"AXTextArea";
    tree.nodes[@103][@"AXValue"] = @"NEVER DRAFT";
    add(@110,@101,@[@"conversation-timeline"],@[@111]);
    add(@111,@110,@[@"cr-message-list"],@[@112,@120]);
    add(@112,@111,@[@"cr-self-message"],@[@113]);
    add(@113,@112,@[@"cr-self-bubble"],@[@114]);
    add(@114,@113,@[@"cr-user-content"],@[@115]);
    add(@115,@114,@[],@[]); tree.nodes[@115][@"AXRole"] = @"AXStaticText"; tree.nodes[@115][@"AXValue"] = @"合成任务甲只核对名称与编号。";
    add(@120,@111,@[@"cr-agent"],@[@121]);
    add(@121,@120,@[@"cr-agent__body-row"],@[@122]);
    add(@122,@121,@[@"cr-agent__body"],@[@123]);
    add(@123,@122,@[@"cr-agent__content"],@[@124,@126]);
    add(@124,@123,@[@"cr-markdown"],@[@125]);
    add(@125,@124,@[],@[]); tree.nodes[@125][@"AXRole"] = @"AXStaticText"; tree.nodes[@125][@"AXValue"] = @"合成对照材料包含两列。";
    add(@126,@123,@[@"cr-tool-call"],@[@127]);
    add(@127,@126,@[@"cr-markdown"],@[@128]);
    add(@128,@127,@[],@[]); tree.nodes[@128][@"AXRole"] = @"AXStaticText"; tree.nodes[@128][@"AXValue"] = @"NEVER TOOL TEXT";
    return tree;
}
static CPAWBFixture *WorkBuddyFlattenedFixture(void) {
    CPAWBFixture *tree = WorkBuddyShellFixture();
    tree.nodes[@112][@"AXDOMClassList"] = @[@"cr-frame", @"cr-frame--right"];
    tree.nodes[@113][@"AXDOMClassList"] = @[@"cr-frame__content"];
    tree.nodes[@113][@"AXChildren"] = @[@114,@117];
    tree.nodes[@114][@"AXDOMClassList"] = @[];
    tree.nodes[@115][@"AXDOMClassList"] = @[@"_editable_fixture_1"];
    tree.nodes[@115][@"AXRole"] = @"AXGroup";
    tree.nodes[@115][@"AXChildren"] = @[@116];
    tree.nodes[@116] = [@{@"AXParent":@115, @"AXRole":@"AXStaticText", @"AXValue":@"合成任务甲只核对名称与编号。"} mutableCopy];
    tree.nodes[@117] = [@{@"AXParent":@113, @"AXDOMClassList":@[@"cr-toolbar"], @"AXRole":@"AXToolbar", @"AXChildren":@[@118]} mutableCopy];
    tree.nodes[@118] = [@{@"AXParent":@117, @"AXRole":@"AXButton", @"AXDescription":@"编辑"} mutableCopy];
    return tree;
}
static void WorkBuddyFlattenedReaderTests(void) {
    CPAWorkBuddyContextReader *reader = [CPAWorkBuddyContextReader new];
    CPAWBFixture *tree = WorkBuddyFlattenedFixture();
    NSArray *result = [reader readComposer:@103 tree:tree stillCurrent:^{return YES;}];
    Assert([result[1] count] == 2 && tree.bodyReads == 2, @"flattened AX user frame with sent edit toolbar is readable");
    tree.bodyReads = 0; tree.nodes[@118][@"AXDescription"] = @"重新编辑";
    Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}] == nil && tree.bodyReads==0, @"flattened unsent frame rejected before text read");
    tree.nodes[@118][@"AXDescription"] = @"Edit again";
    Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}] == nil && tree.bodyReads==0, @"English unsent frame rejected");
    tree.nodes[@118][@"AXDescription"] = @"Edit";
    Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}] != nil, @"English sent user edit metadata supported");
    tree = WorkBuddyFlattenedFixture(); tree.nodes[@113][@"AXChildren"] = @[@114];
    Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}] == nil && tree.bodyReads==0, @"discarded or editing flattened frame without toolbar rejected");
    tree = WorkBuddyFlattenedFixture(); tree.nodes[@112][@"AXDOMClassList"] = @[@"cr-frame",@"cr-frame--left"];
    Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}] == nil && tree.bodyReads==0, @"flattened assistant is not mistaken for user history");
    tree = WorkBuddyFlattenedFixture(); tree.nodes[@114][@"AXDOMClassList"] = @[@"cr-tool-call"];
    Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}] == nil && tree.bodyReads==0, @"editable content inside a tool is rejected");
    tree = WorkBuddyFlattenedFixture(); tree.nodes[@119] = [tree.nodes[@115] mutableCopy]; tree.nodes[@114][@"AXChildren"] = @[@115,@119];
    Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}] == nil && tree.bodyReads==0, @"multiple editor bodies in one frame are ambiguous");
    tree = WorkBuddyFlattenedFixture(); __weak CPAWBFixture *weak = tree;
    tree.onRead = ^{ weak.nodes[@118][@"AXDescription"] = @"重新编辑"; };
    Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}] == nil, @"flattened row state changing during body read rejects result");
}
static void WorkBuddyPartialProjectionTests(void) {
    CPAWorkBuddyContextReader *reader = [CPAWorkBuddyContextReader new];
    for (NSString *wrapper in @[@"cr-self-bubble",@"cr-self-message__content",@"cr-self-message",@"cr-user-content"]) {
        CPAWBFixture *tree = WorkBuddyFlattenedFixture();
        tree.nodes[@114][@"AXDOMClassList"] = @[wrapper];
        NSArray *result = [reader readComposer:@103 tree:tree stillCurrent:^{return YES;}];
        Assert([result[1] count]==2 && tree.bodyReads==2, @"partial user wrapper projection retains exact sent message body");
    }
    for (NSArray *classes in @[@[@"cr-self-bubble",@"cr-self-bubble--editing"],
        @[@"cr-self-message",@"cr-self-message--discarded"],@[@"cr-user-message-editor"],@[@"cr-tool-call"]]) {
        CPAWBFixture *tree = WorkBuddyFlattenedFixture(); tree.nodes[@114][@"AXDOMClassList"] = classes;
        Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}]==nil && tree.bodyReads==0,
            @"partial wrappers never admit editing, discarded or tool history");
    }
    CPAWBFixture *tree = WorkBuddyFlattenedFixture(); tree.nodes[@114][@"AXDOMClassList"] = @[@"cr-self-message"];
    tree.nodes[@115][@"AXDOMClassList"] = @[@"cr-user-content"];
    tree.nodes[@116][@"AXDOMClassList"] = @[@"_editable_fixture_1"];
    NSArray *result = [reader readComposer:@103 tree:tree stillCurrent:^{return YES;}];
    Assert([result[1] count]==2 && tree.bodyReads==2, @"retained structured owner wins over flattened fallback without duplicate messages");
    tree = WorkBuddyFlattenedFixture(); tree.nodes[@114][@"AXDOMClassList"] = @[@"cr-self-message"];
    tree.nodes[@114][@"AXChildren"] = @[@115,@119];
    tree.nodes[@119] = [@{@"AXParent":@114,@"AXDOMClassList":@[@"cr-self-message__not-sent"]} mutableCopy];
    Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}]==nil && tree.bodyReads==0,
        @"partial unsent owner excludes its flattened frame even if toolbar still shows sent edit action");
    tree = WorkBuddyFlattenedFixture(); tree.nodes[@114][@"AXDOMClassList"] = @[@"cr-self-bubble"];
    __weak CPAWBFixture *weak = tree;
    tree.onRead = ^{ weak.nodes[@114][@"AXDOMClassList"] = @[@"cr-self-bubble",@"cr-self-bubble--editing"]; };
    Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}]==nil,
        @"partial user wrapper becoming editable during read rejects the snapshot");
}
static void WorkBuddyShellReaderTests(void) {
    CPAWBFixture *tree = WorkBuddyShellFixture(); CPAWorkBuddyContextReader *r = [CPAWorkBuddyContextReader new];
    NSArray *(^read)(void) = ^{ return [r readComposer:@103 tree:tree stillCurrent:^{ return YES; }]; };
    NSArray *a = read();
    Assert([a[1] count] == 2 && tree.bodyReads == 2, @"5.5.3 shell reads user and finished assistant only");
    Assert([a isEqual:read()], @"shell snapshot identity stable for same nodes");
    tree.bodyReads = 0;
    Assert([r readComposer:@103 tree:tree stillCurrent:^{return NO;}] == nil && tree.bodyReads == 0, @"shell denied before any text read");
    Assert([r readComposer:@114 tree:tree stillCurrent:^{return YES;}] == nil && tree.bodyReads == 0, @"shell historical editing cannot acquire history");
    tree.nodes[@120][@"AXDOMClassList"] = @[@"cr-agent",@"cr-agent--processing"];
    Assert([read()[1] count] == 1, @"shell streaming assistant excluded");
    tree.nodes[@120][@"AXDOMClassList"] = @[@"cr-agent",@"cr-agent--discarded"];
    Assert([read()[1] count] == 1, @"shell discarded assistant excluded");
    tree.nodes[@112][@"AXDOMClassList"] = @[@"cr-self-message",@"cr-self-message--discarded"];
    tree.bodyReads=0; Assert(read()==nil && tree.bodyReads==0, @"no usable user owner fails closed");
    CPAWBFixture *other = WorkBuddyShellFixture();
    other.nodes[@126][@"AXDOMClassList"] = @[@"conversation-shell"];
    Assert([r readComposer:@103 tree:other stillCurrent:^{return YES;}] == nil && other.bodyReads == 0, @"nested conversation rejected before body reads");
    other = WorkBuddyShellFixture(); other.nodes[@126][@"AXDOMClassList"] = @[@"conversation-timeline"];
    Assert([r readComposer:@103 tree:other stillCurrent:^{return YES;}] == nil && other.bodyReads == 0, @"ambiguous timelines rejected before body reads");
    other = WorkBuddyShellFixture(); other.nodes[@102][@"AXDOMClassList"] = @[@"unknown-input"];
    Assert([r readComposer:@103 tree:other stillCurrent:^{return YES;}] == nil && other.bodyReads == 0, @"unknown shell editor cannot acquire history");
    other = WorkBuddyShellFixture(); other.nodes[@113][@"AXChildren"] = @[@114,@130];
    other.nodes[@130] = [@{@"AXParent":@112, @"AXDOMClassList":@[@"cr-self-message__not-sent"]} mutableCopy];
    Assert([r readComposer:@103 tree:other stillCurrent:^{return YES;}] == nil && other.bodyReads == 0, @"unsent message cannot anchor history");
    other = WorkBuddyShellFixture(); other.nodes[@115][@"AXValue"] = [@"字" stringByPaddingToLength:3001 withString:@"字" startingAtIndex:0];
    NSArray *budget = [r readComposer:@103 tree:other stillCurrent:^{return YES;}];
    Assert([budget[1] count] == 1 && [budget[1][0][@"role"] isEqual:@"assistant"], @"shell oversized user message is never fragmented");
    other = WorkBuddyShellFixture();
    NSArray *before = [r readComposer:@103 tree:other stillCurrent:^{return YES;}];
    other.nodes[@140] = [other.nodes[@112] mutableCopy];
    other.nodes[@111][@"AXChildren"] = @[@140,@120]; other.nodes[@113][@"AXParent"] = @140;
    NSArray *after = [r readComposer:@103 tree:other stillCurrent:^{return YES;}];
    Assert(after != nil && ![before[0] isEqual:after[0]], @"same text under replaced message node changes ownership");
    other = WorkBuddyShellFixture();
    other.nodes[@111][@"AXChildren"] = @[@112,@126];
    other.nodes[@126][@"AXParent"] = @111; other.nodes[@126][@"AXChildren"] = @[@120];
    other.nodes[@120][@"AXParent"] = @126; other.nodes[@123][@"AXChildren"] = @[@124];
    NSArray *nestedTool = [r readComposer:@103 tree:other stillCurrent:^{return YES;}];
    Assert([nestedTool[1] count] == 1 && other.bodyReads == 1, @"nested assistant inside tool is not conversation prose");
    other = WorkBuddyShellFixture(); __weak CPAWBFixture *weak = other;
    other.onRead = ^{ weak.nodes[@112][@"AXParent"] = @999; };
    Assert([r readComposer:@103 tree:other stillCurrent:^{return YES;}] == nil, @"shell detached message rejected after body read");
    other = WorkBuddyShellFixture(); weak = other;
    other.onRead = ^{ weak.nodes[@103][@"AXParent"] = @999; };
    Assert([r readComposer:@103 tree:other stillCurrent:^{return YES;}] == nil, @"shell composer moved while reading rejected");
}
static void WorkBuddyPresentationLeafTest(void) {
    CPAWBFixture *tree = WorkBuddyFlattenedFixture();
    NSMutableArray *glyphs = [NSMutableArray array];
    for (NSUInteger i=0; i<6001; i++) {
        NSNumber *key = @(10000+i); [glyphs addObject:key];
        tree.nodes[key] = [@{@"AXParent":@116,@"AXRole":@"AXInlineTextBox",@"AXValue":@"NEVER GLYPH TEXT"} mutableCopy];
    }
    tree.nodes[@116][@"AXChildren"] = glyphs;
    tree.batchEnabled = YES;
    CPAWorkBuddyContextReader *reader = [CPAWorkBuddyContextReader new];
    NSArray *result = [reader readComposer:@103 tree:tree stillCurrent:^{return YES;}];
    Assert([result[1] count]==2 && tree.bodyReads==2, @"inline glyph boxes do not exhaust structure budget or duplicate message text");
    Assert(tree.batchReads > 0 && tree.batchReads < 100, @"batched structure remains bounded without reading thousands of glyph nodes");
    __weak CPAWBFixture *weak = tree;
    tree.onRead = ^{ weak.nodes[@118][@"AXDescription"] = @"重新编辑"; };
    Assert([reader readComposer:@103 tree:tree stillCurrent:^{return YES;}]==nil,
        @"fresh verification does not reuse metadata cache after sent state changes");
}
static void WorkBuddySwitchReaderTests(void) {
    CPAWorkBuddyContextReader *reader = [CPAWorkBuddyContextReader new];
    CPAWBFixture *a = WorkBuddyFlattenedFixture(), *b = WorkBuddyFlattenedFixture();
    // Same composer/root IDs model a reused editor. Only current message content changes.
    b.nodes[@116][@"AXValue"] = @"合成任务乙只核对日期，不处理甲任务。";
    b.nodes[@125][@"AXValue"] = @"乙任务合成对照。";
    NSArray *first = [reader readComposer:@103 tree:a stillCurrent:^{return YES;}];
    NSArray *second = [reader readComposer:@103 tree:b stillCurrent:^{return YES;}];
    Assert([second[1] isEqual:@[@{@"role":@"user",@"content":@"合成任务乙只核对日期，不处理甲任务。"},
        @{@"role":@"assistant",@"content":@"乙任务合成对照。"}]], @"reused composer reads exact B history with no A body");
    Assert([first isEqual:[reader readComposer:@103 tree:a stillCurrent:^{return YES;}]], @"A to B to A restores exact A material");
    b.nodes[@111][@"AXChildren"] = @[];
    Assert([reader readComposer:@103 tree:b stillCurrent:^{return YES;}]==nil, @"empty switching timeline never reuses A history");
    Assert(reader.readPending, @"recognized conversation with an empty loading timeline must defer draft-only generation");
    CPAWBFixture *large = WorkBuddyShellFixture();
    NSMutableArray *children = [NSMutableArray array];
    for (NSUInteger i=0;i<1801;i++) {
        NSNumber *key = @(1000+i); [children addObject:key];
        large.nodes[key] = [@{@"AXParent":@126,@"AXDOMClassList":@[]} mutableCopy];
    }
    large.nodes[@126][@"AXChildren"] = children;
    NSArray *largeResult = [reader readComposer:@103 tree:large stillCurrent:^{return YES;}];
    Assert(largeResult != nil && large.bodyReads == 2,
        @"large structure within expanded bound still reads only recognized bodies");
    Assert([reader.diagnostic containsString:@"contextStage=ready"], @"expanded structure scan reaches ready without root-missing diagnostic");
    for (NSUInteger i=1801;i<6001;i++) {
        NSNumber *key = @(1000+i); [children addObject:key];
        large.nodes[key] = [@{@"AXParent":@126,@"AXDOMClassList":@[]} mutableCopy];
    }
    large.bodyReads = 0;
    Assert([reader readComposer:@103 tree:large stillCurrent:^{return YES;}]==nil && large.bodyReads==0,
        @"expanded structure limit still rejects oversized trees before body reads");
    Assert([reader.diagnostic containsString:@"contextStage=structure_node_limit"], @"expanded bound retains accurate failure reason");
    __block NSUInteger checks = 0;
    Assert([reader readComposer:@103 tree:large stillCurrent:^BOOL{return ++checks < 30;}] == nil && large.bodyReads==0,
        @"expanded traversal stops immediately on deadline or focus cancellation");
    Assert(reader.readPending, @"deadline or focus loss is distinct from an empty conversation");
    Assert([reader readComposer:@103 tree:a stillCurrent:^{return YES;}] != nil && !reader.readPending,
        @"fresh successful read clears interruption state");

}
static void WorkBuddyReaderTests(void) {
    WorkBuddyPartialProjectionTests();
    WorkBuddyPresentationLeafTest();
    WorkBuddySwitchReaderTests();
    WorkBuddyShellReaderTests();
    WorkBuddyFlattenedReaderTests();
    CPAWBFixture *tree = [CPAWBFixture new];
    tree.nodes = [@{
        @1:[@{@"AXDOMClassList":@[@"_cbChat_fixture_7"], @"AXChildren":@[@2,@3]} mutableCopy],
        @2:[@{@"AXParent":@1, @"AXRole":@"AXTextArea", @"AXValue":@"DO NOT READ DRAFT"} mutableCopy],
        @3:[@{@"AXParent":@1, @"AXDOMClassList":@[@"_chatMessageContainer_fixture_72"], @"AXChildren":@[@4,@7,@10]} mutableCopy],
        @4:[@{@"AXParent":@3, @"AXDOMClassList":@[@"_userMessage_fixture_149"], @"AXDOMIdentifier":@"user-message-fixture-a", @"AXChildren":@[@5]} mutableCopy],
        @5:[@{@"AXParent":@4, @"AXDOMClassList":@[@"_userMessageText_fixture_153"], @"AXChildren":@[@6]} mutableCopy],
        @6:[@{@"AXRole":@"AXStaticText", @"AXValue":@"只处理合成项目甲。"} mutableCopy],
        @7:[@{@"AXDOMClassList":@[@"cb-assistant-message"], @"AXChildren":@[@8]} mutableCopy],
        @8:[@{@"AXDOMClassList":@[@"_assistantTextContent_fixture_207"], @"AXChildren":@[@9]} mutableCopy],
        @9:[@{@"AXRole":@"AXStaticText", @"AXValue":@"合成项目甲有三项待办。"} mutableCopy],
        @10:[@{@"AXDOMClassList":@[@"_toolCallContent_fixture_230"], @"AXChildren":@[@11]} mutableCopy],
        @11:[@{@"AXRole":@"AXStaticText", @"AXValue":@"NEVER TOOL OUTPUT"} mutableCopy]
    } mutableCopy];
    CPAWorkBuddyContextReader *reader = [CPAWorkBuddyContextReader new];
    NSArray *a = [reader readComposer:@2 tree:tree stillCurrent:^{ return YES; }];
    Assert([a[1] count] == 2 && tree.bodyReads == 2, @"only recognized user and assistant text is read");
    Assert([a[1][0][@"role"] isEqual:@"user"] && [a[1][1][@"role"] isEqual:@"assistant"], @"roles and chronology preserved");
    Assert([a isEqual:[reader readComposer:@2 tree:tree stillCurrent:^{ return YES; }]], @"same rendered context has stable identity");
    tree.bodyReads = 0;
    Assert([reader readComposer:@2 tree:tree stillCurrent:^{ return NO; }] == nil && tree.bodyReads == 0, @"denied input reads no history");
    tree.nodes[@1][@"AXDOMClassList"] = @[@"unknown"];
    Assert([reader readComposer:@2 tree:tree stillCurrent:^{ return YES; }] == nil && tree.bodyReads == 0, @"unknown layout fails closed before body reads");
    tree.nodes[@1][@"AXDOMClassList"] = @[@"_cbChat_fixture_7"];
    Assert([reader readComposer:@5 tree:tree stillCurrent:^{ return YES; }] == nil, @"editing a historical message cannot select conversation context");
    tree.nodes[@4][@"AXDOMIdentifier"] = @"user-message-fixture-b";
    NSArray *b = [reader readComposer:@2 tree:tree stillCurrent:^{ return YES; }];
    Assert(![a[0] isEqual:b[0]], @"same composer and same text in a different request changes ownership");
    tree.nodes[@7][@"AXDOMClassList"] = @[@"cb-assistant-message", @"_streamingMessage_fixture_1"];
    Assert([[reader readComposer:@2 tree:tree stillCurrent:^{ return YES; }][1] count] == 1, @"streaming answer excluded");
    tree.nodes[@7][@"AXDOMClassList"] = @[@"cb-assistant-message", @"undefined"];
    Assert([[reader readComposer:@2 tree:tree stillCurrent:^{ return YES; }][1] count] == 1, @"5.2.5 active-stream marker is rejected");
    tree.nodes[@6][@"AXValue"] = [@"字" stringByPaddingToLength:3001 withString:@"字" startingAtIndex:0];
    Assert([[reader readComposer:@2 tree:tree stillCurrent:^{ return YES; }][1] count] == 0, @"over-budget message is not cut into a misleading fragment");
    tree.nodes[@6][@"AXValue"] = @"合成正文";
    __weak CPAWBFixture *weakTree = tree;
    tree.onRead = ^{ weakTree.nodes[@4][@"AXParent"] = @99; };
    Assert([reader readComposer:@2 tree:tree stillCurrent:^{ return YES; }] == nil, @"detached old conversation is rejected during reading");
    tree.onRead = nil;
}
