#!/usr/bin/env python3
"""Dependency-free structural checks, usable on Linux and macOS (not a build)."""
import json
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent


def parse_openstep(text):
    tokens = re.findall(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', text, re.S)
    tokens = [t for t in tokens if not t.startswith(('//', '/*'))]
    position = 0

    def consume(expected=None):
        nonlocal position
        if position >= len(tokens):
            raise ValueError('Unexpected end of project')
        token = tokens[position]
        position += 1
        if expected is not None and token != expected:
            raise ValueError(f'Expected {expected!r}, got {token!r}')
        return token

    def value():
        token = consume()
        if token == '{':
            result = {}
            while tokens[position] != '}':
                key = value()
                consume('=')
                if key in result:
                    raise ValueError(f'Duplicate key: {key}')
                result[key] = value()
                consume(';')
            consume('}')
            return result
        if token == '(':
            result = []
            while tokens[position] != ')':
                result.append(value())
                if tokens[position] != ')':
                    consume(',')
            consume(')')
            return result
        return json.loads(token) if token.startswith('"') else token

    result = value()
    if position != len(tokens):
        raise ValueError('Trailing tokens in project')
    return result


def check():
    project = parse_openstep((ROOT / 'machoview.xcodeproj/project.pbxproj').read_text())
    objects = project['objects']
    target = objects['8D1107260486CEB800E47090']
    source_paths = []
    for phase_id in target['buildPhases']:
        phase = objects[phase_id]
        for build_id in phase.get('files', []):
            reference = objects[objects[build_id]['fileRef']]
            if phase['isa'] == 'PBXSourcesBuildPhase':
                path = reference['path']
                assert (ROOT / path).is_file(), f'Missing source: {path}'
                source_paths.append(path)
            assert reference.get('path') not in ('libdisasm.a', 'lib/libLTO.dylib'), 'Intel-only legacy binary in build'
    assert len(source_paths) == len(set(source_paths)), 'Duplicate source compilation'
    c_sources = {p.name for p in (ROOT / 'otool_disasm').glob('*.c')} - {'symbol.c'}
    built_c_sources = {Path(p).name for p in source_paths if p.endswith('.c')}
    assert c_sources == built_c_sources, f'Disassembler source mismatch: {c_sources ^ built_c_sources}'
    assert 'tests/data-controller-tests.mm' in source_paths
    for obj in objects.values():
        if obj['isa'] != 'XCBuildConfiguration':
            continue
        settings = obj['buildSettings']
        assert 'VALID_ARCHS' not in settings, 'Obsolete VALID_ARCHS overrides Apple Silicon'
        assert '$(SRCROOT)' not in settings.get('HEADER_SEARCH_PATHS', []), 'Legacy headers shadow SDK'
        if 'SDKROOT' in settings:
            assert settings['SDKROOT'] == 'macosx'
            assert settings['ARCHS'] == '$(ARCHS_STANDARD)'
            assert float(settings['MACOSX_DEPLOYMENT_TARGET']) >= 15
    scheme = ET.parse(ROOT / 'machoview.xcodeproj/xcshareddata/xcschemes/MachOView.xcscheme')
    for reference in scheme.iter('BuildableReference'):
        assert reference.attrib['BlueprintIdentifier'] in objects
    with (ROOT / 'Info.plist').open('rb') as file:
        info = plistlib.load(file)
    assert info['CFBundleVersion'] == '$(CURRENT_PROJECT_VERSION)'
    assert info['CFBundleShortVersionString'] == '$(MARKETING_VERSION)'
    for xib in (ROOT / 'English.lproj').glob('*.xib'):
        ET.parse(xib)
    print(f'PASS: project graph, {len(source_paths)} sources, shared scheme, plist and XIB XML')


if __name__ == '__main__':
    check()
