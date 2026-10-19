"""Guard the explicit product boundary: PicHarbor never deletes PhotoKit assets."""
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ExternalCleanupTests(unittest.TestCase):
    def test_native_sources_have_no_local_media_deletion_call(self):
        for path in (ROOT / 'Sources').rglob('*.swift'):
            source = path.read_text(encoding='utf-8')
            self.assertNotIn('PHAssetChangeRequest.deleteAssets', source, str(path))
            self.assertNotIn('PHAssetCollectionChangeRequest.deleteAssetCollections', source, str(path))
        model = (ROOT / 'Sources/Core/HarborModel.swift').read_text(encoding='utf-8')
        self.assertNotIn('func deleteVerified', model)
        self.assertNotIn('func verifyCleanup', model)

    def test_scheme_query_and_version_match_the_shipped_app(self):
        info = plistlib.loads((ROOT / 'Resources/Background.plist').read_bytes())
        self.assertIn('googlephotos', info['LSApplicationQueriesSchemes'])
        version = (ROOT / 'VERSION').read_text(encoding='utf-8').strip()
        self.assertIn('MARKETING_VERSION: "' + version + '"', (ROOT / 'project.yml').read_text(encoding='utf-8'))

if __name__ == '__main__': unittest.main()
