#!/usr/bin/env python3
"""Verify that the standalone frontend cannot compile the legacy hardware owner."""
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
project = json.loads(subprocess.check_output([
    'plutil', '-convert', 'json', '-o', '-', str(root / 'AhaKey Studio.xcodeproj/project.pbxproj'),
]))
objects = project['objects']
target = next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'Studio Frontend')
sources = list((root / 'StudioFrontend').rglob('*.swift'))
assert len(sources) > 0
for phase_id in target['buildPhases']:
    phase = objects[phase_id]
    assert phase['isa'] != 'PBXCopyFilesBuildPhase', 'Frontend must not embed the old Agent or flasher'
    if phase['isa'] == 'PBXSourcesBuildPhase':
        sources += [root / objects[objects[file_id]['fileRef']]['path'] for file_id in phase['files']]
for dependency in target['dependencies']:
    name = objects[objects[dependency]['target']]['name']
    assert name == 'VibeBar', f'Unexpected frontend dependency: {name}'
for path in sources:
    text = path.read_text()
    assert not re.search(r'\b(import CoreBluetooth|AhaKeyBLEManager|AgentManager|AhaKeyCommand|AhaKeyResponseParser|OLEDFrameEncoder)\b|\bProcess\(', text), f'Hardware owner leaked into {path}'
print(f'Frontend boundary verified across {len(sources)} Swift files.')
