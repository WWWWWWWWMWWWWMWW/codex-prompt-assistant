"""Read-only local-model artifact checks. Never execute the runtime or fetch weights."""
import argparse
import json
import os
from pathlib import Path
import re

from model_agent import configuration

MAX_METADATA_BYTES = 4 * 1024 * 1024


def read_small(path):
    if not path.is_file():
        raise ValueError('metadata_not_regular_file')
    with path.open('rb') as stream:
        data = stream.read(MAX_METADATA_BYTES + 1)
    if len(data) > MAX_METADATA_BYTES:
        raise ValueError('metadata_too_large')
    return data.decode('utf-8')


def executable(path):
    return path.is_file() and os.access(path, os.X_OK)


def launcher_python(header):
    lines = header.splitlines()
    if not lines:
        return None
    # Known pip entrypoint forms; unknown shell source is never evaluated.
    if lines[0] == '#!/bin/sh' and len(lines) > 2 and lines[2] == "' '''":
        match = re.fullmatch(r"'''exec' \"([^\"\n]+)\" \"\$0\" \"\$@\"", lines[1])
        return Path(match[1]) if match else None
    if re.fullmatch(r'#!/[^\s]+/python(?:3(?:\.\d+)?)?', lines[0]):
        return Path(lines[0][2:])
    return None


def inspect(user_home):
    config = configuration(user_home)
    checks = []

    def check(key, passed, message, next_step=''):
        checks.append({'id': key, 'status': 'pass' if passed else 'blocked',
                       'message': message if passed else '检查未通过。',
                       'nextStep': '' if passed else next_step})

    entry = Path(config['ProgramArguments'][0])
    runtime = entry.parent.parent
    check('launcher', executable(entry), '模型启动程序存在且可执行。',
          '先为目标用户安装模型运行环境；仅复制启动配置不会安装模型。')
    python = runtime / 'bin/python'
    try:
        interpreter = launcher_python(read_small(entry)) if executable(entry) else None
        # A copied venv must point to its own launcher, not a still-existing old user's venv.
        matched = interpreter is not None and interpreter.is_absolute() and interpreter == python
        check('launcher_interpreter', matched, '启动脚本指向目标用户的 Python。',
              '在目标目录重新创建运行环境；不要直接复制旧用户的虚拟环境。')
    except (OSError, ValueError, UnicodeError):
        check('launcher_interpreter', False, '无法识别或读取启动脚本。', '重新准备受支持的 Python 运行环境。')
    check('python', executable(python), 'Python 解释器存在且可执行。',
          '安装或修复目标机器的 Python；原机器的 Homebrew 路径不能直接复用。')

    model = config['ProgramArguments'][config['ProgramArguments'].index('--model') + 1]
    cache = Path(config['EnvironmentVariables']['HF_HOME']) / 'hub' / ('models--' + model.replace('/', '--'))
    revision = None
    try:
        revision = read_small(cache / 'refs/main').strip()
        if not re.fullmatch(r'[0-9a-f]{40}', revision):
            raise ValueError('invalid_revision')
    except (OSError, ValueError, UnicodeError):
        revision = None
    check('cache_revision', revision is not None, '默认模型的 main 缓存版本可识别。',
          '准备默认模型缓存及明确版本；检查过程不会联网下载。')
    weight_files = []
    weight_bytes = 0
    if revision:
        snapshot = cache / 'snapshots' / revision

        def cached_file(name):
            path = snapshot / name
            # HF cache links normally resolve into this model repository's blobs.
            return (path.resolve().is_relative_to(cache.resolve())
                    and path.is_file() and path.stat().st_size > 0)

        try:
            required = ['config.json', 'tokenizer.json', 'tokenizer_config.json']
            valid = all(cached_file(name) for name in required)
            if valid:
                valid = all(isinstance(json.loads(read_small(snapshot / name)), dict)
                            for name in ('config.json', 'tokenizer_config.json'))
            check('model_metadata', valid, '默认模型的配置与 tokenizer 文件存在。',
                  '补齐默认模型的配置和 tokenizer 文件，保留当前可用服务。')
            index = snapshot / 'model.safetensors.index.json'
            if index.exists() or index.is_symlink():
                if not cached_file(index.name):
                    raise ValueError('invalid_index')
                weight_map = json.loads(read_small(index)).get('weight_map')
                if not isinstance(weight_map, dict) or not weight_map:
                    raise ValueError('empty_weight_map')
                values = list(weight_map.values())
                if any(not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_.-]+\.safetensors', name)
                       for name in values):
                    raise ValueError('invalid_weight_path')
                weight_files = sorted(set(values))
            else:
                weight_files = ['model.safetensors']
            complete = all(cached_file(name) for name in weight_files)
            if complete:
                weight_bytes = sum((snapshot / name).stat().st_size for name in weight_files)
            check('weight_files', complete, '索引引用的权重文件存在且非空。',
                  '补齐缺失权重分片；不要把下载中的文件当作完整模型。')
        except (OSError, ValueError, UnicodeError, AttributeError, RuntimeError):
            check('cache_inspection', False, '模型缓存结构无法完整核对。',
                  '核对模型索引、文件链接和读取权限后重试。')

    return {'scope': 'read-only-artifacts', 'artifactChecksPassed': all(c['status'] == 'pass' for c in checks),
            'runtimeVerified': False, 'model': model, 'cacheRevision': revision,
            'weightFileCount': len(weight_files), 'weightBytes': weight_bytes,
            'pythonResolvedPath': str(python.resolve()), 'checks': checks,
            'notVerified': ['Python 模块与原生库加载', '权重内容及校验和', '端口与服务归属',
                            '模型加载与实际生成', '新用户权限与宿主插入'],
            'note': '文件检查不证明运行可用。未执行解释器、加载模型、联网或修改设置。'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, default=Path.home(), help='目标用户目录（默认当前用户）')
    parser.add_argument('--json', action='store_true', help='输出结构化检查报告')
    args = parser.parse_args()
    try:
        result = inspect(args.home)
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f'无法检查目标目录：{error}\n')
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print('文件检查通过，实际运行仍需验证。' if result['artifactChecksPassed'] else '文件检查发现缺失或不匹配：')
        for item in result['checks']:
            if item['status'] != 'pass':
                print(f"- {item['id']}：{item['nextStep']}")
        print(result['note'])
    return 0 if result['artifactChecksPassed'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
