"""Offline resource coverage and placeholder safety, without conversion tools."""
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

def table(language):
    result = {}
    for line in (ROOT / 'Resources' / (language + '.lproj') / 'Localizable.strings').read_text(encoding='utf-8').splitlines():
        key, value = line[:-1].split(' = ', 1)
        key, value = json.loads(key), json.loads(value)
        if key in result: raise ValueError('Duplicate key')
        result[key] = value
    return result

class LocalizationTests(unittest.TestCase):
    def test_all_languages_cover_the_same_keys_and_preserve_arguments(self):
        base = table('zh-Hans')
        self.assertGreaterEqual(len(base), 480)
        for language in ['en', 'zh-Hant-HK', 'yue-Hant-HK']:
            translated = table(language)
            self.assertEqual(base.keys(), translated.keys())
            for key, value in translated.items():
                self.assertEqual(sorted(re.findall(r'\{\d+\}', key)), sorted(re.findall(r'\{\d+\}', value)), key)
                self.assertTrue(value)
                if language == 'en': self.assertFalse(re.search('[\u3400-\u9fff]', value), key)
        self.assertEqual(table('zh-Hant-HK')['照片'], '相片')
        self.assertIn('唔會', table('zh-Hant-HK')['切换方式只影响新任务，已有照片不会自动重新上传。'])

    def test_user_visible_swift_literals_use_translation_lookup(self):
        spec = importlib.util.spec_from_file_location('localize_swift', ROOT / 'tools/localize_swift.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        known, unwrapped = table('zh-Hans'), set()
        for path in (ROOT / 'Sources').rglob('*.swift'):
            if path.name == 'Localization.swift': continue
            source = path.read_text(encoding='utf-8')
            module.transform(source, unwrapped)
            for match in re.finditer(r'L10n\.text\(("(?:\\.|[^"\\])*")', source):
                self.assertIn(json.loads(match.group(1)), known, str(path))
        self.assertEqual(unwrapped, set())

    def test_privacy_prompts_and_message_index_are_packaged(self):
        for language in ['zh-Hans', 'en', 'zh-Hant-HK', 'yue-Hant-HK']:
            self.assertIn('NSPhotoLibraryUsageDescription', (ROOT / 'Resources' / (language + '.lproj') / 'InfoPlist.strings').read_text(encoding='utf-8'))
        index = json.loads((ROOT / 'Resources/MessageKeys.json').read_text(encoding='utf-8'))
        self.assertEqual(set(index), table('zh-Hans').keys())
