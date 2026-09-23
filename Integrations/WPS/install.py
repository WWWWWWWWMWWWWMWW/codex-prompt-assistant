"""Install only this local WPS add-in, preserving every existing entry."""
from pathlib import Path
import json, os, shutil, xml.etree.ElementTree as ET
base = Path.home() / 'Library/Containers/com.kingsoft.wpsoffice.mac/Data/.kingsoft/wps/jsaddons'
name, version = 'CodexPromptAssistantBridge', '1.0.0'
plugin = base / (name + '_' + version)
bridge = plugin / 'bridge'
bridge.mkdir(parents=True, exist_ok=True)
os.chmod(plugin, 0o700); os.chmod(bridge, 0o700)
source = Path(__file__).parent
(plugin / 'main.js').write_text('var CPA_BRIDGE_PATH = ' + json.dumps(str(bridge)) + ';\n' + (source/'main.js').read_text())
shutil.copy2(source/'ribbon.xml', plugin/'ribbon.xml')
config = base/'publish.xml'
if config.exists():
    tree = ET.parse(config)
    backup = base/'publish.xml.before-codex-bridge'
    if not backup.exists(): shutil.copy2(config, backup)
else:
    tree = ET.ElementTree(ET.Element('jsplugins'))
root = tree.getroot()
for child in list(root):
    if child.get('name') == name: root.remove(child)
ET.SubElement(root, 'jsplugin', {'name':name, 'version':version, 'type':'wps',
    'url':plugin.as_uri()+'/', 'enable':'enable', 'install':'null'})
temporary = config.with_suffix('.xml.tmp')
tree.write(temporary, encoding='utf-8', xml_declaration=True)
os.replace(temporary, config)
print('Installed local WPS add-in:', plugin)
print('WPS was not restarted. Host loading and live compatibility still require verification.')
