#import <Foundation/Foundation.h>

#import <sqlite3.h>

#import "../../Sources/CodexDataCore/LocalDataStore.h"

static void Assert(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static int RunRebuild(NSArray<NSString *> *arguments, NSString **output) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@".build/tests/CodexDataRebuild"];
    task.arguments = arguments;
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;
    NSError *error = nil;
    Assert([task launchAndReturnError:&error] && error == nil, @"应能启动重建工具");
    [task waitUntilExit];
    NSMutableData *data = [NSMutableData dataWithData:
        [stdoutPipe.fileHandleForReading readDataToEndOfFile]];
    [data appendData:[stderrPipe.fileHandleForReading readDataToEndOfFile]];
    if (output != NULL) {
        *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return task.terminationStatus;
}

static NSUInteger TableCount(NSURL *databaseURL, NSString *tableName) {
    sqlite3 *database = NULL;
    Assert(sqlite3_open_v2(databaseURL.fileSystemRepresentation, &database,
        SQLITE_OPEN_READONLY, NULL) == SQLITE_OK, @"应只读打开 staging 数据库");
    sqlite3_stmt *statement = NULL;
    NSString *sql = [NSString stringWithFormat:@"SELECT COUNT(*) FROM %@", tableName];
    Assert(sqlite3_prepare_v2(database, sql.UTF8String, -1,
        &statement, NULL) == SQLITE_OK, @"应准备消息计数查询");
    Assert(sqlite3_step(statement) == SQLITE_ROW, @"应读取消息计数");
    NSUInteger count = (NSUInteger)sqlite3_column_int64(statement, 0);
    sqlite3_finalize(statement);
    sqlite3_close_v2(database);
    return count;
}

static NSData *SyntheticMasterKey(void) {
    NSMutableData *key = [NSMutableData dataWithLength:64];
    memset(key.mutableBytes, 0x5a, key.length);
    return key;
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSURL *active = [base URLByAppendingPathComponent:@"active" isDirectory:YES];
        NSURL *archived = [base URLByAppendingPathComponent:@"archived" isDirectory:YES];
        NSError *error = nil;
        Assert([fileManager createDirectoryAtURL:active withIntermediateDirectories:YES
            attributes:nil error:&error], @"应创建 active 重建夹具目录");
        Assert([fileManager createDirectoryAtURL:archived withIntermediateDirectories:YES
            attributes:nil error:&error], @"应创建 archived 重建夹具目录");
        NSURL *rootFixture = [NSURL fileURLWithPath:
            @"Tests/Fixtures/Codex/root-task.jsonl"];
        NSURL *subagentFixture = [NSURL fileURLWithPath:
            @"Tests/Fixtures/Codex/subagent-task.jsonl"];
        Assert([fileManager copyItemAtURL:rootFixture
            toURL:[active URLByAppendingPathComponent:@"root.jsonl"] error:&error],
            @"应复制 root 重建夹具");
        Assert([fileManager copyItemAtURL:subagentFixture
            toURL:[active URLByAppendingPathComponent:@"subagent.jsonl"] error:&error],
            @"应复制 subagent 重建夹具");

        NSString *service = [@"local.codex.prompt-assistant.rebuild-test."
            stringByAppendingString:NSUUID.UUID.UUIDString];
        NSURL *databaseURL = [base URLByAppendingPathComponent:@"history.staging.sqlite3"];
        NSArray<NSString *> *arguments = @[
            active.path, archived.path, databaseURL.path, service,
        ];
        NSString *output = nil;
        int status = RunRebuild(arguments, &output);
        Assert(status == 0 && [output containsString:@"rebuild_complete=true"],
            @"合成来源应成功重建 staging 数据库");
        Assert(TableCount(databaseURL, @"messages") == 4,
            @"重建只应导入 root 夹具中的四条可见消息");

        status = RunRebuild(arguments, &output);
        Assert(status == 2 && [output containsString:@"destination_exists"],
            @"重建工具必须拒绝覆盖已存在的 staging 数据库");
        Assert(TableCount(databaseURL, @"messages") == 4,
            @"拒绝覆盖后原 staging 数据不得变化");

        NSURL *wrongSuffix = [base URLByAppendingPathComponent:@"history.sqlite3"];
        status = RunRebuild(@[active.path, archived.path, wrongSuffix.path, service], &output);
        Assert(status == 2 && ![fileManager fileExistsAtPath:wrongSuffix.path],
            @"非 staging 后缀必须在创建文件前被拒绝");

        CPALocalDataStore *store = [[CPALocalDataStore alloc]
            initWithDatabaseURL:databaseURL masterKey:SyntheticMasterKey() error:&error];
        Assert(store != nil && error == nil, @"应打开合成 staging 数据库以记录删除决定");
        Assert([store deleteSourceKind:@"codex" externalID:@"root-1" error:&error]
            && error == nil, @"应删除合成来源并保留墓碑");
        Assert([store close:&error] && error == nil, @"应关闭已删除来源的数据库");
        Assert(TableCount(databaseURL, @"messages") == 0,
            @"删除来源应级联删除合成消息");
        Assert(TableCount(databaseURL, @"source_tombstones") == 1,
            @"删除来源应留下一个墓碑");

        NSURL *rebuiltURL = [base URLByAppendingPathComponent:
            @"history-preserved.staging.sqlite3"];
        status = RunRebuild(@[
            active.path, archived.path, rebuiltURL.path, service, databaseURL.path,
        ], &output);
        Assert(status == 0 && [output containsString:@"tombstones_preserved=1"]
            && [output containsString:@"tombstoned_sources=1"],
            [NSString stringWithFormat:@"重建应继承墓碑并跳过已删除来源：%@", output]);
        Assert(TableCount(rebuiltURL, @"messages") == 0,
            @"重建后已删除来源不得复活");
        Assert(TableCount(rebuiltURL, @"source_tombstones") == 1,
            @"重建后应保留来源墓碑");

        NSURL *invalidSource = [base URLByAppendingPathComponent:@"invalid.sqlite3"];
        Assert([@"not a sqlite database" writeToURL:invalidSource atomically:YES
            encoding:NSUTF8StringEncoding error:&error], @"应创建损坏墓碑来源夹具");
        NSURL *invalidDestination = [base URLByAppendingPathComponent:
            @"invalid-source.staging.sqlite3"];
        status = RunRebuild(@[
            active.path, archived.path, invalidDestination.path, service, invalidSource.path,
        ], &output);
        Assert(status == 1 && [output containsString:@"tombstone_source"]
            && ![fileManager fileExistsAtPath:invalidDestination.path],
            @"损坏墓碑来源必须失败关闭且不得创建 staging 数据库");

        NSURL *symlinkSource = [base URLByAppendingPathComponent:@"tombstones-link.sqlite3"];
        error = nil;
        Assert([fileManager createSymbolicLinkAtPath:symlinkSource.path
            withDestinationPath:databaseURL.path error:&error] && error == nil,
            @"应创建墓碑来源符号链接夹具");
        NSURL *symlinkDestination = [base URLByAppendingPathComponent:
            @"symlink-source.staging.sqlite3"];
        status = RunRebuild(@[
            active.path, archived.path, symlinkDestination.path, service, symlinkSource.path,
        ], &output);
        Assert(status == 1 && [output containsString:@"tombstone_source"]
            && ![fileManager fileExistsAtPath:symlinkDestination.path],
            @"墓碑来源符号链接必须失败关闭且不得创建 staging 数据库");

        status = RunRebuild(@[@"--delete-test-key",
            @"local.codex.prompt-assistant"], &output);
        Assert(status == 2, @"测试清理入口不得删除正式服务密钥");

        status = RunRebuild(@[@"--delete-test-key", service], &output);
        Assert(status == 0 && [output containsString:@"test_key_delete=true"],
            @"应由创建密钥的重建工具清理合成测试密钥");
        [fileManager removeItemAtURL:base error:nil];
        NSLog(@"PASS: CodexDataRebuildTests");
    }
    return 0;
}
