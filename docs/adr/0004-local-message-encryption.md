# ADR-0004：本地消息加密

## 状态

部分替代（2026-09-08 补记）：主密钥“只在 Keychain”条款已由 [ADR-0006](0006-local-master-key-file-for-background-scan.md) 的文件保管替代；其余加密原则保留。现行装配见 [ADR-0007](0007-m0-current-baseline.md)。

已接受（2026-08-20 通过本机技术验证）

## 背景

Codex 和 ChatGPT 历史可能包含 API Key、密码、私人联系方式和未公开业务内容。数据库需要支持本地学习与重建，但不能把完整聊天以明文写入 SQLite，也不能把主密钥写入源码、配置、数据库或日志。

本机现场能力：

- 系统 SQLite 支持 FTS5，但没有可直接使用的 SQLCipher 可执行文件或公共加密接口。
- FileVault 已开启，只能作为整盘丢失场景的额外保护，不能替代应用级密钥隔离。
- 公共 SDK 提供 CommonCrypto AES-CBC、HMAC-SHA256、`SecRandomCopyBytes` 和 macOS Keychain；未提供本项目可直接依赖的公共 AES-GCM 接口。

## 决策

- 使用 64 字节随机主密钥：前 32 字节为 AES-256 密钥，后 32 字节为 HMAC-SHA256 密钥。
- 主密钥只保存为 macOS Keychain generic password，属性为 `AfterFirstUnlockThisDeviceOnly`，不允许 iCloud 同步。
- 消息正文使用 Encrypt-then-MAC 信封：`CPA1 | 16-byte random IV | AES-256-CBC-PKCS7 ciphertext | HMAC-SHA256`。
- HMAC 覆盖版本、IV 和密文；解密前使用恒定时间比较验证 HMAC。错误密钥、篡改、未知版本和损坏长度都返回同一类泛化错误。
- 每次加密使用独立随机 IV；同一明文重复加密不得产生相同信封。
- SQLite 只保存加密正文和必要元数据。完整脱敏正文也不进入明文 FTS；后续派生表达必须先脱敏，只保留重建所需来源关系。
- 日志只记录长度、类型计数、状态和耗时，不记录主密钥、IV、密文、原文或解密错误细节。

## 验证证据

- 自动测试通过：正确密钥往返、随机 IV、错误密钥失败、单字节篡改失败、随机 64 字节主密钥、钥匙串写入／读取／删除。
- 跨进程探针通过：独立 `create`、`verify`、`delete` 进程依次输出 `true`，只报告密钥长度，不输出密钥内容。
- 临时测试钥匙串项使用随机 service 名并在验证后删除。

## 安全边界

- 该方案保护数据库文件单独泄露，不防御用户会话已解锁且恶意进程拥有同等钥匙串访问权限的场景。
- 主密钥丢失时不提供后门恢复；数据库应从只读聊天源和最近导出包重建。
- 未来若引入经过审计的 SQLCipher 或系统公开 AEAD API，必须通过迁移与兼容测试后另写 ADR，不能静默改变信封格式。

## 被拒绝方案

- 仅依赖 FileVault：缺少应用级密钥边界，拒绝作为唯一保护。
- 自行复制非公开 CommonCrypto GCM SPI：升级与审核风险高，拒绝。
- 为第一版新增大型第三方密码库：供应链和分发成本高，当前已验证方案足够，暂不引入。
