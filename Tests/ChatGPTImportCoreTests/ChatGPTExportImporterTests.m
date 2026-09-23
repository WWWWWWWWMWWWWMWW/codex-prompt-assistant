#import <Foundation/Foundation.h>

#import <string.h>
#import <zlib.h>

#import "../../Sources/ChatGPTImportCore/ChatGPTExportImporter.h"
#import "../../Sources/CodexDataCore/LocalDataStore.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSData *SyntheticMasterKey(void) {
    NSMutableData *data = [NSMutableData dataWithLength:64];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0, len = data.length; i < len; i++) {
        bytes[i] = (uint8_t)(i + 31);
    }
    return data;
}

static void AppendUInt16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8)};
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void AppendUInt32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[] = {
        (uint8_t)value, (uint8_t)(value >> 8),
        (uint8_t)(value >> 16), (uint8_t)(value >> 24),
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static uint16_t ReadUInt16(NSData *data, NSUInteger offset) {
    const uint8_t *bytes = data.bytes;
    return (uint16_t)(bytes[offset] | ((uint16_t)bytes[offset + 1] << 8));
}

static uint32_t ReadUInt32(NSData *data, NSUInteger offset) {
    const uint8_t *bytes = data.bytes;
    return (uint32_t)bytes[offset]
        | ((uint32_t)bytes[offset + 1] << 8)
        | ((uint32_t)bytes[offset + 2] << 16)
        | ((uint32_t)bytes[offset + 3] << 24);
}

static NSData *RawDeflate(NSData *data) {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    Assert(deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
        -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) == Z_OK, @"应初始化合成 raw-deflate");
    NSMutableData *compressed = [NSMutableData dataWithLength:compressBound((uLong)data.length)];
    stream.next_in = (Bytef *)data.bytes;
    stream.avail_in = (uInt)data.length;
    stream.next_out = compressed.mutableBytes;
    stream.avail_out = (uInt)compressed.length;
    Assert(deflate(&stream, Z_FINISH) == Z_STREAM_END, @"应压缩合成 ZIP 条目");
    [compressed setLength:stream.total_out];
    deflateEnd(&stream);
    return compressed;
}

static NSURL *WriteZIP(NSURL *directory, NSString *name,
    NSArray<NSDictionary<NSString *, id> *> *entries) {
    NSMutableData *archive = [NSMutableData data];
    NSMutableData *central = [NSMutableData data];
    for (NSUInteger i = 0, len = entries.count; i < len; i++) {
        NSDictionary<NSString *, id> *entry = entries[i];
        NSData *nameData = [entry[@"name"] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *body = entry[@"data"];
        BOOL shouldDeflate = [entry[@"deflate"] boolValue];
        NSData *payload = shouldDeflate ? RawDeflate(body) : body;
        uint16_t method = shouldDeflate ? 8 : 0;
        NSNumber *declaredNumber = entry[@"declaredSize"];
        uint32_t declaredSize = declaredNumber != nil
            ? declaredNumber.unsignedIntValue
            : (uint32_t)body.length;
        uint32_t crc = (uint32_t)crc32(0, body.bytes, (uInt)body.length);
        uint32_t localOffset = (uint32_t)archive.length;

        AppendUInt32(archive, 0x04034b50);
        AppendUInt16(archive, 20);
        AppendUInt16(archive, 0x0800);
        AppendUInt16(archive, method);
        AppendUInt16(archive, 0);
        AppendUInt16(archive, 0);
        AppendUInt32(archive, crc);
        AppendUInt32(archive, (uint32_t)payload.length);
        AppendUInt32(archive, declaredSize);
        AppendUInt16(archive, (uint16_t)nameData.length);
        AppendUInt16(archive, 0);
        [archive appendData:nameData];
        [archive appendData:payload];

        AppendUInt32(central, 0x02014b50);
        AppendUInt16(central, 20);
        AppendUInt16(central, 20);
        AppendUInt16(central, 0x0800);
        AppendUInt16(central, method);
        AppendUInt16(central, 0);
        AppendUInt16(central, 0);
        AppendUInt32(central, crc);
        AppendUInt32(central, (uint32_t)payload.length);
        AppendUInt32(central, declaredSize);
        AppendUInt16(central, (uint16_t)nameData.length);
        AppendUInt16(central, 0);
        AppendUInt16(central, 0);
        AppendUInt16(central, 0);
        AppendUInt16(central, 0);
        AppendUInt32(central, 0);
        AppendUInt32(central, localOffset);
        [central appendData:nameData];
    }
    uint32_t centralOffset = (uint32_t)archive.length;
    [archive appendData:central];
    AppendUInt32(archive, 0x06054b50);
    AppendUInt16(archive, 0);
    AppendUInt16(archive, 0);
    AppendUInt16(archive, (uint16_t)entries.count);
    AppendUInt16(archive, (uint16_t)entries.count);
    AppendUInt32(archive, (uint32_t)central.length);
    AppendUInt32(archive, centralOffset);
    AppendUInt16(archive, 0);

    NSURL *url = [directory URLByAppendingPathComponent:name];
    NSError *error = nil;
    Assert([archive writeToURL:url options:NSDataWritingAtomic error:&error]
        && error == nil, @"应写入合成 ZIP");
    return url;
}

static NSDictionary *MessageNode(NSString *nodeID, NSString *messageID,
    NSString *role, NSString *text, id parent, NSArray<NSString *> *children) {
    return @{
        @"id": nodeID,
        @"parent": parent,
        @"children": children,
        @"message": @{
            @"id": messageID,
            @"author": @{@"role": role},
            @"create_time": @1724112000.0,
            @"content": @{
                @"content_type": @"text",
                @"parts": @[text],
            },
        },
    };
}

static NSDictionary *Conversation(NSString *conversationID, NSString *suffix) {
    NSString *rootID = [@"root-" stringByAppendingString:suffix];
    NSString *userNodeID = [@"user-node-" stringByAppendingString:suffix];
    NSString *activeNodeID = [@"active-node-" stringByAppendingString:suffix];
    NSString *alternateNodeID = [@"alternate-node-" stringByAppendingString:suffix];
    return @{
        @"id": conversationID,
        @"title": [@"Synthetic " stringByAppendingString:suffix],
        @"create_time": @1724112000.0,
        @"update_time": @1724112002.0,
        @"current_node": activeNodeID,
        @"mapping": @{
            rootID: @{
                @"id": rootID,
                @"parent": NSNull.null,
                @"children": @[userNodeID],
                @"message": NSNull.null,
            },
            userNodeID: MessageNode(userNodeID,
                [@"user-message-" stringByAppendingString:suffix],
                @"user", [@"用户问题-" stringByAppendingString:suffix],
                rootID, @[activeNodeID, alternateNodeID]),
            activeNodeID: MessageNode(activeNodeID,
                [@"active-message-" stringByAppendingString:suffix],
                @"assistant", [@"当前回答-" stringByAppendingString:suffix],
                userNodeID, @[]),
            alternateNodeID: MessageNode(alternateNodeID,
                [@"alternate-message-" stringByAppendingString:suffix],
                @"assistant", [@"未选回答-" stringByAppendingString:suffix],
                userNodeID, @[]),
        },
    };
}

static NSData *JSONData(id object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
        options:NSJSONWritingSortedKeys error:&error];
    Assert(data != nil && error == nil, @"合成导出 JSON 必须有效");
    return data;
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSError *error = nil;
        Assert([fileManager createDirectoryAtURL:base withIntermediateDirectories:YES
            attributes:nil error:&error], @"应创建 ChatGPT 导入测试目录");
        NSURL *databaseURL = [base URLByAppendingPathComponent:@"history.sqlite3"];
        CPALocalDataStore *store = [[CPALocalDataStore alloc]
            initWithDatabaseURL:databaseURL masterKey:SyntheticMasterKey() error:&error];
        Assert(store != nil && error == nil, @"应打开 ChatGPT 导入测试数据库");

        CPAChatGPTImportLimits *limits = [[CPAChatGPTImportLimits alloc]
            initWithMaximumArchiveBytes:1024 * 1024
            maximumEntryCount:20
            maximumEntryUncompressedBytes:64 * 1024
            maximumTotalUncompressedBytes:128 * 1024
            maximumConversationBytes:32 * 1024
            maximumCompressionRatio:100.0];
        CPAChatGPTExportImporter *importer = [[CPAChatGPTExportImporter alloc]
            initWithLimits:limits];
        NSArray *conversations = @[
            Conversation(@"conversation-1", @"one"),
            Conversation(@"conversation-2", @"two"),
        ];
        NSURL *normalZIP = WriteZIP(base, @"normal.zip", @[
            @{
                @"name": @"conversations.json",
                @"data": JSONData(conversations),
                @"deflate": @YES,
            },
            @{@"name": @"chat.html", @"data": [@"ignored" dataUsingEncoding:
                NSUTF8StringEncoding]},
        ]);
        for (NSUInteger pass = 0; pass < 3; pass++) {
            error = nil;
            CPAChatGPTExportImportResult *result = [importer importExportAtURL:normalZIP
                intoStore:store cancellationCheck:nil error:&error];
            Assert(result != nil && error == nil, @"正常 ChatGPT 导出应成功导入");
            Assert(result.conversationCount == 2, @"正常导出应识别两个会话");
            Assert(result.insertedMessageCount == (pass == 0 ? 4 : 0),
                @"重复导入只允许首次新增当前分支消息");
            Assert(result.existingMessageCount == (pass == 0 ? 0 : 4),
                @"后续导入应识别四条已存在消息");
        }
        CPALocalDataCounts *counts = [store currentCounts:&error];
        Assert(counts.sourceCount == 2 && counts.conversationCount == 2
                && counts.messageCount == 4 && counts.importRunCount == 3,
            @"三次正常导入必须保持两会话四消息幂等");
        NSString *activeText = [store decryptedMessageTextForSourceKind:@"chatgpt"
            conversationID:@"conversation-1" messageID:@"active-message-one"
            error:&error];
        NSString *alternateText = [store decryptedMessageTextForSourceKind:@"chatgpt"
            conversationID:@"conversation-1" messageID:@"alternate-message-one"
            error:&error];
        Assert([activeText isEqualToString:@"当前回答-one"] && alternateText == nil,
            @"只导入 current_node 所在可见分支，未选回答不得入库");

        NSMutableData *tamperedData = [NSMutableData dataWithContentsOfURL:normalZIP];
        NSUInteger firstDataOffset = 30 + ReadUInt16(tamperedData, 26);
        uint32_t firstCompressedSize = ReadUInt32(tamperedData, 18);
        Assert(firstCompressedSize > 2, @"压缩夹具应有可篡改的正文");
        uint8_t *tamperedBytes = tamperedData.mutableBytes;
        tamperedBytes[firstDataOffset + firstCompressedSize / 2] ^= 0x01;
        NSURL *tamperedZIP = [base URLByAppendingPathComponent:@"tampered.zip"];
        Assert([tamperedData writeToURL:tamperedZIP options:NSDataWritingAtomic error:&error],
            @"应写入篡改 ZIP 夹具");
        error = nil;
        Assert([importer importExportAtURL:tamperedZIP intoStore:store
            cancellationCheck:nil error:&error] == nil && error != nil,
            @"压缩正文篡改必须在 CRC 或 deflate 校验中失败");
        counts = [store currentCounts:&error];
        Assert(counts.messageCount == 4 && counts.importRunCount == 3,
            @"篡改包失败后数据库不得变化");

        NSURL *unknownZIP = WriteZIP(base, @"unknown.zip", @[
            @{@"name": @"conversations.json", @"data": JSONData(@[
                Conversation(@"conversation-rollback", @"rollback"),
                @{@"id": @"unknown-schema"},
            ])},
        ]);
        error = nil;
        Assert([importer importExportAtURL:unknownZIP intoStore:store
            cancellationCheck:nil error:&error] == nil && error != nil,
            @"未知会话结构必须让整包失败");
        counts = [store currentCounts:&error];
        Assert(counts.sourceCount == 2 && counts.messageCount == 4
                && counts.importRunCount == 3,
            @"未知结构前已解析的会话也必须回滚");

        NSURL *traversalZIP = WriteZIP(base, @"traversal.zip", @[
            @{@"name": @"../outside.txt", @"data": [@"bad" dataUsingEncoding:
                NSUTF8StringEncoding]},
            @{@"name": @"conversations.json", @"data": JSONData(conversations)},
        ]);
        error = nil;
        Assert([importer importExportAtURL:traversalZIP intoStore:store
            cancellationCheck:nil error:&error] == nil && error != nil,
            @"包含路径穿越条目的 ZIP 必须整包拒绝");
        Assert(![fileManager fileExistsAtPath:[base.URLByDeletingLastPathComponent.path
            stringByAppendingPathComponent:@"outside.txt"]],
            @"导入器不得把 ZIP 条目解压到磁盘");

        NSURL *bombZIP = WriteZIP(base, @"bomb.zip", @[
            @{
                @"name": @"conversations.json",
                @"data": [@"[]" dataUsingEncoding:NSUTF8StringEncoding],
                @"declaredSize": @70000,
            },
        ]);
        error = nil;
        Assert([importer importExportAtURL:bombZIP intoStore:store
            cancellationCheck:nil error:&error] == nil && error != nil,
            @"声明解压尺寸超限的 ZIP 必须在读取正文前拒绝");

        NSURL *ratioZIP = WriteZIP(base, @"ratio.zip", @[
            @{
                @"name": @"conversations.json",
                @"data": [@"[]" dataUsingEncoding:NSUTF8StringEncoding],
                @"declaredSize": @60000,
            },
        ]);
        error = nil;
        Assert([importer importExportAtURL:ratioZIP intoStore:store
            cancellationCheck:nil error:&error] == nil && error != nil,
            @"异常声明压缩比必须在解压前拒绝");

        NSURL *cancelZIP = WriteZIP(base, @"cancel.zip", @[
            @{@"name": @"conversations.json", @"data": JSONData(@[
                Conversation(@"conversation-cancel-1", @"cancel-one"),
                Conversation(@"conversation-cancel-2", @"cancel-two"),
            ])},
        ]);
        __block NSUInteger cancellationChecks = 0;
        error = nil;
        CPAChatGPTExportImportResult *cancelled = [importer importExportAtURL:cancelZIP
            intoStore:store cancellationCheck:^BOOL{
                cancellationChecks++;
                return cancellationChecks >= 3;
            } error:&error];
        Assert(cancelled == nil && error != nil, @"取消必须中止正在进行的导入");
        counts = [store currentCounts:&error];
        Assert(counts.sourceCount == 2 && counts.messageCount == 4
                && counts.importRunCount == 3,
            @"取消前已经写入事务的会话必须全部回滚");

        error = nil;
        Assert([store deleteSourceKind:@"chatgpt"
                externalID:@"conversation-1" error:&error] && error == nil,
            @"应删除指定 ChatGPT 会话并记录墓碑");
        counts = [store currentCounts:&error];
        Assert(counts.sourceCount == 1 && counts.conversationCount == 1
                && counts.messageCount == 2 && counts.tombstoneCount == 1,
            @"删除一个 ChatGPT 会话应级联删除其两条消息");
        CPAChatGPTExportImportResult *afterDeletion = [importer importExportAtURL:normalZIP
            intoStore:store cancellationCheck:nil error:&error];
        Assert(afterDeletion != nil && error == nil
                && afterDeletion.insertedMessageCount == 0,
            @"重新导入导出包不得让已删除 ChatGPT 会话复活");
        counts = [store currentCounts:&error];
        Assert(counts.sourceCount == 1 && counts.conversationCount == 1
                && counts.messageCount == 2 && counts.tombstoneCount == 1,
            @"重导入后已删除 ChatGPT 会话仍必须保持删除");

        Assert([store close:&error], @"ChatGPT 导入测试数据库应安全关闭");
        [fileManager removeItemAtURL:base error:nil];
        NSLog(@"PASS: ChatGPTExportImporterTests");
    }
    return 0;
}
