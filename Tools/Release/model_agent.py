"""Prepare a user-specific model LaunchAgent; never run launchctl or download models."""
import argparse
import os
from pathlib import Path
import plistlib
import tempfile

LABEL = 'local.codex.prompt-assistant-model'
TEMPLATE = Path(__file__).resolve().parents[2] / 'Resources' / (LABEL + '.plist')
HOME_TOKEN = '${CPA_USER_HOME}'


def configuration(user_home):
    user_home = Path(user_home)
    if not user_home.is_absolute() or not user_home.is_dir():
        raise ValueError('目标用户目录必须是已存在的绝对路径。')
    home = str(user_home)
    if any(c in home for c in ('\n', '\r', '\x00')):
        raise ValueError('目标用户目录含不支持的控制字符。')
    config = plistlib.loads(TEMPLATE.read_bytes())
    if config['Label'] != LABEL:
        raise ValueError('模型服务标识不匹配。')
    # Replace decoded string values, never XML or shell source.
    def expand(value):
        if isinstance(value, str):
            return value.replace(HOME_TOKEN, home)
        if isinstance(value, list):
            return [expand(item) for item in value]
        if isinstance(value, dict):
            return {key: expand(item) for key, item in value.items()}
        return value
    return expand(config)


def prepare(user_home, output):
    config = configuration(user_home)
    runtime = Path(config['ProgramArguments'][0])
    if not runtime.is_file() or not os.access(runtime, os.X_OK):
        raise ValueError('未找到可执行的本机模型运行程序；请先准备 mlx-runtime/bin/mlx_lm.server。未写入启动配置。')
    output = Path(output)
    if output.is_symlink():
        raise ValueError('目标配置是符号链接，已保留原文件。')
    if output.exists():
        try:
            matches = plistlib.loads(output.read_bytes()) == config
        except (OSError, ValueError, plistlib.InvalidFileException):
            matches = False
        if not matches:
            raise ValueError('已有不同的启动配置，已保留原文件。请先单独准备并审查迁移。')
        return 'unchanged'
    # Runtime validation happens before creating any destination directories.
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(plistlib.dumps(config, sort_keys=False))
            stream.flush()
            os.fsync(stream.fileno())
        # Exclusive publication: no truncation or replacement if another writer wins.
        os.link(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink()
    return 'prepared'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    stage = sub.add_parser('prepare', help='生成可审查的配置，不加载服务')
    stage.add_argument('--home', type=Path, required=True)
    stage.add_argument('--output', type=Path, required=True)
    sub.add_parser('install', help='仅写入当前用户配置；保留已有不同配置，不加载服务')
    args = parser.parse_args()
    user_home = args.home if args.command == 'prepare' else Path.home()
    output = args.output if args.command == 'prepare' else user_home / 'Library/LaunchAgents' / (LABEL + '.plist')
    try:
        result = prepare(user_home, output)
    except (OSError, ValueError) as error:
        parser.exit(1, str(error) + '\n')
    print(f'{result}: {output}')
    print('仅核对运行程序存在；未验证权重缓存、模型加载、端口或生成能力。未启动服务。')


if __name__ == '__main__':
    main()
