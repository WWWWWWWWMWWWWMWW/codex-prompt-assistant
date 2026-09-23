"""Build personal online edition with truthful source snapshot identity.
Does not relax the clean-only generic updater. Native installation accepts only
exact signed manifests and one approved previous version.
"""
import json
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'Tools/Release'))
from prepare_update import inspect, copy_bundle, sha256, tree_digest, verify_signature

VERSION = '0.3.5'
SOURCE = ROOT/'build/CodexPromptAssistantPOC.app'
PREVIOUS = ROOT/'.build/default-scopes-package-20260917/image/安装续言.app/Contents/Resources/CodexPromptAssistantPOC.app'
BUILD = ROOT/'.build/feishu-browser-package-20260917'
OUTPUT = ROOT/f'outputs/续言-{VERSION}-macOS-arm64'
README = '''续言 0.3.5 — 飞书网页版支持版（个人安装包）

适用：Apple 芯片 Mac，macOS 15 或更新版本。

安装
1. 已安装旧版时，先从菜单栏退出续言。不要退出 Codex 或本地模型。
2. 双击“安装续言”，填写 sapi-ai.hortorgames.com 服务的 API Key（必填）。
   服务地址固定为 https://sapi-ai.hortorgames.com/v1，其他供应商的 Key 不通用。
3. 点“安装并打开”，安装到 ~/Applications，无需管理员密码。
4. 首次使用允许辅助功能。首次安装默认开启在线续写，并勾选 Codex 和 WorkBuddy；可在设置中调整。
安装后关闭安装器并推出磁盘映像。Key 加密保存在本机，不放进安装包或日志。
填写 Key 只检查格式和保存，不代表服务已验证有效或有可用额度。

设置只有三组
在线续写开关；API Key；使用范围（多选）。不再提供本地模型、历史导入、模型选择或高级设置。
此版不会调用本地模型、检索历史表达或自动扫描历史；已有模型服务和旧配置文件保留。

使用范围如何生效
首次安装只默认勾选 Codex 和 WorkBuddy，其他应用不勾选。
从 0.3.3 升级保留已有选择，仅为尚未配置的 Codex 和 WorkBuddy 补上默认勾选；手动取消的选择在重启、重装和升级时均保留。
勾选立即保存，重启后仍保留。可选项固定为：便笺、终端、文本编辑、无边记、飞书、WPS Office、Codex、WorkBuddy、CodeBuddy、微信。
飞书一项同时授权客户端与浏览器中的飞书文档，不需要选择整个浏览器或新增设置。
例如同时勾选 Codex 和文本编辑：在任一应用当前输入框中都可续写；其他应用不能触发。
只处理当前前台输入，不会把多个应用的文本合并。
Codex 和 WorkBuddy 沿用各自当前任务中可识别的上下文，其他应用仅用当前输入框内容。
勾选表示允许将该范围内的输入及适用的当前任务上下文发送到上述在线服务。
普通应用按 bundle ID 匹配。飞书网页版仅限 HTTPS 的单层租户域名 *.feishu.cn 下 /docx/、/docs/、/wiki/ 的文档链接；只读取当前文档的输入位置，未知网址、登录页、地址栏和搜索框不生效。
没有添加其他网站的入口；旧版已选的其他应用和网站不触发续写。
取消勾选立即清除候选、取消请求；已发到服务端的内容无法撤回，迟到结果不会再显示或插入。
全部取消或关闭在线续写则停止续写。密码、搜索框、地址栏及其他敏感位置仍受保护。
选中不代表所有输入控件均受支持，仍需要可识别的普通输入框和辅助功能权限。
灰字出现后 Tab 接受、Esc 忽略，不会自动发送。

本版变更
新增 Chrome 中的飞书文档续写，沿用“飞书（含网页版）”勾选及中间插入能力；其他浏览器兼容性尚未实机验收。
取消“飞书”会同时停止客户端和网页候选。切换文档、标签页或网站会使旧候选失效，避免插入到别的页面。
真实 Chrome 文档已验证正文/光标读取（只读）；新版真实联网提示和实体 Tab 尚未验收。
支持在光标后已有文字时生成插入内容，同时参考前文与后文；Tab 只插入新增内容，后文原样保留，不自动发送。
例如“请说明|的原因。”可以提示“接口超时”，接受后为“请说明接口超时的原因。”。
移除旧版“光标必须在全文末尾”的在线续写限制；选中文字、输入法组词、未闭合引号/代码和不确定焦点仍不触发。
候选会检查是否重复后文；请求期间移动光标或修改前后文，旧候选失效。模型仍可能返回空，不保证每次出现提示。
飞书改用与光标相同的文本坐标读取正文，避免表格/图片的 AX 展示文本导致位置偏移；聊天占位提示不参与生成。
若飞书无法提供一致的正文/光标，则停止本次候选，避免误插。没有可靠光标矩形时沿用输入区域提示条。
保留现有前文最多 2000 个 UTF-16 单元的请求门槛；后文发送脱敏后的前 2000 个单元，完整后文参与候选身份和接受校验。
设置仍只有在线续写、Key、多选范围；十项列表无 App Store，Codex 和 WorkBuddy 安装默认选择规则不变。
离线回放已验证中间插入和过期候选保护；真实飞书客户端和 Chrome 正文的读取/坐标样本已核对。新版真实联网浮层与实体 Tab 尚未验收。

升级与回退
支持已交付的精确 0.3.3 安装包升级及完全相同的 0.3.5 重装。
旧版有任何文件变化或其他版本均拒绝覆盖。运行中禁止安装，避免 Key 缓存或文件版本不一致。
升级前原应用保留到 ~/Applications/.cpa-upgrade-backup-随机编号/CodexPromptAssistantPOC.app。
回退：退出续言，保留新版副本，再将该备份应用移回 ~/Applications/ 原位置。
Key 输入会替换旧 Key；回退应用不会回退 Key 或使用范围勾选。
不新增或修改 LaunchAgent，不启停 Codex 或本地模型。

系统安全提示
本包为本地 ad-hoc 签名，未使用 Developer ID 或 Apple 公证。
若 macOS 提示无法确认开发者，确认来源后在“系统设置 → 隐私与安全性”允许打开。
安装器和续言可能各需确认一次。不需要关闭 Gatekeeper。

验证边界
离线自动化覆盖三项设置、多范围策略、旧候选失效、Key 必填与加密保存、安装与精确版本升级。
真实服务 Key、全新 macOS 用户授权、其他电脑与各宿主输入法仍需使用中确认。
这是未提交工作区构建；保留真实 Git/dirty 标记，并附源码快照及哈希。非公开稳定发行。
'''

def run(args, log):
    with log.open('ab') as stream:
        subprocess.run(args, cwd=ROOT, check=True, stdout=stream, stderr=subprocess.STDOUT)

def personal_identity(bundle, version=VERSION):
    before = tree_digest(bundle)
    info = plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'local.codex.prompt-assistant-poc'
    assert info['CFBundleShortVersionString'] == version
    assert isinstance(info['CPABuildMetadata']['WorktreeDirty'], bool)
    verify_signature(bundle)
    assert tree_digest(bundle) == before
    return {'build':info['CPABuildMetadata'], 'executableSHA256':sha256(bundle/'Contents/MacOS/CodexPromptAssistantPOC'), 'treeSHA256':before}

def manifest(bundle):
    rows = []
    for path in [bundle, *sorted(bundle.rglob('*'))]:
        mode = path.lstat().st_mode
        assert stat.S_ISDIR(mode) or stat.S_ISREG(mode)
        row = {'path':str(path.relative_to(bundle)), 'type':'directory' if path.is_dir() else 'file', 'mode':stat.S_IMODE(mode)}
        if path.is_file(): row['sha256'] = sha256(path)
        rows.append(row)
    return rows

def source_files():
    # Explicit code/resource roots; never archive .build, output, preferences or logs.
    extensions = {'.m','.h','.py','.plist','.strings','.icns','.png','.sh','.inc'}
    files = [ROOT/'Makefile', ROOT/'AGENTS.md']
    for directory in ('Sources','Resources','Tests','Tools'):
        files.extend(p for p in (ROOT/directory).rglob('*') if p.is_file()
            and p.suffix in extensions and '__pycache__' not in p.parts)
    return sorted(files)

def main():
    old = personal_identity(PREVIOUS, '0.3.3')
    assert old['executableSHA256'] == '1fa7af4ee95edaa10d48ce78f3a0de8aabcfa6e2e4faceee0d0e7cc739a568af'
    assert old['treeSHA256'] == '35a929e5a1c42539ab4d8be7af78b42258cd6780bd945f0c6675f0481ac8ac60'
    BUILD.mkdir(exist_ok=True); OUTPUT.mkdir(exist_ok=False)
    files = source_files(); hashes = {str(p.relative_to(ROOT)):sha256(p) for p in files}
    run(['make','app'], BUILD/'app-build.log')
    identity = personal_identity(SOURCE)
    image = BUILD/'image'; image.mkdir(exist_ok=False)
    installer = image/'安装续言.app'; contents = installer/'Contents'; resources = contents/'Resources'
    resources.mkdir(parents=True); (contents/'MacOS').mkdir()
    payload = resources/SOURCE.name; copy_bundle(SOURCE,payload); assert personal_identity(payload) == identity
    (resources/'payload-manifest.json').write_text(json.dumps(manifest(payload),ensure_ascii=False,indent=2)+'\n')
    (resources/'previous-manifest.json').write_text(json.dumps(manifest(PREVIOUS),ensure_ascii=False,indent=2)+'\n')
    shutil.copyfile(SOURCE/'Contents/Resources/AppIcon.icns',resources/'AppIcon.icns')
    info = {'CFBundleIdentifier':'local.codex.prompt-assistant-installer','CFBundleName':'安装续言',
        'CFBundleDisplayName':'安装续言','CFBundleExecutable':'Installer','CFBundlePackageType':'APPL',
        'CFBundleVersion':'8','CFBundleShortVersionString':VERSION,'CFBundleIconFile':'AppIcon',
        'LSMinimumSystemVersion':'15.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication',
        'CPAPackagingSourceSHA256':sha256(ROOT/'Tools/Packaging/Installer.m')}
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    run(['clang','-arch','arm64','-mmacosx-version-min=15.0','-fobjc-arc','-fmodules','-Wall','-Wextra','-Werror',
        '-framework','AppKit','-framework','Security',str(ROOT/'Tools/Packaging/Installer.m'),
        *[str(ROOT/'Sources/CodexDataCore'/name) for name in ('RemoteAPIKeyFileStore.m','MasterKeyFileStore.m','MessageCrypto.m')],
        '-o',str(contents/'MacOS/Installer')], BUILD/'build.log')
    run(['/usr/bin/codesign','--force','--sign','-','--identifier','local.codex.prompt-assistant-installer',str(installer)],BUILD/'build.log')
    run(['/usr/bin/codesign','--verify','--deep','--strict','--verbose=2',str(installer)],BUILD/'build.log')
    assert personal_identity(payload) == identity
    run([sys.executable,str(ROOT/'Tools/Testing/run_isolated.py'),str(contents/'MacOS/Installer'),'--self-test',str(PREVIOUS)],BUILD/'installer-tests.log')
    assert hashes == {str(p.relative_to(ROOT)):sha256(p) for p in source_files()}, 'sources changed during build'
    archive = OUTPUT/'源码快照.tar.gz'
    with tarfile.open(archive,'w:gz') as tar:
        for path in files: tar.add(path,arcname=str(path.relative_to(ROOT)),recursive=False)
    (OUTPUT/'源码文件哈希.json').write_text(json.dumps(hashes,ensure_ascii=False,indent=2)+'\n')
    (image/'先读我.txt').write_text(README); (OUTPUT/'安装说明.txt').write_text(README)
    dmg = OUTPUT/f'续言-{VERSION}-Apple芯片.dmg'
    run(['/usr/bin/hdiutil','create','-volname',f'续言 {VERSION}','-srcfolder',str(image),'-format','UDZO',str(dmg)],BUILD/'dmg-build.log')
    (OUTPUT/'SHA256.txt').write_text(sha256(dmg)+'  '+dmg.name+'\n'+sha256(archive)+'  '+archive.name+'\n')
    record = {'scope':'personal-installable-online-edition','dmg':str(dmg),'dmgSHA256':sha256(dmg),'payload':identity,
        'previousPayload':old,'sourceArchiveSHA256':sha256(archive),'installerSourceSHA256':sha256(ROOT/'Tools/Packaging/Installer.m'),
        'builderSHA256':sha256(Path(__file__)),'architecture':'arm64','minimumOS':'15.0','developerIDSigned':False,
        'notarized':False,'bundlesCredentials':False,'installsLaunchAgent':False,'installerSelfTestsPassed':True,
        'cleanUserAuthorizationVerified':False,'liveCandidateTabVerified':False}
    (OUTPUT/'交付清单.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'dmg':str(dmg),'bytes':dmg.stat().st_size,'sha256':record['dmgSHA256']},ensure_ascii=False))

if __name__ == '__main__': main()
