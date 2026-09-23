#import "WorkBuddyContextReader.h"
#import "InputElementIdentity.h"

static BOOL HasClass(NSArray *classes, NSString *prefix) {
    for (id name in classes) if ([name isKindOfClass:NSString.class]
        && ([name isEqual:prefix] || ([prefix hasPrefix:@"_"] && [name hasPrefix:prefix]))) return YES;
    return NO;
}

// Pass-local metadata cache: validation gets a new cache and never borrows the
// first scan's topology. Body values are always read through the original tree.
@interface CPAWorkBuddyStructureTree : NSObject <CPAWorkBuddyTreeReading>
@property(nonatomic, strong) id<CPAWorkBuddyTreeReading> source;
@property(nonatomic, strong) NSMapTable *metadata;
@end
@implementation CPAWorkBuddyStructureTree
- (id)workBuddyAttribute:(NSString *)attribute element:(id)element {
    if ([attribute isEqual:@"AXValue"]) return [self.source workBuddyAttribute:attribute element:element];
    NSMutableDictionary *values = [self.metadata objectForKey:element];
    if (!values) {
        values = [NSMutableDictionary dictionary];
        if ([self.source respondsToSelector:@selector(workBuddyStructureAttributesForElement:)]) {
            NSDictionary *batch = [self.source workBuddyStructureAttributesForElement:element];
            if (batch) [values addEntriesFromDictionary:batch];
        }
        [self.metadata setObject:values forKey:element];
    }
    id value = values[attribute];
    if (!value) { value = [self.source workBuddyAttribute:attribute element:element] ?: NSNull.null; values[attribute] = value; }
    return value == NSNull.null ? nil : value;
}
@end

@interface CPAWorkBuddyContextReader ()
@property(nonatomic, strong) CPAInputElementIdentity *identity;
@property(nonatomic) NSUInteger flatPartialUserWrappers;
@property(nonatomic, copy, readwrite) NSString *diagnostic;
@property(nonatomic, readwrite) BOOL readPending;
@property(nonatomic) BOOL conversationRootFound;
@end

@implementation CPAWorkBuddyContextReader
- (NSArray *)classes:(id)node tree:(id<CPAWorkBuddyTreeReading>)tree {
    id value = [tree workBuddyAttribute:@"AXDOMClassList" element:node];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}
- (NSArray *)children:(id)node tree:(id<CPAWorkBuddyTreeReading>)tree {
    id value = [tree workBuddyAttribute:@"AXChildren" element:node];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}
// 5.5.3 uses a dedicated shell instead of the legacy cbChat component.
// Ownership is the focused shell + live message nodes, never a task title or
// a guessed data-* identifier (Chromium does not expose those as DOM IDs).
- (BOOL)shellComposer:(id)composer belongsTo:(id)root tree:(id<CPAWorkBuddyTreeReading>)tree {
    BOOL input = NO;
    id node = composer;
    for (NSUInteger depth = 0; node && depth < 20; depth++) {
        if ([node isEqual:root]) return input;
        NSArray *classes = [self classes:node tree:tree];
        if (HasClass(classes, @"cr-self-message") || HasClass(classes, @"cr-agent")
            || HasClass(classes, @"conversation-timeline") || HasClass(classes, @"cr-user-message-editor")) return NO;
        if (HasClass(classes, @"conversation-input")) input = YES;
        node = [tree workBuddyAttribute:@"AXParent" element:node];
    }
    return NO;
}
- (BOOL)node:(id)node attachedTo:(id)root tree:(id<CPAWorkBuddyTreeReading>)tree {
    for (NSUInteger depth = 0; node && depth < 32; depth++) {
        if ([node isEqual:root]) return YES;
        node = [tree workBuddyAttribute:@"AXParent" element:node];
    }
    return NO;
}
- (id)shellOwnerForBody:(id)body user:(BOOL)user tree:(id<CPAWorkBuddyTreeReading>)tree {
    id parent = [tree workBuddyAttribute:@"AXParent" element:body];
    for (NSUInteger depth = 0; parent && depth < 12; depth++) {
        NSArray *classes = [self classes:parent tree:tree];
        if (user) {
            if (HasClass(classes, @"cr-self-message"))
                return HasClass(classes, @"cr-self-message--discarded") ? nil : parent;
            if (!HasClass(classes, @"cr-self-bubble") && !HasClass(classes, @"cr-self-message__content")) return nil;
            if (HasClass(classes, @"cr-self-bubble--editing")) return nil;
        } else {
            if (HasClass(classes, @"cr-agent"))
                return (HasClass(classes, @"cr-agent--processing") || HasClass(classes, @"cr-agent--discarded")) ? nil : parent;
            // A tool, thinking fold, footer, or unknown block never becomes assistant prose.
            if (!HasClass(classes, @"cr-agent__content") && !HasClass(classes, @"cr-agent__body")
                && !HasClass(classes, @"cr-agent__body-row") && !HasClass(classes, @"cr-text-block")) return nil;
        }
        parent = [tree workBuddyAttribute:@"AXParent" element:parent];
    }
    return nil;
}
- (BOOL)shellOwnerIsTopLevel:(id)owner tree:(id<CPAWorkBuddyTreeReading>)tree {
    id parent = [tree workBuddyAttribute:@"AXParent" element:owner];
    for (NSUInteger depth = 0; parent && depth < 20; depth++) {
        NSArray *classes = [self classes:parent tree:tree];
        if (HasClass(classes, @"cr-message-list")) return YES;
        if (classes.count && !HasClass(classes, @"cr-frame__content") && !HasClass(classes, @"cr-frame")
            && !HasClass(classes, @"cr-document") && !HasClass(classes, @"cr-document__virtual-item")
            && !HasClass(classes, @"cr-document__virtual-spacer") && !HasClass(classes, @"cr-message-list__content")
            && !HasClass(classes, @"cr-message-list__scroller")) return NO;
        if (HasClass(classes, @"cr-message-list__content--hydrating")) return NO;
        parent = [tree workBuddyAttribute:@"AXParent" element:parent];
    }
    return NO;
}
// Chromium can omit non-semantic wrapper divs from both AXChildren and AXParent.
// The actual projection still exposes a right-aligned message frame, its readonly
// editor, and an AXToolbar. Require the sent-message edit action: WorkBuddy hides
// this toolbar for discarded/editing rows and labels unsent rows "Edit again".
- (id)flattenedUserFrameForNode:(id)node tree:(id<CPAWorkBuddyTreeReading>)tree {
    id parent = [tree workBuddyAttribute:@"AXParent" element:node];
    for (NSUInteger depth = 0; parent && depth < 12; depth++) {
        NSArray *classes = [self classes:parent tree:tree];
        if (HasClass(classes, @"cr-frame")) return HasClass(classes, @"cr-frame--right")
            && !HasClass(classes, @"cr-frame--left") ? parent : nil;
        // Chromium sometimes keeps only part of the user-message wrappers
        // (e.g. a scrollable bubble for a long message). Preserve their state
        // checks, while still requiring the same unique sent-message toolbar.
        if (HasClass(classes, @"cr-self-bubble--editing") || HasClass(classes, @"cr-self-message--discarded")) return nil;
        if (HasClass(classes, @"cr-user-content")) {
            id owner = [self shellOwnerForBody:parent user:YES tree:tree];
            // When the full structured chain survives, it owns this text body.
            if (owner && [self shellOwnerIsTopLevel:owner tree:tree]) return nil;
        }
        if (classes.count && !HasClass(classes, @"cr-frame__content")
            && !HasClass(classes, @"cr-self-bubble") && !HasClass(classes, @"cr-self-message")
            && !HasClass(classes, @"cr-self-message__content") && !HasClass(classes, @"cr-user-content")) return nil;
        if (HasClass(classes, @"cr-self-bubble") || HasClass(classes, @"cr-self-message")
            || HasClass(classes, @"cr-self-message__content") || HasClass(classes, @"cr-user-content")) self.flatPartialUserWrappers++;
        parent = [tree workBuddyAttribute:@"AXParent" element:parent];
    }
    return nil;
}
- (BOOL)toolbarConfirmsSentUser:(id)toolbar tree:(id<CPAWorkBuddyTreeReading>)tree {
    if (![[tree workBuddyAttribute:@"AXRole" element:toolbar] isEqual:@"AXToolbar"]) return NO;
    BOOL edit = NO;
    // Toolbar actions are direct children in the observed 5.5.3 AX projection.
    NSArray *children = [self children:toolbar tree:tree];
    if (children.count > 20) return NO;
    for (id child in children) {
        if (![[tree workBuddyAttribute:@"AXRole" element:child] isEqual:@"AXButton"]) continue;
        for (NSString *attribute in @[@"AXTitle", @"AXDescription"]) {
            id label = [tree workBuddyAttribute:attribute element:child];
            if ([label isEqual:@"重新编辑"] || [label isEqual:@"Edit again"]) return NO;
            if ([label isEqual:@"编辑"] || [label isEqual:@"Edit"]) edit = YES;
        }
    }
    return edit;
}

- (NSArray *)shellStructure:(id)root composer:(id)composer tree:(id<CPAWorkBuddyTreeReading>)tree
    stillCurrent:(BOOL (^)(void))stillCurrent {
    CPAWorkBuddyStructureTree *metadataTree = [CPAWorkBuddyStructureTree new];
    metadataTree.source = tree; metadataTree.metadata = [NSMapTable strongToStrongObjectsMapTable];
    tree = metadataTree;
    self.flatPartialUserWrappers = 0;
    self.diagnostic = @"contextStage=composer_check contextLayout=shell";
    if (![self shellComposer:composer belongsTo:root tree:tree] || !stillCurrent()) return nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:@[root, @NO, @NO]];
    NSMutableArray *bodies = [NSMutableArray array], *owners = [NSMutableArray array], *unsentOwners = [NSMutableArray array];
    NSMutableArray *flattenedBodies = [NSMutableArray array], *confirmedFrames = [NSMutableArray array], *bodyOrder = [NSMutableArray array];
    NSUInteger visited = 0, timelines = 0, lists = 0;
    while (stack.count) {
        if (++visited > 6000 || !stillCurrent()) {
            self.diagnostic = [NSString stringWithFormat:@"contextStage=%@ contextLayout=shell contextNodes=%lu", visited > 6000 ? @"structure_node_limit" : @"structure_cancelled", (unsigned long)visited];
            return nil;
        }
        NSArray *entry = stack.lastObject; [stack removeLastObject];
        id node = entry[0]; BOOL inTimeline = [entry[1] boolValue], inList = [entry[2] boolValue];
        NSArray *classes = [self classes:node tree:tree];
        if (![node isEqual:root] && (HasClass(classes, @"conversation-shell") || HasClass(classes, @"_cbChat_"))) {
            self.diagnostic = @"contextStage=nested_shell contextLayout=shell"; return nil;
        }
        if (HasClass(classes, @"conversation-timeline")) { timelines++; inTimeline = YES; }
        if (inTimeline && HasClass(classes, @"cr-message-list")) { lists++; inList = YES; }
        if (HasClass(classes, @"cr-self-message__not-sent")) {
            id owner = [self shellOwnerForBody:node user:YES tree:tree];
            if (owner) {
                [unsentOwners addObject:owner];
                // A partial projection is keyed by its frame rather than the
                // retained owner. Both must reject an explicit unsent marker,
                // even while a toolbar is still catching up with row state.
                id frame = [self flattenedUserFrameForNode:owner tree:tree];
                if (frame) [unsentOwners addObject:frame];
            }
        }
        if (inTimeline && inList && (HasClass(classes, @"_editable_") || HasClass(classes, @"cr-toolbar"))) {
            id frame = [self flattenedUserFrameForNode:node tree:tree];
            if (frame && [self shellOwnerIsTopLevel:frame tree:tree] && [self node:node attachedTo:root tree:tree]) {
                if (HasClass(classes, @"cr-toolbar")) {
                    if ([self toolbarConfirmsSentUser:node tree:tree]) [confirmedFrames addObject:frame];
                } else {
                    NSString *role = [tree workBuddyAttribute:@"AXRole" element:node];
                    if (![role isEqual:@"AXTextArea"] && ![role isEqual:@"AXTextField"])
                        { [flattenedBodies addObject:@[node, @"user", frame]]; [bodyOrder addObject:node]; }
                }
            }
        }
        BOOL user = HasClass(classes, @"cr-user-content");
        if (inTimeline && inList && (user || HasClass(classes, @"cr-markdown"))) {
            id owner = [self shellOwnerForBody:node user:user tree:tree];
            if (owner && [self shellOwnerIsTopLevel:owner tree:tree] && [self node:node attachedTo:root tree:tree]) {
                [bodies addObject:@[node, user ? @"user" : @"assistant", owner]]; [bodyOrder addObject:node];
                if (user) [owners addObject:owner];
            }
        }
        // Static text children are inline glyph boxes, never message containers.
        // Do not spend the structure budget traversing those presentation leaves.
        if ([[tree workBuddyAttribute:@"AXRole" element:node] isEqual:@"AXStaticText"]) continue;
        // Only metadata is read here; AXValue remains behind body selection.
        for (id child in [[self children:node tree:tree] reverseObjectEnumerator])
            [stack addObject:@[child, @(inTimeline), @(inList)]];
    }
    for (NSArray *body in flattenedBodies) {
        NSUInteger bodyCount = 0, toolbarCount = 0;
        for (NSArray *other in flattenedBodies) if ([other[2] isEqual:body[2]]) bodyCount++;
        for (id frame in confirmedFrames) if ([frame isEqual:body[2]]) toolbarCount++;
        if (bodyCount != 1 || toolbarCount != 1) continue;
        // Merge by DFS encounter order below so mixed projections retain chronology.
        [bodies addObject:body]; [owners addObject:body[2]];
    }
    [bodies sortUsingComparator:^NSComparisonResult(NSArray *left, NSArray *right) {
        NSUInteger a = [bodyOrder indexOfObject:left[0]], b = [bodyOrder indexOfObject:right[0]];
        return a < b ? NSOrderedAscending : a > b ? NSOrderedDescending : NSOrderedSame;
    }];
    [bodies filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSArray *body, NSDictionary *bindings) {
        (void)bindings; return ![unsentOwners containsObject:body[2]];
    }]];
    [owners removeObjectsInArray:unsentOwners];
    self.diagnostic = [NSString stringWithFormat:@"contextStage=structure_check contextLayout=shell contextNodes=%lu contextTimelines=%lu contextLists=%lu contextOwners=%lu contextBodies=%lu contextFlatBodies=%lu contextConfirmedFrames=%lu contextPartialUserWrappers=%lu",
        (unsigned long)visited, (unsigned long)timelines, (unsigned long)lists,
        (unsigned long)owners.count, (unsigned long)bodies.count, (unsigned long)flattenedBodies.count, (unsigned long)confirmedFrames.count, (unsigned long)self.flatPartialUserWrappers];
    if (timelines != 1 || lists != 1 || owners.count == 0 || !stillCurrent()) return nil;
    return @[[owners copy], [bodies copy]];
}
- (NSArray *)readShell:(id)root composer:(id)composer tree:(id<CPAWorkBuddyTreeReading>)tree
    stillCurrent:(BOOL (^)(void))stillCurrent {
    NSArray *structure = [self shellStructure:root composer:composer tree:tree stillCurrent:stillCurrent];
    if (!structure) return nil;
    NSMutableArray *messages = [NSMutableArray array];
    NSUInteger users = 0, assistants = 0, remaining = 3000, visited = 0;
    BOOL budgetStopped = NO;
    NSUInteger omittedLength = 0;
    self.diagnostic = @"contextStage=text_scan contextLayout=shell";
    for (NSArray *body in [structure[1] reverseObjectEnumerator]) {
        BOOL user = [body[1] isEqual:@"user"];
        if ((user ? users >= 6 : assistants >= 2) || remaining == 0) continue;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:body[0]], *parts = [NSMutableArray array];
        NSUInteger length = 0;
        while (stack.count) {
            if (++visited > 600 || !stillCurrent()) {
                self.diagnostic = visited > 600 ? @"contextStage=text_node_limit contextLayout=shell" : @"contextStage=text_cancelled contextLayout=shell";
                return nil;
            }
            id leaf = stack.lastObject; [stack removeLastObject];
            NSString *role = [tree workBuddyAttribute:@"AXRole" element:leaf];
            if ([role isEqual:@"AXStaticText"]) {
                id value = [tree workBuddyAttribute:@"AXValue" element:leaf];
                if ([value isKindOfClass:NSString.class] && [value length]) {
                    length += [value length] + (parts.count ? 1 : 0);
                    if (length > remaining) break;
                    [parts addObject:value];
                }
            } else {
                if ([role isEqual:@"AXButton"] || [role isEqual:@"AXTextField"] || [role isEqual:@"AXTextArea"]) continue;
                for (id child in [[self children:leaf tree:tree] reverseObjectEnumerator]) [stack addObject:child];
            }
        }
        if (length > remaining) { budgetStopped = YES; omittedLength = length; break; }
        if (!parts.count) continue;
        NSString *text = [parts componentsJoinedByString:@"\n"];
        [messages insertObject:@{@"role":body[1], @"content":text} atIndex:0];
        remaining -= text.length; if (user) users++; else assistants++;
    }
    // Recheck topology, row state, and composer ownership after reading. The
    // caller additionally rechecks focus and the complete current draft.
    NSArray *fresh = [self shellStructure:root composer:composer tree:tree stillCurrent:stillCurrent];
    if (!fresh) return nil;
    if (![structure isEqual:fresh] || !stillCurrent()) {
        self.diagnostic = @"contextStage=ownership_changed contextLayout=shell"; return nil;
    }
    if (!self.identity) self.identity = [CPAInputElementIdentity new];
    NSString *token = [self.identity tokenForElement:@[root, composer, structure] window:nil rendererIdentifier:@"workbuddy-shell"];
    self.diagnostic = [NSString stringWithFormat:@"%@ contextMessages=%lu contextBudgetStopped=%@ contextOmittedChars=%lu contextRemainingChars=%lu",
        [self.diagnostic stringByReplacingOccurrencesOfString:@"contextStage=structure_check" withString:@"contextStage=ready"],
        (unsigned long)messages.count, budgetStopped ? @"true" : @"false", (unsigned long)omittedLength, (unsigned long)remaining];
    return @[@[token], [messages copy]];
}

- (NSArray *)readComposer:(id)composer tree:(id<CPAWorkBuddyTreeReading>)tree
    stillCurrent:(BOOL (^)(void))stillCurrent {
    self.readPending = NO;
    self.conversationRootFound = NO;
    NSArray *result = [self readCurrentComposer:composer tree:tree stillCurrent:^BOOL {
        BOOL valid = stillCurrent();
        if (!valid) self.readPending = YES;
        return valid;
    }];
    // A mounted shell/list may be between conversations or still hydrating.
    // Failure to validate its history is not proof of an empty conversation.
    if (self.conversationRootFound && result == nil) self.readPending = YES;
    return result;
}
- (NSArray *)readCurrentComposer:(id)composer tree:(id<CPAWorkBuddyTreeReading>)tree
    stillCurrent:(BOOL (^)(void))stillCurrent {
    self.diagnostic = @"contextStage=precheck";
    if (!stillCurrent()) return nil;
    self.diagnostic = @"contextStage=root_missing";
    // Restrict to the closest cb-chat root enclosing the focused composer.
    // Never scan an application/window or select a task by its title.
    id root = nil, node = composer;
    NSUInteger ancestors = 0, classNodes = 0, windows = 0, webAreas = 0;
    for (NSUInteger depth = 0; node != nil && depth < 20; depth++) {
        ancestors++;
        NSArray *classes = [self classes:node tree:tree];
        if (classes.count > 0) classNodes++;
        NSString *role = [tree workBuddyAttribute:@"AXRole" element:node];
        if ([role isEqual:@"AXWindow"]) windows++;
        if ([role isEqual:@"AXWebArea"]) webAreas++;
        if (HasClass(classes, @"_userMessage_") || HasClass(classes, @"_userMessageText_")) return nil;
        if (HasClass(classes, @"conversation-shell")) {
            self.conversationRootFound = YES;
            return [self readShell:node composer:composer tree:tree stillCurrent:stillCurrent];
        }
        if (HasClass(classes, @"cr-self-message") || HasClass(classes, @"cr-user-content")
            || HasClass(classes, @"cr-user-message-editor")) return nil;
        if (HasClass(classes, @"_cbChat_")) { self.conversationRootFound = YES; root = node; break; }
        if ([role isEqual:@"AXWebArea"] || [role isEqual:@"AXWindow"]) break;
        node = [tree workBuddyAttribute:@"AXParent" element:node];
    }
    if (root == nil || !stillCurrent()) {
        self.diagnostic = [NSString stringWithFormat:
            @"contextStage=root_missing contextAncestors=%lu contextClassNodes=%lu contextWindows=%lu contextWebAreas=%lu contextDepthLimit=%@",
            (unsigned long)ancestors, (unsigned long)classNodes,
            (unsigned long)windows, (unsigned long)webAreas,
            node != nil && ancestors == 20 ? @"true" : @"false"];
        return nil;
    }
    self.diagnostic = @"contextStage=structure_scan";
    NSMutableArray *stack = [NSMutableArray arrayWithObject:@[root, @"", @NO]];
    NSMutableArray *bodies = [NSMutableArray array], *ownership = [NSMutableArray array];
    NSMutableArray *ownerNodes = [NSMutableArray array];
    NSUInteger visited = 0, timelines = 0;
    while (stack.count > 0) {
        if (++visited > 1800 || !stillCurrent()) return nil;
        NSArray *entry = stack.lastObject; [stack removeLastObject];
        node = entry[0]; NSString *role = entry[1]; BOOL inTimeline = [entry[2] boolValue];
        NSArray *classes = [self classes:node tree:tree];
        if (node != root && HasClass(classes, @"_cbChat_")) return nil;
        if (HasClass(classes, @"_chatMessageContainer_")) { timelines++; inTimeline = YES; }
        // WorkBuddy 5.2.5 interpolates an absent CSS-module export as the
        // literal class "undefined" on its active streaming assistant row.
        if ((HasClass(classes, @"cb-assistant-message") && HasClass(classes, @"undefined"))
            || HasClass(classes, @"_streamingMessage_") || HasClass(classes, @"_grayMessage_")
            || HasClass(classes, @"_toolCallContent_") || HasClass(classes, @"_summaryUserMessage_")) continue;
        if (inTimeline && HasClass(classes, @"_userMessage_")) {
            id identifier = [tree workBuddyAttribute:@"AXDOMIdentifier" element:node];
            if (![identifier isKindOfClass:NSString.class] || ![identifier hasPrefix:@"user-message-"]
                || [identifier length] <= 13) return nil;
            [ownership addObject:identifier]; [ownerNodes addObject:node]; role = @"user";
        } else if (inTimeline && HasClass(classes, @"cb-assistant-message")) role = @"assistant";
        if (([role isEqual:@"user"] && HasClass(classes, @"_userMessageText_"))
            || ([role isEqual:@"assistant"] && HasClass(classes, @"_assistantTextContent_"))) {
            [bodies addObject:@[node, role]];
            continue;
        }
        for (id child in [[self children:node tree:tree] reverseObjectEnumerator])
            [stack addObject:@[child, role, @(inTimeline)]];
    }
    self.diagnostic = [NSString stringWithFormat:@"contextStage=structure_check contextNodes=%lu contextTimelines=%lu contextOwners=%lu contextBodies=%lu", (unsigned long)visited, (unsigned long)timelines, (unsigned long)ownership.count, (unsigned long)bodies.count];
    // A user request ID is required to anchor the rendered conversation.
    if (timelines != 1 || ownership.count == 0 || !stillCurrent()) return nil;
    self.diagnostic = @"contextStage=text_scan";
    NSMutableArray *messages = [NSMutableArray array];
    NSUInteger users = 0, assistants = 0, remaining = 3000;
    for (NSArray *body in bodies.reverseObjectEnumerator) {
        BOOL user = [body[1] isEqual:@"user"];
        if ((user ? users >= 6 : assistants >= 2) || remaining == 0) continue;
        NSMutableArray *textStack = [NSMutableArray arrayWithObject:body[0]];
        NSMutableArray *parts = [NSMutableArray array]; NSUInteger length = 0;
        while (textStack.count > 0) {
            if (++visited > 2400 || !stillCurrent()) return nil;
            id leaf = textStack.lastObject; [textStack removeLastObject];
            NSString *axRole = [tree workBuddyAttribute:@"AXRole" element:leaf];
            if ([axRole isEqual:@"AXStaticText"]) {
                id value = [tree workBuddyAttribute:@"AXValue" element:leaf];
                if ([value isKindOfClass:NSString.class] && [value length] > 0) {
                    length += [value length] + (parts.count > 0 ? 1 : 0);
                    if (length > remaining) break; // only complete messages, never a misleading fragment
                    [parts addObject:value];
                }
            } else {
                // Buttons/attachments/code tools do not become dialogue text.
                if ([axRole isEqual:@"AXButton"] || [axRole isEqual:@"AXTextField"]) continue;
                for (id child in [[self children:leaf tree:tree] reverseObjectEnumerator])
                    [textStack addObject:child];
            }
        }
        if (length > remaining) break;
        if (parts.count == 0) continue;
        NSString *text = [parts componentsJoinedByString:@"\n"];
        [messages insertObject:@{@"role":body[1], @"content":text} atIndex:0];
        remaining -= text.length; if (user) users++; else assistants++;
    }
    self.diagnostic = @"contextStage=ownership_recheck";
    // Reject detached/replaced message nodes even if the app reused its composer.
    for (NSUInteger i = 0; i < ownerNodes.count; i++) {
        id owner = ownerNodes[i];
        if (![[tree workBuddyAttribute:@"AXDOMIdentifier" element:owner] isEqual:ownership[i]]) return nil;
        BOOL attached = NO;
        for (NSUInteger depth = 0; owner != nil && depth < 32; depth++) {
            if ([owner isEqual:root]) { attached = YES; break; }
            owner = [tree workBuddyAttribute:@"AXParent" element:owner];
        }
        if (!attached || !stillCurrent()) return nil;
    }
    if (!stillCurrent()) return nil;
    if (self.identity == nil) self.identity = [CPAInputElementIdentity new];
    NSString *token = [self.identity tokenForElement:root window:nil rendererIdentifier:@""];
    self.diagnostic = [NSString stringWithFormat:@"contextStage=ready contextNodes=%lu contextMessages=%lu", (unsigned long)visited, (unsigned long)messages.count];
    return @[@[token, [ownership copy]], [messages copy]];
}
@end
